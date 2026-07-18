const account = @import("account.zig");
const ids = @import("ids.zig");
const text = @import("text.zig");

pub const InboxFilter = enum { all, unread, starred, snoozed, archive, trash, drafts };

pub const MailThread = struct {
    id: ids.MessageId = .{},
    account_id: ids.AccountId = .{},

    // Compatibility locator for the current fixed account store. New domain
    // and async code should retain account_id instead.
    account_index: usize = 0,
    provider: account.ProviderKind = .gmail,
    provider_thread_id: text.Text(512) = .{},
    provider_message_id: text.Text(512) = .{},
    rfc_message_id: text.Text(512) = .{},
    references: text.Text(2048) = .{},
    subject: text.Text(256) = .{},
    sender: text.Text(192) = .{},
    sender_email: text.Text(192) = .{},
    reply_to: text.Text(192) = .{},
    to_recipients: text.Text(1024) = .{},
    cc_recipients: text.Text(1024) = .{},
    snippet: text.Text(512) = .{},
    body: text.Text(8192) = .{},
    received_at: text.Text(64) = .{},
    window_label: text.Text(64) = .{},
    canvas_label: text.Text(64) = .{},
    unread: bool = false,
    starred: bool = false,
    in_inbox: bool = true,
    archived: bool = false,
    trashed: bool = false,
    snoozed: bool = false,

    pub fn subjectSlice(self: *const MailThread) []const u8 {
        return self.subject.slice();
    }

    pub fn senderSlice(self: *const MailThread) []const u8 {
        return self.sender.slice();
    }

    pub fn senderEmailSlice(self: *const MailThread) []const u8 {
        return if (self.sender_email.isEmpty()) self.sender.slice() else self.sender_email.slice();
    }

    pub fn replyTargetSlice(self: *const MailThread) []const u8 {
        return if (self.reply_to.isEmpty()) self.senderEmailSlice() else self.reply_to.slice();
    }

    pub fn snippetSlice(self: *const MailThread) []const u8 {
        return self.snippet.slice();
    }

    pub fn bodySlice(self: *const MailThread) []const u8 {
        return self.body.slice();
    }

    pub fn providerThreadID(self: *const MailThread) []const u8 {
        return self.provider_thread_id.slice();
    }

    pub fn providerMessageID(self: *const MailThread) []const u8 {
        return self.provider_message_id.slice();
    }
};
