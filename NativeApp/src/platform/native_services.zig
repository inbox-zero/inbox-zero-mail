const std = @import("std");
const native_sdk = @import("native_sdk");
const oauth_config = @import("../auth/config.zig");
const oauth_coordinator = @import("../auth/coordinator.zig");
const oauth_session = @import("../auth/session.zig");
const oauth_wire = @import("../auth/wire.zig");
const account_domain = @import("../domain/account.zig");
const text = @import("../domain/text.zig");

const ReplayFn = @typeInfo(@FieldType(native_sdk.App, "replay_fn")).optional.child;
const ReplayControl = @typeInfo(@typeInfo(ReplayFn).pointer.child).@"fn".params[1].type.?;

/// The native UI effects channel deliberately exposes only deterministic app
/// effects. This adapter is the narrow boundary for the handful of trusted OS
/// services that account onboarding needs.
pub const Service = struct {
    pub const supports_credentials = "inbox-zero.native.supports.credentials";
    pub const supports_open_url = "inbox-zero.native.supports.open-url";
    pub const open_url = "inbox-zero.native.open-url";
    pub const credential_set = "inbox-zero.native.credentials.set";
    pub const credential_get = "inbox-zero.native.credentials.get";
    pub const credential_delete = "inbox-zero.native.credentials.delete";
    pub const oauth_begin = oauth_wire.service_begin;
    pub const oauth_cancel = oauth_wire.service_cancel;
    pub const oauth_disconnect = oauth_wire.service_disconnect;
    pub const oauth_restore = oauth_wire.service_restore;
    pub const authorized_request = oauth_wire.service_authorized_request;
};

pub const OAuthSettings = struct {
    emulate: bool = false,
    gmail_client_id: []const u8 = "",
    gmail_client_secret: []const u8 = "",
    microsoft_client_id: []const u8 = "",
    microsoft_client_secret: []const u8 = "",
};

const credential_service = "com.inboxzero.mail.native.oauth";
const emulator_credential_service = "com.inboxzero.mail.native.oauth.emulate";
const authorized_request_timeout = std.Io.Clock.Duration{ .raw = std.Io.Duration.fromSeconds(60), .clock = .awake };
const max_sessions = 4;

const SessionEntry = struct {
    active: bool = false,
    key: text.Text(256) = .{},
    credential_key: text.Text(256) = .{},
    provider: account_domain.ProviderKind = .gmail,
    client_id: text.Text(oauth_coordinator.max_client_id_bytes) = .{},
    client_secret: text.Text(oauth_coordinator.max_client_secret_bytes) = .{},
    token_url: text.Text(512) = .{},
    api_base_url: text.Text(512) = .{},
};

/// Worker-owned token state. Refresh is serialized per account while ordinary
/// provider requests remain concurrent. `version` is the commit/CAS fence used
/// by the loop thread before persisting a rotating refresh token.
const SessionAuthState = struct {
    mutex: std.Io.Mutex = .init,
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    version: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    auth: oauth_session.Session = .{},
};

const AuthorizedJob = struct {
    key: u64,
    payload: []u8,
    response: []u8,
    response_len: usize = 0,
    result_ok: bool = true,
    auth: oauth_session.Session = .{},
    auth_state: *SessionAuthState,
    auth_version: u64 = 0,
    persist_refresh: bool = false,
    client_id: text.Text(oauth_coordinator.max_client_id_bytes),
    client_secret: text.Text(oauth_coordinator.max_client_secret_bytes),
    token_url: text.Text(512),
    credential_key: text.Text(256),
    io: std.Io,
    wake: oauth_coordinator.Wake,
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    future: std.Io.Future(void) = undefined,
};

pub const max_open_url_bytes: usize = 4096;
pub const max_credential_service_bytes: usize = 128;
pub const max_credential_account_bytes: usize = 256;
pub const max_credential_secret_bytes: usize = 4096;

pub const ValidationError = error{
    InvalidCredential,
    InvalidPayload,
};

fn validateCredentialParts(service: []const u8, account: []const u8, secret: ?[]const u8) ValidationError!void {
    if (service.len == 0 or service.len > max_credential_service_bytes or
        account.len == 0 or account.len > max_credential_account_bytes)
    {
        return error.InvalidCredential;
    }
    if (secret) |value| {
        if (value.len == 0 or value.len > max_credential_secret_bytes) return error.InvalidCredential;
    }
}

const DispatchResult = struct {
    ok: bool,
    bytes: []const u8,
};

