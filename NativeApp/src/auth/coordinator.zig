const std = @import("std");
const callback = @import("callback.zig");
const config = @import("config.zig");
const pkce = @import("pkce.zig");
const session = @import("session.zig");
const text = @import("../domain/text.zig");

pub const max_client_id_bytes: usize = 512;
pub const max_client_secret_bytes: usize = 512;
pub const max_authorization_url_bytes: usize = 4096;
pub const max_http_body_bytes: usize = 64 * 1024;
const default_authorization_timeout = std.Io.Clock.Duration{ .raw = std.Io.Duration.fromSeconds(300), .clock = .awake };

pub const Wake = struct {
    context: *anyopaque,
    call_fn: *const fn (*anyopaque) void,

    pub fn call(self: Wake) void {
        self.call_fn(self.context);
    }
};

pub const BeginOptions = struct {
    provider: config.ProviderConfig,
    client_id: []const u8,
    client_secret: ?[]const u8 = null,
    wake: Wake,
};

pub const Success = struct {
    provider: config.ProviderConfig,
    profile: session.Profile,
    auth: session.Session,
    client_id: text.Text(max_client_id_bytes),
    client_secret: text.Text(max_client_secret_bytes),
};

pub const Completion = union(enum) {
    success: Success,
    failed: text.Text(96),
};

