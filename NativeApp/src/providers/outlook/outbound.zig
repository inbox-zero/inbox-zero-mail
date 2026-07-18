const std = @import("std");
const common = @import("../outbound.zig");

pub fn createDraft(buffers: common.Buffers, base_url: []const u8, message: common.OutgoingMessage) common.BuildError!common.Request {
    var url = try graphUrl(buffers.url, base_url, "/v1.0/me/messages", null, null);
    var body = common.bodyCursor(buffers.body);
    try appendGraphMessage(&body, message);
    return common.finishRequest(.POST, &url, &body);
}

pub fn updateDraft(buffers: common.Buffers, base_url: []const u8, draft_id: []const u8, message: common.OutgoingMessage) common.BuildError!common.Request {
    var url = try graphUrl(buffers.url, base_url, "/v1.0/me/messages/", draft_id, null);
    var body = common.bodyCursor(buffers.body);
    try appendGraphMessage(&body, message);
    return common.finishRequest(.PATCH, &url, &body);
}

pub fn sendDraft(buffers: common.Buffers, base_url: []const u8, draft_id: []const u8) common.BuildError!common.Request {
    var url = try graphUrl(buffers.url, base_url, "/v1.0/me/messages/", draft_id, "/send");
    return common.finishRequest(.POST, &url, null);
}

pub fn deleteDraft(buffers: common.Buffers, base_url: []const u8, draft_id: []const u8) common.BuildError!common.Request {
    var url = try graphUrl(buffers.url, base_url, "/v1.0/me/messages/", draft_id, null);
    return common.finishRequest(.DELETE, &url, null);
}

pub fn sendMail(buffers: common.Buffers, base_url: []const u8, message: common.OutgoingMessage) common.BuildError!common.Request {
    var url = try graphUrl(buffers.url, base_url, "/v1.0/me/sendMail", null, null);
    var body = common.bodyCursor(buffers.body);
    try body.append("{\"message\":");
    try appendGraphMessage(&body, message);
    try body.append(",\"saveToSentItems\":true}");
    return common.finishRequest(.POST, &url, &body);
}

pub fn reply(buffers: common.Buffers, base_url: []const u8, original_message_id: []const u8, message: common.OutgoingMessage) common.BuildError!common.Request {
    return replyRequest(buffers, base_url, original_message_id, message, false);
}

pub fn replyAll(buffers: common.Buffers, base_url: []const u8, original_message_id: []const u8, message: common.OutgoingMessage) common.BuildError!common.Request {
    return replyRequest(buffers, base_url, original_message_id, message, true);
}

pub fn createReplyDraft(buffers: common.Buffers, base_url: []const u8, original_message_id: []const u8, reply_all: bool) common.BuildError!common.Request {
    const suffix = if (reply_all) "/createReplyAll" else "/createReply";
    var url = try graphUrl(buffers.url, base_url, "/v1.0/me/messages/", original_message_id, suffix);
    return common.finishRequest(.POST, &url, null);
}

pub fn createForwardDraft(buffers: common.Buffers, base_url: []const u8, original_message_id: []const u8) common.BuildError!common.Request {
    var url = try graphUrl(buffers.url, base_url, "/v1.0/me/messages/", original_message_id, "/createForward");
    return common.finishRequest(.POST, &url, null);
}

pub fn forward(buffers: common.Buffers, base_url: []const u8, original_message_id: []const u8, message: common.OutgoingMessage) common.BuildError!common.Request {
    var url = try graphUrl(buffers.url, base_url, "/v1.0/me/messages/", original_message_id, "/forward");
    var body = common.bodyCursor(buffers.body);
    try body.append("{\"message\":");
    try appendGraphMessage(&body, message);
    try body.appendByte('}');
    return common.finishRequest(.POST, &url, &body);
}

fn replyRequest(buffers: common.Buffers, base_url: []const u8, original_message_id: []const u8, message: common.OutgoingMessage, all: bool) common.BuildError!common.Request {
    const suffix = if (all) "/replyAll" else "/reply";
    var url = try graphUrl(buffers.url, base_url, "/v1.0/me/messages/", original_message_id, suffix);
    var body = common.bodyCursor(buffers.body);
    try body.append("{\"comment\":");
    try common.appendJsonString(&body, message.html_body orelse message.plain_body);
    try body.appendByte('}');
    return common.finishRequest(.POST, &url, &body);
}

fn graphUrl(buffer: []u8, base_url: []const u8, path: []const u8, segment: ?[]const u8, suffix: ?[]const u8) common.BuildError!common.Cursor {
    var url = common.urlCursor(buffer);
    try common.appendBaseUrl(&url, base_url);
    try url.append(path);
    if (segment) |value| try common.appendPathSegment(&url, value);
    if (suffix) |value| try url.append(value);
    return url;
}

fn appendGraphMessage(body: *common.Cursor, message: common.OutgoingMessage) common.BuildError!void {
    try body.append("{\"subject\":");
    try common.appendJsonString(body, message.subject);
    try body.append(",\"body\":{\"contentType\":");
    try common.appendJsonString(body, if (message.html_body != null) "html" else "text");
    try body.append(",\"content\":");
    try common.appendJsonString(body, message.html_body orelse message.plain_body);
    try body.append("},\"toRecipients\":");
    try appendRecipients(body, message.to);
    try body.append(",\"ccRecipients\":");
    try appendRecipients(body, message.cc);
    try body.append(",\"bccRecipients\":");
    try appendRecipients(body, message.bcc);
    try body.appendByte('}');
}