/// Wrap a Native SDK App and bind trusted runtime services onto its Effects
/// host-call channel. The wrapped lifecycle is always delegated exactly once.
pub fn RuntimeServices(comptime Effects: type) type {
    return struct {
        const Self = @This();

        inner: native_sdk.App,
        effects: *Effects,
        runtime: ?*native_sdk.Runtime = null,
        oauth: oauth_coordinator.Coordinator,
        oauth_settings: OAuthSettings = .{},
        oauth_result_key: ?u64 = null,
        sessions: [max_sessions]SessionEntry = [_]SessionEntry{.{}} ** max_sessions,
        session_auth: [max_sessions]SessionAuthState = [_]SessionAuthState{.{}} ** max_sessions,
        authorized_io: ?*std.Io.Threaded = null,
        authorized_jobs: [16]?*AuthorizedJob = [_]?*AuthorizedJob{null} ** 16,
        restore_result: [2048]u8 = undefined,

        pub fn init(inner: native_sdk.App, effects: *Effects) Self {
            return .{ .inner = inner, .effects = effects, .oauth = oauth_coordinator.Coordinator.init(std.heap.page_allocator) };
        }

        pub fn initWithOAuth(inner: native_sdk.App, effects: *Effects, settings: OAuthSettings) Self {
            var self = init(inner, effects);
            self.oauth_settings = settings;
            return self;
        }

        pub fn app(self: *Self) native_sdk.App {
            return .{
                .context = self,
                .name = self.inner.name,
                .source = self.inner.source,
                .source_fn = if (self.inner.source_fn != null) sourceFn else null,
                .scene_fn = if (self.inner.scene_fn != null) sceneFn else null,
                .start_fn = startFn,
                .event_fn = eventFn,
                .stop_fn = stopFn,
                .replay_fn = if (self.inner.replay_fn != null) replayFn else null,
            };
        }

        pub fn supportsCredentials(self: *const Self) bool {
            const runtime = self.runtime orelse return false;
            return runtime.supports(.credentials);
        }

        pub fn supportsOpenUrl(self: *const Self) bool {
            const runtime = self.runtime orelse return false;
            return runtime.supports(.open_url);
        }

        /// Direct loop-thread credential APIs. Secrets must not ride an
        /// EffectHostResult: Native SDK session recording journals those bytes.
        pub fn setCredential(self: *Self, service: []const u8, account: []const u8, secret: []const u8) anyerror!void {
            try validateCredentialParts(service, account, secret);
            const runtime = self.runtime orelse return error.RuntimeUnavailable;
            try runtime.setCredential(.{ .service = service, .account = account, .secret = secret });
        }

        pub fn getCredential(self: *Self, service: []const u8, account: []const u8, output: []u8) anyerror!?[]const u8 {
            try validateCredentialParts(service, account, null);
            if (output.len > max_credential_secret_bytes) return error.InvalidPayload;
            const runtime = self.runtime orelse return error.RuntimeUnavailable;
            return runtime.getCredential(.{ .service = service, .account = account }, output);
        }

        pub fn deleteCredential(self: *Self, service: []const u8, account: []const u8) anyerror!bool {
            try validateCredentialParts(service, account, null);
            const runtime = self.runtime orelse return error.RuntimeUnavailable;
            return runtime.deleteCredential(.{ .service = service, .account = account });
        }

        pub fn openUrl(self: *Self, url: []const u8) anyerror!void {
            if (url.len == 0 or url.len > max_open_url_bytes) return error.InvalidPayload;
            const runtime = self.runtime orelse return error.RuntimeUnavailable;
            try runtime.openExternalUrl(url);
        }

        fn sourceFn(context: *anyopaque) anyerror!native_sdk.WebViewSource {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.inner.webViewSource();
        }

        fn sceneFn(context: *anyopaque) anyerror!native_sdk.ShellConfig {
            const self: *Self = @ptrCast(@alignCast(context));
            return (try self.inner.scene()) orelse return error.SceneUnavailable;
        }

        fn startFn(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.runtime = runtime;
            errdefer self.runtime = null;
            self.effects.bindHostCalls(.{
                .context = self,
                .send_fn = hostSend,
                .request_fn = hostRequest,
                .cancel_fn = hostCancel,
            });
            try self.inner.start(runtime);
        }

        fn eventFn(context: *anyopaque, runtime: *native_sdk.Runtime, event: native_sdk.Event) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.drainOAuth();
            self.drainAuthorized();
            try self.inner.event(runtime, event);
        }

        fn stopFn(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.oauth.deinit();
            self.stopAuthorized();
            self.oauth_result_key = null;
            for (&self.sessions) |*entry| {
                std.crypto.secureZero(u8, std.mem.asBytes(entry));
                entry.* = .{};
            }
            for (&self.session_auth) |*state| {
                state.active.store(false, .release);
                std.crypto.secureZero(u8, std.mem.asBytes(&state.auth));
                state.auth = .{};
            }
            defer self.runtime = null;
            try self.inner.stop(runtime);
        }

        fn replayFn(context: *anyopaque, control: ReplayControl) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(context));
            try self.inner.replayControl(control);
        }

        fn hostSend(context: *anyopaque, name: []const u8, payload: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(context));
            _ = self.dispatch(name, payload) catch {};
        }

        fn hostRequest(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (std.mem.eql(u8, name, Service.oauth_begin)) {
                self.beginOAuth(key, payload) catch |err| self.effects.feedHostResult(key, false, errorLabel(err)) catch {};
                return;
            }
            if (std.mem.eql(u8, name, Service.oauth_cancel)) {
                if (payload.len != 0) {
                    self.effects.feedHostResult(key, false, "invalid_payload") catch {};
                    return;
                }
                self.oauth.cancel();
                self.oauth_result_key = null;
                self.effects.feedHostResult(key, false, "Authorization cancelled.") catch {};
                return;
            }
            if (std.mem.eql(u8, name, Service.oauth_disconnect)) {
                const result = self.disconnectOAuth(payload) catch |err| DispatchResult{ .ok = false, .bytes = errorLabel(err) };
                self.effects.feedHostResult(key, result.ok, result.bytes) catch {};
                return;
            }
            if (std.mem.eql(u8, name, Service.oauth_restore)) {
                const result = self.restoreOAuth(payload) catch |err| DispatchResult{ .ok = false, .bytes = errorLabel(err) };
                self.effects.feedHostResult(key, result.ok, result.bytes) catch {};
                return;
            }
            if (std.mem.eql(u8, name, Service.authorized_request)) {
                self.startAuthorized(key, payload) catch |err| self.effects.feedHostResult(key, false, errorLabel(err)) catch {};
                return;
            }
            const result = self.dispatch(name, payload) catch |err| DispatchResult{
                .ok = false,
                .bytes = errorLabel(err),
            };
            // Host requests execute on the loop thread, as required by the
            // Effects feed contract. feedHostResult copies before returning.
            self.effects.feedHostResult(key, result.ok, result.bytes) catch {};
        }

        fn hostCancel(context: *anyopaque, key: u64) void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.oauth_result_key == key) {
                self.oauth.cancel();
                self.oauth_result_key = null;
            }
            for (&self.authorized_jobs) |job_pointer| {
                const job = job_pointer orelse continue;
                if (job.key != key) continue;
                const threaded = self.authorized_io orelse return;
                job.future.cancel(threaded.io());
            }
        }

        fn beginOAuth(self: *Self, key: u64, payload: []const u8) !void {
            if (!self.supportsOpenUrl()) return error.UnsupportedService;
            if (!self.supportsCredentials()) return error.CredentialsUnavailable;
            const provider_kind: account_domain.ProviderKind = if (std.mem.eql(u8, payload, "gmail"))
                .gmail
            else if (std.mem.eql(u8, payload, "microsoft"))
                .microsoft
            else
                return error.InvalidPayload;
            const provider = if (self.oauth_settings.emulate) oauth_config.emulator(provider_kind) else oauth_config.forProvider(provider_kind).*;
            const client_id = switch (provider_kind) {
                .gmail => if (self.oauth_settings.emulate and self.oauth_settings.gmail_client_id.len == 0) "inbox-zero-mail-dev" else self.oauth_settings.gmail_client_id,
                .microsoft => if (self.oauth_settings.emulate and self.oauth_settings.microsoft_client_id.len == 0) "inbox-zero-mail-dev" else self.oauth_settings.microsoft_client_id,
            };
            if (client_id.len == 0) return error.ClientNotConfigured;
            const client_secret = switch (provider_kind) {
                .gmail => if (self.oauth_settings.emulate and self.oauth_settings.gmail_client_secret.len == 0) "inbox-zero-google-secret" else self.oauth_settings.gmail_client_secret,
                // Entra desktop/native registrations are public clients. A
                // secret is used only by the local emulate.dev fork.
                .microsoft => if (!self.oauth_settings.emulate) "" else if (self.oauth_settings.microsoft_client_secret.len == 0) "inbox-zero-microsoft-secret" else self.oauth_settings.microsoft_client_secret,
            };
            self.oauth_result_key = key;
            const url = self.oauth.begin(.{
                .provider = provider,
                .client_id = client_id,
                .client_secret = if (client_secret.len == 0) null else client_secret,
                .wake = .{ .context = self, .call_fn = oauthWake },
            }) catch |err| {
                self.oauth_result_key = null;
                return err;
            };
            self.openUrl(url) catch |err| {
                self.oauth.cancel();
                self.oauth_result_key = null;
                return err;
            };
        }

        fn oauthWake(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const runtime = self.runtime orelse return;
            runtime.options.platform.services.wake() catch {};
        }

        fn drainOAuth(self: *Self) void {
            var completion = self.oauth.takeCompletion() orelse return;
            defer std.crypto.secureZero(u8, std.mem.asBytes(&completion));
            const key = self.oauth_result_key orelse return;
            self.oauth_result_key = null;
            switch (completion) {
                .failed => |message| self.effects.feedHostResult(key, false, message.slice()) catch {},
                .success => |*success| self.completeOAuth(key, success) catch |err| self.effects.feedHostResult(key, false, errorLabel(err)) catch {},
            }
        }

        fn completeOAuth(self: *Self, key: u64, success: *const oauth_coordinator.Success) !void {
            if (success.auth.refresh_token.isEmpty()) return error.RefreshTokenMissing;
            if (!validAccountField(success.profile.provider_account_id.slice(), 256) or
                !validAccountField(success.profile.email.slice(), 128) or
                !validAccountField(success.profile.display_name.slice(), 96)) return error.InvalidPayload;
            var key_buffer: [256]u8 = undefined;
            const provider_name = if (success.provider.kind == .gmail) "gmail" else "microsoft";
            const session_key = try std.fmt.bufPrint(&key_buffer, "{s}:{s}", .{ provider_name, success.profile.provider_account_id.slice() });
            const entry = self.sessionSlot(session_key) orelse return error.TooManyAccounts;
            const session_index: usize = @intCast((@intFromPtr(entry) - @intFromPtr(&self.sessions[0])) / @sizeOf(SessionEntry));
            const auth_state = &self.session_auth[session_index];
            const had_previous = entry.active;
            var previous_entry = entry.*;
            var previous_auth = auth_state.auth;
            const previous_version = auth_state.version.load(.acquire);
            defer std.crypto.secureZero(u8, std.mem.asBytes(&previous_entry));
            defer std.crypto.secureZero(u8, std.mem.asBytes(&previous_auth));

            try self.setCredential(self.oauthCredentialService(), session_key, success.auth.refresh_token.slice());
            errdefer {
                if (had_previous and !previous_auth.refresh_token.isEmpty())
                    self.setCredential(self.oauthCredentialService(), session_key, previous_auth.refresh_token.slice()) catch {}
                else
                    _ = self.deleteCredential(self.oauthCredentialService(), session_key) catch false;
            }
            if (had_previous) {
                auth_state.active.store(false, .release);
                self.cancelAuthorizedForState(auth_state);
            }
            std.crypto.secureZero(u8, std.mem.asBytes(&auth_state.auth));
            std.crypto.secureZero(u8, std.mem.asBytes(entry));
            entry.* = .{ .active = true, .provider = success.provider.kind };
            auth_state.auth = success.auth;
            _ = auth_state.version.fetchAdd(1, .acq_rel);
            auth_state.active.store(true, .release);
            errdefer {
                auth_state.active.store(false, .release);
                std.crypto.secureZero(u8, std.mem.asBytes(&auth_state.auth));
                std.crypto.secureZero(u8, std.mem.asBytes(entry));
                entry.* = previous_entry;
                auth_state.auth = previous_auth;
                auth_state.version.store(previous_version, .release);
                auth_state.active.store(had_previous, .release);
            }
            entry.key.set(session_key);
            entry.credential_key.set(session_key);
            entry.client_id = success.client_id;
            entry.client_secret = success.client_secret;
            entry.token_url.set(success.provider.token_url);
            entry.api_base_url.set(success.provider.api_base_url);

            var result_buffer: [2048]u8 = undefined;
            const result = try oauth_wire.encodeAccountResult(&result_buffer, .{
                .provider = if (success.provider.kind == .gmail) .gmail else .microsoft,
                .provider_account_id = success.profile.provider_account_id.slice(),
                .email = success.profile.email.slice(),
                .display_name = success.profile.display_name.slice(),
                .session_key = session_key,
                .api_base_url = success.provider.api_base_url,
            });
            try self.storeRegistry(session_index, result);
            try self.effects.feedHostResult(key, true, result);
        }

        fn sessionSlot(self: *Self, key: []const u8) ?*SessionEntry {
            for (&self.sessions) |*entry| if (entry.active and std.mem.eql(u8, entry.key.slice(), key)) return entry;
            for (&self.sessions, 0..) |*entry, index| {
                if (!entry.active and !self.authStateInUse(&self.session_auth[index])) return entry;
            }
            return null;
        }

        fn authStateInUse(self: *const Self, state: *const SessionAuthState) bool {
            for (self.authorized_jobs) |job_pointer| {
                const job = job_pointer orelse continue;
                if (job.auth_state == state) return true;
            }
            return false;
        }

        fn disconnectOAuth(self: *Self, key: []const u8) !DispatchResult {
            if (key.len == 0 or key.len > 256) return error.InvalidPayload;
            for (&self.sessions, 0..) |*entry, index| {
                if (!entry.active or !std.mem.eql(u8, entry.key.slice(), key)) continue;
                self.session_auth[index].active.store(false, .release);
                self.cancelAuthorizedForState(&self.session_auth[index]);
                std.crypto.secureZero(u8, std.mem.asBytes(&self.session_auth[index].auth));
                self.session_auth[index].auth = .{};
                _ = try self.deleteCredential(self.oauthCredentialService(), entry.credential_key.slice());
                var registry_buffer: [32]u8 = undefined;
                const registry_key = try registryKey(&registry_buffer, index);
                _ = self.deleteCredential(self.oauthCredentialService(), registry_key) catch false;
                std.crypto.secureZero(u8, std.mem.asBytes(entry));
                entry.* = .{};
                return .{ .ok = true, .bytes = "" };
            }
            return error.SessionNotFound;
        }

        fn storeRegistry(self: *Self, index: usize, account_bytes: []const u8) !void {
            var registry_buffer: [32]u8 = undefined;
            const registry_key = try registryKey(&registry_buffer, index);
            var encoded: [max_credential_secret_bytes]u8 = undefined;
            const encoded_len = std.base64.standard.Encoder.calcSize(account_bytes.len);
            if (encoded_len > encoded.len) return error.InvalidPayload;
            const value = std.base64.standard.Encoder.encode(encoded[0..encoded_len], account_bytes);
            try self.setCredential(self.oauthCredentialService(), registry_key, value);
        }

        fn restoreOAuth(self: *Self, payload: []const u8) !DispatchResult {
            if (payload.len != 1 or payload[0] < '0' or payload[0] >= '0' + @as(u8, max_sessions)) return error.InvalidPayload;
            const index: usize = payload[0] - '0';
            var registry_buffer: [32]u8 = undefined;
            const registry_key = try registryKey(&registry_buffer, index);
            var encoded: [max_credential_secret_bytes]u8 = undefined;
            const stored = (try self.getCredential(self.oauthCredentialService(), registry_key, &encoded)) orelse return error.SessionNotFound;
            var decoded: [2048]u8 = undefined;
            const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(stored) catch return error.InvalidPayload;
            if (decoded_len > decoded.len) return error.InvalidPayload;
            try std.base64.standard.Decoder.decode(decoded[0..decoded_len], stored);
            const metadata = try oauth_wire.decodeAccountResult(decoded[0..decoded_len]);
            var refresh_buffer: [max_credential_secret_bytes]u8 = undefined;
            defer std.crypto.secureZero(u8, &refresh_buffer);
            const refresh = (try self.getCredential(self.oauthCredentialService(), metadata.session_key, &refresh_buffer)) orelse return error.SessionNotFound;
            const kind: account_domain.ProviderKind = if (metadata.provider == .gmail) .gmail else .microsoft;
            const provider = if (self.oauth_settings.emulate) oauth_config.emulator(kind) else oauth_config.forProvider(kind).*;
            if (!validRestoredMetadata(metadata, &provider)) return error.InvalidPayload;
            if (self.findSession(metadata.session_key)) |existing| {
                if (existing != &self.sessions[index]) return error.InvalidPayload;
            }
            const client_id = switch (kind) {
                .gmail => if (self.oauth_settings.emulate and self.oauth_settings.gmail_client_id.len == 0) "inbox-zero-mail-dev" else self.oauth_settings.gmail_client_id,
                .microsoft => if (self.oauth_settings.emulate and self.oauth_settings.microsoft_client_id.len == 0) "inbox-zero-mail-dev" else self.oauth_settings.microsoft_client_id,
            };
            if (client_id.len == 0) return error.ClientNotConfigured;
            const client_secret = switch (kind) {
                .gmail => if (self.oauth_settings.emulate and self.oauth_settings.gmail_client_secret.len == 0) "inbox-zero-google-secret" else self.oauth_settings.gmail_client_secret,
                .microsoft => if (!self.oauth_settings.emulate) "" else if (self.oauth_settings.microsoft_client_secret.len == 0) "inbox-zero-microsoft-secret" else self.oauth_settings.microsoft_client_secret,
            };
            var auth: oauth_session.Session = .{};
            defer std.crypto.secureZero(u8, std.mem.asBytes(&auth));
            auth.refresh_token.set(refresh);
            const entry = &self.sessions[index];
            entry.* = .{ .active = true, .provider = kind };
            self.session_auth[index].auth = auth;
            _ = self.session_auth[index].version.fetchAdd(1, .acq_rel);
            self.session_auth[index].active.store(true, .release);
            entry.key.set(metadata.session_key);
            entry.credential_key.set(metadata.session_key);
            entry.client_id.set(client_id);
            entry.client_secret.set(client_secret);
            entry.token_url.set(provider.token_url);
            entry.api_base_url.set(provider.api_base_url);
            @memcpy(self.restore_result[0..decoded_len], decoded[0..decoded_len]);
            return .{ .ok = true, .bytes = self.restore_result[0..decoded_len] };
        }

        fn startAuthorized(self: *Self, key: u64, payload: []const u8) !void {
            const request = try oauth_wire.decodeRequest(payload);
            const entry = self.findSession(request.session_key) orelse return error.SessionNotFound;
            const session_index: usize = @intCast((@intFromPtr(entry) - @intFromPtr(&self.sessions[0])) / @sizeOf(SessionEntry));
            if (!allowedProviderUrl(entry.api_base_url.slice(), request.url)) return error.UrlNotAllowed;
            var slot: ?*?*AuthorizedJob = null;
            for (&self.authorized_jobs) |*candidate| if (candidate.* == null) {
                slot = candidate;
                break;
            };
            const destination = slot orelse return error.TooManyRequests;
            const threaded = try self.ensureAuthorizedIo();
            const allocator = std.heap.page_allocator;
            const job = try allocator.create(AuthorizedJob);
            errdefer allocator.destroy(job);
            const payload_copy = try allocator.dupe(u8, payload);
            errdefer allocator.free(payload_copy);
            const response = try allocator.alloc(u8, oauth_wire.max_host_result_bytes);
            errdefer allocator.free(response);
            job.* = .{
                .key = key,
                .payload = payload_copy,
                .response = response,
                .auth_state = &self.session_auth[session_index],
                .client_id = entry.client_id,
                .client_secret = entry.client_secret,
                .token_url = entry.token_url,
                .credential_key = entry.credential_key,
                .io = threaded.io(),
                .wake = .{ .context = self, .call_fn = oauthWake },
            };
            destination.* = job;
            job.future = std.Io.concurrent(threaded.io(), authorizedWorker, .{job}) catch |err| {
                destination.* = null;
                allocator.free(job.response);
                allocator.free(job.payload);
                allocator.destroy(job);
                return err;
            };
        }

        fn findSession(self: *Self, key: []const u8) ?*SessionEntry {
            for (&self.sessions, 0..) |*entry, index| {
                if (entry.active and self.session_auth[index].active.load(.acquire) and std.mem.eql(u8, entry.key.slice(), key)) return entry;
            }
            return null;
        }

        fn ensureAuthorizedIo(self: *Self) !*std.Io.Threaded {
            if (self.authorized_io) |threaded| return threaded;
            const threaded = try std.heap.page_allocator.create(std.Io.Threaded);
            threaded.* = std.Io.Threaded.init(std.heap.page_allocator, .{});
            self.authorized_io = threaded;
            return threaded;
        }

        fn drainAuthorized(self: *Self) void {
            const threaded = self.authorized_io orelse return;
            const io = threaded.io();
            for (&self.authorized_jobs) |*job_pointer| {
                const job = job_pointer.* orelse continue;
                if (!job.ready.load(.acquire)) continue;
                job.future.await(io);
                if (isCurrentRefreshCommit(job)) {
                    self.setCredential(self.oauthCredentialService(), job.credential_key.slice(), job.auth.refresh_token.slice()) catch {
                        job.auth_state.active.store(false, .release);
                        self.cancelAuthorizedForState(job.auth_state);
                        std.crypto.secureZero(u8, std.mem.asBytes(&job.auth_state.auth));
                        job.auth_state.auth = .{};
                        const failure = oauth_wire.encodeResponse(job.response, .{ .outcome = .authorization_failed }) catch "";
                        job.response_len = failure.len;
                        job.result_ok = failure.len > 0;
                    };
                }
                self.effects.feedHostResult(job.key, job.result_ok, job.response[0..job.response_len]) catch {};
                destroyAuthorizedJob(job);
                job_pointer.* = null;
            }
        }

        fn stopAuthorized(self: *Self) void {
            const threaded = self.authorized_io orelse return;
            const io = threaded.io();
            for (self.authorized_jobs) |job_pointer| if (job_pointer) |job| job.future.cancel(io);
            for (&self.authorized_jobs) |*job_pointer| if (job_pointer.*) |job| {
                job.future.await(io);
                destroyAuthorizedJob(job);
                job_pointer.* = null;
            };
            threaded.deinit();
            std.heap.page_allocator.destroy(threaded);
            self.authorized_io = null;
            for (&self.session_auth) |*state| {
                state.active.store(false, .release);
                std.crypto.secureZero(u8, std.mem.asBytes(&state.auth));
                state.auth = .{};
            }
        }

        fn cancelAuthorizedForState(self: *Self, state: *SessionAuthState) void {
            const threaded = self.authorized_io orelse return;
            for (self.authorized_jobs) |job_pointer| {
                const job = job_pointer orelse continue;
                if (job.auth_state == state) job.future.cancel(threaded.io());
            }
        }

        fn oauthCredentialService(self: *const Self) []const u8 {
            return if (self.oauth_settings.emulate) emulator_credential_service else credential_service;
        }

        fn dispatch(self: *Self, name: []const u8, payload: []const u8) anyerror!DispatchResult {
            if (std.mem.eql(u8, name, Service.supports_credentials)) {
                if (payload.len != 0) return error.InvalidPayload;
                return .{ .ok = true, .bytes = if (self.supportsCredentials()) "true" else "false" };
            }
            if (std.mem.eql(u8, name, Service.supports_open_url)) {
                if (payload.len != 0) return error.InvalidPayload;
                return .{ .ok = true, .bytes = if (self.supportsOpenUrl()) "true" else "false" };
            }
            if (std.mem.eql(u8, name, Service.open_url)) {
                try self.openUrl(payload);
                return .{ .ok = true, .bytes = "" };
            }
            if (std.mem.eql(u8, name, Service.credential_set) or
                std.mem.eql(u8, name, Service.credential_get) or
                std.mem.eql(u8, name, Service.credential_delete))
            {
                // Secret-bearing host calls are intentionally unavailable:
                // both ordinary host results and OAuth fetch responses are
                // journaled by Native SDK session recording. Call the direct
                // loop-thread methods above from the lifecycle coordinator.
                return error.DirectOnly;
            }
            return error.UnknownService;
        }
    };
}

