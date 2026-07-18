const std = @import("std");
const native_sdk = @import("native_sdk");
const compose = @import("compose.zig");
const mail = @import("../model.zig");
const ids = @import("../domain/ids.zig");
const transport = @import("../platform/effects_transport.zig");
const common = @import("../providers/outbound.zig");
const gmail = @import("../providers/gmail/outbound.zig");
const outlook = @import("../providers/outlook/outbound.zig");

pub const autosave_timer_key: u64 = 0x4f55_5442_4f55_4e44;
const operation_key_namespace: u64 = 0x4000_0000_0000_0000;

const ReceiptMessage = struct {
    id: ?[]const u8 = null,
    threadId: ?[]const u8 = null,
};

const Receipt = struct {
    id: ?[]const u8 = null,
    conversationId: ?[]const u8 = null,
    message: ?ReceiptMessage = null,
};

const RecipientScratch = struct {
    to: [32]common.Recipient = undefined,
    to_count: usize = 0,
    cc: [32]common.Recipient = undefined,
    cc_count: usize = 0,
    bcc: [32]common.Recipient = undefined,
    bcc_count: usize = 0,
    body: [32 * 1024]u8 = undefined,
    references: [4096]u8 = undefined,
};

pub fn scheduleAutosave(model: *mail.Model, fx: anytype, on_fire: anytype) void {
    if (!model.composer.isOpen()) return;
    fx.startTimer(.{
        .key = autosave_timer_key,
        .interval_ms = 5_000,
        .mode = .one_shot,
        .on_fire = on_fire,
    });
}

pub fn save(model: *mail.Model, fx: anytype, on_response: anytype, on_authorized_response: anytype, close_after: bool) void {
    if (model.composer.stage != .idle) return;
    if (!model.composer.isOpen() or !model.composer.hasContent()) {
        if (close_after) model.composer.close();
        return;
    }
    if (model.composer.provider_content_read_only) {
        model.status_message.set("Provider draft preserved without rewriting rich content.");
        if (close_after) model.composer.close();
        return;
    }
    if (!model.composer.provider_draft_id.isEmpty() and !model.composer.dirty) {
        model.status_message.set("Draft is already saved to the provider.");
        if (close_after) model.composer.close();
        return;
    }
    fx.cancelTimer(autosave_timer_key);
    if (model.snapshotComposer(false) == null) {
        fail(model, "The local draft limit has been reached. Discard another draft before saving.");
        return;
    }
    beginOperation(model, if (close_after) .save_and_close else .save, .saving);
    startUpsert(model, fx, on_response, on_authorized_response);
    if (close_after and model.composer.state != .failed) model.composer.window_open = false;
}

pub fn send(model: *mail.Model, fx: anytype, on_response: anytype, on_authorized_response: anytype) void {
    if (model.composer.stage != .idle) return;
    if (!model.composer.canSend()) {
        fail(model, "Add a valid recipient and a subject or message before sending.");
        return;
    }
    fx.cancelTimer(autosave_timer_key);
    const deliver_existing = !model.composer.provider_draft_id.isEmpty() and !model.composer.dirty;
    if (model.snapshotComposer(false) == null) {
        fail(model, "The local draft limit has been reached. Discard another draft before sending.");
        return;
    }
    beginOperation(model, .send, .sending);
    if (deliver_existing) {
        model.composer.stage = .deliver;
        issueCurrentStage(model, fx, on_response, on_authorized_response);
    } else {
        startUpsert(model, fx, on_response, on_authorized_response);
    }
}

pub fn discard(model: *mail.Model, fx: anytype, on_response: anytype, on_authorized_response: anytype) void {
    if (model.composer.stage != .idle) return;
    fx.cancelTimer(autosave_timer_key);
    if (model.composer.provider_draft_id.isEmpty() or model.composer.account_index >= model.account_count) {
        removeComposerDraft(model);
        model.composer.close();
        model.status_message.set("Draft discarded.");
        return;
    }
    beginOperation(model, .discard, .saving);
    model.composer.stage = .delete;
    issueCurrentStage(model, fx, on_response, on_authorized_response);
    if (model.composer.state != .failed) model.composer.window_open = false;
}