/// One-at-a-time desktop OAuth coordinator. It binds only an ephemeral IPv4
/// loopback socket, uses authorization-code + PKCE S256, and performs token and
/// profile traffic off the Native SDK loop thread.
pub const Coordinator = struct {
    allocator: std.mem.Allocator,
    threaded: ?*std.Io.Threaded = null,
    listener: ?std.Io.net.Server = null,
    future: ?std.Io.Future(void) = null,
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    completion: Completion = undefined,
    provider: config.ProviderConfig = config.gmail,
    client_id: text.Text(max_client_id_bytes) = .{},
    client_secret: text.Text(max_client_secret_bytes) = .{},
    material: pkce.Material = undefined,
    redirect_uri: text.Text(256) = .{},
    authorization_url: text.Text(max_authorization_url_bytes) = .{},
    authorization_timeout: std.Io.Clock.Duration = default_authorization_timeout,
    wake: Wake = undefined,

    pub fn init(allocator: std.mem.Allocator) Coordinator {
        return .{ .allocator = allocator };
    }

    pub fn active(self: *const Coordinator) bool {
        return self.future != null;
    }

    /// Starts listening before returning the browser URL so an immediate
    /// redirect can never race the callback socket.
    pub fn begin(self: *Coordinator, options: BeginOptions) ![]const u8 {
        if (self.active()) return error.AuthorizationInProgress;
        if (options.client_id.len == 0 or options.client_id.len > max_client_id_bytes) return error.InvalidClientId;
        if (options.client_secret) |secret_value| if (secret_value.len > max_client_secret_bytes) return error.InvalidClientSecret;

        const threaded = try self.allocator.create(std.Io.Threaded);
        errdefer self.allocator.destroy(threaded);
        threaded.* = std.Io.Threaded.init(self.allocator, .{});
        errdefer threaded.deinit();
        const io = threaded.io();
        const listener = try bindLoopback(&options.provider, io);
        errdefer {
            var closing = listener;
            closing.deinit(io);
        }

        self.provider = options.provider;
        self.client_id.set(options.client_id);
        self.client_secret.set(options.client_secret orelse "");
        self.material = pkce.generate(io);
        self.wake = options.wake;
        self.ready.store(false, .release);
        var redirect_buffer: [256]u8 = undefined;
        const redirect = try std.fmt.bufPrint(&redirect_buffer, "http://{s}:{d}{s}", .{ redirectHost(&self.provider), listener.socket.address.getPort(), self.provider.loopback_path });
        self.redirect_uri.set(redirect);
        var auth_buffer: [max_authorization_url_bytes]u8 = undefined;
        self.authorization_url.set(try pkce.authorizationUrl(&auth_buffer, &self.provider, self.client_id.slice(), self.redirect_uri.slice(), &self.material));
        self.threaded = threaded;
        self.listener = listener;
        self.future = try std.Io.concurrent(io, workerMain, .{self});
        return self.authorization_url.slice();
    }

    pub fn takeCompletion(self: *Coordinator) ?Completion {
        if (!self.ready.load(.acquire)) return null;
        self.finishWorker();
        self.ready.store(false, .release);
        const completion = self.completion;
        std.crypto.secureZero(u8, std.mem.asBytes(&self.completion));
        return completion;
    }

    pub fn cancel(self: *Coordinator) void {
        if (self.future) |*future| {
            const threaded = self.threaded orelse return;
            const io = threaded.io();
            future.cancel(io);
        }
        self.finishWorker();
        std.crypto.secureZero(u8, std.mem.asBytes(&self.completion));
    }

    pub fn deinit(self: *Coordinator) void {
        self.cancel();
    }

    fn finishWorker(self: *Coordinator) void {
        const threaded = self.threaded orelse return;
        const io = threaded.io();
        if (self.future) |*future| future.await(io);
        self.future = null;
        if (self.listener) |*listener| listener.deinit(io);
        self.listener = null;
        threaded.deinit();
        self.allocator.destroy(threaded);
        self.threaded = null;
        std.crypto.secureZero(u8, std.mem.asBytes(&self.client_secret));
        std.crypto.secureZero(u8, std.mem.asBytes(&self.material));
    }

    fn workerMain(self: *Coordinator) void {
        const Race = union(enum) { completion: Completion, timeout: void };
        var results: [2]Race = undefined;
        defer std.crypto.secureZero(u8, std.mem.asBytes(&results));
        var race = std.Io.Select(Race).init(self.threaded.?.io(), &results);
        race.concurrent(.completion, runCompletion, .{self}) catch {
            self.completion = failedCompletion("The account could not be connected.");
            self.ready.store(true, .release);
            self.wake.call();
            return;
        };
        race.concurrent(.timeout, waitForAuthorizationTimeout, .{ self.threaded.?.io(), self.authorization_timeout }) catch {
            race.cancelDiscard();
            self.completion = failedCompletion("The account could not be connected.");
            self.ready.store(true, .release);
            self.wake.call();
            return;
        };
        const winner = race.await() catch null;
        self.completion = if (winner) |result| switch (result) {
            .completion => |completion| completion,
            .timeout => failedCompletion("Authorization timed out. Please try again."),
        } else failedCompletion("The account could not be connected.");
        race.cancelDiscard();
        self.ready.store(true, .release);
        self.wake.call();
    }

    fn runCompletion(self: *Coordinator) Completion {
        return self.run() catch |err| failedCompletion(errorName(err));
    }

    fn waitForAuthorizationTimeout(io: std.Io, duration: std.Io.Clock.Duration) void {
        duration.sleep(io) catch {};
    }

    fn failedCompletion(message_value: []const u8) Completion {
        var message: text.Text(96) = .{};
        message.set(message_value);
        return .{ .failed = message };
    }

    fn run(self: *Coordinator) !Completion {
        const threaded = self.threaded.?;
        const io = threaded.io();
        const parsed_callback = try self.acceptValidCallback(io);

        var form_buffer: [8192]u8 = undefined;
        defer std.crypto.secureZero(u8, &form_buffer);
        const form = try pkce.tokenBody(&form_buffer, self.client_id.slice(), parsed_callback.codeSlice(), self.redirect_uri.slice(), &self.material.verifier, optionalSecret(self));
        var token_body: [max_http_body_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &token_body);
        const token_response = try http(io, self.allocator, .POST, self.provider.token_url, &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }}, form, &token_body);
        if (token_response.status < 200 or token_response.status >= 300 or token_response.truncated) return error.TokenExchangeFailed;
        const now_ms = std.Io.Clock.real.now(io).toMilliseconds();
        var auth = try session.parseTokenResponse(self.allocator, token_response.body, now_ms);
        defer std.crypto.secureZero(u8, std.mem.asBytes(&auth));

        var authorization_buffer: [session.max_token_bytes + 7]u8 = undefined;
        defer std.crypto.secureZero(u8, &authorization_buffer);
        const authorization = try std.fmt.bufPrint(&authorization_buffer, "Bearer {s}", .{auth.access_token.slice()});
        var profile_body: [max_http_body_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &profile_body);
        const profile_response = try http(io, self.allocator, .GET, self.provider.profile_url, &.{.{ .name = "authorization", .value = authorization }}, "", &profile_body);
        if (profile_response.status < 200 or profile_response.status >= 300 or profile_response.truncated) return error.ProfileRequestFailed;
        const profile = switch (self.provider.kind) {
            .gmail => try session.parseGoogleProfile(self.allocator, profile_response.body),
            .microsoft => try session.parseMicrosoftProfile(self.allocator, profile_response.body),
        };
        return .{ .success = .{
            .provider = self.provider,
            .profile = profile,
            .auth = auth,
            .client_id = self.client_id,
            .client_secret = self.client_secret,
        } };
    }

    /// Browsers, security tools, and Windows connectivity probes can touch a
    /// newly opened loopback port. Ignore malformed/wrong-path requests and
    /// keep accepting until the state-bound OAuth callback arrives.
    fn acceptValidCallback(self: *Coordinator, io: std.Io) !callback.Result {
        while (true) {
            const stream = try self.listener.?.accept(io);
            defer stream.close(io);
            var recv_buffer: [8192]u8 = undefined;
            var send_buffer: [4096]u8 = undefined;
            var conn_reader = stream.reader(io, &recv_buffer);
            var conn_writer = stream.writer(io, &send_buffer);
            var server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);
            var request = server.receiveHead() catch continue;
            if (request.head.method != .GET) {
                request.respond("The authorization callback must use GET.", .{ .status = .method_not_allowed, .keep_alive = false }) catch {};
                continue;
            }
            const parsed = callback.parse(request.head.target, self.provider.loopback_path, &self.material.state) catch |err| switch (err) {
                error.AuthorizationRejected => {
                    request.respond("Authorization was cancelled. You can close this window.", .{ .status = .bad_request, .keep_alive = false }) catch {};
                    return err;
                },
                else => {
                    request.respond("This is not the expected authorization callback.", .{ .status = .bad_request, .keep_alive = false }) catch {};
                    continue;
                },
            };
            try request.respond("Authorization received. You can close this window and return to Inbox Zero Mail while setup finishes.", .{ .keep_alive = false });
            return parsed;
        }
    }

    fn optionalSecret(self: *const Coordinator) ?[]const u8 {
        return if (self.client_secret.isEmpty()) null else self.client_secret.slice();
    }
};

