const std = @import("std");
const native_sdk = @import("native_sdk");
const compose_app = @import("app/compose.zig");
const emulator_config = @import("config/emulator.zig");
const account_domain = @import("domain/account.zig");
const draft_domain = @import("domain/draft.zig");
const ids = @import("domain/ids.zig");
const mail_domain = @import("domain/mail.zig");
const text_domain = @import("domain/text.zig");

const canvas = native_sdk.canvas;

pub const max_accounts = 4;
pub const max_threads = 128;
pub const max_drafts = 16;
pub const max_gmail_refs = account_domain.max_gmail_refs;
pub const no_index = std.math.maxInt(usize);

// Compatibility facade: callers can migrate to domain/* incrementally.
pub const Text = text_domain.Text;
pub const AccountId = ids.AccountId;
pub const MessageId = ids.MessageId;
pub const DraftId = ids.DraftId;
pub const OperationId = ids.OperationId;
pub const ProviderKind = account_domain.ProviderKind;
pub const AccountSyncState = account_domain.AccountSyncState;
pub const InboxFilter = mail_domain.InboxFilter;
pub const GmailRef = account_domain.GmailRef;
pub const Account = account_domain.Account;
pub const MailThread = mail_domain.MailThread;
pub const Draft = draft_domain.Draft;
pub const ComposeMode = draft_domain.ComposeMode;

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

pub const DraftView = struct {
    id: u64,
    subject: []const u8,
    recipients: []const u8,
    account: []const u8,
    accessible: []const u8,
    selected: bool,
    remote: bool,
};

pub const ComposeAccountView = struct {
    index: usize,
    email: []const u8,
    provider_name: []const u8,
    selected: bool,
    visible: bool,
};

