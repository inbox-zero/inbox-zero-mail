const ids = @import("ids.zig");
const mail = @import("mail.zig");
const text = @import("text.zig");

// Native SDK 0.5.3 exposes four secondary-window slots. Reserve one for a
// composer/message detail while the main window serves as All Inboxes.
pub const max_inbox_windows = 3;

/// Presentation state owned by one inbox window. Mail data itself never
/// lives here: every window reads the app's shared account/thread/draft store.
pub const InboxWindowState = struct {
    id: u64 = 0,
    active: bool = false,
    account_id: ids.AccountId = .{}, // invalid means All Inboxes
    filter: mail.InboxFilter = .all,
    selected_thread_id: ids.MessageId = .{},
    reading: bool = false,
    title: text.Text(64) = .{},
    window_label: text.Text(64) = .{},
    canvas_label: text.Text(64) = .{},

    pub fn isAllInboxes(self: *const InboxWindowState) bool {
        return !self.account_id.isValid();
    }
};

pub const ThreadAction = struct {
    window_id: u64,
    thread_id: u64,
};

pub const FilterAction = struct {
    window_id: u64,
    filter: mail.InboxFilter,
};