fn appendRecipients(body: *common.Cursor, recipients: []const common.Recipient) common.BuildError!void {
    try body.appendByte('[');
    for (recipients, 0..) |recipient, index| {
        try common.validateAddress(recipient.address);
        if (index > 0) try body.appendByte(',');
        try body.append("{\"emailAddress\":{\"address\":");
        try common.appendJsonString(body, recipient.address);
        if (recipient.name) |name| {
            try common.validateHeader(name);
            try body.append(",\"name\":");
            try common.appendJsonString(body, name);
        }
        try body.append("}}");
    }
    try body.appendByte(']');
}

test "Outlook new mail and draft requests include escaped recipients and UTF-8" {
    const to = [_]common.Recipient{.{ .name = "A \"quoted\" name", .address = "to@example.com" }};
    const cc = [_]common.Recipient{.{ .address = "cc@example.com" }};
    const bcc = [_]common.Recipient{.{ .address = "bcc@example.com" }};
    const message: common.OutgoingMessage = .{
        .from = .{ .address = "me@example.com" },
        .to = &to,
        .cc = &cc,
        .bcc = &bcc,
        .subject = "Hello \"Graph\"",
        .plain_body = "Plain",
        .html_body = "<p>Zażółć 🌍</p>",
    };
    var url_bytes: [2048]u8 = undefined;
    var body_bytes: [64 * 1024]u8 = undefined;
    const sent = try sendMail(.init(&url_bytes, &body_bytes), "http://localhost:4403/", message);
    try std.testing.expectEqualStrings("http://localhost:4403/v1.0/me/sendMail", sent.url);
    try std.testing.expect(std.mem.indexOf(u8, sent.body.?, "\"saveToSentItems\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent.body.?, "A \\\"quoted\\\" name") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent.body.?, "<p>Zażółć 🌍</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent.body.?, "\"bccRecipients\":[{\"emailAddress\":{\"address\":\"bcc@example.com\"}}]") != null);

    const draft = try createDraft(.init(&url_bytes, &body_bytes), "https://graph.microsoft.com", message);
    try std.testing.expectEqual(std.http.Method.POST, draft.method);
    try std.testing.expectEqualStrings("https://graph.microsoft.com/v1.0/me/messages", draft.url);
}

test "Outlook draft, reply, reply-all, and forward endpoints are exact" {
    const message: common.OutgoingMessage = .{
        .mode = .reply,
        .from = .{ .address = "me@example.com" },
        .to = &.{.{ .address = "to@example.com" }},
        .subject = "Re: status",
        .plain_body = "Line one\n\"quoted\"",
    };
    var url_bytes: [2048]u8 = undefined;
    var body_bytes: [64 * 1024]u8 = undefined;

    const updated = try updateDraft(.init(&url_bytes, &body_bytes), "http://localhost:4403", "draft/id", message);
    try std.testing.expectEqual(std.http.Method.PATCH, updated.method);
    try std.testing.expectEqualStrings("http://localhost:4403/v1.0/me/messages/draft%2Fid", updated.url);

    const sent = try sendDraft(.init(&url_bytes, &body_bytes), "http://localhost:4403", "draft/id");
    try std.testing.expectEqualStrings("http://localhost:4403/v1.0/me/messages/draft%2Fid/send", sent.url);
    try std.testing.expect(sent.body == null);

    const deleted = try deleteDraft(.init(&url_bytes, &body_bytes), "http://localhost:4403", "draft/id");
    try std.testing.expectEqual(std.http.Method.DELETE, deleted.method);

    const replied = try reply(.init(&url_bytes, &body_bytes), "http://localhost:4403", "message 1", message);
    try std.testing.expectEqualStrings("http://localhost:4403/v1.0/me/messages/message%201/reply", replied.url);
    try std.testing.expectEqualStrings("{\"comment\":\"Line one\\n\\\"quoted\\\"\"}", replied.body.?);

    const replied_all = try replyAll(.init(&url_bytes, &body_bytes), "http://localhost:4403", "message 1", message);
    try std.testing.expectEqualStrings("http://localhost:4403/v1.0/me/messages/message%201/replyAll", replied_all.url);

    const reply_draft = try createReplyDraft(.init(&url_bytes, &body_bytes), "http://localhost:4403", "message 1", true);
    try std.testing.expectEqualStrings("http://localhost:4403/v1.0/me/messages/message%201/createReplyAll", reply_draft.url);

    const forward_draft = try createForwardDraft(.init(&url_bytes, &body_bytes), "http://localhost:4403", "message 1");
    try std.testing.expectEqualStrings("http://localhost:4403/v1.0/me/messages/message%201/createForward", forward_draft.url);

    const forwarded = try forward(.init(&url_bytes, &body_bytes), "http://localhost:4403", "message 1", message);
    try std.testing.expectEqualStrings("http://localhost:4403/v1.0/me/messages/message%201/forward", forwarded.url);
    try std.testing.expect(std.mem.startsWith(u8, forwarded.body.?, "{\"message\":{"));
}
