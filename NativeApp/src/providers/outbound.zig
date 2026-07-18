const std = @import("std");

pub const max_url_bytes: usize = 2048;
pub const max_payload_bytes: usize = 64 * 1024;

pub const BuildError = error{
    BufferTooSmall,
    InvalidHeader,
    InvalidAddress,
    PayloadTooLarge,
    UrlTooLong,
};

pub const ComposeMode = enum {
    new,
    reply,
    reply_all,
    forward,
};

pub const Recipient = struct {
    name: ?[]const u8 = null,
    address: []const u8,
};

/// Provider-neutral outbound state. All slices are borrowed; request builders
/// copy their output into caller-owned buffers before returning a Request.
pub const OutgoingMessage = struct {
    mode: ComposeMode = .new,
    from: Recipient,
    to: []const Recipient = &.{},
    cc: []const Recipient = &.{},
    bcc: []const Recipient = &.{},
    subject: []const u8 = "",
    plain_body: []const u8 = "",
    html_body: ?[]const u8 = null,
    thread_id: ?[]const u8 = null,
    in_reply_to: ?[]const u8 = null,
    references: ?[]const u8 = null,
};

pub const Request = struct {
    method: std.http.Method,
    url: []const u8,
    content_type: ?[]const u8,
    body: ?[]const u8,
};

pub const Buffers = struct {
    url: []u8,
    body: []u8,

    pub fn init(url: []u8, body: []u8) Buffers {
        return .{ .url = url, .body = body };
    }
};

pub const Cursor = struct {
    bytes: []u8,
    len: usize = 0,
    limit: usize,

    pub fn init(bytes: []u8, limit: usize) Cursor {
        return .{ .bytes = bytes, .limit = @min(bytes.len, limit) };
    }

    pub fn append(self: *Cursor, value: []const u8) BuildError!void {
        const end = std.math.add(usize, self.len, value.len) catch return error.BufferTooSmall;
        if (end > self.limit) return error.BufferTooSmall;
        @memcpy(self.bytes[self.len..end], value);
        self.len = end;
    }

    pub fn appendByte(self: *Cursor, value: u8) BuildError!void {
        if (self.len >= self.limit) return error.BufferTooSmall;
        self.bytes[self.len] = value;
        self.len += 1;
    }

    pub fn reserve(self: *Cursor, count: usize) BuildError![]u8 {
        const end = std.math.add(usize, self.len, count) catch return error.BufferTooSmall;
        if (end > self.limit) return error.BufferTooSmall;
        const result = self.bytes[self.len..end];
        self.len = end;
        return result;
    }

    pub fn written(self: *const Cursor) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub fn urlCursor(buffer: []u8) Cursor {
    return Cursor.init(buffer, max_url_bytes);
}

pub fn bodyCursor(buffer: []u8) Cursor {
    return Cursor.init(buffer, max_payload_bytes);
}

pub fn finishRequest(method: std.http.Method, url: *const Cursor, body: ?*const Cursor) BuildError!Request {
    if (url.len > max_url_bytes) return error.UrlTooLong;
    if (body) |value| {
        if (value.len > max_payload_bytes) return error.PayloadTooLarge;
        return .{
            .method = method,
            .url = url.written(),
            .content_type = "application/json",
            .body = value.written(),
        };
    }
    return .{
        .method = method,
        .url = url.written(),
        .content_type = null,
        .body = null,
    };
}

pub fn appendBaseUrl(cursor: *Cursor, base_url: []const u8) BuildError!void {
    if (base_url.len == 0) return error.UrlTooLong;
    if (base_url[base_url.len - 1] == '/') {
        try cursor.append(base_url[0 .. base_url.len - 1]);
    } else {
        try cursor.append(base_url);
    }
}

pub fn appendPathSegment(cursor: *Cursor, value: []const u8) BuildError!void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try cursor.appendByte(byte);
        } else {
            try cursor.appendByte('%');
            try cursor.appendByte(hex[byte >> 4]);
            try cursor.appendByte(hex[byte & 0x0f]);
        }
    }
}

pub fn appendJsonString(cursor: *Cursor, value: []const u8) BuildError!void {
    const hex = "0123456789ABCDEF";
    try cursor.appendByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try cursor.append("\\\""),
            '\\' => try cursor.append("\\\\"),
            '\n' => try cursor.append("\\n"),
            '\r' => try cursor.append("\\r"),
            '\t' => try cursor.append("\\t"),
            0x08 => try cursor.append("\\b"),
            0x0c => try cursor.append("\\f"),
            0...0x07, 0x0b, 0x0e...0x1f => {
                try cursor.append("\\u00");
                try cursor.appendByte(hex[byte >> 4]);
                try cursor.appendByte(hex[byte & 0x0f]);
            },
            else => try cursor.appendByte(byte),
        }
    }
    try cursor.appendByte('"');
}

pub fn validateHeader(value: []const u8) BuildError!void {
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidHeader;
}

pub fn validateAddress(value: []const u8) BuildError!void {
    try validateHeader(value);
    const at = std.mem.indexOfScalar(u8, value, '@') orelse return error.InvalidAddress;
    if (at == 0 or at + 1 == value.len or std.mem.indexOfAny(u8, value, "<>,\"\\ \t") != null) {
        return error.InvalidAddress;
    }
}

test "JSON strings escape controls and retain UTF-8" {
    var bytes: [128]u8 = undefined;
    var cursor = bodyCursor(&bytes);
    try appendJsonString(&cursor, "quote \" slash \\ line\nCafé");
    try std.testing.expectEqualStrings("\"quote \\\" slash \\\\ line\\nCafé\"", cursor.written());
}

test "path segments are percent encoded" {
    var bytes: [128]u8 = undefined;
    var cursor = urlCursor(&bytes);
    try appendPathSegment(&cursor, "draft/id + one");
    try std.testing.expectEqualStrings("draft%2Fid%20%2B%20one", cursor.written());
}

test "header injection is rejected" {
    try std.testing.expectError(error.InvalidHeader, validateHeader("Safe\r\nBcc: attacker@example.com"));
    try std.testing.expectError(error.InvalidAddress, validateAddress("Display Name only"));
}

test "request bodies cannot exceed the Native SDK fetch limit" {
    var bytes: [max_payload_bytes + 1]u8 = undefined;
    var cursor = bodyCursor(&bytes);
    _ = try cursor.reserve(max_payload_bytes);
    try std.testing.expectError(error.BufferTooSmall, cursor.appendByte('x'));
}
