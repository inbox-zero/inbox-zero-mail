const std = @import("std");

pub const service_authorized_request = "inbox-zero.oauth.authorized-request.v1";
pub const service_begin = "inbox-zero.oauth.begin.v1";
pub const service_cancel = "inbox-zero.oauth.cancel.v1";
pub const service_disconnect = "inbox-zero.oauth.disconnect.v1";
pub const service_restore = "inbox-zero.oauth.restore.v1";
pub const max_host_payload_bytes: usize = 64 * 1024;
pub const max_host_result_bytes: usize = 256 * 1024;
pub const max_session_key_bytes: usize = 256;
pub const max_url_bytes: usize = 4096;
pub const max_content_type_bytes: usize = 256;

const request_magic = "IZRQ";
const response_magic = "IZRS";
const request_header_bytes: usize = 16;
const response_header_bytes: usize = 14;

pub const Method = enum(u8) { get, post, patch, put, delete };
pub const TransportOutcome = enum(u8) {
    ok,
    invalid_request,
    session_not_found,
    authorization_failed,
    connect_failed,
    tls_failed,
    protocol_failed,
    timeout,
    cancelled,
    response_too_large,
    internal_error,
};

pub const Provider = enum(u8) { gmail, microsoft };

pub const AccountResult = struct {
    provider: Provider,
    provider_account_id: []const u8,
    email: []const u8,
    display_name: []const u8,
    session_key: []const u8,
    api_base_url: []const u8,
};

pub fn encodeAccountResult(output: []u8, result: AccountResult) ![]const u8 {
    const fields = .{ result.provider_account_id, result.email, result.display_name, result.session_key, result.api_base_url };
    var total: usize = 16;
    inline for (fields) |field| {
        if (field.len == 0 or field.len > std.math.maxInt(u16)) return error.InvalidAccountResult;
        total += field.len;
    }
    if (total > output.len) return error.ResponseTooLarge;
    @memcpy(output[0..4], "IZOA");
    output[4] = 1;
    output[5] = @intFromEnum(result.provider);
    var header_offset: usize = 6;
    inline for (fields) |field| {
        writeU16(output[header_offset..][0..2], @intCast(field.len));
        header_offset += 2;
    }
    var offset: usize = 16;
    inline for (fields) |field| {
        @memcpy(output[offset..][0..field.len], field);
        offset += field.len;
    }
    return output[0..offset];
}

pub fn decodeAccountResult(bytes: []const u8) !AccountResult {
    if (bytes.len < 16 or !std.mem.eql(u8, bytes[0..4], "IZOA") or bytes[4] != 1) return error.InvalidAccountResult;
    const provider = std.enums.fromInt(Provider, bytes[5]) orelse return error.InvalidAccountResult;
    var lengths: [5]usize = undefined;
    var header_offset: usize = 6;
    var total: usize = 16;
    for (&lengths) |*length| {
        length.* = readU16(bytes[header_offset..][0..2]);
        if (length.* == 0) return error.InvalidAccountResult;
        total += length.*;
        header_offset += 2;
    }
    if (total != bytes.len) return error.InvalidAccountResult;
    var offset: usize = 16;
    return .{
        .provider = provider,
        .provider_account_id = take(bytes, &offset, lengths[0]),
        .email = take(bytes, &offset, lengths[1]),
        .display_name = take(bytes, &offset, lengths[2]),
        .session_key = take(bytes, &offset, lengths[3]),
        .api_base_url = take(bytes, &offset, lengths[4]),
    };
}

pub const Request = struct {
    method: Method,
    session_key: []const u8,
    url: []const u8,
    content_type: []const u8 = "",
    body: []const u8 = "",
};

/// Compact framing avoids JSON escaping expansion crossing Native SDK's 64 KiB
/// host-payload limit.
pub fn encodeRequest(output: []u8, request: Request) ![]const u8 {
    if (request.session_key.len == 0 or request.session_key.len > max_session_key_bytes or
        request.url.len == 0 or request.url.len > max_url_bytes or
        request.content_type.len > max_content_type_bytes or request.body.len > std.math.maxInt(u32)) return error.InvalidRequest;
    const total = request_header_bytes + request.session_key.len + request.url.len + request.content_type.len + request.body.len;
    if (total > max_host_payload_bytes or total > output.len) return error.RequestTooLarge;
    @memcpy(output[0..4], request_magic);
    output[4] = 1;
    output[5] = @intFromEnum(request.method);
    writeU16(output[6..8], @intCast(request.session_key.len));
    writeU16(output[8..10], @intCast(request.url.len));
    writeU16(output[10..12], @intCast(request.content_type.len));
    writeU32(output[12..16], @intCast(request.body.len));
    var offset: usize = request_header_bytes;
    inline for (.{ request.session_key, request.url, request.content_type, request.body }) |part| {
        @memcpy(output[offset..][0..part.len], part);
        offset += part.len;
    }
    return output[0..offset];
}

pub fn decodeRequest(bytes: []const u8) !Request {
    if (bytes.len < request_header_bytes or bytes.len > max_host_payload_bytes or !std.mem.eql(u8, bytes[0..4], request_magic) or bytes[4] != 1)
        return error.InvalidRequest;
    const method = std.enums.fromInt(Method, bytes[5]) orelse return error.InvalidRequest;
    const session_len: usize = readU16(bytes[6..8]);
    const url_len: usize = readU16(bytes[8..10]);
    const content_type_len: usize = readU16(bytes[10..12]);
    const body_len: usize = readU32(bytes[12..16]);
    const total = request_header_bytes + session_len + url_len + content_type_len + body_len;
    if (total != bytes.len or session_len == 0 or session_len > max_session_key_bytes or url_len == 0 or url_len > max_url_bytes or content_type_len > max_content_type_bytes)
        return error.InvalidRequest;
    var offset: usize = request_header_bytes;
    return .{
        .method = method,
        .session_key = take(bytes, &offset, session_len),
        .url = take(bytes, &offset, url_len),
        .content_type = take(bytes, &offset, content_type_len),
        .body = take(bytes, &offset, body_len),
    };
}

