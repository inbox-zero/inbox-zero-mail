const std = @import("std");
const request_types = @import("../providers/outbound.zig");

/// Adapter between pure provider requests and Native SDK's bounded HTTP
/// effect. Provider modules stay independently testable and SDK-free.
pub fn fetchAuthorized(fx: anytype, key: u64, request: request_types.Request, token: []const u8, on_response: anytype) bool {
    var authorization_buffer: [256]u8 = undefined;
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