/// Returns true when the operation reached a terminal state and provider sync
/// should restart. A fresh generation invalidates any stale draft-list response
/// that was already in flight when this mutation began.
pub fn handleResponse(model: *mail.Model, response: native_sdk.EffectResponse, fx: anytype, on_response: anytype, on_authorized_response: anytype) bool {
    if (!model.composer.operation_id.isValid() or response.key != operationKey(model.composer.operation_id.value, model.composer.stage)) return false;
    if (!responseOk(response)) {
        fail(model, "The provider rejected the mail operation. Your draft is still available.");
        return true;
    }
    switch (model.composer.stage) {
        .create_threaded => {
            if (!applyReceipt(model, response.body)) {
                fail(model, "Outlook did not return the threaded draft it created.");
                return true;
            }
            model.composer.operation_generation = model.composer.autosave_generation;
            model.composer.stage = .upsert;
            issueCurrentStage(model, fx, on_response, on_authorized_response);
            return model.composer.state == .failed;
        },
        .upsert => {
            if (!applyReceipt(model, response.body)) {
                fail(model, "The provider saved a draft without returning its identifier.");
                return true;
            }
            const edited_while_saving = model.composer.autosave_generation != model.composer.operation_generation;
            _ = model.snapshotComposer(!edited_while_saving);
            if (edited_while_saving) {
                // A revision is a distinct fetch identity. This prevents the
                // effects runtime from coalescing it with the completed save.
                model.composer.operation_id = ids.nextOperationId(&model.next_operation_id);
                model.composer.operation_generation = model.composer.autosave_generation;
                model.composer.state = if (model.composer.intent == .send) .sending else .saving;
                issueCurrentStage(model, fx, on_response, on_authorized_response);
                return model.composer.state == .failed;
            }
            model.composer.dirty = false;
            if (model.composer.intent == .send) {
                model.composer.stage = .deliver;
                issueCurrentStage(model, fx, on_response, on_authorized_response);
                return model.composer.state == .failed;
            } else {
                const close_after = model.composer.intent == .save_and_close;
                model.composer.state = .saved;
                model.composer.intent = .none;
                model.composer.stage = .idle;
                model.status_message.set("Draft saved to the provider.");
                if (close_after) model.composer.close();
                return true;
            }
        },
        .deliver => {
            removeComposerDraft(model);
            model.composer.close();
            model.status_message.set("Email sent.");
            return true;
        },
        .delete => {
            removeComposerDraft(model);
            model.composer.close();
            model.status_message.set("Draft discarded.");
            return true;
        },
        .idle => return false,
    }
}

fn beginOperation(model: *mail.Model, intent: compose.Intent, state: compose.State) void {
    model.composer.operation_id = ids.nextOperationId(&model.next_operation_id);
    model.composer.intent = intent;
    model.composer.state = state;
    model.composer.operation_generation = model.composer.autosave_generation;
    model.composer.error_message = .{};
}

fn startUpsert(model: *mail.Model, fx: anytype, on_response: anytype, on_authorized_response: anytype) void {
    if (model.composer.account_index >= model.account_count) {
        fail(model, "The sending account is no longer available.");
        return;
    }
    const account = &model.accounts[model.composer.account_index];
    if (account.provider == .microsoft and model.composer.provider_draft_id.isEmpty() and
        model.composer.mode != .new)
    {
        model.composer.stage = .create_threaded;
    } else {
        model.composer.stage = .upsert;
    }
    issueCurrentStage(model, fx, on_response, on_authorized_response);
}