fn errorLabel(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidCredential, error.InvalidPayload => "invalid_payload",
        error.CredentialNotFound => "credential_not_found",
        error.UnsupportedService => "unsupported_service",
        error.CredentialsUnavailable => "credentials_unavailable",
        error.ClientNotConfigured => "client_not_configured",
        error.RefreshTokenMissing => "refresh_token_missing",
        error.TooManyAccounts => "too_many_accounts",
        error.SessionNotFound => "session_not_found",
        error.UrlNotAllowed => "url_not_allowed",
        error.TooManyRequests => "too_many_requests",
        error.NavigationDenied, error.InvalidExternalUrl => "url_denied",
        error.RuntimeUnavailable => "runtime_unavailable",
        error.DirectOnly => "direct_only",
        error.UnknownService => "unknown_service",
        else => "operation_failed",
    };
}

fn allowedProviderUrl(base_url: []const u8, url: []const u8) bool {
    const base = std.Uri.parse(base_url) catch return false;
    const candidate = std.Uri.parse(url) catch return false;
    if (candidate.user != null or candidate.password != null or candidate.fragment != null) return false;
    if (!std.ascii.eqlIgnoreCase(base.scheme, candidate.scheme)) return false;
    if (!std.ascii.eqlIgnoreCase(base.scheme, "https") and !std.ascii.eqlIgnoreCase(base.scheme, "http")) return false;
    var base_host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    var candidate_host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const base_host = base.getHost(&base_host_buffer) catch return false;
    const candidate_host = candidate.getHost(&candidate_host_buffer) catch return false;
    if (!std.ascii.eqlIgnoreCase(base_host.bytes, candidate_host.bytes)) return false;
    return effectivePort(base) == effectivePort(candidate);
}

