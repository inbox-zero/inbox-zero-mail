const account = @import("../domain/account.zig");

/// Development-only account bootstrap for the emulate.dev fork. Production
/// OAuth can replace this module without changing the domain or provider
/// clients; tokens are deliberately kept out of markup and persisted files.
pub const AccountSeed = struct {
    provider: account.ProviderKind,
    email: []const u8,
    display_name: []const u8,
    bearer_token: []const u8,
    base_url: []const u8,
};

pub const accounts = [_]AccountSeed{
    .{
        .provider = .gmail,
        .email = "alpha.inbox@example.com",
        .display_name = "Alpha Inbox",
        .bearer_token = "inbox_zero_native_alpha",
        .base_url = "http://127.0.0.1:4402",
    },
    .{
        .provider = .gmail,
        .email = "beta.inbox@example.com",
        .display_name = "Beta Inbox",
        .bearer_token = "inbox_zero_native_beta",
        .base_url = "http://127.0.0.1:4402",
    },
    .{
        .provider = .microsoft,
        .email = "gamma.outlook@example.com",
        .display_name = "Gamma Outlook",
        .bearer_token = "inbox_zero_native_gamma",
        .base_url = "http://127.0.0.1:4403",
    },
};
