const std = @import("std");
const native_sdk = @import("native_sdk");
const text = @import("../domain/text.zig");
const ids = @import("../domain/ids.zig");
const draft = @import("../domain/draft.zig");

const canvas = native_sdk.canvas;

pub const Mode = draft.ComposeMode;
pub const State = enum { closed, editing, saving, saved, sending, failed };
pub const Intent = enum { none, save, save_and_close, send, discard };
pub const Stage = enum { idle, create_threaded, upsert, deliver, delete };

/// Model-owned compose editor state. Provider request construction deliberately
/// lives outside this type so UI edits can be tested without HTTP concerns.
pub const Composer = struct {
    window_open: bool = false,
    state: State = .closed,
    mode: Mode = .new,
    /// Stable identity of the local/provider-backed draft being edited. This
    /// must never be inferred from the drafts list's current selection.
    draft_id: ids.DraftId = .{},
    account_id: ids.AccountId = .{},
    account_index: usize = 0,
    source_message_id: text.Text(512) = .{},
    source_thread_id: text.Text(512) = .{},
    source_rfc_message_id: text.Text(512) = .{},
    source_references: text.Text(2048) = .{},
    provider_draft_id: text.Text(512) = .{},
    provider_message_id: text.Text(512) = .{},
    to_buffer: canvas.TextBuffer(1024) = .{},
    cc_buffer: canvas.TextBuffer(1024) = .{},
    bcc_buffer: canvas.TextBuffer(1024) = .{},
    subject_buffer: canvas.TextBuffer(512) = .{},
    body_buffer: canvas.TextBuffer(16 * 1024) = .{},
    quoted_body: text.Text(8192) = .{},
    cc_bcc_visible: bool = false,
    provider_content_read_only: bool = false,
    dirty: bool = false,
    autosave_generation: u64 = 0,
    operation_generation: u64 = 0,
    error_message: text.Text(256) = .{},
    operation_id: ids.OperationId = .{},
    intent: Intent = .none,
    stage: Stage = .idle,

    pub fn isOpen(self: *const Composer) bool {
        return self.window_open;
    }

    pub fn canSend(self: *const Composer) bool {
        return self.isOpen() and self.stage == .idle and self.state != .saving and self.state != .sending and
            std.mem.trim(u8, self.to(), " \t\r\n,;").len != 0 and
            (std.mem.trim(u8, self.subject(), " \t\r\n").len != 0 or
                std.mem.trim(u8, self.body(), " \t\r\n").len != 0);
    }

    pub fn hasContent(self: *const Composer) bool {
        return std.mem.trim(u8, self.to(), " \t\r\n,;").len != 0 or
            std.mem.trim(u8, self.cc(), " \t\r\n,;").len != 0 or
            std.mem.trim(u8, self.bcc(), " \t\r\n,;").len != 0 or
            std.mem.trim(u8, self.subject(), " \t\r\n").len != 0 or
            std.mem.trim(u8, self.body(), " \t\r\n").len != 0;
    }

    pub fn begin(self: *Composer, mode: Mode, account_id: ids.AccountId, account_index: usize) void {
        self.* = .{
            .window_open = true,
            .state = .editing,
            .mode = mode,
            .account_id = account_id,
            .account_index = account_index,
        };
    }

    pub fn close(self: *Composer) void {
        self.* = .{};
    }

    pub fn markEdited(self: *Composer) void {
        if (self.stage == .idle) self.state = .editing;
        self.dirty = true;
        self.error_message = .{};
        self.autosave_generation +%= 1;
        if (self.autosave_generation == 0) self.autosave_generation = 1;
    }

    pub fn to(self: *const Composer) []const u8 {
        return self.to_buffer.text();
    }

    pub fn cc(self: *const Composer) []const u8 {
        return self.cc_buffer.text();
    }

    pub fn bcc(self: *const Composer) []const u8 {
        return self.bcc_buffer.text();
    }

    pub fn subject(self: *const Composer) []const u8 {
        return self.subject_buffer.text();
    }

    pub fn body(self: *const Composer) []const u8 {
        return self.body_buffer.text();
    }

    pub fn applyTo(self: *Composer, edit: canvas.TextInputEvent) void {
        self.to_buffer.apply(edit);
        self.markEdited();
    }

    pub fn applyCc(self: *Composer, edit: canvas.TextInputEvent) void {
        self.cc_buffer.apply(edit);
        self.markEdited();
    }

    pub fn applyBcc(self: *Composer, edit: canvas.TextInputEvent) void {
        self.bcc_buffer.apply(edit);
        self.markEdited();
    }

    pub fn applySubject(self: *Composer, edit: canvas.TextInputEvent) void {
        self.subject_buffer.apply(edit);
        self.markEdited();
    }

    pub fn applyBody(self: *Composer, edit: canvas.TextInputEvent) void {
        self.body_buffer.apply(edit);
        self.markEdited();
    }
};

test "composer requires a recipient and useful content before sending" {
    var composer = Composer{};
    composer.begin(.new, .{ .value = 1 }, 0);
    try std.testing.expect(!composer.canSend());
    composer.to_buffer.set("person@example.com");
    composer.subject_buffer.set("Hello");
    try std.testing.expect(composer.canSend());
}

test "editing advances autosave identity and preserves provider identity" {
    var composer = Composer{};
    composer.begin(.reply, .{ .value = 9 }, 2);
    composer.provider_draft_id.set("draft-1");
    composer.applyBody(.{ .insert_text = "Thanks" });
    try std.testing.expect(composer.dirty);
    try std.testing.expectEqual(@as(u64, 1), composer.autosave_generation);
    try std.testing.expectEqualStrings("draft-1", composer.provider_draft_id.slice());
}
