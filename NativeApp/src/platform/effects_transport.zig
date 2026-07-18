const std = @import("std");
const native_sdk = @import("native_sdk");
const oauth_wire = @import("../auth/wire.zig");
const request_types = @import("../providers/outbound.zig");

/// Adapter between pure provider requests and Native SDK's bounded HTTP
/// effect. Provider modules stay independently testable and SDK-free.
pub fn fetchAuthorized(
    fx: anytype,
    key: u64,
    request: request_types.Request,
    token: []const u8,
    session_key: []const u8,
    on_response: anytype,
    on_authorized_response: anytype,
) bool {
    if (session_key.len > 0) {
        var payload_buffer: [oauth_wire.max_host_payload_bytes]u8 = undefined;
        const payload = oauth_wire.encodeRequest(&payload_buffer, .{
            .method = switch (request.method) {
                .GET => .get,
                .POST => .post,
                .PATCH => .patch,
                .PUT => .put,
                .DELETE => .delete,
                else => return false,
            },
            .session_key = session_key,
            .url = request.url,
            .content_type = request.content_type orelse "",
            .body = request.body orelse "",
        }) catch return false;
        fx.hostRequest(.{
            .key = key,
            .name = oauth_wire.service_authorized_request,
            .payload = payload,
            .on_result = on_authorized_response,
        });
        return true;
    }

    // Explicit emulator seed accounts use the deterministic fake bearer path.
    // Production sessions always take the token-free host transport above.
    var authorization_buffer: [4096 + 7]u8 = undefined;
    const authorization = std.fmt.bufPrint(&authorization_buffer, "Bearer {s}", .{token}) catch return false;
    const headers = if (request.content_type) |content_type|
        &[_]std.http.Header{
            .{ .name = "authorization", .value = authorization },
            .{ .name = "content-type", .value = content_type },
        }
    else
        &[_]std.http.Header{.{ .name = "authorization", .value = authorization }};
    fx.fetch(.{
        .key = key,
        .method = request.method,
        .url = request.url,
        .headers = headers,
        .body = request.body,
        .timeout_ms = 20_000,
        .on_response = on_response,
    });
    return true;
}

test "production provider requests carry only an opaque session handle" {
    const TestMsg = union(enum) {
        response: native_sdk.EffectResponse,
        host: native_sdk.EffectHostResult,
    };
    const TestEffects = native_sdk.Effects(TestMsg);
    var fx = TestEffects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    try std.testing.expect(fetchAuthorized(
        &fx,
        42,
        .{ .method = .POST, .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/send", .content_type = "application/json", .body = "{\"raw\":\"mail\"}" },
        "access-token-must-not-be-journaled",
        "gmail:provider-subject",
        TestEffects.responseMsg(.response),
        TestEffects.hostMsg(.host),
    ));
    try std.testing.expectEqual(@as(usize, 1), fx.pendingHostCount());
    const pending = fx.pendingHostAt(0) orelse return error.HostRequestMissing;
    try std.testing.expectEqualStrings(oauth_wire.service_authorized_request, pending.name);
    const decoded = try oauth_wire.decodeRequest(pending.payload);
    try std.testing.expectEqualStrings("gmail:provider-subject", decoded.session_key);
    try std.testing.expectEqualStrings("{\"raw\":\"mail\"}", decoded.body);
    try std.testing.expect(std.mem.indexOf(u8, pending.payload, "access-token-must-not-be-journaled") == null);
}