fn effectivePort(uri: std.Uri) ?u16 {
    if (uri.port) |port| return port;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return 443;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) return 80;
    return null;
}

fn validRestoredMetadata(metadata: oauth_wire.AccountResult, provider: *const oauth_config.ProviderConfig) bool {
    const expected_prefix = if (metadata.provider == .gmail) "gmail:" else "microsoft:";
    return std.mem.eql(u8, metadata.api_base_url, provider.api_base_url) and
        std.mem.startsWith(u8, metadata.session_key, expected_prefix) and
        std.mem.eql(u8, metadata.session_key[expected_prefix.len..], metadata.provider_account_id) and
        validAccountField(metadata.provider_account_id, 256) and
        validAccountField(metadata.email, 128) and
        validAccountField(metadata.display_name, 96) and
        validAccountField(metadata.session_key, 256);
}

fn validAccountField(value: []const u8, max_len: usize) bool {
    if (value.len == 0 or value.len > max_len or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn registryKey(output: []u8, index: usize) ![]const u8 {
    if (index >= max_sessions) return error.InvalidPayload;
    return std.fmt.bufPrint(output, "registry-{d}", .{index});
}

fn authorizedWorker(job: *AuthorizedJob) void {
    const Race = union(enum) { result: ?anyerror, timeout: void };
    var results: [2]Race = undefined;
    var race = std.Io.Select(Race).init(job.io, &results);
    race.concurrent(.result, runAuthorizedResult, .{job}) catch {
        finishAuthorizedFailure(job, .internal_error);
        return;
    };
    race.concurrent(.timeout, waitForAuthorizedTimeout, .{job.io}) catch {
        race.cancelDiscard();
        finishAuthorizedFailure(job, .internal_error);
        return;
    };
    const winner = race.await() catch null;
    const outcome: ?oauth_wire.TransportOutcome = if (winner) |result| switch (result) {
        .result => |maybe_error| if (maybe_error) |err| authorizedErrorOutcome(err) else null,
        .timeout => .timeout,
    } else .internal_error;
    race.cancelDiscard();
    if (outcome) |failure| {
        finishAuthorizedFailure(job, failure);
        return;
    }
    job.ready.store(true, .release);
    job.wake.call();
}

fn runAuthorizedResult(job: *AuthorizedJob) ?anyerror {
    runAuthorized(job) catch |err| return err;
    return null;
}

fn waitForAuthorizedTimeout(io: std.Io) void {
    authorized_request_timeout.sleep(io) catch {};
}

fn authorizedErrorOutcome(err: anyerror) oauth_wire.TransportOutcome {
    return switch (err) {
        error.AuthorizationRefreshFailed, error.InvalidTokenResponse, error.OAuthRejected, error.RefreshTokenMissing => .authorization_failed,
        error.SessionNotFound => .session_not_found,
        error.ConnectFailed => .connect_failed,
        error.Timeout => .timeout,
        error.Canceled => .cancelled,
        error.ResponseTooLarge => .response_too_large,
        else => .protocol_failed,
    };
}

fn finishAuthorizedFailure(job: *AuthorizedJob, outcome: oauth_wire.TransportOutcome) void {
    const bytes = oauth_wire.encodeResponse(job.response, .{ .outcome = outcome }) catch "";
    job.response_len = bytes.len;
    job.result_ok = bytes.len > 0;
    job.ready.store(true, .release);
    job.wake.call();
}

fn destroyAuthorizedJob(job: *AuthorizedJob) void {
    const allocator = std.heap.page_allocator;
    std.crypto.secureZero(u8, job.response);
    std.crypto.secureZero(u8, job.payload);
    allocator.free(job.response);
    allocator.free(job.payload);
    std.crypto.secureZero(u8, std.mem.asBytes(&job.auth));
    std.crypto.secureZero(u8, std.mem.asBytes(&job.client_secret));
    allocator.destroy(job);
}

fn isCurrentRefreshCommit(job: *const AuthorizedJob) bool {
    return job.persist_refresh and
        job.auth_state.active.load(.acquire) and
        job.auth_state.version.load(.acquire) == job.auth_version and
        !job.auth.refresh_token.isEmpty();
}

fn runAuthorized(job: *AuthorizedJob) !void {
    const request = try oauth_wire.decodeRequest(job.payload);
    try prepareAuthorizedAuth(job, false);
    var response = try providerHttp(job, request);
    if (response.status == 401) {
        try prepareAuthorizedAuth(job, true);
        response = try providerHttp(job, request);
        try rejectPersistentUnauthorized(response.status);
    }
    const encoded = try oauth_wire.encodeResponse(job.response, .{
        .outcome = .ok,
        .status = response.status,
        .truncated = response.truncated,
        .body = response.body,
    });
    job.response_len = encoded.len;
}

fn rejectPersistentUnauthorized(status: u16) !void {
    if (status == 401) return error.AuthorizationRefreshFailed;
}

/// Copy a current access token, refreshing under the account's mutex only when
/// necessary. A worker that received a 401 on an older version coalesces onto
/// the refresh another worker already committed instead of rotating twice.
fn prepareAuthorizedAuth(job: *AuthorizedJob, force_refresh: bool) !void {
    const state = job.auth_state;
    try state.mutex.lock(job.io);
    defer state.mutex.unlock(job.io);
    if (!state.active.load(.acquire)) return error.SessionNotFound;

    const current_version = state.version.load(.acquire);
    if (force_refresh and job.auth_version != 0 and current_version != job.auth_version) {
        job.auth = state.auth;
        job.auth_version = current_version;
        return;
    }

    const now_ms = std.Io.Clock.real.now(job.io).toMilliseconds();
    if (!force_refresh and !state.auth.shouldRefresh(now_ms)) {
        job.auth = state.auth;
        job.auth_version = current_version;
        return;
    }

    job.auth = state.auth;
    try refreshAuthorized(job);
    if (!state.active.load(.acquire)) return error.SessionNotFound;
    const committed_version = current_version +% 1;
    state.auth = job.auth;
    state.version.store(committed_version, .release);
    job.auth_version = committed_version;
    job.persist_refresh = true;
}

fn refreshAuthorized(job: *AuthorizedJob) !void {
    if (job.auth.refresh_token.isEmpty()) return error.RefreshTokenMissing;
    var form_buffer: [8192]u8 = undefined;
    defer std.crypto.secureZero(u8, &form_buffer);
    const form = try @import("../auth/pkce.zig").refreshBody(
        &form_buffer,
        job.client_id.slice(),
        job.auth.refresh_token.slice(),
        if (job.client_secret.isEmpty()) null else job.client_secret.slice(),
    );
    var body_buffer: [oauth_coordinator.max_http_body_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &body_buffer);
    const response = try rawHttp(job.io, std.heap.page_allocator, .POST, job.token_url.slice(), &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }}, form, &body_buffer);
    if (response.status < 200 or response.status >= 300 or response.truncated) return error.AuthorizationRefreshFailed;
    var refreshed = oauth_session.parseTokenResponse(std.heap.page_allocator, response.body, std.Io.Clock.real.now(job.io).toMilliseconds()) catch return error.AuthorizationRefreshFailed;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&refreshed));
    if (refreshed.refresh_token.isEmpty()) refreshed.refresh_token = job.auth.refresh_token;
    job.auth = refreshed;
}