fn issueCurrentStage(model: *mail.Model, fx: anytype, on_response: anytype, on_authorized_response: anytype) void {
    const account_index = model.accountIndexById(model.composer.account_id) orelse {
        fail(model, "The sending account is no longer available.");
        return;
    };
    model.composer.account_index = account_index;
    const account = &model.accounts[account_index];
    var url_bytes: [common.max_url_bytes]u8 = undefined;
    var body_bytes: [common.max_payload_bytes]u8 = undefined;
    var raw_bytes: [48 * 1024]u8 = undefined;
    var recipients = RecipientScratch{};
    const message = buildMessage(model, &recipients) catch {
        fail(model, "Use valid email addresses; at most 32 recipients are allowed in each field.");
        return;
    };
    const request = switch (model.composer.stage) {
        .create_threaded => switch (model.composer.mode) {
            .reply, .reply_all => outlook.createReplyDraft(.init(&url_bytes, &body_bytes), account.baseUrl(), model.composer.source_message_id.slice(), model.composer.mode == .reply_all),
            .forward => outlook.createForwardDraft(.init(&url_bytes, &body_bytes), account.baseUrl(), model.composer.source_message_id.slice()),
            .new => return,
        },
        .upsert => switch (account.provider) {
            .gmail => if (model.composer.provider_draft_id.isEmpty())
                gmail.createDraft(.init(&url_bytes, &body_bytes, &raw_bytes), account.baseUrl(), message)
            else
                gmail.updateDraft(.init(&url_bytes, &body_bytes, &raw_bytes), account.baseUrl(), model.composer.provider_draft_id.slice(), message),
            .microsoft => if (model.composer.provider_draft_id.isEmpty())
                outlook.createDraft(.init(&url_bytes, &body_bytes), account.baseUrl(), message)
            else
                outlook.updateDraft(.init(&url_bytes, &body_bytes), account.baseUrl(), model.composer.provider_draft_id.slice(), message),
        },
        .deliver => switch (account.provider) {
            .gmail => gmail.sendDraft(.init(&url_bytes, &body_bytes), account.baseUrl(), model.composer.provider_draft_id.slice()),
            .microsoft => outlook.sendDraft(.init(&url_bytes, &body_bytes), account.baseUrl(), model.composer.provider_draft_id.slice()),
        },
        .delete => switch (account.provider) {
            .gmail => gmail.deleteDraft(.init(&url_bytes, &body_bytes), account.baseUrl(), model.composer.provider_draft_id.slice()),
            .microsoft => outlook.deleteDraft(.init(&url_bytes, &body_bytes), account.baseUrl(), model.composer.provider_draft_id.slice()),
        },
        .idle => return,
    } catch {
        fail(model, "This message is too large or contains an invalid recipient/header.");
        return;
    };
    const key = operationKey(model.composer.operation_id.value, model.composer.stage);
    if (!transport.fetchAuthorized(fx, key, request, account.tokenSlice(), account.credential_key.slice(), on_response, on_authorized_response)) {
        fail(model, "Could not queue the provider request.");
    }
}

fn buildMessage(model: *const mail.Model, scratch: *RecipientScratch) common.BuildError!common.OutgoingMessage {
    const account = &model.accounts[model.composer.account_index];
    scratch.to_count = try parseRecipients(model.composer.to(), &scratch.to);
    scratch.cc_count = try parseRecipients(model.composer.cc(), &scratch.cc);
    scratch.bcc_count = try parseRecipients(model.composer.bcc(), &scratch.bcc);
    const body = composedBody(model, &scratch.body);
    return .{
        .mode = switch (model.composer.mode) {
            .new => .new,
            .reply => .reply,
            .reply_all => .reply_all,
            .forward => .forward,
        },
        .from = .{ .name = account.displayName(), .address = account.emailSlice() },
        .to = scratch.to[0..scratch.to_count],
        .cc = scratch.cc[0..scratch.cc_count],
        .bcc = scratch.bcc[0..scratch.bcc_count],
        .subject = model.composer.subject(),
        .plain_body = body,
        .thread_id = if (model.composer.source_thread_id.isEmpty()) null else model.composer.source_thread_id.slice(),
        .in_reply_to = if (model.composer.source_rfc_message_id.isEmpty()) null else model.composer.source_rfc_message_id.slice(),
        .references = composeReferences(model, &scratch.references),
    };
}

fn composeReferences(model: *const mail.Model, scratch: []u8) ?[]const u8 {
    if (model.composer.source_rfc_message_id.isEmpty()) {
        return if (model.composer.source_references.isEmpty()) null else model.composer.source_references.slice();
    }
    if (model.composer.source_references.isEmpty()) return model.composer.source_rfc_message_id.slice();
    const existing = model.composer.source_references.slice();
    const message_id = model.composer.source_rfc_message_id.slice();
    if (existing.len + 1 + message_id.len > scratch.len) return existing;
    @memcpy(scratch[0..existing.len], existing);
    scratch[existing.len] = ' ';
    @memcpy(scratch[existing.len + 1 .. existing.len + 1 + message_id.len], message_id);
    return scratch[0 .. existing.len + 1 + message_id.len];
}

fn composedBody(model: *const mail.Model, output: []u8) []const u8 {
    if (model.composer.quoted_body.isEmpty()) return model.composer.body();
    var cursor: usize = 0;
    appendClamped(output, &cursor, model.composer.body());
    appendClamped(output, &cursor, "\n\nOn an earlier message, the sender wrote:\n");
    var lines = std.mem.splitScalar(u8, model.composer.quoted_body.slice(), '\n');
    while (lines.next()) |line| {
        appendClamped(output, &cursor, "> ");
        appendClamped(output, &cursor, line);
        appendClamped(output, &cursor, "\n");
    }
    return output[0..cursor];
}

