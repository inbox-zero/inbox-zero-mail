const std = @import("std");
const common = @import("../outbound.zig");
const mime = @import("mime.zig");

pub const BuildBuffers = struct {
    request: common.Buffers,
    mime_raw: []u8,

    pub fn init(url: []u8, body: []u8, mime_raw: []u8) BuildBuffers {
        return .{ .request = .init(url, body), .mime_raw = mime_raw };
    }
};

pub fn directSend(buffers: BuildBuffers, base_url: []const u8, message: common.OutgoingMessage) common.BuildError!common.Request {
    var url = try gmailUrl(buffers.request.url, base_url, "/gmail/v1/users/me/messages/send", null);
    var body = common.bodyCursor(buffers.request.body);
    try appendRawMessageBody(&body, buffers.mime_raw, message, false);
    return common.finishRequest(.POST, &url, &body);
}

pub fn createDraft(buffers: BuildBuffers, base_url: []const u8, message: common.OutgoingMessage) common.BuildError!common.Request {
    var url = try gmailUrl(buffers.request.url, base_url, "/gmail/v1/users/me/drafts", null);
    var body = common.bodyCursor(buffers.request.body);
    try appendRawMessageBody(&body, buffers.mime_raw, message, true);
    return common.finishRequest(.POST, &url, &body);
}

pub fn updateDraft(buffers: BuildBuffers, base_url: []const u8, draft_id: []const u8, message: common.OutgoingMessage) common.BuildError!common.Request {
    var url = try gmailUrl(buffers.request.url, base_url, "/gmail/v1/users/me/drafts/", draft_id);
    var body = common.bodyCursor(buffers.request.body);
    try appendRawMessageBody(&body, buffers.mime_raw, message, true);
    return common.finishRequest(.PUT, &url, &body);
}

pub fn sendDraft(buffers: common.Buffers, base_url: []const u8, draft_id: []const u8) common.BuildError!common.Request {
    var url = try gmailUrl(buffers.url, base_url, "/gmail/v1/users/me/drafts/send", null);
    var body = common.bodyCursor(buffers.body);
    try body.append("{\"id\":");
    try common.appendJsonString(&body, draft_id);
    try body.appendByte('}');
    return common.finishRequest(.POST, &url, &body);
}

pub fn deleteDraft(buffers: common.Buffers, base_url: []const u8, draft_id: []const u8) common.BuildError!common.Request {
    var url = try gmailUrl(buffers.url, base_url, "/gmail/v1/users/me/drafts/", draft_id);
    return common.finishRequest(.DELETE, &url, null);
}

fn gmailUrl(buffer: []u8, base_url: []const u8, path: []const u8, segment: ?[]const u8) common.BuildError!common.Cursor {
    var url = common.urlCursor(buffer);
    try common.appendBaseUrl(&url, base_url);
    try url.append(path);
    if (segment) |value| try common.appendPathSegment(&url, value);
    return url;
}

fn appendRawMessageBody(body: *common.Cursor, raw_buffer: []u8, message: common.OutgoingMessage, nested: bool) common.BuildError!void {
    const raw = try mime.buildRaw(raw_buffer, message);
    const encoded_size = std.base64.url_safe_no_pad.Encoder.calcSize(raw.len);
    if (nested) try body.append("{\"message\":{") else try body.appendByte('{');
    try body.append("\"raw\":\"");
    const encoded = try body.reserve(encoded_size);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, raw);
    try body.appendByte('"');
    if (message.thread_id) |thread_id| {
        try body.append(",\"threadId\":");
        try common.appendJsonString(body, thread_id);
    }
    if (nested) try body.append("}}") else try body.appendByte('}');
}

test "Gmail direct reply uses exact endpoint and threadId" {
    var url_bytes: [2048]u8 = undefined;
    var body_bytes: [64 * 1024]u8 = undefined;
    var raw_bytes: [48 * 1024]u8 = undefined;
    const request = try directSend(.init(&url_bytes, &body_bytes, &raw_bytes), "http://localhost:4402/", .{
        .mode = .reply,
        .from = .{ .name = "Me", .address = "me@example.com" },
        .to = &.{.{ .name = "Customer", .address = "customer@example.com" }},
        .cc = &.{.{ .address = "cc@example.com" }},
        .bcc = &.{.{ .address = "bcc@example.com" }},
        .subject = "Re: Hello \"team\"",
        .plain_body = "Unicode: Zażółć 🌍",
        .thread_id = "thread/one",
    });
    try std.testing.expectEqual(std.http.Method.POST, request.method);
    try std.testing.expectEqualStrings("http://localhost:4402/gmail/v1/users/me/messages/send", request.url);
    try std.testing.expect(std.mem.indexOf(u8, request.body.?, "\"threadId\":\"thread/one\"") != null);
    try std.testing.expect(request.body.?.len <= common.max_payload_bytes);
}

test "Gmail draft endpoints and JSON escaping are exact" {
    var url_bytes: [2048]u8 = undefined;
    var body_bytes: [64 * 1024]u8 = undefined;
    var raw_bytes: [48 * 1024]u8 = undefined;
    const message: common.OutgoingMessage = .{
        .from = .{ .address = "me@example.com" },
        .to = &.{.{ .address = "to@example.com" }},
        .subject = "Draft",
        .plain_body = "Body",
    };
    const created = try createDraft(.init(&url_bytes, &body_bytes, &raw_bytes), "https://gmail.googleapis.com", message);
    try std.testing.expectEqualStrings("https://gmail.googleapis.com/gmail/v1/users/me/drafts", created.url);
    try std.testing.expect(std.mem.startsWith(u8, created.body.?, "{\"message\":{\"raw\":\""));

    const updated = try updateDraft(.init(&url_bytes, &body_bytes, &raw_bytes), "http://localhost:4402", "draft/id + one", message);
    try std.testing.expectEqual(std.http.Method.PUT, updated.method);
    try std.testing.expectEqualStrings("http://localhost:4402/gmail/v1/users/me/drafts/draft%2Fid%20%2B%20one", updated.url);

    const sent = try sendDraft(.init(&url_bytes, &body_bytes), "http://localhost:4402", "draft\"one");
    try std.testing.expectEqualStrings("http://localhost:4402/gmail/v1/users/me/drafts/send", sent.url);
    try std.testing.expectEqualStrings("{\"id\":\"draft\\\"one\"}", sent.body.?);

    const deleted = try deleteDraft(.init(&url_bytes, &body_bytes), "http://localhost:4402", "draft/id");
    try std.testing.expectEqual(std.http.Method.DELETE, deleted.method);
    try std.testing.expectEqualStrings("http://localhost:4402/gmail/v1/users/me/drafts/draft%2Fid", deleted.url);
}