fn providerHttp(job: *AuthorizedJob, request: oauth_wire.Request) !RawResponse {
    var authorization_buffer: [oauth_session.max_token_bytes + 7]u8 = undefined;
    defer std.crypto.secureZero(u8, &authorization_buffer);
    const authorization = try std.fmt.bufPrint(&authorization_buffer, "Bearer {s}", .{job.auth.access_token.slice()});
    const method: std.http.Method = switch (request.method) {
        .get => .GET,
        .post => .POST,
        .patch => .PATCH,
        .put => .PUT,
        .delete => .DELETE,
    };
    const headers = if (request.content_type.len > 0)
        &[_]std.http.Header{
            .{ .name = "authorization", .value = authorization },
            .{ .name = "content-type", .value = request.content_type },
        }
    else
        &[_]std.http.Header{.{ .name = "authorization", .value = authorization }};
    // Reserve the response frame prefix so body bytes never need a second
    // 256-KiB allocation or an overlapping move.
    return rawHttp(job.io, std.heap.page_allocator, method, request.url, headers, request.body, job.response[14..]);
}

const RawResponse = struct { status: u16, truncated: bool, body: []const u8 };

fn rawHttp(io: std.Io, allocator: std.mem.Allocator, method: std.http.Method, url: []const u8, headers: []const std.http.Header, body: []const u8, output: []u8) !RawResponse {
    const uri = try std.Uri.parse(url);
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var http_request = client.request(method, uri, .{ .keep_alive = false, .extra_headers = headers, .redirect_behavior = .unhandled }) catch return error.ConnectFailed;
    defer http_request.deinit();
    if (body.len > 0) {
        http_request.transfer_encoding = .{ .content_length = body.len };
        var request_body = try http_request.sendBodyUnflushed(&.{});
        try request_body.writer.writeAll(body);
        try request_body.end();
        try http_request.connection.?.flush();
    } else try http_request.sendBodiless();
    var head_buffer: [8192]u8 = undefined;
    var response = try http_request.receiveHead(&head_buffer);
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (decompress_buffer.len > 0) allocator.free(decompress_buffer);
    var transfer_buffer: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    var writer = std.Io.Writer.fixed(output);
    var truncated = false;
    _ = reader.streamRemaining(&writer) catch |err| switch (err) {
        error.WriteFailed => truncated = true,
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
    };
    return .{ .status = @intFromEnum(response.head.status), .truncated = truncated, .body = writer.buffered() };
}

