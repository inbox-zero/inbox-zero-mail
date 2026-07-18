const account = @import("account.zig");
const ids = @import("ids.zig");
const text = @import("text.zig");

pub const ComposeMode = enum { new, reply, reply_all, forward };

/// Provider-neutral saved draft metadata and content. The editor owns caret
/// state separately; this value is the durable/provider reconciliation shape.
pub const Draft = struct {
    id: ids.DraftId = .{},
    account_id: ids.AccountId = .{},
    account_index: usize = 0,
    provider: account.ProviderKind = .gmail,
    mode: ComposeMode = .new,
    provider_draft_id: text.Text(512) = .{},
    provider_message_id: text.Text(512) = .{},
    source_message_id: text.Text(512) = .{},
    source_thread_id: text.Text(512) = .{},
    source_rfc_message_id: text.Text(512) = .{},
    source_references: text.Text(2048) = .{},
    to: text.Text(1024) = .{},
    cc: text.Text(1024) = .{},
    bcc: text.Text(1024) = .{},
    subject: text.Text(512) = .{},
    body: text.Text(16 * 1024) = .{},
    quoted_body: text.Text(8192) = .{},
    updated_at: text.Text(64) = .{},
    remote: bool = false,
    /// True when the provider draft contains HTML/attachments that this plain
    /// text editor cannot rewrite without data loss. It remains sendable.
    provider_content_read_only: bool = false,

    pub fn displaySubject(self: *const Draft) []const u8 {
        return if (self.subject.isEmpty()) "(No subject)" else self.subject.slice();
    }

    pub fn recipientSummary(self: *const Draft) []const u8 {
        return if (self.to.isEmpty()) "No recipients" else self.to.slice();
    }
};