fn appendClamped(output: []u8, cursor: *usize, value: []const u8) void {
    const count = @min(value.len, output.len - cursor.*);
    @memcpy(output[cursor.* .. cursor.* + count], value[0..count]);
    cursor.* += count;
}

fn parseRecipients(source: []const u8, output: []common.Recipient) common.BuildError!usize {
    var count: usize = 0;
    var start: usize = 0;
    var index: usize = 0;
    var quoted = false;
    var angle_depth: usize = 0;
    while (index <= source.len) : (index += 1) {
        const at_end = index == source.len;
        if (!at_end) {
            switch (source[index]) {
                '"' => quoted = !quoted,
                '<' => if (!quoted) {
                    angle_depth += 1;
                },
                '>' => if (!quoted and angle_depth > 0) {
                    angle_depth -= 1;
                },
                else => {},
            }
        }
        if (!at_end and (source[index] != ',' and source[index] != ';' or quoted or angle_depth != 0)) continue;
        const raw = source[start..index];
        start = index + 1;
        const value = std.mem.trim(u8, raw, " \t\r\n");
        if (value.len == 0) continue;
        if (count >= output.len) return error.InvalidAddress;
        const address = mail.extractAddress(value);
        const name = if (std.mem.indexOfScalar(u8, value, '<')) |open|
            std.mem.trim(u8, value[0..open], " \t\r\n\"")
        else
            null;
        output[count] = .{ .name = if (name) |candidate| if (candidate.len == 0) null else candidate else null, .address = address };
        count += 1;
    }
    return count;
}

fn applyReceipt(model: *mail.Model, body: []const u8) bool {
    if (body.len == 0) return !model.composer.provider_draft_id.isEmpty();
    const parsed = std.json.parseFromSlice(Receipt, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    const id = parsed.value.id orelse return false;
    model.composer.provider_draft_id.set(id);
    if (parsed.value.message) |message| {
        if (message.id) |message_id| model.composer.provider_message_id.set(message_id);
        if (message.threadId) |thread_id| model.composer.source_thread_id.set(thread_id);
    } else {
        model.composer.provider_message_id.set(id);
        if (parsed.value.conversationId) |thread_id| model.composer.source_thread_id.set(thread_id);
    }
    return true;
}

fn removeComposerDraft(model: *mail.Model) void {
    if (model.removeDraftById(model.composer.draft_id)) return;
    var index: usize = 0;
    while (index < model.draft_count) {
        const draft = &model.drafts[index];
        const same_provider = !model.composer.provider_draft_id.isEmpty() and
            std.mem.eql(u8, draft.provider_draft_id.slice(), model.composer.provider_draft_id.slice()) and
            draft.account_id.value == model.composer.account_id.value;
        if (same_provider) {
            model.selected_draft = index;
            model.removeSelectedDraft();
            return;
        }
        index += 1;
    }
}

fn operationKey(operation_id: u64, stage: compose.Stage) u64 {
    return operation_key_namespace | ((operation_id & 0x00ff_ffff_ffff_ffff) << 4) | @intFromEnum(stage);
}

fn responseOk(response: native_sdk.EffectResponse) bool {
    return response.outcome == .ok and response.status >= 200 and response.status < 300 and !response.truncated;
}

fn fail(model: *mail.Model, message: []const u8) void {
    model.composer.window_open = true;
    model.composer.state = .failed;
    model.composer.intent = .none;
    model.composer.stage = .idle;
    model.composer.error_message.set(message);
    model.status_message.set(message);
}

test "recipient parsing retains names and addresses" {
    var recipients: [4]common.Recipient = undefined;
    const count = try parseRecipients("Customer <customer@example.com>, ops@example.com", &recipients);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("Customer", recipients[0].name.?);
    try std.testing.expectEqualStrings("customer@example.com", recipients[0].address);
}

test "recipient parsing preserves quoted display-name commas" {
    var recipients: [4]common.Recipient = undefined;
    const count = try parseRecipients("\"Doe, Jane\" <jane@example.com>; ops@example.com", &recipients);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("Doe, Jane", recipients[0].name.?);
    try std.testing.expectEqualStrings("jane@example.com", recipients[0].address);
}