test "authorized provider URLs cannot escape an account API origin prefix" {
    try std.testing.expect(allowedProviderUrl("https://graph.microsoft.com", "https://graph.microsoft.com/v1.0/me"));
    try std.testing.expect(allowedProviderUrl("https://graph.microsoft.com", "https://GRAPH.microsoft.com:443/v1.0/me?x=1"));
    try std.testing.expect(!allowedProviderUrl("https://graph.microsoft.com", "https://graph.microsoft.com.evil.test/steal"));
    try std.testing.expect(!allowedProviderUrl("https://graph.microsoft.com", "https://evil.test/"));
    try std.testing.expect(!allowedProviderUrl("https://graph.microsoft.com", "https://graph.microsoft.com@evil.test/v1.0/me"));
    try std.testing.expect(!allowedProviderUrl("https://graph.microsoft.com", "http://graph.microsoft.com/v1.0/me"));
    try std.testing.expect(!allowedProviderUrl("https://graph.microsoft.com", "https://graph.microsoft.com:444/v1.0/me"));
    try std.testing.expect(!allowedProviderUrl("https://graph.microsoft.com", "https://graph.microsoft.com/v1.0/me#fragment"));
}

test "restored account metadata cannot bind one profile to another credential" {
    const metadata = oauth_wire.AccountResult{
        .provider = .gmail,
        .provider_account_id = "subject-a",
        .email = "a@example.com",
        .display_name = "Account A",
        .session_key = "gmail:subject-a",
        .api_base_url = oauth_config.gmail.api_base_url,
    };
    try std.testing.expect(validRestoredMetadata(metadata, &oauth_config.gmail));
    var mismatched = metadata;
    mismatched.session_key = "gmail:subject-b";
    try std.testing.expect(!validRestoredMetadata(mismatched, &oauth_config.gmail));
}

