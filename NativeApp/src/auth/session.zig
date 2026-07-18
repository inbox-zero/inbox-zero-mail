const std = @import("std");
const text = @import("../domain/text.zig");

pub const max_token_bytes: usize = 4096;
pub const max_profile_field_bytes: usize = 256;
const default_token_lifetime_seconds: i64 = 3600;
const max_token_lifetime_seconds: i64 = 365 * 24 * 60 * 60;

pub const TokenResponse = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    expires_in: ?i64 = null,
    scope: ?[]const u8 = null,
    token_type: ?[]const u8 = null,
};

pub const Session = struct {
    access_token: text.Text(max_token_bytes) = .{},
    refresh_token: text.Text(max_token_bytes) = .{},
    expires_at_ms: i64 = 0,

    pub fn fromTokenResponse(response: TokenResponse, now_ms: i64) !Session {
        if (response.access_token.len == 0 or response.access_token.len > max_token_bytes) return error.InvalidAccessToken;
        if (response.refresh_token) |refresh| {
            if (refresh.len > max_token_bytes) return error.InvalidRefreshToken;
        }
        if (response.token_type) |token_type| {
            if (!std.ascii.eqlIgnoreCase(token_type, "Bearer")) return error.UnsupportedTokenType;
        }

        const lifetime_seconds = response.expires_in orelse default_token_lifetime_seconds;
        if (lifetime_seconds < 0 or lifetime_seconds > max_token_lifetime_seconds) return error.InvalidExpiration;
        const lifetime_ms = lifetime_seconds * std.time.ms_per_s;
        if (now_ms > std.math.maxInt(i64) - lifetime_ms) return error.InvalidExpiration;

        var result: Session = .{};
        result.access_token.set(response.access_token);
        if (response.refresh_token) |refresh| result.refresh_token.set(refresh);
        result.expires_at_ms = now_ms + lifetime_ms;
        return result;
    }

    pub fn shouldRefresh(self: *const Session, now_ms: i64) bool {
        const refresh_boundary = self.expires_at_ms -| (60 * std.time.ms_per_s);
        return self.access_token.isEmpty() or self.expires_at_ms == 0 or now_ms >= refresh_boundary;
    }

    pub fn mergeRefresh(self: *Session, response: TokenResponse, now_ms: i64) !void {
        const previous_refresh = self.refresh_token;
        self.* = try fromTokenResponse(response, now_ms);
        if (self.refresh_token.isEmpty()) self.refresh_token = previous_refresh;
    }
};

const TokenEnvelope = struct {
    access_token: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
    expires_in: ?i64 = null,
    scope: ?[]const u8 = null,
    token_type: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    error_description: ?[]const u8 = null,
};

pub fn parseTokenResponse(allocator: std.mem.Allocator, body: []const u8, now_ms: i64) !Session {
    const parsed = try std.json.parseFromSlice(TokenEnvelope, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.@"error") |oauth_error| {
        if (oauth_error.len > 0) return error.OAuthRejected;
    }
    const access_token = parsed.value.access_token orelse return error.InvalidTokenResponse;
    return Session.fromTokenResponse(.{
        .access_token = access_token,
        .refresh_token = parsed.value.refresh_token,
        .expires_in = parsed.value.expires_in,
        .scope = parsed.value.scope,
        .token_type = parsed.value.token_type,
    }, now_ms);
}

pub const Profile = struct {
    provider_account_id: text.Text(max_profile_field_bytes) = .{},
    email: text.Text(max_profile_field_bytes) = .{},
    display_name: text.Text(max_profile_field_bytes) = .{},
};

const GoogleProfile = struct {
    sub: ?[]const u8 = null,
    id: ?[]const u8 = null,
    email: []const u8,
    name: ?[]const u8 = null,
};

const MicrosoftProfile = struct {
    id: []const u8,
    mail: ?[]const u8 = null,
    userPrincipalName: ?[]const u8 = null,
    displayName: ?[]const u8 = null,
};

