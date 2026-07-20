const std = @import("std");
const outbound = @import("../outbound.zig");

pub const default_boundary = "=_InboxZeroMail_Native";

pub fn buildRaw(buffer: []u8, message: outbound.OutgoingMessage) outbound.BuildError![]const u8 {
    var cursor = outbound.Cursor.init(buffer, outbound.max_payload_bytes);
    try appendAddressHeader(&cursor, "From", &.{message.from});
    try appendAddressHeader(&cursor, "To", message.to);
    if (message.cc.len > 0) try appendAddressHeader(&cursor, "Cc", message.cc);
    if (message.bcc.len > 0) try appendAddressHeader(&cursor, "Bcc", message.bcc);
    try appendSimpleHeader(&cursor, "Subject", message.subject);
    if (message.in_reply_to) |value| try appendSimpleHeader(&cursor, "In-Reply-To", value);
    if (message.references) |value| try appendSimpleHeader(&cursor, "References", value);
    try cursor.append("MIME-Version: 1.0\r\n");
    try cursor.append("Content-Type: multipart/alternative; boundary=\"");
    try cursor.append(default_boundary);
    try cursor.append("\"\r\n\r\n");

    try cursor.append("--");
    try cursor.append(default_boundary);
    try cursor.append("\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n");
    try appendCrlfBody(&cursor, message.plain_body);
    try cursor.append("\r\n--");
    try cursor.append(default_boundary);
    try cursor.append("\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n");
    if (message.html_body) |html| {
        try appendCrlfBody(&cursor, html);
    } else {
        try cursor.append("<div>");
        try appendHtmlEscaped(&cursor, message.plain_body);
        try cursor.append("</div>");
    }
    try cursor.append("\r\n--");
    try cursor.append(default_boundary);
    try cursor.append("--\r\n");
    return cursor.written();
}

pub fn encodedSize(message: outbound.OutgoingMessage, raw_buffer: []u8) outbound.BuildError!usize {
    const raw = try buildRaw(raw_buffer, message);
    return std.base64.url_safe_no_pad.Encoder.calcSize(raw.len);
}

pub fn encodeBase64Url(destination: []u8, raw_buffer: []u8, message: outbound.OutgoingMessage) outbound.BuildError![]const u8 {
    const raw = try buildRaw(raw_buffer, message);
    const size = std.base64.url_safe_no_pad.Encoder.calcSize(raw.len);
    if (size > destination.len or size > outbound.max_payload_bytes) return error.BufferTooSmall;
    return std.base64.url_safe_no_pad.Encoder.encode(destination[0..size], raw);
}

fn appendSimpleHeader(cursor: *outbound.Cursor, name: []const u8, value: []const u8) outbound.BuildError!void {
    try outbound.validateHeader(value);
    try cursor.append(name);
    try cursor.append(": ");
    try cursor.append(value);
    try cursor.append("\r\n");
}

fn appendAddressHeader(cursor: *outbound.Cursor, name: []const u8, recipients: []const outbound.Recipient) outbound.BuildError!void {
    try cursor.append(name);
    try cursor.append(": ");
    for (recipients, 0..) |recipient, index| {
        if (index > 0) try cursor.append(", ");
        try appendRecipient(cursor, recipient);
    }
    try cursor.append("\r\n");
}

fn appendRecipient(cursor: *outbound.Cursor, recipient: outbound.Recipient) outbound.BuildError!void {
    try outbound.validateAddress(recipient.address);
    if (recipient.name) |name| {
        try outbound.validateHeader(name);
        if (name.len > 0) {
            try cursor.appendByte('"');
            for (name) |byte| {
                if (byte == '"' or byte == '\\') try cursor.appendByte('\\');
                try cursor.appendByte(byte);
            }
            try cursor.append("\" <");
            try cursor.append(recipient.address);
            try cursor.appendByte('>');
            return;
        }
    }
    try cursor.append(recipient.address);
}

fn appendCrlfBody(cursor: *outbound.Cursor, value: []const u8) outbound.BuildError!void {
    var index: usize = 0;
    while (index < value.len) {
        switch (value[index]) {
            '\r' => {
                try cursor.append("\r\n");
                index += 1;
                if (index < value.len and value[index] == '\n') index += 1;
            },
            '\n' => {
                try cursor.append("\r\n");
                index += 1;
            },
            else => {
                try cursor.appendByte(value[index]);
                index += 1;
            },
        }
    }
}

fn appendHtmlEscaped(cursor: *outbound.Cursor, value: []const u8) outbound.BuildError!void {
    for (value) |byte| {
        switch (byte) {
            '&' => try cursor.append("&amp;"),
            '<' => try cursor.append("&lt;"),
            '>' => try cursor.append("&gt;"),
            '"' => try cursor.append("&quot;"),
            '\n' => try cursor.append("<br>\r\n"),
            '\r' => {},
            else => try cursor.appendByte(byte),
        }
    }
}

test "MIME uses proper address headers, CRLF, UTF-8, and reply headers" {
    const to = [_]outbound.Recipient{
        .{ .name = "Customer, Inc.", .address = "customer@example.com" },
        .{ .address = "second@example.com" },
    };
    const cc = [_]outbound.Recipient{.{ .name = "Café Ops", .address = "ops@example.com" }};
    const bcc = [_]outbound.Recipient{.{ .address = "audit@example.com" }};
    var buffer: [8192]u8 = undefined;
    const raw = try buildRaw(&buffer, .{
        .mode = .reply,
        .from = .{ .name = "Inbox Zero", .address = "me@example.com" },
        .to = &to,
        .cc = &cc,
        .bcc = &bcc,
        .subject = "Re: Launch",
        .plain_body = "Hello 🌍\nSecond line\rThird line\r\nFourth line",
        .html_body = "<p>Hello 🌍</p>",
        .thread_id = "thread-1",
        .in_reply_to = "<message-1@example.com>",
        .references = "<root@example.com> <message-1@example.com>",
    });
    try std.testing.expect(std.mem.indexOf(u8, raw, "From: \"Inbox Zero\" <me@example.com>\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "To: \"Customer, Inc.\" <customer@example.com>, second@example.com\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "Cc: \"Café Ops\" <ops@example.com>\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "Bcc: audit@example.com\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "In-Reply-To: <message-1@example.com>\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "Hello 🌍\r\nSecond line\r\nThird line\r\nFourth line") != null);
    for (raw, 0..) |byte, index| {
        if (byte == '\n') try std.testing.expect(index > 0 and raw[index - 1] == '\r');
    }
}

test "MIME rejects injected addresses" {
    var buffer: [1024]u8 = undefined;
    try std.testing.expectError(error.InvalidHeader, buildRaw(&buffer, .{
        .from = .{ .address = "me@example.com\r\nBcc: bad@example.com" },
        .to = &.{.{ .address = "to@example.com" }},
    }));
}
