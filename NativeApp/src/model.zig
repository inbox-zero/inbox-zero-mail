const std = @import("std");
const native_sdk = @import("native_sdk");

const canvas = native_sdk.canvas;

pub const max_accounts = 4;
pub const max_threads = 128;
pub const max_gmail_refs = 48;
pub const no_index = std.math.maxInt(usize);

pub fn Text(comptime capacity: usize) type {
    return struct {
        storage: [capacity]u8 = [_]u8{0} ** capacity,
        len: usize = 0,

        const Self = @This();

        pub fn set(self: *Self, value: []const u8) void {
            const size = @min(value.len, capacity);
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

pub const ProviderKind = enum { gmail, microsoft };
pub const AccountSyncState = enum { idle, loading, ready, failed };
pub const InboxFilter = enum { all, unread, starred, snoozed, archive, trash };

pub const GmailRef = struct {
    id: Text(96) = .{},
};

pub const Account = struct {
    provider: ProviderKind = .gmail,
    email: Text(128) = .{},
    display_name: Text(96) = .{},
    token: Text(160) = .{},
    base_url: Text(192) = .{},
    sync_state: AccountSyncState = .idle,
    gmail_refs: [max_gmail_refs]GmailRef = [_]GmailRef{.{}} ** max_gmail_refs,
    gmail_ref_count: usize = 0,
    gmail_next_ref: usize = 0,
    gmail_in_flight: bool = false,
    error_message: Text(160) = .{},

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

pub const MailThread = struct {
    account_index: usize = 0,
    provider: ProviderKind = .gmail,
    provider_thread_id: Text(128) = .{},
    provider_message_id: Text(128) = .{},
    subject: Text(256) = .{},
    sender: Text(192) = .{},
    snippet: Text(512) = .{},
    body: Text(8192) = .{},
    received_at: Text(64) = .{},
    window_label: Text(64) = .{},
    canvas_label: Text(64) = .{},
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

pub const AccountView = struct {
    index: usize,
    title: []const u8,
    email: []const u8,
    selected: bool,
    unread_count: usize,
    provider_name: []const u8,
    sync_label: []const u8,
};

pub const ThreadView = struct {
    index: usize,
    subject: []const u8,
    sender: []const u8,
    snippet: []const u8,
    account: []const u8,
    accessible: []const u8,
    selected: bool,
    unread: bool,
    starred: bool,
};

pub const MutationSnapshot = struct {
    active: bool = false,
    key: u64 = 0,
    thread_index: usize = no_index,
    unread: bool = false,
    starred: bool = false,
    in_inbox: bool = true,
    archived: bool = false,
    trashed: bool = false,
    snoozed: bool = false,
};

pub const Model = struct {
    accounts: [max_accounts]Account = [_]Account{.{}} ** max_accounts,
    account_count: usize = 0,
    threads: [max_threads]MailThread = [_]MailThread{.{}} ** max_threads,
    thread_count: usize = 0,
    selected_account: usize = no_index,
    selected_thread: usize = no_index,
    filter: InboxFilter = .all,
    search_buffer: canvas.TextBuffer(160) = .{},
    sidebar_split: f32 = 0.20,
    list_split: f32 = 0.43,
    status_message: Text(256) = .{},
    mutation_counter: u64 = 1,
    pending_mutations: [16]MutationSnapshot = [_]MutationSnapshot{.{}} ** 16,
    open_windows: [3]usize = [_]usize{no_index} ** 3,
    open_window_count: usize = 0,
    search_requested: bool = false,
    sync_generation: u64 = 0,

    pub const filters = [_]InboxFilter{ .all, .unread, .starred, .snoozed, .archive, .trash };
    pub const view_unbound = .{
        "accounts",
        "account_count",
        "threads",
        "thread_count",
        "selected_account",
        "selected_thread",
        "search_buffer",
        "status_message",
        "mutation_counter",
        "pending_mutations",
        "open_windows",
        "open_window_count",
        "sync_generation",
        "selectedUnread",
        "selectedStarred",
    };

    pub fn search(model: *const Model) []const u8 {
        return model.search_buffer.text();
    }

    pub fn hasSelection(model: *const Model) bool {
        return model.selected_thread < model.thread_count and model.threadMatches(model.selected_thread);
    }

    pub fn selectedSubject(model: *const Model) []const u8 {
        return if (model.selected()) |thread| thread.subjectSlice() else "No message selected";
    }

    pub fn selectedSender(model: *const Model) []const u8 {
        return if (model.selected()) |thread| thread.senderSlice() else "";
    }

    pub fn selectedBody(model: *const Model) []const u8 {
        if (model.selected()) |thread| {
            if (!thread.body.isEmpty()) return thread.bodySlice();
            return thread.snippetSlice();
        }
        return "";
    }

    pub fn selectedAccountLabel(model: *const Model) []const u8 {
        if (model.selected()) |thread| {
            if (thread.account_index < model.account_count) return model.accounts[thread.account_index].emailSlice();
        }
        return "";
    }

    pub fn selectedUnread(model: *const Model) bool {
        return if (model.selected()) |thread| thread.unread else false;
    }

    pub fn selectedStarred(model: *const Model) bool {
        return if (model.selected()) |thread| thread.starred else false;
    }

    pub fn selectedStarLabel(model: *const Model) []const u8 {
        return if (model.selectedStarred()) "Unstar" else "Star";
    }

    pub fn selectedReadLabel(model: *const Model) []const u8 {
        return if (model.selectedUnread()) "Mark read" else "Mark unread";
    }

    pub fn loading(model: *const Model) bool {
        for (model.accounts[0..model.account_count]) |account| {
            if (account.sync_state == .idle or account.sync_state == .loading) return true;
        }
        return false;
    }

    pub fn loadingLabel(model: *const Model) []const u8 {
        return if (model.loading()) "Syncing accounts" else "Up to date";
    }

    pub fn statusMessage(model: *const Model) []const u8 {
        return model.status_message.slice();
    }

    pub fn scopeTitle(model: *const Model) []const u8 {
        if (model.selected_account < model.account_count) return model.accounts[model.selected_account].displayName();
        return "Combined inbox";
    }

    pub fn accountsView(model: *const Model, arena: std.mem.Allocator) []const AccountView {
        const out = arena.alloc(AccountView, model.account_count + 1) catch return &.{};
        out[0] = .{
            // Markup's integer value channel is signed 64-bit. Keep the
            // public combined-account sentinel small and translate it in
            // selectAccount rather than exposing usize max through a Msg.
            .index = max_accounts,
            .title = "All accounts",
            .email = "Combined inbox",
            .selected = model.selected_account == no_index,
            .unread_count = model.unreadCountForAccount(no_index),
            .provider_name = "Unified",
            .sync_label = model.loadingLabel(),
        };
        for (model.accounts[0..model.account_count], 0..) |*account, index| {
            out[index + 1] = .{
                .index = index,
                .title = account.displayName(),
                .email = account.emailSlice(),
                .selected = model.selected_account == index,
                .unread_count = model.unreadCountForAccount(index),
                .provider_name = if (account.provider == .gmail) "Gmail" else "Outlook",
                .sync_label = @tagName(account.sync_state),
            };
        }
        return out;
    }

    pub fn visibleThreads(model: *const Model, arena: std.mem.Allocator) []const ThreadView {
        const out = arena.alloc(ThreadView, model.thread_count) catch return &.{};
        var count: usize = 0;
        for (model.threads[0..model.thread_count], 0..) |*thread, index| {
            if (!model.threadMatches(index)) continue;
            const account_name = if (thread.account_index < model.account_count)
                model.accounts[thread.account_index].emailSlice()
            else
                "Unknown account";
            const accessible = std.fmt.allocPrint(arena, "{s}, from {s}, account {s}", .{
                thread.subjectSlice(), thread.senderSlice(), account_name,
            }) catch thread.subjectSlice();
            out[count] = .{
                .index = index,
                .subject = thread.subjectSlice(),
                .sender = thread.senderSlice(),
                .snippet = thread.snippetSlice(),
                .account = account_name,
                .accessible = accessible,
                .selected = model.selected_thread == index,
                .unread = thread.unread,
                .starred = thread.starred,
            };
            count += 1;
        }
        return out[0..count];
    }

    pub fn visibleThreadCount(model: *const Model) usize {
        var count: usize = 0;
        for (0..model.thread_count) |index| count += @intFromBool(model.threadMatches(index));
        return count;
    }

    pub fn unreadCount(model: *const Model) usize {
        return model.unreadCountForAccount(model.selected_account);
    }

    pub fn addAccount(model: *Model, provider: ProviderKind, email: []const u8, display_name: []const u8, token: []const u8, base_url: []const u8) void {
        if (model.account_count >= max_accounts) return;
        const account = &model.accounts[model.account_count];
        account.* = .{ .provider = provider };
        account.email.set(email);
        account.display_name.set(display_name);
        account.token.set(token);
        account.base_url.set(base_url);
        model.account_count += 1;
    }

    pub fn addThread(model: *Model, thread: MailThread) ?usize {
        if (model.thread_count >= max_threads) return null;
        for (model.threads[0..model.thread_count], 0..) |*existing, index| {
            if (existing.account_index == thread.account_index and std.mem.eql(u8, existing.providerThreadID(), thread.providerThreadID())) {
                // Both Gmail's millisecond internalDate and Graph's ISO-8601
                // receivedDateTime sort lexicographically newest-first within
                // their own provider. Keep the newest message as the thread
                // preview when a conversation appears more than once.
                if (!existing.received_at.isEmpty() and !thread.received_at.isEmpty() and
                    std.mem.order(u8, existing.received_at.slice(), thread.received_at.slice()) != .lt)
                {
                    return index;
                }
                const window_label = existing.window_label;
                const canvas_label = existing.canvas_label;
                existing.* = thread;
                existing.window_label = window_label;
                existing.canvas_label = canvas_label;
                return index;
            }
        }
        const index = model.thread_count;
        model.threads[index] = thread;
        var label_buffer: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buffer, "message-{d}", .{index}) catch "message";
        model.threads[index].window_label.set(label);
        const canvas_label = std.fmt.bufPrint(&label_buffer, "message-canvas-{d}", .{index}) catch "message-canvas";
        model.threads[index].canvas_label.set(canvas_label);
        model.thread_count += 1;
        if (model.selected_thread == no_index and model.threadMatches(index)) model.selected_thread = index;
        return index;
    }

    pub fn selectAccount(model: *Model, index: usize) void {
        model.selected_account = if (index < model.account_count) index else no_index;
        model.reconcileSelection();
    }

    pub fn selectFilter(model: *Model, filter: InboxFilter) void {
        model.filter = filter;
        model.reconcileSelection();
    }

    pub fn selectThread(model: *Model, index: usize) void {
        if (index < model.thread_count and model.threadMatches(index)) {
            model.selected_thread = index;
        }
    }

    pub fn selectRelative(model: *Model, delta: isize) void {
        var visible: [max_threads]usize = undefined;
        var count: usize = 0;
        for (0..model.thread_count) |index| {
            if (model.threadMatches(index)) {
                visible[count] = index;
                count += 1;
            }
        }
        if (count == 0) {
            model.selected_thread = no_index;
            return;
        }
        var current: usize = 0;
        for (visible[0..count], 0..) |thread_index, position| {
            if (thread_index == model.selected_thread) {
                current = position;
                break;
            }
        }
        if (delta > 0) {
            current = @min(count - 1, current + @as(usize, @intCast(delta)));
        } else if (delta < 0) {
            const amount: usize = @intCast(-delta);
            current = current -| amount;
        }
        model.selected_thread = visible[current];
    }

    pub fn openSelectedWindow(model: *Model) void {
        if (!model.hasSelection()) return;
        for (model.open_windows[0..model.open_window_count]) |index| {
            if (index == model.selected_thread) return;
        }
        if (model.open_window_count >= model.open_windows.len) return;
        model.open_windows[model.open_window_count] = model.selected_thread;
        model.open_window_count += 1;
    }

    pub fn closeWindow(model: *Model, thread_index: usize) void {
        var kept: usize = 0;
        for (model.open_windows[0..model.open_window_count]) |index| {
            if (index == thread_index) continue;
            model.open_windows[kept] = index;
            kept += 1;
        }
        for (kept..model.open_window_count) |index| model.open_windows[index] = no_index;
        model.open_window_count = kept;
    }

    pub fn resetForSync(model: *Model) u64 {
        model.sync_generation +%= 1;
        if (model.sync_generation == 0) model.sync_generation = 1;
        model.thread_count = 0;
        model.selected_thread = no_index;
        model.open_windows = [_]usize{no_index} ** 3;
        model.open_window_count = 0;
        model.pending_mutations = [_]MutationSnapshot{.{}} ** 16;
        return model.sync_generation;
    }

    pub fn selected(model: *const Model) ?*const MailThread {
        if (model.selected_thread >= model.thread_count) return null;
        return &model.threads[model.selected_thread];
    }

    pub fn selectedMut(model: *Model) ?*MailThread {
        if (model.selected_thread >= model.thread_count) return null;
        return &model.threads[model.selected_thread];
    }

    pub fn beginMutation(model: *Model, thread_index: usize) ?u64 {
        if (thread_index >= model.thread_count) return null;
        for (&model.pending_mutations) |*pending| {
            if (pending.active) continue;
            const thread = &model.threads[thread_index];
            const key = 10_000 + model.mutation_counter;
            model.mutation_counter += 1;
            pending.* = .{
                .active = true,
                .key = key,
                .thread_index = thread_index,
                .unread = thread.unread,
                .starred = thread.starred,
                .in_inbox = thread.in_inbox,
                .archived = thread.archived,
                .trashed = thread.trashed,
                .snoozed = thread.snoozed,
            };
            return key;
        }
        return null;
    }

    pub fn finishMutation(model: *Model, key: u64, success: bool) void {
        for (&model.pending_mutations) |*pending| {
            if (!pending.active or pending.key != key) continue;
            if (!success and pending.thread_index < model.thread_count) {
                const thread = &model.threads[pending.thread_index];
                thread.unread = pending.unread;
                thread.starred = pending.starred;
                thread.in_inbox = pending.in_inbox;
                thread.archived = pending.archived;
                thread.trashed = pending.trashed;
                thread.snoozed = pending.snoozed;
                model.status_message.set("The provider rejected the action; the message was restored.");
            }
            pending.* = .{};
            model.reconcileSelection();
            return;
        }
    }

    pub fn reconcileSelection(model: *Model) void {
        if (model.selected_thread < model.thread_count and model.threadMatches(model.selected_thread)) return;
        model.selected_thread = no_index;
        for (0..model.thread_count) |index| {
            if (model.threadMatches(index)) {
                model.selected_thread = index;
                break;
            }
        }
    }

    fn unreadCountForAccount(model: *const Model, account_index: usize) usize {
        var count: usize = 0;
        for (model.threads[0..model.thread_count]) |thread| {
            if (account_index != no_index and thread.account_index != account_index) continue;
            if (thread.unread and thread.in_inbox and !thread.trashed) count += 1;
        }
        return count;
    }

    fn threadMatches(model: *const Model, index: usize) bool {
        if (index >= model.thread_count) return false;
        const thread = &model.threads[index];
        if (model.selected_account != no_index and thread.account_index != model.selected_account) return false;
        const matches_filter = switch (model.filter) {
            .all => thread.in_inbox and !thread.trashed and !thread.snoozed,
            .unread => thread.in_inbox and thread.unread and !thread.trashed and !thread.snoozed,
            .starred => thread.starred and !thread.trashed,
            .snoozed => thread.snoozed and !thread.trashed,
            .archive => thread.archived and !thread.trashed,
            .trash => thread.trashed,
        };
        if (!matches_filter) return false;
        const query = std.mem.trim(u8, model.search(), " \t\r\n");
        if (query.len == 0) return true;
        return containsAsciiIgnoreCase(thread.subjectSlice(), query) or
            containsAsciiIgnoreCase(thread.senderSlice(), query) or
            containsAsciiIgnoreCase(thread.snippetSlice(), query) or
            (thread.account_index < model.account_count and containsAsciiIgnoreCase(model.accounts[thread.account_index].emailSlice(), query));
    }
};

pub fn initialModel() Model {
    var model = Model{};
    model.addAccount(.gmail, "alpha.inbox@example.com", "Alpha Inbox", "inbox_zero_native_alpha", "http://127.0.0.1:4402");
    model.addAccount(.gmail, "beta.inbox@example.com", "Beta Inbox", "inbox_zero_native_beta", "http://127.0.0.1:4402");
    model.addAccount(.microsoft, "gamma.outlook@example.com", "Gamma Outlook", "inbox_zero_native_gamma", "http://127.0.0.1:4403");
    model.status_message.set("Connecting to Gmail and Outlook emulators.");
    return model;
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

test "fixed text truncates without invalid slices" {
    var text: Text(4) = .{};
    text.set("abcdef");
    try std.testing.expectEqualStrings("abcd", text.slice());
    text.set("x");
    try std.testing.expectEqualStrings("x", text.slice());
}

test "combined and account filters keep independent scope" {
    var model = initialModel();
    var alpha = MailThread{ .account_index = 0, .unread = true };
    alpha.provider_thread_id.set("a");
    alpha.subject.set("Alpha subject");
    _ = model.addThread(alpha);
    var beta = MailThread{ .account_index = 1 };
    beta.provider_thread_id.set("b");
    beta.subject.set("Beta subject");
    _ = model.addThread(beta);

    try std.testing.expectEqual(@as(usize, 2), model.visibleThreadCount());
    model.selectAccount(0);
    try std.testing.expectEqual(@as(usize, 1), model.visibleThreadCount());
    model.selectFilter(.unread);
    try std.testing.expectEqual(@as(usize, 1), model.visibleThreadCount());
    model.selectAccount(1);
    try std.testing.expectEqual(@as(usize, 0), model.visibleThreadCount());
}

test "search and keyboard-style relative selection use visible rows" {
    var model = initialModel();
    var first = MailThread{ .account_index = 0 };
    first.provider_thread_id.set("a");
    first.subject.set("Release checklist");
    _ = model.addThread(first);
    var second = MailThread{ .account_index = 1 };
    second.provider_thread_id.set("b");
    second.subject.set("Hiring debrief");
    _ = model.addThread(second);
    model.search_buffer.set("hiring");
    model.reconcileSelection();
    try std.testing.expectEqual(@as(usize, 1), model.selected_thread);
    model.selectRelative(1);
    try std.testing.expectEqual(@as(usize, 1), model.selected_thread);
}

test "refresh invalidates stale windows and mutations" {
    var model = initialModel();
    var thread = MailThread{ .account_index = 0 };
    thread.provider_thread_id.set("refresh-me");
    _ = model.addThread(thread);
    model.openSelectedWindow();
    _ = model.beginMutation(0);

    const generation = model.resetForSync();
    try std.testing.expectEqual(@as(u64, 1), generation);
    try std.testing.expectEqual(@as(usize, 0), model.thread_count);
    try std.testing.expectEqual(@as(usize, 0), model.open_window_count);
    try std.testing.expect(!model.pending_mutations[0].active);
}

test "conversation aggregation keeps its newest message and window identity" {
    var model = initialModel();
    var newer = MailThread{ .account_index = 2, .provider = .microsoft };
    newer.provider_thread_id.set("conversation");
    newer.provider_message_id.set("new-message");
    newer.subject.set("Newest reply");
    newer.received_at.set("2026-07-18T10:00:00Z");
    const index = model.addThread(newer).?;
    const original_window_label = model.threads[index].window_label;

    var older = MailThread{ .account_index = 2, .provider = .microsoft };
    older.provider_thread_id.set("conversation");
    older.provider_message_id.set("old-message");
    older.subject.set("Older reply");
    older.received_at.set("2026-07-18T09:00:00Z");
    try std.testing.expectEqual(index, model.addThread(older).?);
    try std.testing.expectEqualStrings("Newest reply", model.threads[index].subjectSlice());
    try std.testing.expectEqualStrings(original_window_label.slice(), model.threads[index].window_label.slice());
}