test "a persistent 401 after refresh requires account reauthorization" {
    try std.testing.expectError(error.AuthorizationRefreshFailed, rejectPersistentUnauthorized(401));
    try rejectPersistentUnauthorized(200);
    try std.testing.expectEqual(oauth_wire.TransportOutcome.authorization_failed, authorizedErrorOutcome(error.AuthorizationRefreshFailed));
}

test "authorized worker injects bearer and returns framed HTTP response" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try std.Io.net.IpAddress.listen(&address, io, .{});
    defer listener.deinit(io);

    const Fixture = struct {
        listener: *std.Io.net.Server,
        io: std.Io,
        saw_bearer: bool = false,

        fn serve(self: *@This()) void {
            const stream = self.listener.accept(self.io) catch return;
            defer stream.close(self.io);
            var recv_buffer: [4096]u8 = undefined;
            var send_buffer: [4096]u8 = undefined;
            var conn_reader = stream.reader(self.io, &recv_buffer);
            var conn_writer = stream.writer(self.io, &send_buffer);
            var server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);
            var request = server.receiveHead() catch return;
            self.saw_bearer = std.mem.indexOf(u8, request.head_buffer, "Bearer runtime-access") != null;
            request.respond("{\"messages\":[]}", .{ .keep_alive = false }) catch {};
        }
    };
    var fixture = Fixture{ .listener = &listener, .io = io };
    var server_future = try std.Io.concurrent(io, Fixture.serve, .{&fixture});

    var url_buffer: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/mail", .{listener.socket.address.getPort()});
    var request_buffer: [1024]u8 = undefined;
    const request_bytes = try oauth_wire.encodeRequest(&request_buffer, .{ .method = .get, .session_key = "gmail:subject", .url = url });
    var response_buffer: [oauth_wire.max_host_result_bytes]u8 = undefined;
    var auth = try oauth_session.Session.fromTokenResponse(.{ .access_token = "runtime-access", .refresh_token = "runtime-refresh", .expires_in = 3600 }, std.Io.Clock.real.now(io).toMilliseconds());
    auth.expires_at_ms = std.math.maxInt(i64);
    var client_id: text.Text(oauth_coordinator.max_client_id_bytes) = .{};
    client_id.set("client");
    var token_url: text.Text(512) = .{};
    token_url.set("http://127.0.0.1/token");
    var credential_key: text.Text(256) = .{};
    credential_key.set("gmail:subject");
    var wake_context: u8 = 0;
    const WakeStub = struct {
        fn call(_: *anyopaque) void {}
    };
    var auth_state: SessionAuthState = .{ .auth = auth };
    auth_state.version.store(1, .release);
    auth_state.active.store(true, .release);
    var job = AuthorizedJob{
        .key = 1,
        .payload = @constCast(request_bytes),
        .response = &response_buffer,
        .auth_state = &auth_state,
        .client_id = client_id,
        .client_secret = .{},
        .token_url = token_url,
        .credential_key = credential_key,
        .io = io,
        .wake = .{ .context = &wake_context, .call_fn = WakeStub.call },
    };
    try runAuthorized(&job);
    server_future.await(io);
    try std.testing.expect(fixture.saw_bearer);
    const framed = try oauth_wire.decodeResponse(job.response[0..job.response_len]);
    try std.testing.expectEqual(oauth_wire.TransportOutcome.ok, framed.outcome);
    try std.testing.expectEqual(@as(u16, 200), framed.status);
    try std.testing.expectEqualStrings("{\"messages\":[]}", framed.body);
}

