const std = @import("std");

/// Fixed-capacity, model-owned UTF-8 bytes. Values are truncated at the
/// capacity boundary so every slice remains valid across UI rebuilds.
pub fn Text(comptime capacity: usize) type {
    return struct {
        storage: [capacity]u8 = [_]u8{0} ** capacity,
        len: usize = 0,

        const Self = @This();

        pub fn set(self: *Self, value: []const u8) void {
            var size = @min(value.len, capacity);
            while (size > 0 and !std.unicode.utf8ValidateSlice(value[0..size])) size -= 1;
            @memcpy(self.storage[0..size], value[0..size]);
            if (size < self.len) @memset(self.storage[size..self.len], 0);
            self.len = size;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.storage[0..self.len];
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }
    };
}

pub fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        var matches = true;
        for (needle, 0..) |byte, offset| {
            if (std.ascii.toLower(haystack[start + offset]) != std.ascii.toLower(byte)) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

test "fixed text truncates and clears its visible tail" {
    var text: Text(4) = .{};
    text.set("abcdef");
    try std.testing.expectEqualStrings("abcd", text.slice());
    text.set("x");
    try std.testing.expectEqualStrings("x", text.slice());
}

test "fixed text never truncates inside a UTF-8 codepoint" {
    var text: Text(4) = .{};
    text.set("abcé");
    try std.testing.expectEqualStrings("abc", text.slice());
    try std.testing.expect(std.unicode.utf8ValidateSlice(text.slice()));
}
