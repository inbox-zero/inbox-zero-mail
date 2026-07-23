const ids = @import("ids.zig");
const text = @import("text.zig");

pub const max_gmail_refs = 128;

pub const ProviderKind = enum { gmail, microsoft };
pub const AccountSyncState = enum { idle, loading, ready, partial, failed };

pub const GmailRef = struct {
    id: text.Text(96) = .{},
};

pub const Account = struct {
    id: ids.AccountId = .{},
    provider: ProviderKind = .gmail,
    email: text.Text(128) = .{},
    display_name: text.Text(96) = .{},
    provider_account_id: text.Text(256) = .{},
    credential_key: text.Text(256) = .{},
    /// Short development-only identity used by the explicit emulator profile.
    /// Production tokens never enter the app model; the native runtime keeps
    /// them behind `credential_key` and injects authorization on host requests.
    token: text.Text(160) = .{},
    base_url: text.Text(192) = .{},
    sync_state: AccountSyncState = .idle,
    gmail_refs: [max_gmail_refs]GmailRef = [_]GmailRef{.{}} ** max_gmail_refs,
    gmail_ref_count: usize = 0,
    // Gmail's broad thread listing can put sent/archive/trash ahead of inbox
    // mail. Keep it aside until the inbox-scoped listing arrives so the first
    // detail requests always produce rows for the view the user is looking at.
    gmail_background_refs: [max_gmail_refs]GmailRef = [_]GmailRef{.{}} ** max_gmail_refs,
    gmail_background_ref_count: usize = 0,
    gmail_inbox_list_done: bool = false,
    gmail_background_list_done: bool = false,
    gmail_next_ref: usize = 0,
    gmail_in_flight: usize = 0,
    gmail_retry_counts: [max_gmail_refs]u8 = [_]u8{0} ** max_gmail_refs,
    gmail_threads_done: bool = false,
    gmail_draft_refs: [16]GmailRef = [_]GmailRef{.{}} ** 16,
    gmail_draft_ref_count: usize = 0,
    gmail_draft_next_ref: usize = 0,
    gmail_draft_in_flight: usize = 0,
    gmail_draft_retry_counts: [16]u8 = [_]u8{0} ** 16,
    gmail_drafts_done: bool = false,
    outlook_pending: usize = 0,
    error_message: text.Text(160) = .{},

    pub fn emailSlice(self: *const Account) []const u8 {
        return self.email.slice();
    }

    pub fn displayName(self: *const Account) []const u8 {
        return self.display_name.slice();
    }

    pub fn tokenSlice(self: *const Account) []const u8 {
        return self.token.slice();
    }

    pub fn baseUrl(self: *const Account) []const u8 {
        return self.base_url.slice();
    }
};
