const std = @import("std");

pub const max_code_bytes: usize = 2048;

pub const Result = struct {
    code: [max_code_bytes]u8 = undefined,
    code_len: usize = 0,

    pub fn codeSlice(self: *const Result) []const u8 {
        return self.code[0..self.code_len];
    }
};

/// Parse an OAuth loopback request target and validate both the exact callback
/// path and the unguessable state. A code is never returned before state
/// validation succeeds.
pub fn parse(target: []const u8, expected_path: []const u8, expected_state: []const u8) !Result {
    const question = std.mem.indexOfScalar(u8, target, '?') orelse return error.MissingQuery;
    if (!std.mem.eql(u8, target[0..question], expected_path)) return error.UnexpectedPath;

    var state_buffer: [256]u8 = undefined;
    var state_len: ?usize = null;
    var code_buffer: [max_code_bytes]u8 = undefined;
    var code_len: ?usize = null;
    var oauth_error = false;

    var pairs = std.mem.splitScalar(u8, target[question + 1 ..], '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const name = pair[0..equals];
        const value = if (equals < pair.len) pair[equals + 1 ..] else "";
        if (std.mem.eql(u8, name, "state")) {
            if (state_len != null) return error.DuplicateParameter;
            state_len = try decode(value, &state_buffer);
        } else if (std.mem.eql(u8, name, "code")) {
            if (code_len != null) return error.DuplicateParameter;
            code_len = try decode(value, &code_buffer);
        } else if (std.mem.eql(u8, name, "error")) {
            oauth_error = true;
        }
    }

    const actual_state_len = state_len orelse return error.MissingState;
    if (actual_state_len != expected_state.len or !constantTimeEqual(state_buffer[0..actual_state_len], expected_state))
        return error.StateMismatch;
    if (oauth_error) return error.AuthorizationRejected;
    const actual_code_len = code_len orelse return error.MissingCode;
    if (actual_code_len == 0) return error.MissingCode;
    return .{ .code = code_buffer, .code_len = actual_code_len };
}

fn constantTimeEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    var difference: u8 = 0;
    for (left, right) |a, b| difference |= a ^ b;
    return difference == 0;
}

fn decode(encoded: []const u8, output: []u8) !usize {
    var source: usize = 0;
    var destination: usize = 0;
    while (source < encoded.len) {
        if (destination >= output.len) return error.ParameterTooLong;
        switch (encoded[source]) {
            '%' => {
                if (source + 2 >= encoded.len) return error.InvalidEncoding;
                const high = std.fmt.charToDigit(encoded[source + 1], 16) catch return error.InvalidEncoding;
                const low = std.fmt.charToDigit(encoded[source + 2], 16) catch return error.InvalidEncoding;
                output[destination] = @as(u8, high) << 4 | @as(u8, low);
                source += 3;
            },
            '+' => {
                output[destination] = ' ';
                source += 1;
            },
            else => |byte| {
                output[destination] = byte;
                source += 1;
            },
        }
        destination += 1;
    }
    return destination;
}

test "callback validates exact path state and percent-decodes the code" {
    const result = try parse("/oauth/google?code=code%2Fwith%2Breserved&state=known-state", "/oauth/google", "known-state");
    try std.testing.expectEqualStrings("code/with+reserved", result.codeSlice());
}

test "callback rejects state substitution before exposing a code" {
    try std.testing.expectError(error.StateMismatch, parse("/oauth/google?code=secret&state=attacker", "/oauth/google", "expected"));
    try std.testing.expectError(error.UnexpectedPath, parse("/oauth/microsoft?code=secret&state=expected", "/oauth/google", "expected"));
    try std.testing.expectError(error.DuplicateParameter, parse("/oauth/google?code=one&code=two&state=expected", "/oauth/google", "expected"));
}

test "provider rejection still requires valid state" {
    try std.testing.expectError(error.StateMismatch, parse("/oauth/google?error=access_denied&state=attacker", "/oauth/google", "expected"));
    try std.testing.expectError(error.AuthorizationRejected, parse("/oauth/google?error=access_denied&state=expected", "/oauth/google", "expected"));
}