pub const MutationSnapshot = struct {
    active: bool = false,
    key: u64 = 0,
    thread_id: MessageId = .{},
    // Compatibility hint for provider response code. Rollback and all new
    // async work resolve thread_id instead of trusting this array position.
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
    drafts: [max_drafts]Draft = [_]Draft{.{}} ** max_drafts,
    draft_count: usize = 0,
    selected_draft: usize = no_index,
    composer: compose_app.Composer = .{},
    selected_account: usize = no_index,
    selected_thread: usize = no_index,
    filter: InboxFilter = .all,
    search_buffer: canvas.TextBuffer(160) = .{},
    sidebar_split: f32 = 0.20,
    list_split: f32 = 0.43,
    status_message: Text(256) = .{},
    next_account_id: u64 = 1,
    next_message_id: u64 = 1,
    next_draft_id: u64 = 1,
    next_operation_id: u64 = 1,
    mutation_counter: u64 = 1,
    pending_mutations: [16]MutationSnapshot = [_]MutationSnapshot{.{}} ** 16,
    open_windows: [3]MessageId = [_]MessageId{.{}} ** 3,
    open_window_count: usize = 0,
    search_requested: bool = false,
    sync_generation: u64 = 0,

    pub const filters = [_]InboxFilter{ .all, .unread, .starred, .snoozed, .archive, .trash, .drafts };
    pub const view_unbound = .{
        "accounts",
        "composeBusy",
        "syncInFlight",
        "account_count",
        "threads",
        "thread_count",
        "drafts",
        "draft_count",
        "selected_draft",
        "composer",
        "selected_account",
        "selected_thread",
        "search_buffer",
        "status_message",
        "next_account_id",
        "next_message_id",
        "next_draft_id",
        "next_operation_id",
        "mutation_counter",
        "pending_mutations",
        "open_windows",
        "open_window_count",
        "sync_generation",
        "selectedUnread",
        "selectedStarred",
        "composeOpen",
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

    pub fn isDraftsView(model: *const Model) bool {
        return model.filter == .drafts;
    }

    pub fn composeOpen(model: *const Model) bool {
        return model.composer.isOpen();
    }

    pub fn composeBusy(model: *const Model) bool {
        return model.composer.state != .closed;
    }

    pub fn composeTitle(model: *const Model) []const u8 {
        return switch (model.composer.mode) {
            .new => "Compose",
            .reply => "Reply",
            .reply_all => "Reply all",
            .forward => "Forward",
        };
    }

    pub fn composeAccountLocked(model: *const Model) bool {
        return model.composer.mode == .reply or model.composer.mode == .reply_all or
            !model.composer.provider_draft_id.isEmpty();
    }

    pub fn composeOperationBusy(model: *const Model) bool {
        return model.composer.stage != .idle;
    }

    pub fn composeContentReadOnly(model: *const Model) bool {
        return model.composer.provider_content_read_only;
    }

    pub fn composePreservationNotice(_: *const Model) []const u8 {
        return "This provider draft contains rich content or attachments. You can send or discard it, but editing is locked to prevent data loss.";
    }

    pub fn composeCanSend(model: *const Model) bool {
        return model.composer.canSend();
    }

    pub fn composeTo(model: *const Model) []const u8 {
        return model.composer.to();
    }

    pub fn composeCc(model: *const Model) []const u8 {
        return model.composer.cc();
    }

    pub fn composeBcc(model: *const Model) []const u8 {
        return model.composer.bcc();
    }

    pub fn composeSubject(model: *const Model) []const u8 {
        return model.composer.subject();
    }

    pub fn composeBody(model: *const Model) []const u8 {
        return model.composer.body();
    }

    pub fn composeStatus(model: *const Model) []const u8 {
        return switch (model.composer.state) {
            .closed => "",
            .editing => if (model.composer.dirty) "Unsaved changes" else "Draft ready",
            .saving => "Saving draft...",
            .saved => "Saved to provider",
            .sending => "Sending...",
            .failed => "Could not complete the mail operation",
        };
    }

    pub fn composeHasError(model: *const Model) bool {
        return !model.composer.error_message.isEmpty();
    }

    pub fn composeError(model: *const Model) []const u8 {
        return model.composer.error_message.slice();
    }

    pub fn composeAccountsView(model: *const Model, arena: std.mem.Allocator) []const ComposeAccountView {
        const out = arena.alloc(ComposeAccountView, model.account_count) catch return &.{};
        for (model.accounts[0..model.account_count], 0..) |*account, index| {
            out[index] = .{
                .index = index,
                .email = account.emailSlice(),
                .provider_name = if (account.provider == .gmail) "Gmail" else "Outlook",
                .selected = model.composer.account_index == index,
                .visible = !model.composeAccountLocked() or model.composer.account_index == index,
            };
        }
        return out;
    }

    pub fn loading(model: *const Model) bool {
        for (model.accounts[0..model.account_count]) |account| {
            if (account.sync_state == .idle or account.sync_state == .loading) return true;
        }
        return false;
    }

    pub fn syncInFlight(model: *const Model) bool {
        if (model.sync_generation == 0) return false;
        for (model.accounts[0..model.account_count]) |account| {
            if (account.sync_state == .loading) return true;
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
        if (model.isDraftsView()) return "Drafts";
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
        if (model.isDraftsView()) return 0;
        var count: usize = 0;
        for (0..model.thread_count) |index| count += @intFromBool(model.threadMatches(index));
        return count;
    }

    pub fn draftsView(model: *const Model, arena: std.mem.Allocator) []const DraftView {
        const out = arena.alloc(DraftView, model.draft_count) catch return &.{};
        var count: usize = 0;
        for (model.drafts[0..model.draft_count], 0..) |*draft, index| {
            if (!model.draftMatches(index)) continue;
            const account_name = if (draft.account_index < model.account_count)
                model.accounts[draft.account_index].emailSlice()
            else
                "Unknown account";
            const accessible = std.fmt.allocPrint(arena, "{s}, to {s}, account {s}, {s}", .{
                draft.displaySubject(), draft.recipientSummary(), account_name, if (draft.remote) "saved" else "local",
            }) catch draft.displaySubject();
            out[count] = .{
                .id = draft.id.value,
                .subject = draft.displaySubject(),
                .recipients = draft.recipientSummary(),
                .account = account_name,
                .accessible = accessible,
                .selected = model.selected_draft == index,
                .remote = draft.remote,
            };
            count += 1;
        }
        return out[0..count];
    }

    pub fn visibleDraftCount(model: *const Model) usize {
        var count: usize = 0;
        for (0..model.draft_count) |index| count += @intFromBool(model.draftMatches(index));
        return count;
    }

    pub fn unreadCount(model: *const Model) usize {
        return model.unreadCountForAccount(model.selected_account);
    }

    pub fn addAccount(model: *Model, provider: ProviderKind, email: []const u8, display_name: []const u8, token: []const u8, base_url: []const u8) void {
        if (model.account_count >= max_accounts) return;
        const account = &model.accounts[model.account_count];
        account.* = .{ .id = ids.nextAccountId(&model.next_account_id), .provider = provider };
        account.email.set(email);
        account.display_name.set(display_name);
        account.token.set(token);
        account.base_url.set(base_url);
        model.account_count += 1;
    }

    pub fn addThread(model: *Model, thread: MailThread) ?usize {
        var candidate = thread;
        if (!candidate.account_id.isValid() and candidate.account_index < model.account_count) {
            candidate.account_id = model.accounts[candidate.account_index].id;
        }
        for (model.threads[0..model.thread_count], 0..) |*existing, index| {
            if (existing.account_id.value == candidate.account_id.value and
                std.mem.eql(u8, existing.providerThreadID(), candidate.providerThreadID()))
            {
                // Both Gmail's millisecond internalDate and Graph's ISO-8601
                // receivedDateTime sort lexicographically newest-first within
                // their own provider. Keep the newest message as the thread
                // preview when a conversation appears more than once.
                if (!existing.received_at.isEmpty() and !candidate.received_at.isEmpty() and
                    std.mem.order(u8, existing.received_at.slice(), candidate.received_at.slice()) != .lt)
                {
                    return index;
                }
                const id = existing.id;
                const account_id = existing.account_id;
                const window_label = existing.window_label;
                const canvas_label = existing.canvas_label;
                existing.* = candidate;
                existing.id = id;
                existing.account_id = account_id;
                existing.window_label = window_label;
                existing.canvas_label = canvas_label;
                return index;
            }
        }
        if (model.thread_count >= max_threads) return null;
        const index = model.thread_count;
        if (!candidate.id.isValid()) candidate.id = ids.nextMessageId(&model.next_message_id);
        model.threads[index] = candidate;
        var label_buffer: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buffer, "message-{d}", .{index}) catch "message";
        model.threads[index].window_label.set(label);
        const canvas_label = std.fmt.bufPrint(&label_buffer, "message-canvas-{d}", .{index}) catch "message-canvas";
        model.threads[index].canvas_label.set(canvas_label);
        model.thread_count += 1;
        if (model.selected_thread == no_index and model.threadMatches(index)) model.selected_thread = index;
        return index;
    }

    pub fn addDraft(model: *Model, draft: Draft) ?usize {
        var candidate = draft;
        if (!candidate.account_id.isValid() and candidate.account_index < model.account_count) {
            candidate.account_id = model.accounts[candidate.account_index].id;
        }
        if (!candidate.provider_draft_id.isEmpty()) {
            for (model.drafts[0..model.draft_count], 0..) |*existing, index| {
                if (existing.account_id.value == candidate.account_id.value and
                    std.mem.eql(u8, existing.provider_draft_id.slice(), candidate.provider_draft_id.slice()))
                {
                    // An older refresh must not overwrite a local snapshot
                    // created by an in-flight or failed provider mutation.
                    if (!existing.remote and candidate.remote) return index;
                    const local_id = existing.id;
                    existing.* = candidate;
                    existing.id = local_id;
                    return index;
                }
            }
        }
        if (model.draft_count >= max_drafts) return null;
        if (!candidate.id.isValid()) candidate.id = ids.nextDraftId(&model.next_draft_id);
        const index = model.draft_count;
        model.drafts[index] = candidate;
        model.draft_count += 1;
        if (model.selected_draft == no_index) model.selected_draft = index;
        return index;
    }

    pub fn selectedDraft(model: *const Model) ?*const Draft {
        if (model.selected_draft >= model.draft_count) return null;
        return &model.drafts[model.selected_draft];
    }

    pub fn draftIndexById(model: *const Model, id: DraftId) ?usize {
        if (!id.isValid()) return null;
        for (model.drafts[0..model.draft_count], 0..) |candidate, index| {
            if (candidate.id.value == id.value) return index;
        }
        return null;
    }

    pub fn selectDraft(model: *Model, index: usize) void {
        if (index < model.draft_count) model.selected_draft = index;
    }

    pub fn beginNewCompose(model: *Model) void {
        if (model.account_count == 0) return;
        const account_index = if (model.selected_account < model.account_count)
            model.selected_account
        else if (model.selected()) |thread|
            thread.account_index
        else
            0;
        model.composer.begin(.new, model.accounts[account_index].id, account_index);
    }

    pub fn beginMessageCompose(model: *Model, mode: ComposeMode) void {
        const thread = model.selected() orelse return;
        if (thread.account_index >= model.account_count) return;
        model.composer.begin(mode, model.accounts[thread.account_index].id, thread.account_index);
        model.composer.source_message_id.set(thread.providerMessageID());
        if (mode != .forward) model.composer.source_thread_id.set(thread.providerThreadID());
        if (mode == .reply or mode == .reply_all) {
            model.composer.source_rfc_message_id.set(thread.rfc_message_id.slice());
            model.composer.source_references.set(thread.references.slice());
        }
        switch (mode) {
            .new => {},
            .reply, .reply_all => {
                model.composer.to_buffer.set(thread.replyTargetSlice());
                if (mode == .reply_all) {
                    fillReplyAllCc(model, thread, &model.composer.cc_buffer);
                    model.composer.cc_bcc_visible = model.composer.cc().len != 0;
                }
                var subject_buffer: [512]u8 = undefined;
                model.composer.subject_buffer.set(prefixedSubject(&subject_buffer, "Re: ", thread.subjectSlice()));
                model.composer.quoted_body.set(thread.bodySlice());
            },
            .forward => {
                var subject_buffer: [512]u8 = undefined;
                model.composer.subject_buffer.set(prefixedSubject(&subject_buffer, "Fwd: ", thread.subjectSlice()));
                var body_buffer: [32 * 1024]u8 = undefined;
                const forwarded = std.fmt.bufPrint(&body_buffer, "\n\n---------- Forwarded message ----------\nFrom: {s}\nSubject: {s}\n\n{s}", .{ thread.senderSlice(), thread.subjectSlice(), thread.bodySlice() }) catch thread.bodySlice();
                model.composer.body_buffer.set(forwarded);
            },
        }
        model.composer.dirty = false;
    }

    pub fn openDraft(model: *Model, index: usize) void {
        if (index >= model.draft_count) return;
        model.selected_draft = index;
        const draft = &model.drafts[index];
        if (draft.account_index >= model.account_count) return;
        model.composer.begin(draft.mode, draft.account_id, draft.account_index);
        model.composer.draft_id = draft.id;
        model.composer.provider_draft_id.set(draft.provider_draft_id.slice());
        model.composer.provider_message_id.set(draft.provider_message_id.slice());
        model.composer.source_message_id.set(draft.source_message_id.slice());
        model.composer.source_thread_id.set(draft.source_thread_id.slice());
        model.composer.source_rfc_message_id.set(draft.source_rfc_message_id.slice());
        model.composer.source_references.set(draft.source_references.slice());
        model.composer.to_buffer.set(draft.to.slice());
        model.composer.cc_buffer.set(draft.cc.slice());
        model.composer.bcc_buffer.set(draft.bcc.slice());
        model.composer.subject_buffer.set(draft.subject.slice());
        model.composer.body_buffer.set(draft.body.slice());
        model.composer.quoted_body.set(draft.quoted_body.slice());
        model.composer.cc_bcc_visible = !draft.cc.isEmpty() or !draft.bcc.isEmpty();
        model.composer.provider_content_read_only = draft.provider_content_read_only;
        model.composer.state = .saved;
        model.composer.dirty = false;
    }

    pub fn openDraftById(model: *Model, id_value: u64) void {
        const index = model.draftIndexById(.{ .value = id_value }) orelse return;
        model.openDraft(index);
    }

    pub fn snapshotComposer(model: *Model, remote: bool) ?usize {
        if (!model.composer.hasContent() or model.composer.account_index >= model.account_count) return null;
        var draft = Draft{
            .account_id = model.composer.account_id,
            .account_index = model.composer.account_index,
            .provider = model.accounts[model.composer.account_index].provider,
            .mode = model.composer.mode,
            .remote = remote,
            .provider_content_read_only = model.composer.provider_content_read_only,
        };
        draft.provider_draft_id.set(model.composer.provider_draft_id.slice());
        draft.provider_message_id.set(model.composer.provider_message_id.slice());
        draft.source_message_id.set(model.composer.source_message_id.slice());
        draft.source_thread_id.set(model.composer.source_thread_id.slice());
        draft.source_rfc_message_id.set(model.composer.source_rfc_message_id.slice());
        draft.source_references.set(model.composer.source_references.slice());
        draft.to.set(model.composer.to());
        draft.cc.set(model.composer.cc());
        draft.bcc.set(model.composer.bcc());
        draft.subject.set(model.composer.subject());
        draft.body.set(model.composer.body());
        draft.quoted_body.set(model.composer.quoted_body.slice());
        if (model.draftIndexById(model.composer.draft_id)) |index| {
            draft.id = model.composer.draft_id;
            model.drafts[index] = draft;
            model.selected_draft = index;
            return index;
        }
        const index = model.addDraft(draft) orelse return null;
        model.composer.draft_id = model.drafts[index].id;
        model.selected_draft = index;
        return index;
    }

    pub fn removeSelectedDraft(model: *Model) void {
        if (model.selected_draft >= model.draft_count) return;
        const removed = model.selected_draft;
        for (removed + 1..model.draft_count) |index| model.drafts[index - 1] = model.drafts[index];
        model.draft_count -= 1;
        model.drafts[model.draft_count] = .{};
        model.selected_draft = if (model.draft_count == 0) no_index else @min(removed, model.draft_count - 1);
    }

    pub fn removeDraftById(model: *Model, id: DraftId) bool {
        const index = model.draftIndexById(id) orelse return false;
        model.selected_draft = index;
        model.removeSelectedDraft();
        return true;
    }

    pub fn resetRemoteDrafts(model: *Model) void {
        var kept: usize = 0;
        for (model.drafts[0..model.draft_count]) |draft| {
            if (draft.remote) continue;
            model.drafts[kept] = draft;
            kept += 1;
        }
        for (kept..model.draft_count) |index| model.drafts[index] = .{};
        model.draft_count = kept;
        model.selected_draft = if (kept == 0) no_index else @min(model.selected_draft, kept - 1);
    }

    pub fn selectAccount(model: *Model, index: usize) void {
        model.selected_account = if (index < model.account_count) index else no_index;
        model.reconcileSelection();
    }

    pub fn selectFilter(model: *Model, filter: InboxFilter) void {
        model.filter = filter;
        if (filter == .drafts) {
            if (model.selected_draft >= model.draft_count and model.draft_count > 0) model.selected_draft = 0;
        }
        model.reconcileSelection();
    }

    pub fn selectThread(model: *Model, index: usize) void {
        if (index < model.thread_count and model.threadMatches(index)) {
            model.selected_thread = index;
        }
    }

    pub fn selectRelative(model: *Model, delta: isize) void {
        if (model.isDraftsView()) {
            model.selectRelativeDraft(delta);
            return;
        }
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

    pub fn activateSelected(model: *Model) void {
        if (model.isDraftsView()) {
            if (!model.composeBusy() and model.selected_draft < model.draft_count) model.openDraft(model.selected_draft);
            return;
        }
        model.openSelectedWindow();
    }

    pub fn openSelectedWindow(model: *Model) void {
        if (!model.hasSelection()) return;
        const message_id = model.threads[model.selected_thread].id;
        for (model.open_windows[0..model.open_window_count]) |open_id| {
            if (open_id.value == message_id.value) return;
        }
        if (model.open_window_count >= model.open_windows.len) return;
        model.open_windows[model.open_window_count] = message_id;
        model.open_window_count += 1;
    }

    pub fn closeWindow(model: *Model, message_id_value: usize) void {
        const close_id: u64 = @intCast(message_id_value);
        var kept: usize = 0;
        for (model.open_windows[0..model.open_window_count]) |message_id| {
            if (message_id.value == close_id) continue;
            model.open_windows[kept] = message_id;
            kept += 1;
        }
        for (kept..model.open_window_count) |index| model.open_windows[index] = .{};
        model.open_window_count = kept;
    }

    pub fn accountIndexById(model: *const Model, account_id: AccountId) ?usize {
        if (!account_id.isValid()) return null;
        for (model.accounts[0..model.account_count], 0..) |account, index| {
            if (account.id.value == account_id.value) return index;
        }
        return null;
    }

    pub fn threadIndexById(model: *const Model, message_id: MessageId) ?usize {
        if (!message_id.isValid()) return null;
        for (model.threads[0..model.thread_count], 0..) |thread, index| {
            if (thread.id.value == message_id.value) return index;
        }
        return null;
    }

    pub fn resetForSync(model: *Model) u64 {
        model.sync_generation +%= 1;
        if (model.sync_generation == 0) model.sync_generation = 1;
        model.thread_count = 0;
        model.selected_thread = no_index;
        model.open_windows = [_]MessageId{.{}} ** 3;
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
            const key = 0x2000_0000_0000_0000 | (model.mutation_counter & 0x0fff_ffff_ffff_ffff);
            model.mutation_counter += 1;
            pending.* = .{
                .active = true,
                .key = key,
                .thread_id = thread.id,
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
            if (!success) {
                if (model.threadIndexById(pending.thread_id)) |thread_index| {
                    const thread = &model.threads[thread_index];
                    thread.unread = pending.unread;
                    thread.starred = pending.starred;
                    thread.in_inbox = pending.in_inbox;
                    thread.archived = pending.archived;
                    thread.trashed = pending.trashed;
                    thread.snoozed = pending.snoozed;
                    model.status_message.set("The provider rejected the action; the message was restored.");
                }
            }
            pending.* = .{};
            model.reconcileSelection();
            return;
        }
    }

    pub fn reconcileSelection(model: *Model) void {
        if (model.isDraftsView()) {
            model.selected_thread = no_index;
            model.reconcileDraftSelection();
            return;
        }
        if (model.selected_thread < model.thread_count and model.threadMatches(model.selected_thread)) return;
        model.selected_thread = no_index;
        for (0..model.thread_count) |index| {
            if (model.threadMatches(index)) {
                model.selected_thread = index;
                break;
            }
        }
    }

    fn selectRelativeDraft(model: *Model, delta: isize) void {
        var visible: [max_drafts]usize = undefined;
        var count: usize = 0;
        for (0..model.draft_count) |index| {
            if (!model.draftMatches(index)) continue;
            visible[count] = index;
            count += 1;
        }
        if (count == 0) {
            model.selected_draft = no_index;
            return;
        }
        var current: usize = 0;
        for (visible[0..count], 0..) |draft_index, position| {
            if (draft_index == model.selected_draft) {
                current = position;
                break;
            }
        }
        if (delta > 0) current = @min(count - 1, current + @as(usize, @intCast(delta)));
        if (delta < 0) current -|= @as(usize, @intCast(-delta));
        model.selected_draft = visible[current];
    }

    fn reconcileDraftSelection(model: *Model) void {
        if (model.selected_draft < model.draft_count and model.draftMatches(model.selected_draft)) return;
        model.selected_draft = no_index;
        for (0..model.draft_count) |index| {
            if (!model.draftMatches(index)) continue;
            model.selected_draft = index;
            return;
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
            .drafts => false,
        };
        if (!matches_filter) return false;
        const query = std.mem.trim(u8, model.search(), " \t\r\n");
        if (query.len == 0) return true;
        return containsAsciiIgnoreCase(thread.subjectSlice(), query) or
            containsAsciiIgnoreCase(thread.senderSlice(), query) or
            containsAsciiIgnoreCase(thread.snippetSlice(), query) or
            (thread.account_index < model.account_count and containsAsciiIgnoreCase(model.accounts[thread.account_index].emailSlice(), query));
    }

    fn draftMatches(model: *const Model, index: usize) bool {
        if (index >= model.draft_count) return false;
        const draft = &model.drafts[index];
        if (model.selected_account != no_index and draft.account_index != model.selected_account) return false;
        const query = std.mem.trim(u8, model.search(), " \t\r\n");
        if (query.len == 0) return true;
        return containsAsciiIgnoreCase(draft.subject.slice(), query) or
            containsAsciiIgnoreCase(draft.to.slice(), query) or
            containsAsciiIgnoreCase(draft.body.slice(), query) or
            (draft.account_index < model.account_count and containsAsciiIgnoreCase(model.accounts[draft.account_index].emailSlice(), query));
    }
};

fn prefixedSubject(buffer: []u8, prefix: []const u8, subject: []const u8) []const u8 {
    if (std.ascii.startsWithIgnoreCase(subject, prefix)) return subject;
    return std.fmt.bufPrint(buffer, "{s}{s}", .{ prefix, subject }) catch subject;
}

fn fillReplyAllCc(model: *const Model, thread: *const MailThread, output: *canvas.TextBuffer(1024)) void {
    var buffer: [1024]u8 = undefined;
    var length: usize = 0;
    const sources = [_][]const u8{ thread.to_recipients.slice(), thread.cc_recipients.slice() };
    for (sources) |source| {
        var tokens = std.mem.tokenizeAny(u8, source, ",;");
        while (tokens.next()) |raw| {
            const recipient = std.mem.trim(u8, raw, " \t\r\n");
            if (recipient.len == 0 or isOwnAddress(model, recipient) or containsRecipient(buffer[0..length], recipient)) continue;
            const separator = if (length == 0) "" else ", ";
            if (length + separator.len + recipient.len > buffer.len) break;
            @memcpy(buffer[length .. length + separator.len], separator);
            length += separator.len;
            @memcpy(buffer[length .. length + recipient.len], recipient);
            length += recipient.len;
        }
    }
    output.set(buffer[0..length]);
}

fn isOwnAddress(model: *const Model, candidate: []const u8) bool {
    for (model.accounts[0..model.account_count]) |*account| {
        if (std.ascii.eqlIgnoreCase(account.emailSlice(), extractAddress(candidate))) return true;
    }
    return false;
}

fn containsRecipient(list: []const u8, candidate: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, list, ",;");
    while (tokens.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(extractAddress(std.mem.trim(u8, entry, " \t\r\n")), extractAddress(candidate))) return true;
    }
    return false;
}

