const std = @import("std");
const config = @import("config.zig");

pub const Material = struct {
    verifier: [43]u8,
    challenge: [43]u8,
    state: [43]u8,
};

pub fn generate(io: std.Io) Material {
    var verifier_bytes: [32]u8 = undefined;
    var state_bytes: [32]u8 = undefined;
    io.random(&verifier_bytes);
    io.random(&state_bytes);
    return fromBytes(verifier_bytes, state_bytes);
}

pub fn fromBytes(verifier_bytes: [32]u8, state_bytes: [32]u8) Material {
    var material: Material = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&material.verifier, &verifier_bytes);
    _ = std.base64.url_safe_no_pad.Encoder.encode(&material.state, &state_bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&material.verifier, &digest, .{});
    _ = std.base64.url_safe_no_pad.Encoder.encode(&material.challenge, &digest);
    return material;
}

pub fn authorizationUrl(
    output: []u8,
    provider: *const config.ProviderConfig,
    client_id: []const u8,
    redirect_uri: []const u8,
    material: *const Material,
) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll(provider.authorization_url);
    try writer.writeAll("?client_id=");
    try writeFormComponent(&writer, client_id);
    try writer.writeAll("&redirect_uri=");
    try writeFormComponent(&writer, redirect_uri);
    try writer.writeAll("&response_type=code&response_mode=query&scope=");
    try writeFormComponent(&writer, provider.scopes);
    try writer.writeAll("&state=");
    try writeFormComponent(&writer, &material.state);
    try writer.writeAll("&code_challenge=");
    try writeFormComponent(&writer, &material.challenge);
    try writer.writeAll("&code_challenge_method=S256");
    if (provider.prompt_parameter.len > 0) {
        try writer.writeByte('&');
        try writer.writeAll(provider.prompt_parameter);
    }
    return writer.buffered();
}

pub fn tokenBody(
    output: []u8,
    client_id: []const u8,
    code: []const u8,
    redirect_uri: []const u8,
    verifier: []const u8,
    client_secret: ?[]const u8,
) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writePair(&writer, "client_id", client_id, false);
    try writePair(&writer, "code", code, true);
    try writePair(&writer, "redirect_uri", redirect_uri, true);
    try writePair(&writer, "code_verifier", verifier, true);
    try writePair(&writer, "grant_type", "authorization_code", true);
    if (client_secret) |secret| {
        if (secret.len > 0) try writePair(&writer, "client_secret", secret, true);
    }
    return writer.buffered();
}

pub fn refreshBody(output: []u8, client_id: []const u8, refresh_token: []const u8, client_secret: ?[]const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writePair(&writer, "client_id", client_id, false);
    try writePair(&writer, "refresh_token", refresh_token, true);
    try writePair(&writer, "grant_type", "refresh_token", true);
    if (client_secret) |secret| {
        if (secret.len > 0) try writePair(&writer, "client_secret", secret, true);
    }
    return writer.buffered();
}

fn writePair(writer: *std.Io.Writer, name: []const u8, value: []const u8, prefix_ampersand: bool) !void {
    if (prefix_ampersand) try writer.writeByte('&');
    try writer.writeAll(name);
    try writer.writeByte('=');
    try writeFormComponent(writer, value);
}

pub fn writeFormComponent(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~') {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        }
    }
}

test "PKCE uses deterministic S256 base64url material" {
    const zero = [_]u8{0} ** 32;
    const one = [_]u8{1} ** 32;
    const material = fromBytes(zero, one);
    try std.testing.expectEqualStrings("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", &material.verifier);
    try std.testing.expectEqualStrings("DwBzhbb51LfusnSGBa_hqYSgo7-j8BTQnip4TOnlzRo", &material.challenge);
    try std.testing.expectEqualStrings("AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE", &material.state);
    try std.testing.expect(std.mem.indexOfScalar(u8, &material.verifier, '=') == null);
}

test "authorization URL contains encoded state scopes and S256 challenge" {
    const material = fromBytes([_]u8{2} ** 32, [_]u8{3} ** 32);
    var buffer: [2048]u8 = undefined;
    const url = try authorizationUrl(&buffer, &config.microsoft, "client id", "http://127.0.0.1:4001/oauth/microsoft", &material);
    try std.testing.expect(std.mem.indexOf(u8, url, "client_id=client%20id") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "Mail.Send") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "prompt=select_account") != null);
}

test "token bodies encode public client and emulator secret variants" {
    var buffer: [1024]u8 = undefined;
    const public = try tokenBody(&buffer, "client", "code", "http://127.0.0.1:4000/oauth/google", "verifier", null);
    try std.testing.expect(std.mem.indexOf(u8, public, "client_secret") == null);
    const with_secret = try tokenBody(&buffer, "client", "code", "redirect", "verifier", "emulator-secret");
    try std.testing.expect(std.mem.indexOf(u8, with_secret, "client_secret=emulator-secret") != null);
}

test "OAuth query and form values encode every reserved delimiter" {
    const material = fromBytes([_]u8{4} ** 32, [_]u8{5} ** 32);
    var url_buffer: [2048]u8 = undefined;
    const url = try authorizationUrl(&url_buffer, &config.gmail, "client&=+ %", "http://127.0.0.1:4000/oauth/google?x=1&y=2", &material);
    try std.testing.expect(std.mem.indexOf(u8, url, "client_id=client%26%3D%2B%20%25") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A4000%2Foauth%2Fgoogle%3Fx%3D1%26y%3D2") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "scope=openid%20email%20profile%20https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fgmail.modify%20https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fgmail.send") != null);

    var body_buffer: [1024]u8 = undefined;
    const body = try tokenBody(&body_buffer, "id&one", "code=two+three", "http://localhost/cb?a=b", "verify%value", "secret&=+");
    try std.testing.expectEqualStrings("client_id=id%26one&code=code%3Dtwo%2Bthree&redirect_uri=http%3A%2F%2Flocalhost%2Fcb%3Fa%3Db&code_verifier=verify%25value&grant_type=authorization_code&client_secret=secret%26%3D%2B", body);

    const refresh = try refreshBody(&body_buffer, "id", "refresh&=+ %", null);
    try std.testing.expectEqualStrings("client_id=id&refresh_token=refresh%26%3D%2B%20%25&grant_type=refresh_token", refresh);
}
