const std = @import("std");
const account = @import("../domain/account.zig");
const config = @import("config.zig");
const coordinator_module = @import("coordinator.zig");
const pkce = @import("pkce.zig");

const coordinator_timeout: std.Io.Timeout = .{ .duration = .{
    .clock = .awake,
    .raw = .fromSeconds(20),
} };

const WakeContext = struct {
    event: std.Io.Event = .unset,
    io: std.Io,

    fn wake(context: *anyopaque) void {
        const self: *WakeContext = @ptrCast(@alignCast(context));
        self.event.set(self.io);
    }
};

pub fn main() !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try exerciseProvider(io, .gmail, "alpha.inbox@example.com", "inbox-zero-google-secret");
    try exerciseProvider(io, .microsoft, "gamma.outlook@example.com", "inbox-zero-microsoft-secret");
    std.debug.print("oauth-coordinator-emulator: PASS — Native coordinator completed Gmail and Outlook OAuth\n", .{});
}

fn exerciseProvider(io: std.Io, kind: account.ProviderKind, email: []const u8, client_secret: []const u8) !void {
    const provider = config.emulator(kind);
    var wake_context = WakeContext{ .io = io };
    var coordinator = coordinator_module.Coordinator.init(std.heap.page_allocator);
    defer coordinator.deinit();

    const authorization_url = try coordinator.begin(.{
        .provider = provider,
        .client_id = "inbox-zero-mail-dev",
        .client_secret = client_secret,
        .wake = .{ .context = &wake_context, .call_fn = WakeContext.wake },
    });

    var callback_url_buffer: [4096]u8 = undefined;
    const callback_url = try authorizeWithEmulator(io, provider, authorization_url, email, &callback_url_buffer);
    try followLoopbackCallback(io, callback_url);
    try wake_context.event.waitTimeout(io, coordinator_timeout);

    const completion = coordinator.takeCompletion() orelse return error.CoordinatorDidNotComplete;
    switch (completion) {
        .failed => |message| {
            std.debug.print("oauth-coordinator-emulator: {s} failed: {s}\n", .{ provider.display_name, message.slice() });
            return error.CoordinatorFailed;
        },
        .success => |success| {
            if (success.provider.kind != kind) return error.ProviderMismatch;
            if (!std.mem.eql(u8, success.profile.email.slice(), email)) return error.ProfileMismatch;
            if (success.profile.provider_account_id.isEmpty()) return error.ProfileIdMissing;
            if (success.auth.access_token.isEmpty()) return error.AccessTokenMissing;
            if (success.auth.refresh_token.isEmpty()) return error.RefreshTokenMissing;
            if (std.mem.eql(u8, success.auth.access_token.slice(), success.auth.refresh_token.slice())) return error.TokenKindsAliased;
            if (!std.mem.eql(u8, success.client_id.slice(), "inbox-zero-mail-dev")) return error.ClientIdMismatch;
            if (!std.mem.eql(u8, success.client_secret.slice(), client_secret)) return error.ClientSecretMismatch;
        },
    }
    std.debug.print("oauth-coordinator-emulator: {s} connected as {s}\n", .{ provider.display_name, email });
}

fn authorizeWithEmulator(
    io: std.Io,
    provider: config.ProviderConfig,
    authorization_url: []const u8,
    email: []const u8,
    output: []u8,
) ![]const u8 {
    var redirect_buffer: [512]u8 = undefined;
    var scope_buffer: [1024]u8 = undefined;
    var client_buffer: [512]u8 = undefined;
    var state_buffer: [256]u8 = undefined;
    var challenge_buffer: [256]u8 = undefined;
    const redirect_uri = try queryValue(authorization_url, "redirect_uri", &redirect_buffer);
    const scope = try queryValue(authorization_url, "scope", &scope_buffer);
    const client_id = try queryValue(authorization_url, "client_id", &client_buffer);
    const state = try queryValue(authorization_url, "state", &state_buffer);
    const challenge = try queryValue(authorization_url, "code_challenge", &challenge_buffer);

    var form_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&form_buffer);
    try formPair(&writer, "email", email, false);
    try formPair(&writer, "redirect_uri", redirect_uri, true);
    try formPair(&writer, "scope", scope, true);
    try formPair(&writer, "client_id", client_id, true);
    try formPair(&writer, "state", state, true);
    try formPair(&writer, "response_mode", "query", true);
    try formPair(&writer, "code_challenge", challenge, true);
    try formPair(&writer, "code_challenge_method", "S256", true);

    var endpoint_buffer: [512]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/callback", .{provider.authorization_url});
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = io };
    defer client.deinit();
    var request = try client.request(.POST, try std.Uri.parse(endpoint), .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }},
    });
    defer request.deinit();
    const form = writer.buffered();
    request.transfer_encoding = .{ .content_length = form.len };
    var request_body = try request.sendBodyUnflushed(&.{});
    try request_body.writer.writeAll(form);
    try request_body.end();
    try request.connection.?.flush();
    var head_buffer: [8192]u8 = undefined;
    var response = try request.receiveHead(&head_buffer);
    if (response.head.status != .found) {
        var transfer_buffer: [4096]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        var error_body_buffer: [4096]u8 = undefined;
        var error_writer = std.Io.Writer.fixed(&error_body_buffer);
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, &.{});
        _ = reader.streamRemaining(&error_writer) catch {};
        std.debug.print("oauth-coordinator-emulator: {s} consent callback returned {d}: {s}\n", .{
            provider.display_name,
            @intFromEnum(response.head.status),
            error_writer.buffered(),
        });
        return error.AuthorizationCallbackFailed;
    }
    const location = response.head.location orelse return error.AuthorizationLocationMissing;
    if (location.len > output.len) return error.AuthorizationLocationTooLong;
    @memcpy(output[0..location.len], location);
    return output[0..location.len];
}

fn followLoopbackCallback(io: std.Io, callback_url: []const u8) !void {
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = io };
    defer client.deinit();
    var request = try client.request(.GET, try std.Uri.parse(callback_url), .{ .keep_alive = false, .redirect_behavior = .unhandled });
    defer request.deinit();
    try request.sendBodiless();
    var head_buffer: [8192]u8 = undefined;
    const response = try request.receiveHead(&head_buffer);
    if (response.head.status != .ok) return error.LoopbackCallbackFailed;
}

fn queryValue(url: []const u8, name: []const u8, output: []u8) ![]const u8 {
    const question = std.mem.indexOfScalar(u8, url, '?') orelse return error.AuthorizationQueryMissing;
    var pairs = std.mem.splitScalar(u8, url[question + 1 ..], '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..equals], name)) continue;
        const encoded = pair[equals + 1 ..];
        if (encoded.len > output.len) return error.AuthorizationParameterTooLong;
        return std.Uri.percentDecodeBackwards(output, encoded);
    }
    return error.AuthorizationParameterMissing;
}

fn formPair(writer: *std.Io.Writer, name: []const u8, value: []const u8, prefix_ampersand: bool) !void {
    if (prefix_ampersand) try writer.writeByte('&');
    try writer.writeAll(name);
    try writer.writeByte('=');
    try pkce.writeFormComponent(writer, value);
}