pub fn parseGoogleProfile(allocator: std.mem.Allocator, body: []const u8) !Profile {
    const parsed = try std.json.parseFromSlice(GoogleProfile, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const provider_account_id = parsed.value.sub orelse parsed.value.id orelse return error.InvalidProfile;
    const display_name = parsed.value.name orelse parsed.value.email;
    if (!validProfileField(provider_account_id) or !validProfileField(parsed.value.email) or !validProfileField(display_name)) return error.InvalidProfile;
    var profile: Profile = .{};
    profile.provider_account_id.set(provider_account_id);
    profile.email.set(parsed.value.email);
    profile.display_name.set(display_name);
    return profile;
}

pub fn parseMicrosoftProfile(allocator: std.mem.Allocator, body: []const u8) !Profile {
    const parsed = try std.json.parseFromSlice(MicrosoftProfile, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const email = parsed.value.mail orelse parsed.value.userPrincipalName orelse return error.InvalidProfile;
    const display_name = parsed.value.displayName orelse email;
    if (!validProfileField(parsed.value.id) or !validProfileField(email) or !validProfileField(display_name)) return error.InvalidProfile;
    var profile: Profile = .{};
    profile.provider_account_id.set(parsed.value.id);
    profile.email.set(email);
    profile.display_name.set(display_name);
    return profile;
}

fn validProfileField(value: []const u8) bool {
    if (value.len == 0 or value.len > max_profile_field_bytes) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

test "token response refreshes sixty seconds before expiry" {
    const response = TokenResponse{ .access_token = "access", .refresh_token = "refresh", .expires_in = 3600 };
    const session = try Session.fromTokenResponse(response, 1_000);
    try std.testing.expect(!session.shouldRefresh(1_000));
    try std.testing.expect(session.shouldRefresh(session.expires_at_ms - 59_000));
}

test "rotating refresh response preserves an omitted refresh token" {
    var session = try Session.fromTokenResponse(.{ .access_token = "old", .refresh_token = "keep", .expires_in = 1 }, 0);
    try session.mergeRefresh(.{ .access_token = "new", .expires_in = 3600 }, 2_000);
    try std.testing.expectEqualStrings("new", session.access_token.slice());
    try std.testing.expectEqualStrings("keep", session.refresh_token.slice());
}

test "rotating refresh response replaces a returned refresh token" {
    var session = try Session.fromTokenResponse(.{ .access_token = "old", .refresh_token = "old-refresh", .expires_in = 1 }, 0);
    try session.mergeRefresh(.{ .access_token = "new", .refresh_token = "rotated-refresh", .expires_in = 3600 }, 2_000);
    try std.testing.expectEqualStrings("new", session.access_token.slice());
    try std.testing.expectEqualStrings("rotated-refresh", session.refresh_token.slice());
}

test "a rejected refresh leaves the existing session intact" {
    var session = try Session.fromTokenResponse(.{ .access_token = "old", .refresh_token = "keep", .expires_in = 1 }, 0);
    const oversized = [_]u8{'x'} ** (max_token_bytes + 1);
    try std.testing.expectError(error.InvalidAccessToken, session.mergeRefresh(.{ .access_token = &oversized, .expires_in = 3600 }, 2_000));
    try std.testing.expectEqualStrings("old", session.access_token.slice());
    try std.testing.expectEqualStrings("keep", session.refresh_token.slice());
}

test "OAuth errors and malformed token envelopes are rejected" {
    try std.testing.expectError(error.OAuthRejected, parseTokenResponse(std.testing.allocator, "{\"error\":\"invalid_grant\",\"error_description\":\"expired code\"}", 0));
    try std.testing.expectError(error.InvalidTokenResponse, parseTokenResponse(std.testing.allocator, "{\"token_type\":\"Bearer\"}", 0));
    try std.testing.expectError(error.UnsupportedTokenType, parseTokenResponse(std.testing.allocator, "{\"access_token\":\"secret\",\"token_type\":\"mac\"}", 0));
}

test "token expiration rejects hostile values without overflow" {
    try std.testing.expectError(error.InvalidExpiration, Session.fromTokenResponse(.{ .access_token = "access", .expires_in = -1 }, 0));
    try std.testing.expectError(error.InvalidExpiration, Session.fromTokenResponse(.{ .access_token = "access", .expires_in = max_token_lifetime_seconds + 1 }, 0));
    try std.testing.expectError(error.InvalidExpiration, Session.fromTokenResponse(.{ .access_token = "access", .expires_in = 1 }, std.math.maxInt(i64)));
}

test "profiles use stable provider ids instead of email identity" {
    const google = try parseGoogleProfile(std.testing.allocator, "{\"sub\":\"subject-1\",\"id\":\"legacy-id\",\"email\":\"new@example.com\",\"name\":\"New Name\"}");
    try std.testing.expectEqualStrings("subject-1", google.provider_account_id.slice());
    const legacy_google = try parseGoogleProfile(std.testing.allocator, "{\"id\":\"legacy-subject\",\"email\":\"legacy@example.com\"}");
    try std.testing.expectEqualStrings("legacy-subject", legacy_google.provider_account_id.slice());
    const microsoft = try parseMicrosoftProfile(std.testing.allocator, "{\"id\":\"graph-1\",\"userPrincipalName\":\"person@example.com\",\"displayName\":\"Person\"}");
    try std.testing.expectEqualStrings("graph-1", microsoft.provider_account_id.slice());
}

test "profiles reject fields that would be truncated or contain controls" {
    const oversized = "x" ** (max_profile_field_bytes + 1);
    const google_body = try std.fmt.allocPrint(std.testing.allocator, "{{\"id\":\"{s}\",\"email\":\"person@example.com\"}}", .{oversized});
    defer std.testing.allocator.free(google_body);
    try std.testing.expectError(error.InvalidProfile, parseGoogleProfile(std.testing.allocator, google_body));
    try std.testing.expectError(error.InvalidProfile, parseMicrosoftProfile(std.testing.allocator, "{\"id\":\"graph-1\",\"mail\":\"person\\u0000@example.com\"}"));
}
