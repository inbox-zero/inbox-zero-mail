const account = @import("../domain/account.zig");

pub const ProviderConfig = struct {
    kind: account.ProviderKind,
    display_name: []const u8,
    authorization_url: []const u8,
    token_url: []const u8,
    profile_url: []const u8,
    api_base_url: []const u8,
    scopes: []const u8,
    prompt_parameter: []const u8,
    loopback_path: []const u8,
    loopback_ports: [2]u16,
};

pub const gmail = ProviderConfig{
    .kind = .gmail,
    .display_name = "Gmail",
    .authorization_url = "https://accounts.google.com/o/oauth2/v2/auth",
    .token_url = "https://oauth2.googleapis.com/token",
    .profile_url = "https://www.googleapis.com/oauth2/v2/userinfo",
    .api_base_url = "https://gmail.googleapis.com",
    .scopes = "openid email profile https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/gmail.send",
    .prompt_parameter = "access_type=offline&prompt=consent",
    .loopback_path = "/oauth/google",
    .loopback_ports = .{ 4000, 4002 },
};

pub const microsoft = ProviderConfig{
    .kind = .microsoft,
    .display_name = "Outlook",
    .authorization_url = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
    .token_url = "https://login.microsoftonline.com/common/oauth2/v2.0/token",
    .profile_url = "https://graph.microsoft.com/v1.0/me",
    .api_base_url = "https://graph.microsoft.com",
    .scopes = "openid email profile offline_access User.Read Mail.ReadWrite Mail.Send",
    .prompt_parameter = "prompt=select_account",
    .loopback_path = "/oauth/microsoft",
    .loopback_ports = .{ 4001, 4003 },
};

pub fn forProvider(kind: account.ProviderKind) *const ProviderConfig {
    return switch (kind) {
        .gmail => &gmail,
        .microsoft => &microsoft,
    };
}

pub fn emulator(kind: account.ProviderKind) ProviderConfig {
    var result = forProvider(kind).*;
    switch (kind) {
        .gmail => {
            result.authorization_url = "http://127.0.0.1:4402/o/oauth2/v2/auth";
            result.token_url = "http://127.0.0.1:4402/oauth2/token";
            result.profile_url = "http://127.0.0.1:4402/oauth2/v2/userinfo";
            result.api_base_url = "http://127.0.0.1:4402";
        },
        .microsoft => {
            result.authorization_url = "http://127.0.0.1:4403/oauth2/v2.0/authorize";
            result.token_url = "http://127.0.0.1:4403/oauth2/v2.0/token";
            result.profile_url = "http://127.0.0.1:4403/v1.0/me";
            result.api_base_url = "http://127.0.0.1:4403";
        },
    }
    return result;
}

test "provider scopes cover offline mail modification and sending" {
    const std = @import("std");
    try std.testing.expect(std.mem.indexOf(u8, gmail.scopes, "gmail.modify") != null);
    try std.testing.expect(std.mem.indexOf(u8, gmail.scopes, "gmail.send") != null);
    try std.testing.expect(std.mem.indexOf(u8, microsoft.scopes, "offline_access") != null);
    try std.testing.expect(std.mem.indexOf(u8, microsoft.scopes, "Mail.ReadWrite") != null);
    try std.testing.expect(std.mem.indexOf(u8, microsoft.scopes, "Mail.Send") != null);
    try std.testing.expectEqualStrings("https://oauth2.googleapis.com/token", gmail.token_url);
}