fn isEmulator(provider: *const config.ProviderConfig) bool {
    return std.mem.startsWith(u8, provider.authorization_url, "http://127.0.0.1:4402/") or
        std.mem.startsWith(u8, provider.authorization_url, "http://127.0.0.1:4403/");
}

/// Entra ignores the ephemeral port only for registered `localhost`
/// redirects. The listener itself remains IPv4-only to avoid dual-stack
/// callback ambiguity. Google and the emulator retain literal loopback.
fn redirectHost(provider: *const config.ProviderConfig) []const u8 {
    return if (provider.kind == .microsoft and !isEmulator(provider)) "localhost" else "127.0.0.1";
}

fn bindLoopback(provider: *const config.ProviderConfig, io: std.Io) !std.Io.net.Server {
    if (!isEmulator(provider)) {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        return std.Io.net.IpAddress.listen(&address, io, .{ .reuse_address = false });
    }
    for (provider.loopback_ports) |port| {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
        const listener = std.Io.net.IpAddress.listen(&address, io, .{ .reuse_address = false }) catch continue;
        return listener;
    }
    return error.LoopbackPortsUnavailable;
}

const HttpResponse = struct { status: u16, truncated: bool, body: []const u8 };

fn http(io: std.Io, allocator: std.mem.Allocator, method: std.http.Method, url: []const u8, headers: []const std.http.Header, body: []const u8, output: []u8) !HttpResponse {
    const uri = try std.Uri.parse(url);
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var request = try client.request(method, uri, .{ .keep_alive = false, .extra_headers = headers, .redirect_behavior = .unhandled });
    defer request.deinit();
    if (body.len > 0) {
        request.transfer_encoding = .{ .content_length = body.len };
        var request_body = try request.sendBodyUnflushed(&.{});
        try request_body.writer.writeAll(body);
        try request_body.end();
        try request.connection.?.flush();
    } else try request.sendBodiless();
    var head_buffer: [8192]u8 = undefined;
    var response = try request.receiveHead(&head_buffer);
    var transfer_buffer: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, &.{});
    var writer = std.Io.Writer.fixed(output);
    var truncated = false;
    _ = reader.streamRemaining(&writer) catch |err| switch (err) {
        error.WriteFailed => truncated = true,
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
    };
    return .{ .status = @intFromEnum(response.head.status), .truncated = truncated, .body = writer.buffered() };
}

fn errorName(err: anyerror) []const u8 {
    return switch (err) {
        error.AuthorizationRejected => "Authorization was cancelled.",
        error.StateMismatch => "Authorization state did not match.",
        error.TokenExchangeFailed, error.InvalidTokenResponse, error.OAuthRejected => "The provider rejected the authorization code.",
        error.ProfileRequestFailed, error.InvalidProfile => "The provider account profile could not be loaded.",
        else => "The account could not be connected.",
    };
}

test "coordinator refuses empty and oversized client configuration" {
    var coordinator = Coordinator.init(std.testing.allocator);
    defer coordinator.deinit();
    const WakeStub = struct {
        fn call(_: *anyopaque) void {}
    };
    var context: u8 = 0;
    const wake = Wake{ .context = &context, .call_fn = WakeStub.call };
    try std.testing.expectError(error.InvalidClientId, coordinator.begin(.{ .provider = config.gmail, .client_id = "", .wake = wake }));
    const oversized = "x" ** (max_client_id_bytes + 1);
    try std.testing.expectError(error.InvalidClientId, coordinator.begin(.{ .provider = config.gmail, .client_id = oversized, .wake = wake }));
}

test "emulator and production callback port policies stay distinct" {
    try std.testing.expect(isEmulator(&config.emulator(.gmail)));
    try std.testing.expect(isEmulator(&config.emulator(.microsoft)));
    try std.testing.expect(!isEmulator(&config.gmail));
    try std.testing.expectEqualStrings("localhost", redirectHost(&config.microsoft));
    try std.testing.expectEqualStrings("127.0.0.1", redirectHost(&config.gmail));
    try std.testing.expectEqualStrings("127.0.0.1", redirectHost(&config.emulator(.microsoft)));
    try std.testing.expectEqual(@as(u16, 4000), config.emulator(.gmail).loopback_ports[0]);
    try std.testing.expectEqual(@as(u16, 4001), config.emulator(.microsoft).loopback_ports[0]);
}