pub const Response = struct {
    outcome: TransportOutcome,
    status: u16 = 0,
    truncated: bool = false,
    body: []const u8 = "",
};

pub fn encodeResponse(output: []u8, response: Response) ![]const u8 {
    const total = response_header_bytes + response.body.len;
    if (response.body.len > std.math.maxInt(u32) or total > max_host_result_bytes or total > output.len) return error.ResponseTooLarge;
    @memcpy(output[0..4], response_magic);
    output[4] = 1;
    output[5] = @intFromEnum(response.outcome);
    output[6] = @intFromBool(response.truncated);
    output[7] = 0;
    writeU16(output[8..10], response.status);
    writeU32(output[10..14], @intCast(response.body.len));
    const destination = output[response_header_bytes..][0..response.body.len];
    if (destination.ptr != response.body.ptr) std.mem.copyForwards(u8, destination, response.body);
    return output[0..total];
}

pub fn decodeResponse(bytes: []const u8) !Response {
    if (bytes.len < response_header_bytes or bytes.len > max_host_result_bytes or !std.mem.eql(u8, bytes[0..4], response_magic) or bytes[4] != 1 or bytes[7] != 0)
        return error.InvalidResponse;
    const outcome = std.enums.fromInt(TransportOutcome, bytes[5]) orelse return error.InvalidResponse;
    if (bytes[6] > 1) return error.InvalidResponse;
    const body_len: usize = readU32(bytes[10..14]);
    if (response_header_bytes + body_len != bytes.len) return error.InvalidResponse;
    return .{ .outcome = outcome, .status = readU16(bytes[8..10]), .truncated = bytes[6] == 1, .body = bytes[response_header_bytes..] };
}

fn take(bytes: []const u8, offset: *usize, len: usize) []const u8 {
    const result = bytes[offset.*..][0..len];
    offset.* += len;
    return result;
}
fn writeU16(output: []u8, value: u16) void {
    std.mem.writeInt(u16, output[0..2], value, .little);
}
fn writeU32(output: []u8, value: u32) void {
    std.mem.writeInt(u32, output[0..4], value, .little);
}
fn readU16(input: []const u8) u16 {
    return std.mem.readInt(u16, input[0..2], .little);
}
fn readU32(input: []const u8) u32 {
    return std.mem.readInt(u32, input[0..4], .little);
}

test "authorized request binary frame preserves opaque provider bodies" {
    var encoded: [max_host_payload_bytes]u8 = undefined;
    const body = "{\"raw\":\"+/= and \\u0000-like text\"}";
    const bytes = try encodeRequest(&encoded, .{ .method = .post, .session_key = "gmail:subject-1", .url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/send", .content_type = "application/json", .body = body });
    const decoded = try decodeRequest(bytes);
    try std.testing.expectEqual(Method.post, decoded.method);
    try std.testing.expectEqualStrings(body, decoded.body);
}

test "authorized request enforces total 64 KiB framing budget" {
    var encoded: [max_host_payload_bytes]u8 = undefined;
    const exact_body_len = max_host_payload_bytes - request_header_bytes - 2;
    const exact_body = try std.testing.allocator.alloc(u8, exact_body_len);
    defer std.testing.allocator.free(exact_body);
    _ = try encodeRequest(&encoded, .{ .method = .post, .session_key = "s", .url = "u", .body = exact_body });
    const oversized = try std.testing.allocator.alloc(u8, exact_body_len + 1);
    defer std.testing.allocator.free(oversized);
    try std.testing.expectError(error.RequestTooLarge, encodeRequest(&encoded, .{ .method = .post, .session_key = "s", .url = "u", .body = oversized }));
}

test "response distinguishes HTTP status transport failure and truncation" {
    var encoded: [128]u8 = undefined;
    const decoded = try decodeResponse(try encodeResponse(&encoded, .{ .outcome = .ok, .status = 401, .truncated = true, .body = "oauth expired" }));
    try std.testing.expectEqual(TransportOutcome.ok, decoded.outcome);
    try std.testing.expectEqual(@as(u16, 401), decoded.status);
    try std.testing.expect(decoded.truncated);
    const failure = try decodeResponse(try encodeResponse(&encoded, .{ .outcome = .connect_failed }));
    try std.testing.expectEqual(TransportOutcome.connect_failed, failure.outcome);
    try std.testing.expectEqual(@as(u16, 0), failure.status);
}

test "response encoder supports body already placed after its frame header" {
    var encoded: [64]u8 = undefined;
    @memcpy(encoded[response_header_bytes..][0..4], "mail");
    const bytes = try encodeResponse(&encoded, .{ .outcome = .ok, .status = 200, .body = encoded[response_header_bytes..][0..4] });
    try std.testing.expectEqualStrings("mail", (try decodeResponse(bytes)).body);
}

test "OAuth account result contains metadata and opaque handle only" {
    var encoded: [1024]u8 = undefined;
    const bytes = try encodeAccountResult(&encoded, .{ .provider = .gmail, .provider_account_id = "google-subject", .email = "person@example.com", .display_name = "Person", .session_key = "gmail:google-subject", .api_base_url = "https://gmail.googleapis.com" });
    const decoded = try decodeAccountResult(bytes);
    try std.testing.expectEqual(Provider.gmail, decoded.provider);
    try std.testing.expectEqualStrings("google-subject", decoded.provider_account_id);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "access_token") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "refresh_token") == null);
}
