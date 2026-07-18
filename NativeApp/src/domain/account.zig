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
    token: text.Text(160) = .{},
    base_url: text.Text(192) = .{},
    sync_state: AccountSyncState = .idle,
    gmail_refs: [max_gmail_refs]GmailRef = [_]GmailRef{.{}} ** max_gmail_refs,
    gmail_ref_count: usize = 0,
    gmail_next_ref: usize = 0,
    gmail_in_flight: bool = false,
    gmail_threads_done: bool = false,
    gmail_draft_refs: [16]GmailRef = [_]GmailRef{.{}} ** 16,
    gmail_draft_ref_count: usize = 0,
    gmail_draft_next_ref: usize = 0,
    gmail_draft_in_flight: bool = false,
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