pub fn extractAddress(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const open = std.mem.lastIndexOfScalar(u8, trimmed, '<') orelse return trimmed;
    const close_relative = std.mem.indexOfScalar(u8, trimmed[open + 1 ..], '>') orelse return trimmed;
    return std.mem.trim(u8, trimmed[open + 1 .. open + 1 + close_relative], " \t\r\n");
}

pub fn initialModel() Model {
    var model = Model{};
    for (emulator_config.accounts) |seed| {
        model.addAccount(seed.provider, seed.email, seed.display_name, seed.bearer_token, seed.base_url);
    }
    model.status_message.set("Connecting to Gmail and Outlook emulators.");
    return model;
}

pub fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return text_domain.containsAsciiIgnoreCase(haystack, needle);
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

test "accounts messages windows and mutation rollback use stable ids" {
    var model = initialModel();
    try std.testing.expect(model.accounts[0].id.isValid());
    try std.testing.expect(model.accounts[1].id.isValid());
    try std.testing.expect(model.accounts[0].id.value != model.accounts[1].id.value);

    var first = MailThread{ .account_index = 0, .unread = true };
    first.provider_thread_id.set("stable-first");
    _ = model.addThread(first);
    var second = MailThread{ .account_index = 1, .unread = false };
    second.provider_thread_id.set("stable-second");
    _ = model.addThread(second);

    const first_id = model.threads[0].id;
    try std.testing.expect(first_id.isValid());
    try std.testing.expectEqual(model.accounts[0].id.value, model.threads[0].account_id.value);
    model.selectThread(0);
    model.openSelectedWindow();
    const mutation_key = model.beginMutation(0).?;
    model.threads[0].unread = false;

    std.mem.swap(MailThread, &model.threads[0], &model.threads[1]);
    try std.testing.expectEqual(@as(usize, 1), model.threadIndexById(first_id).?);
    try std.testing.expectEqual(first_id.value, model.open_windows[0].value);

    model.finishMutation(mutation_key, false);
    try std.testing.expect(model.threads[model.threadIndexById(first_id).?].unread);
}