test "concurrent expired Outlook jobs coalesce one rotating refresh and stale versions cannot persist" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try std.Io.net.IpAddress.listen(&address, io, .{});
    defer listener.deinit(io);

    const TokenFixture = struct {
        listener: *std.Io.net.Server,
        io: std.Io,
        request_count: usize = 0,

        fn serve(self: *@This()) void {
            const stream = self.listener.accept(self.io) catch return;
            defer stream.close(self.io);
            var recv_buffer: [8192]u8 = undefined;
            var send_buffer: [4096]u8 = undefined;
            var conn_reader = stream.reader(self.io, &recv_buffer);
            var conn_writer = stream.writer(self.io, &send_buffer);
            var server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);
            var request = server.receiveHead() catch return;
            var form_buffer: [8192]u8 = undefined;
            const body_reader = request.readerExpectNone(&recv_buffer);
            _ = body_reader.readSliceShort(&form_buffer) catch return;
            self.request_count += 1;
            request.respond("{\"access_token\":\"new-access\",\"refresh_token\":\"rotated-refresh\",\"expires_in\":3600,\"token_type\":\"Bearer\"}", .{ .keep_alive = false }) catch {};
        }
    };
    var fixture = TokenFixture{ .listener = &listener, .io = io };
    var server_future = try std.Io.concurrent(io, TokenFixture.serve, .{&fixture});

    var token_url_buffer: [128]u8 = undefined;
    const token_url_value = try std.fmt.bufPrint(&token_url_buffer, "http://127.0.0.1:{d}/token", .{listener.socket.address.getPort()});
    var token_url: text.Text(512) = .{};
    token_url.set(token_url_value);
    var client_id: text.Text(oauth_coordinator.max_client_id_bytes) = .{};
    client_id.set("public-client");
    var credential_key: text.Text(256) = .{};
    credential_key.set("microsoft:subject");
    const expired = try oauth_session.Session.fromTokenResponse(.{ .access_token = "old-access", .refresh_token = "old-refresh", .expires_in = 0 }, 0);
    var auth_state: SessionAuthState = .{ .auth = expired };
    auth_state.version.store(7, .release);
    auth_state.active.store(true, .release);
    var wake_context: u8 = 0;
    const WakeStub = struct {
        fn call(_: *anyopaque) void {}
    };
    const base_job = AuthorizedJob{
        .key = 1,
        .payload = @constCast(""),
        .response = @constCast(""),
        .auth_state = &auth_state,
        .client_id = client_id,
        .client_secret = .{},
        .token_url = token_url,
        .credential_key = credential_key,
        .io = io,
        .wake = .{ .context = &wake_context, .call_fn = WakeStub.call },
    };
    var first = base_job;
    var second = base_job;
    second.key = 2;
    var first_ok = std.atomic.Value(bool).init(false);
    var second_ok = std.atomic.Value(bool).init(false);
    const Prepare = struct {
        fn run(job: *AuthorizedJob, ok: *std.atomic.Value(bool)) void {
            prepareAuthorizedAuth(job, false) catch return;
            ok.store(true, .release);
        }
    };
    var first_future = try std.Io.concurrent(io, Prepare.run, .{ &first, &first_ok });
    var second_future = try std.Io.concurrent(io, Prepare.run, .{ &second, &second_ok });
    first_future.await(io);
    second_future.await(io);
    server_future.await(io);

    try std.testing.expect(first_ok.load(.acquire));
    try std.testing.expect(second_ok.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), fixture.request_count);
    try std.testing.expectEqualStrings("rotated-refresh", first.auth.refresh_token.slice());
    try std.testing.expectEqualStrings("rotated-refresh", second.auth.refresh_token.slice());
    try std.testing.expectEqual(@as(u64, 8), auth_state.version.load(.acquire));
    try std.testing.expectEqual(@as(u8, 1), @as(u8, @intFromBool(first.persist_refresh)) + @as(u8, @intFromBool(second.persist_refresh)));

    const committing = if (first.persist_refresh) &first else &second;
    try std.testing.expect(isCurrentRefreshCommit(committing));
    auth_state.version.store(9, .release);
    try std.testing.expect(!isCurrentRefreshCommit(committing));
}

test "runtime adapter delegates lifecycle and serves bounded native calls" {
    const TestMsg = union(enum) { host_result: native_sdk.EffectHostResult };
    const TestEffects = native_sdk.Effects(TestMsg);
    const Inner = struct {
        starts: usize = 0,
        stops: usize = 0,

        fn app(self: *@This()) native_sdk.App {
            return .{
                .context = self,
                .name = "native-services-test",
                .start_fn = start,
                .stop_fn = stop,
            };
        }

        fn start(context: *anyopaque, _: *native_sdk.Runtime) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.starts += 1;
        }

        fn stop(context: *anyopaque, _: *native_sdk.Runtime) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.stops += 1;
        }
    };

    var null_platform = native_sdk.NullPlatform.init(.{});
    const runtime = try std.testing.allocator.create(native_sdk.Runtime);
    defer std.testing.allocator.destroy(runtime);
    native_sdk.Runtime.initAt(runtime, .{
        .allocator = std.testing.allocator,
        .platform = null_platform.platform(),
        .security = .{ .navigation = .{ .external_links = .{
            .action = .open_system_browser,
            .allowed_urls = &.{"https://accounts.example.test/*"},
        } } },
    });
    defer runtime.deinit();

    var effects = TestEffects.init(std.testing.allocator);
    defer effects.deinit();
    var inner = Inner{};
    var services = RuntimeServices(TestEffects).initWithOAuth(inner.app(), &effects, .{ .gmail_client_id = "desktop-client-id" });
    const wrapped = services.app();
    try wrapped.start(runtime);
    try std.testing.expectEqual(@as(usize, 1), inner.starts);

    effects.hostRequest(.{
        .key = 1,
        .name = Service.supports_credentials,
        .on_result = TestEffects.hostMsg(.host_result),
    });
    const support = effects.takeMsg().?.host_result;
    try std.testing.expect(support.ok);
    try std.testing.expectEqualStrings("true", support.bytes);

    effects.hostRequest(.{
        .key = 2,
        .name = Service.open_url,
        .payload = "https://accounts.example.test/authorize",
        .on_result = TestEffects.hostMsg(.host_result),
    });
    try std.testing.expect(effects.takeMsg().?.host_result.ok);
    try std.testing.expectEqualStrings("https://accounts.example.test/authorize", null_platform.lastExternalUrl());

    try services.setCredential("com.inboxzero.mail", "account-1", "refresh-token");
    var secret_buffer: [max_credential_secret_bytes]u8 = undefined;
    const secret = (try services.getCredential("com.inboxzero.mail", "account-1", &secret_buffer)).?;
    try std.testing.expectEqualStrings("refresh-token", secret);

    var oversized_service: [max_credential_service_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidCredential, services.setCredential(&oversized_service, "account-1", "token"));

    effects.hostRequest(.{
        .key = 3,
        .name = Service.credential_get,
        .on_result = TestEffects.hostMsg(.host_result),
    });
    const guarded = effects.takeMsg().?.host_result;
    try std.testing.expect(!guarded.ok);
    try std.testing.expectEqualStrings("direct_only", guarded.bytes);

    try std.testing.expect(try services.deleteCredential("com.inboxzero.mail", "account-1"));

    var metadata_buffer: [1024]u8 = undefined;
    const metadata = try oauth_wire.encodeAccountResult(&metadata_buffer, .{
        .provider = .gmail,
        .provider_account_id = "subject-restore",
        .email = "restored@example.com",
        .display_name = "Restored Account",
        .session_key = "gmail:subject-restore",
        .api_base_url = oauth_config.gmail.api_base_url,
    });
    try services.storeRegistry(0, metadata);
    var registry_secret: [max_credential_secret_bytes]u8 = undefined;
    const encoded_registry = (try services.getCredential(credential_service, "registry-0", &registry_secret)).?;
    var decoded_registry: [2048]u8 = undefined;
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded_registry);
    try std.base64.standard.Decoder.decode(decoded_registry[0..decoded_len], encoded_registry);
    try std.testing.expectEqualStrings("restored@example.com", (try oauth_wire.decodeAccountResult(decoded_registry[0..decoded_len])).email);
    _ = try services.deleteCredential(credential_service, "registry-0");

    try wrapped.stop(runtime);
    try std.testing.expectEqual(@as(usize, 1), inner.stops);
}