test "reply and reply-all lock the source account and normalize recipients" {
    var model = initialModel();
    var thread = MailThread{ .account_index = 0 };
    thread.provider_thread_id.set("thread-reply");
    thread.provider_message_id.set("message-reply");
    thread.sender.set("Customer <customer@example.com>");
    thread.sender_email.set("customer@example.com");
    thread.to_recipients.set("alpha.inbox@example.com, teammate@example.com");
    thread.cc_recipients.set("teammate@example.com, beta.inbox@example.com, ops@example.com");
    thread.subject.set("Status update");
    thread.body.set("Original body");
    _ = model.addThread(thread);

    model.beginMessageCompose(.reply_all);
    try std.testing.expectEqual(@as(usize, 0), model.composer.account_index);
    try std.testing.expectEqualStrings("customer@example.com", model.composer.to());
    try std.testing.expectEqualStrings("teammate@example.com, ops@example.com", model.composer.cc());
    try std.testing.expectEqualStrings("Re: Status update", model.composer.subject());
    try std.testing.expectEqualStrings("thread-reply", model.composer.source_thread_id.slice());
}

test "forward opens a new conversation with the original message quoted" {
    var model = initialModel();
    var thread = MailThread{ .account_index = 1 };
    thread.provider_thread_id.set("thread-forward");
    thread.provider_message_id.set("message-forward");
    thread.sender.set("Founder <founder@example.com>");
    thread.subject.set("Plan");
    thread.body.set("Original plan");
    _ = model.addThread(thread);
    model.beginMessageCompose(.forward);
    try std.testing.expectEqualStrings("Fwd: Plan", model.composer.subject());
    try std.testing.expect(model.composer.source_thread_id.isEmpty());
    try std.testing.expect(containsAsciiIgnoreCase(model.composer.body(), "Forwarded message"));
    try std.testing.expect(containsAsciiIgnoreCase(model.composer.body(), "Original plan"));
}
