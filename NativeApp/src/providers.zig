const std = @import("std");
const native_sdk = @import("native_sdk");
const mail = @import("model.zig");
const transport = @import("platform/effects_transport.zig");

pub const initial_key_base: u64 = 100;
pub const gmail_detail_key_base: u64 = 1_000;
pub const gmail_draft_detail_key_base: u64 = 10_000;
pub const gmail_body_key_base: u64 = 20_000;
const generation_key_stride: u64 = 100_000;
const gmail_inbox_list_folder_index: usize = 0;
const gmail_background_list_folder_index: usize = 1;
const gmail_draft_list_folder_index: usize = 10;
const gmail_detail_account_stride: u64 = mail.max_gmail_refs;
const gmail_draft_detail_account_stride: u64 = 16;
// Gmail permits 100 subrequests per batch but recommends no more than 50 to
// reduce per-user rate limiting. One inbox page therefore takes two batches.
const gmail_batch_size: usize = 50;
const gmail_detail_max_retries: u8 = 2;
const gmail_metadata_query = "format=metadata&fields=id%2Csnippet%2Cmessages%28id%2CthreadId%2ClabelIds%2Csnippet%2CinternalDate%2Cpayload%28headers%29%29&metadataHeaders=From&metadataHeaders=Reply-To&metadataHeaders=To&metadataHeaders=Cc&metadataHeaders=Subject&metadataHeaders=Message-ID&metadataHeaders=References";

const GmailThreadReference = struct {
    id: []const u8,
};

const GmailThreadList = struct {
    threads: ?[]const GmailThreadReference = null,
};

const GmailDraftReference = struct {
    id: []const u8,
};

const GmailDraftList = struct {
    drafts: ?[]const GmailDraftReference = null,
};

const GmailBody = struct {
    data: ?[]const u8 = null,
};

const GmailHeader = struct {
    name: []const u8,
    value: []const u8,
};

const GmailPayload = struct {
    mimeType: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    headers: ?[]const GmailHeader = null,
    body: ?GmailBody = null,
    parts: ?[]const GmailPayload = null,
};

const GmailMessage = struct {
    id: []const u8,
    threadId: []const u8,
    labelIds: ?[]const []const u8 = null,
    snippet: ?[]const u8 = null,
    internalDate: ?[]const u8 = null,
    payload: GmailPayload,
};

const GmailThread = struct {
    id: []const u8,
    snippet: ?[]const u8 = null,
    messages: []const GmailMessage,
};

const GmailDraft = struct {
    id: []const u8,
    message: GmailMessage,
};

const OutlookEmailAddress = struct {
    address: []const u8,
    name: ?[]const u8 = null,
};

const OutlookRecipient = struct {
    emailAddress: OutlookEmailAddress,
};

const OutlookBody = struct {
    contentType: []const u8,
    content: []const u8,
};

const OutlookFlag = struct {
    flagStatus: ?[]const u8 = null,
};

const OutlookMessage = struct {
    id: []const u8,
    conversationId: []const u8,
    subject: ?[]const u8 = null,
    bodyPreview: ?[]const u8 = null,
    body: ?OutlookBody = null,
    from: ?OutlookRecipient = null,
    toRecipients: ?[]const OutlookRecipient = null,
    ccRecipients: ?[]const OutlookRecipient = null,
    bccRecipients: ?[]const OutlookRecipient = null,
    replyTo: ?[]const OutlookRecipient = null,
    hasAttachments: ?bool = null,
    categories: ?[]const []const u8 = null,
    parentFolderId: ?[]const u8 = null,
    receivedDateTime: ?[]const u8 = null,
    isRead: ?bool = null,
    flag: ?OutlookFlag = null,
};

const OutlookMessageList = struct {
    value: []const OutlookMessage,
};

const OutlookFolder = enum { inbox, archive, trash, drafts };
const outlook_folders = [_]OutlookFolder{ .inbox, .archive, .trash, .drafts };

const OutlookMutationReceipt = struct {
    id: ?[]const u8 = null,
};

pub fn startInitialSync(model: *mail.Model, fx: anytype, on_response: anytype, on_authorized_response: anytype) void {
    cancelPreviousSync(model, fx);
    const generation = model.resetForSync();
    model.resetRemoteDrafts();
    for (model.accounts[0..model.account_count], 0..) |*account, index| {
        account.sync_state = .loading;
        account.gmail_ref_count = 0;
        account.gmail_background_ref_count = 0;
        account.gmail_inbox_list_done = false;
        account.gmail_background_list_done = false;
        account.gmail_next_ref = 0;
        account.gmail_in_flight = 0;
        account.gmail_retry_counts = [_]u8{0} ** mail.max_gmail_refs;
        account.gmail_threads_done = false;
        account.gmail_draft_ref_count = 0;
        account.gmail_draft_next_ref = 0;
        account.gmail_draft_in_flight = 0;
        account.gmail_draft_retry_counts = [_]u8{0} ** 16;
        account.gmail_drafts_done = false;
        account.outlook_pending = 0;
        account.error_message = .{};
        var url_buffer: [512]u8 = undefined;
        if (account.provider == .microsoft) {
            account.outlook_pending = outlook_folders.len;
            for (outlook_folders, 0..) |folder, folder_index| {
                const url = std.fmt.bufPrint(&url_buffer, "{s}/v1.0/me/mailFolders/{s}/messages?%24top=50&%24orderby=receivedDateTime%20desc", .{ account.baseUrl(), outlookFolderPath(folder) }) catch {
                    account.sync_state = .failed;
                    account.outlook_pending = 0;
                    break;
                };
                const key = generation * generation_key_stride + initial_key_base + folder_index * mail.max_accounts + index;
                if (!fetchAuthorized(fx, key, .GET, url, account, "", on_response, on_authorized_response)) {
                    account.outlook_pending -= 1;
                    account.error_message.set("An Outlook folder request could not be started.");
                }
            }
            finishOutlookSync(model, account);
            continue;
        }
        // Populate the visible inbox first. The broader listing below is a
        // background backfill for starred/archive/trash views.
        if (std.fmt.bufPrint(&url_buffer, "{s}/gmail/v1/users/me/threads?maxResults=100&labelIds=INBOX", .{account.baseUrl()})) |url| {
            if (!fetchAuthorized(fx, generation * generation_key_stride + initial_key_base + index, .GET, url, account, "", on_response, on_authorized_response)) {
                account.error_message.set("The Gmail inbox request could not be started.");
                account.gmail_inbox_list_done = true;
            }
        } else |_| {
            account.error_message.set("Could not build the Gmail inbox URL.");
            account.gmail_inbox_list_done = true;
        }
        if (std.fmt.bufPrint(&url_buffer, "{s}/gmail/v1/users/me/threads?maxResults=128&includeSpamTrash=true", .{account.baseUrl()})) |url| {
            const background_key = generation * generation_key_stride + initial_key_base + gmail_background_list_folder_index * mail.max_accounts + index;
            if (!fetchAuthorized(fx, background_key, .GET, url, account, "", on_response, on_authorized_response)) {
                account.error_message.set("The Gmail background request could not be started.");
                account.gmail_background_list_done = true;
            }
        } else |_| {
            account.error_message.set("Could not build the Gmail background URL.");
            account.gmail_background_list_done = true;
        }
        if (account.gmail_inbox_list_done and account.gmail_background_list_done) account.gmail_threads_done = true;
        const drafts_url = std.fmt.bufPrint(&url_buffer, "{s}/gmail/v1/users/me/drafts?maxResults=50", .{account.baseUrl()}) catch {
            account.error_message.set("Could not build the Gmail drafts URL.");
            account.gmail_drafts_done = true;
            finishGmailSync(model, account);
            continue;
        };
        const draft_key = generation * generation_key_stride + initial_key_base + gmail_draft_list_folder_index * mail.max_accounts + index;
        if (!fetchAuthorized(fx, draft_key, .GET, drafts_url, account, "", on_response, on_authorized_response)) {
            account.error_message.set("The Gmail draft list request could not be started.");
            account.gmail_drafts_done = true;
        }
        finishGmailSync(model, account);
    }
    updateSyncStatus(model);
}

fn cancelPreviousSync(model: *const mail.Model, fx: anytype) void {
    if (model.sync_generation == 0) return;
    const generation = model.sync_generation;
    for (model.accounts[0..model.account_count], 0..) |account, account_index| {
        for (0..gmail_draft_list_folder_index + 1) |folder_index| {
            fx.cancel(generation * generation_key_stride + initial_key_base + folder_index * mail.max_accounts + account_index);
        }
        for (0..account.gmail_next_ref) |ref_index| {
            fx.cancel(generation * generation_key_stride + gmail_detail_key_base + @as(u64, @intCast(account_index)) * gmail_detail_account_stride + ref_index);
        }
        for (0..account.gmail_draft_next_ref) |ref_index| {
            fx.cancel(generation * generation_key_stride + gmail_draft_detail_key_base + @as(u64, @intCast(account_index)) * gmail_draft_detail_account_stride + ref_index);
        }
    }
}

pub fn handleInitialResponse(model: *mail.Model, response: native_sdk.EffectResponse, fx: anytype, detail_response: anytype, authorized_detail_response: anytype) void {
    const generation = response.key / generation_key_stride;
    if (generation != model.sync_generation) return;
    const local_key = response.key % generation_key_stride;
    if (local_key < initial_key_base or local_key >= gmail_detail_key_base) return;
    const encoded = local_key - initial_key_base;
    const folder_index: usize = @intCast(encoded / mail.max_accounts);
    const account_index: usize = @intCast(encoded % mail.max_accounts);
    if (account_index >= model.account_count) return;
    const account = &model.accounts[account_index];
    if (!responseOk(response)) {
        if (account.provider == .microsoft and account.outlook_pending > 0) {
            account.outlook_pending -= 1;
            account.error_message.set("One or more Outlook folders could not be loaded.");
            finishOutlookSync(model, account);
        } else if (account.provider == .gmail) {
            account.error_message.set("One or more Gmail collections could not be loaded.");
            if (folder_index == gmail_draft_list_folder_index) {
                account.gmail_drafts_done = true;
            } else if (folder_index == gmail_background_list_folder_index) {
                account.gmail_background_list_done = true;
            } else {
                account.gmail_inbox_list_done = true;
            }
            scheduleNextGmailDetail(model, account_index, fx, detail_response, authorized_detail_response);
            finishGmailSync(model, account);
        } else {
            failAccount(account, "Initial provider sync failed.");
        }
        updateSyncStatus(model);
        return;
    }
    switch (account.provider) {
        .gmail => {
            if (folder_index == gmail_draft_list_folder_index) {
                parseGmailDraftList(account, response.body) catch {
                    account.error_message.set("Gmail returned an unreadable draft list.");
                    account.gmail_drafts_done = true;
                    finishGmailSync(model, account);
                    updateSyncStatus(model);
                    return;
                };
                scheduleNextGmailDraftDetail(model, account_index, fx, detail_response, authorized_detail_response);
            } else if (folder_index == gmail_background_list_folder_index) {
                parseGmailBackgroundList(account, response.body) catch {
                    account.error_message.set("Gmail returned an unreadable background thread list.");
                    account.gmail_background_list_done = true;
                    scheduleNextGmailDetail(model, account_index, fx, detail_response, authorized_detail_response);
                    finishGmailSync(model, account);
                    updateSyncStatus(model);
                    return;
                };
                scheduleNextGmailDetail(model, account_index, fx, detail_response, authorized_detail_response);
            } else {
                parseGmailInboxList(account, response.body) catch {
                    account.error_message.set("Gmail returned an unreadable inbox thread list.");
                    account.gmail_inbox_list_done = true;
                    appendBackgroundGmailRefs(account);
                    scheduleNextGmailDetail(model, account_index, fx, detail_response, authorized_detail_response);
                    finishGmailSync(model, account);
                    updateSyncStatus(model);
                    return;
                };
                scheduleNextGmailDetail(model, account_index, fx, detail_response, authorized_detail_response);
            }
        },
        .microsoft => {
            if (folder_index >= outlook_folders.len) return;
            const folder = outlook_folders[folder_index];
            const parsed_ok = if (folder == .drafts)
                parseOutlookDrafts(model, account_index, response.body)
            else
                parseOutlookMessages(model, account_index, folder, response.body);
            parsed_ok catch {
                if (account.outlook_pending > 0) account.outlook_pending -= 1;
                account.error_message.set("One or more Outlook folders were unreadable.");
                finishOutlookSync(model, account);
                updateSyncStatus(model);
                return;
            };
            if (account.outlook_pending > 0) account.outlook_pending -= 1;
            finishOutlookSync(model, account);
            model.reconcileSelection();
            updateSyncStatus(model);
        },
    }
}

pub fn handleGmailDetailResponse(model: *mail.Model, response: native_sdk.EffectResponse, fx: anytype, detail_response: anytype, authorized_detail_response: anytype) void {
    const generation = response.key / generation_key_stride;
    if (generation != model.sync_generation) return;
    const local_key = response.key % generation_key_stride;
    if (local_key < gmail_detail_key_base) return;
    const is_draft = local_key >= gmail_draft_detail_key_base;
    const encoded = local_key - if (is_draft) gmail_draft_detail_key_base else gmail_detail_key_base;
    const account_stride = if (is_draft) gmail_draft_detail_account_stride else gmail_detail_account_stride;
    const account_index: usize = @intCast(encoded / account_stride);
    if (account_index >= model.account_count) return;
    const ref_index: usize = @intCast(encoded % account_stride);
    const account = &model.accounts[account_index];
    if (ref_index >= (if (is_draft) account.gmail_draft_ref_count else account.gmail_ref_count)) return;
    if (is_draft) {
        account.gmail_draft_in_flight -|= gmailBatchCount(account, ref_index, true);
    } else {
        account.gmail_in_flight -|= gmailBatchCount(account, ref_index, false);
    }
    if (!responseOk(response)) {
        if (retryGmailDetail(model, account_index, ref_index, is_draft, fx, detail_response, authorized_detail_response)) {
            if (is_draft)
                scheduleNextGmailDraftDetail(model, account_index, fx, detail_response, authorized_detail_response)
            else
                scheduleNextGmailDetail(model, account_index, fx, detail_response, authorized_detail_response);
            updateSyncStatus(model);
            return;
        }
        setGmailRequestFailure(account, is_draft, response);
        if (is_draft)
            scheduleNextGmailDraftDetail(model, account_index, fx, detail_response, authorized_detail_response)
        else
            scheduleNextGmailDetail(model, account_index, fx, detail_response, authorized_detail_response);
        updateSyncStatus(model);
        return;
    }
    if (is_draft) {
        parseGmailBatchResponse(model, account_index, response.body, gmailBatchCount(account, ref_index, true), true) catch {
            if (retryGmailDetail(model, account_index, ref_index, true, fx, detail_response, authorized_detail_response)) {
                scheduleNextGmailDraftDetail(model, account_index, fx, detail_response, authorized_detail_response);
                updateSyncStatus(model);
                return;
            }
            account.error_message.set("One or more Gmail drafts were unreadable after retrying.");
            scheduleNextGmailDraftDetail(model, account_index, fx, detail_response, authorized_detail_response);
            updateSyncStatus(model);
            return;
        };
        scheduleNextGmailDraftDetail(model, account_index, fx, detail_response, authorized_detail_response);
    } else {
        parseGmailBatchResponse(model, account_index, response.body, gmailBatchCount(account, ref_index, false), false) catch {
            if (retryGmailDetail(model, account_index, ref_index, false, fx, detail_response, authorized_detail_response)) {
                scheduleNextGmailDetail(model, account_index, fx, detail_response, authorized_detail_response);
                updateSyncStatus(model);
                return;
            }
            account.error_message.set("One or more Gmail threads were unreadable after retrying.");
            scheduleNextGmailDetail(model, account_index, fx, detail_response, authorized_detail_response);
            updateSyncStatus(model);
            return;
        };
        scheduleNextGmailDetail(model, account_index, fx, detail_response, authorized_detail_response);
    }
    model.reconcileSelection();
    updateSyncStatus(model);
}

pub fn fetchGmailBody(model: *mail.Model, thread_index: usize, fx: anytype, on_response: anytype, on_authorized_response: anytype) bool {
    if (thread_index >= model.thread_count) return false;
    const thread = &model.threads[thread_index];
    if (thread.provider != .gmail or thread.body_loaded or thread.body_loading) return false;
    if (thread.account_index >= model.account_count or thread.provider_message_id.isEmpty()) return false;
    const account = &model.accounts[thread.account_index];
    var url_buffer: [768]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buffer, "{s}/gmail/v1/users/me/messages/{s}?format=full", .{ account.baseUrl(), thread.providerMessageID() }) catch {
        thread.body_load_failed = true;
        return false;
    };
    const key = model.sync_generation * generation_key_stride + gmail_body_key_base + thread_index;
    if (!fetchAuthorized(fx, key, .GET, url, account, "", on_response, on_authorized_response)) {
        thread.body_load_failed = true;
        return false;
    }
    thread.body_loading = true;
    thread.body_load_failed = false;
    return true;
}

pub fn handleGmailBodyResponse(model: *mail.Model, response: native_sdk.EffectResponse) void {
    const generation = response.key / generation_key_stride;
    if (generation != model.sync_generation) return;
    const local_key = response.key % generation_key_stride;
    if (local_key < gmail_body_key_base or local_key >= gmail_body_key_base + mail.max_threads) return;
    const thread_index: usize = @intCast(local_key - gmail_body_key_base);
    if (thread_index >= model.thread_count) return;
    const thread = &model.threads[thread_index];
    thread.body_loading = false;
    if (!responseOk(response)) {
        thread.body_load_failed = true;
        return;
    }
    const parsed = std.json.parseFromSlice(GmailMessage, std.heap.page_allocator, response.body, .{ .ignore_unknown_fields = true }) catch {
        thread.body_load_failed = true;
        return;
    };
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.id, thread.providerMessageID())) {
        thread.body_load_failed = true;
        return;
    }
    setGmailBody(&thread.body, &parsed.value.payload, thread.snippetSlice());
    thread.has_attachments = gmailPayloadHasAttachment(&parsed.value.payload);
    thread.body_loaded = true;
    thread.body_load_failed = false;
}

pub fn fetchMutation(fx: anytype, key: u64, provider: mail.ProviderKind, operation: MutationOperation, account: *const mail.Account, thread: *const mail.MailThread, on_response: anytype, on_authorized_response: anytype) bool {
    var url_buffer: [512]u8 = undefined;
    var body_buffer: [512]u8 = undefined;
    const request = switch (provider) {
        .gmail => gmailMutationRequest(operation, account, thread, &url_buffer, &body_buffer),
        .microsoft => outlookMutationRequest(operation, account, thread, &url_buffer, &body_buffer),
    } catch return false;
    return fetchAuthorized(fx, key, request.method, request.url, account, request.body, on_response, on_authorized_response);
}

pub fn handleMutationResponse(model: *mail.Model, response: native_sdk.EffectResponse) void {
    const success = responseOk(response);
    if (success) {
        for (&model.pending_mutations) |*pending| {
            if (!pending.active or pending.key != response.key) continue;
            const thread_index = model.threadIndexById(pending.thread_id) orelse continue;
            const thread = &model.threads[thread_index];
            if (thread.provider == .microsoft and response.body.len > 0) {
                const parsed = std.json.parseFromSlice(OutlookMutationReceipt, std.heap.page_allocator, response.body, .{ .ignore_unknown_fields = true }) catch break;
                defer parsed.deinit();
                if (parsed.value.id) |id| thread.provider_message_id.set(id);
            }
            break;
        }
    }
    model.finishMutation(response.key, success);
}

pub const MutationOperation = enum { archive, trash, toggle_read, toggle_star };

const MutationRequest = struct {
    method: std.http.Method,
    url: []const u8,
    body: []const u8,
};

fn gmailMutationRequest(operation: MutationOperation, account: *const mail.Account, thread: *const mail.MailThread, url_buffer: []u8, body_buffer: []u8) !MutationRequest {
    const action = if (operation == .trash) "trash" else "modify";
    const url = try std.fmt.bufPrint(url_buffer, "{s}/gmail/v1/users/me/threads/{s}/{s}", .{ account.baseUrl(), thread.providerThreadID(), action });
    const body = switch (operation) {
        .archive => try std.fmt.bufPrint(body_buffer, "{{\"addLabelIds\":[],\"removeLabelIds\":[\"INBOX\"]}}", .{}),
        .trash => try std.fmt.bufPrint(body_buffer, "{{}}", .{}),
        .toggle_read => if (thread.unread)
            try std.fmt.bufPrint(body_buffer, "{{\"addLabelIds\":[],\"removeLabelIds\":[\"UNREAD\"]}}", .{})
        else
            try std.fmt.bufPrint(body_buffer, "{{\"addLabelIds\":[\"UNREAD\"],\"removeLabelIds\":[]}}", .{}),
        .toggle_star => if (thread.starred)
            try std.fmt.bufPrint(body_buffer, "{{\"addLabelIds\":[],\"removeLabelIds\":[\"STARRED\"]}}", .{})
        else
            try std.fmt.bufPrint(body_buffer, "{{\"addLabelIds\":[\"STARRED\"],\"removeLabelIds\":[]}}", .{}),
    };
    return .{ .method = .POST, .url = url, .body = body };
}

fn outlookMutationRequest(operation: MutationOperation, account: *const mail.Account, thread: *const mail.MailThread, url_buffer: []u8, body_buffer: []u8) !MutationRequest {
    switch (operation) {
        .archive, .trash => {
            const url = try std.fmt.bufPrint(url_buffer, "{s}/v1.0/me/messages/{s}/move", .{ account.baseUrl(), thread.providerMessageID() });
            const destination = if (operation == .archive) "archive" else "deleteditems";
            const body = try std.fmt.bufPrint(body_buffer, "{{\"destinationId\":\"{s}\"}}", .{destination});
            return .{ .method = .POST, .url = url, .body = body };
        },
        .toggle_read => {
            const url = try std.fmt.bufPrint(url_buffer, "{s}/v1.0/me/messages/{s}", .{ account.baseUrl(), thread.providerMessageID() });
            const body = try std.fmt.bufPrint(body_buffer, "{{\"isRead\":{s}}}", .{if (thread.unread) "true" else "false"});
            return .{ .method = .PATCH, .url = url, .body = body };
        },
        .toggle_star => {
            const url = try std.fmt.bufPrint(url_buffer, "{s}/v1.0/me/messages/{s}", .{ account.baseUrl(), thread.providerMessageID() });
            const state = if (thread.starred) "notFlagged" else "flagged";
            const body = try std.fmt.bufPrint(body_buffer, "{{\"flag\":{{\"flagStatus\":\"{s}\"}}}}", .{state});
            return .{ .method = .PATCH, .url = url, .body = body };
        },
    }
}

fn fetchAuthorized(fx: anytype, key: u64, method: std.http.Method, url: []const u8, account: *const mail.Account, body: []const u8, on_response: anytype, on_authorized_response: anytype) bool {
    return fetchAuthorizedTyped(fx, key, method, url, account, body, if (body.len > 0) "application/json" else null, on_response, on_authorized_response);
}

fn fetchAuthorizedTyped(fx: anytype, key: u64, method: std.http.Method, url: []const u8, account: *const mail.Account, body: []const u8, content_type: ?[]const u8, on_response: anytype, on_authorized_response: anytype) bool {
    return transport.fetchAuthorized(fx, key, .{
        .method = method,
        .url = url,
        .content_type = content_type,
        .body = if (body.len > 0) body else null,
    }, account.tokenSlice(), account.credential_key.slice(), on_response, on_authorized_response);
}

fn scheduleNextGmailDetail(model: *mail.Model, account_index: usize, fx: anytype, detail_response: anytype, authorized_detail_response: anytype) void {
    const account = &model.accounts[account_index];
    if (account.gmail_in_flight == 0 and account.gmail_next_ref < account.gmail_ref_count) {
        const ref_index = account.gmail_next_ref;
        account.gmail_next_ref += gmailBatchCount(account, ref_index, false);
        if (!scheduleGmailDetail(model, account_index, ref_index, false, fx, detail_response, authorized_detail_response)) {
            account.gmail_next_ref = ref_index;
            account.error_message.set("A Gmail metadata batch could not be started.");
        }
    }
    if (account.gmail_inbox_list_done and account.gmail_background_list_done and
        account.gmail_next_ref >= account.gmail_ref_count and account.gmail_in_flight == 0)
    {
        account.gmail_threads_done = true;
        finishGmailSync(model, account);
        updateSyncStatus(model);
    }
}

fn scheduleNextGmailDraftDetail(model: *mail.Model, account_index: usize, fx: anytype, detail_response: anytype, authorized_detail_response: anytype) void {
    const account = &model.accounts[account_index];
    if (account.gmail_draft_in_flight == 0 and account.gmail_draft_next_ref < account.gmail_draft_ref_count) {
        const ref_index = account.gmail_draft_next_ref;
        account.gmail_draft_next_ref += gmailBatchCount(account, ref_index, true);
        if (!scheduleGmailDetail(model, account_index, ref_index, true, fx, detail_response, authorized_detail_response)) {
            account.gmail_draft_next_ref = ref_index;
            account.error_message.set("A Gmail draft batch could not be started.");
        }
    }
    if (account.gmail_draft_next_ref >= account.gmail_draft_ref_count and account.gmail_draft_in_flight == 0) {
        account.gmail_drafts_done = true;
        finishGmailSync(model, account);
        updateSyncStatus(model);
    }
}

fn scheduleGmailDetail(model: *mail.Model, account_index: usize, ref_index: usize, is_draft: bool, fx: anytype, detail_response: anytype, authorized_detail_response: anytype) bool {
    return scheduleGmailBatch(model, account_index, ref_index, is_draft, fx, detail_response, authorized_detail_response);
}

fn gmailBatchCount(account: *const mail.Account, ref_index: usize, is_draft: bool) usize {
    const ref_count = if (is_draft) account.gmail_draft_ref_count else account.gmail_ref_count;
    if (ref_index >= ref_count) return 0;
    return @min(gmail_batch_size, ref_count - ref_index);
}

fn scheduleGmailBatch(model: *mail.Model, account_index: usize, ref_index: usize, is_draft: bool, fx: anytype, detail_response: anytype, authorized_detail_response: anytype) bool {
    const account = &model.accounts[account_index];
    const count = gmailBatchCount(account, ref_index, is_draft);
    if (count == 0) return false;
    var boundary_buffer: [96]u8 = undefined;
    const boundary = std.fmt.bufPrint(&boundary_buffer, "inbox_zero_{d}_{d}_{d}", .{ model.sync_generation, account_index, ref_index }) catch return false;
    var content_type_buffer: [160]u8 = undefined;
    const content_type = std.fmt.bufPrint(&content_type_buffer, "multipart/mixed; boundary={s}", .{boundary}) catch return false;
    var body_buffer: [60 * 1024]u8 = undefined;
    var body_len: usize = 0;
    const refs = if (is_draft)
        account.gmail_draft_refs[ref_index .. ref_index + count]
    else
        account.gmail_refs[ref_index .. ref_index + count];
    for (refs, 0..) |*reference, offset| {
        const part = if (is_draft)
            std.fmt.bufPrint(body_buffer[body_len..],
                "--{s}\r\nContent-Type: application/http\r\nContent-ID: <draft-{d}>\r\n\r\nGET /gmail/v1/users/me/drafts/{s}?format=full HTTP/1.1\r\n\r\n",
                .{ boundary, offset, reference.id.slice() },
            ) catch return false
        else
            std.fmt.bufPrint(body_buffer[body_len..],
                "--{s}\r\nContent-Type: application/http\r\nContent-ID: <thread-{d}>\r\n\r\nGET /gmail/v1/users/me/threads/{s}?{s} HTTP/1.1\r\n\r\n",
                .{ boundary, offset, reference.id.slice(), gmail_metadata_query },
            ) catch return false;
        body_len += part.len;
    }
    const closing = std.fmt.bufPrint(body_buffer[body_len..], "--{s}--\r\n", .{boundary}) catch return false;
    body_len += closing.len;
    var url_buffer: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buffer, "{s}/batch/gmail/v1", .{account.baseUrl()}) catch return false;
    const key = model.sync_generation * generation_key_stride + gmail_detail_key_base + @as(u64, @intCast(account_index)) * gmail_detail_account_stride + ref_index;
    if (!fetchAuthorizedTyped(fx, key, .POST, url, account, body_buffer[0..body_len], content_type, detail_response, authorized_detail_response)) return false;
    if (is_draft) account.gmail_draft_in_flight += count else account.gmail_in_flight += count;
    return true;
}

fn retryGmailDetail(model: *mail.Model, account_index: usize, ref_index: usize, is_draft: bool, fx: anytype, detail_response: anytype, authorized_detail_response: anytype) bool {
    const account = &model.accounts[account_index];
    const retry_count = if (is_draft) &account.gmail_draft_retry_counts[ref_index] else &account.gmail_retry_counts[ref_index];
    if (retry_count.* >= gmail_detail_max_retries) return false;
    retry_count.* += 1;
    if (scheduleGmailDetail(model, account_index, ref_index, is_draft, fx, detail_response, authorized_detail_response)) return true;
    retry_count.* = gmail_detail_max_retries;
    return false;
}

fn setGmailRequestFailure(account: *mail.Account, is_draft: bool, response: native_sdk.EffectResponse) void {
    var buffer: [160]u8 = undefined;
    const item = if (is_draft) "draft" else "thread";
    const message = if (response.outcome == .ok and response.status > 0)
        std.fmt.bufPrint(&buffer, "A Gmail {s} failed after {d} retries (HTTP {d}).", .{ item, gmail_detail_max_retries, response.status }) catch "A Gmail item could not be loaded after retrying."
    else
        std.fmt.bufPrint(&buffer, "A Gmail {s} failed after {d} retries ({s}).", .{ item, gmail_detail_max_retries, @tagName(response.outcome) }) catch "A Gmail item could not be loaded after retrying.";
    account.error_message.set(message);
}

fn parseGmailInboxList(account: *mail.Account, body: []const u8) !void {
    const parsed = try std.json.parseFromSlice(GmailThreadList, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    account.gmail_ref_count = 0;
    account.gmail_next_ref = 0;
    for (parsed.value.threads orelse &.{}) |reference| {
        appendGmailRef(account, reference.id);
    }
    account.gmail_inbox_list_done = true;
    appendBackgroundGmailRefs(account);
}

fn parseGmailBackgroundList(account: *mail.Account, body: []const u8) !void {
    const parsed = try std.json.parseFromSlice(GmailThreadList, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    account.gmail_background_ref_count = 0;
    for (parsed.value.threads orelse &.{}) |reference| {
        if (account.gmail_background_ref_count >= account.gmail_background_refs.len) break;
        account.gmail_background_refs[account.gmail_background_ref_count].id.set(reference.id);
        account.gmail_background_ref_count += 1;
    }
    account.gmail_background_list_done = true;
    appendBackgroundGmailRefs(account);
}

fn appendBackgroundGmailRefs(account: *mail.Account) void {
    if (!account.gmail_inbox_list_done or !account.gmail_background_list_done) return;
    for (account.gmail_background_refs[0..account.gmail_background_ref_count]) |*reference| {
        appendGmailRef(account, reference.id.slice());
    }
}

fn appendGmailRef(account: *mail.Account, id: []const u8) void {
    for (account.gmail_refs[0..account.gmail_ref_count]) |*existing| {
        if (std.mem.eql(u8, existing.id.slice(), id)) return;
    }
    if (account.gmail_ref_count >= account.gmail_refs.len) return;
    account.gmail_refs[account.gmail_ref_count].id.set(id);
    account.gmail_ref_count += 1;
}

fn parseGmailBatchResponse(model: *mail.Model, account_index: usize, body: []const u8, expected_count: usize, is_draft: bool) !void {
    if (expected_count == 0 or body.len == 0) return error.InvalidBatchResponse;
    const line_end = std.mem.indexOf(u8, body, "\r\n") orelse std.mem.indexOfScalar(u8, body, '\n') orelse return error.InvalidBatchResponse;
    const delimiter = body[0..line_end];
    if (!std.mem.startsWith(u8, delimiter, "--")) return error.InvalidBatchResponse;
    var cursor = line_end;
    for (0..expected_count) |_| {
        const http_start = std.mem.indexOfPos(u8, body, cursor, "HTTP/1.1 ") orelse return error.InvalidBatchResponse;
        if (http_start + 12 > body.len) return error.InvalidBatchResponse;
        const status = std.fmt.parseInt(u16, body[http_start + 9 .. http_start + 12], 10) catch return error.InvalidBatchResponse;
        const crlf_headers_end = std.mem.indexOfPos(u8, body, http_start, "\r\n\r\n");
        const lf_headers_end = std.mem.indexOfPos(u8, body, http_start, "\n\n");
        const json_start = if (crlf_headers_end) |position|
            position + 4
        else if (lf_headers_end) |position|
            position + 2
        else
            return error.InvalidBatchResponse;
        const next_boundary = std.mem.indexOfPos(u8, body, json_start, delimiter) orelse return error.InvalidBatchResponse;
        if (status < 200 or status >= 300) return error.BatchPartFailed;
        const json = std.mem.trim(u8, body[json_start..next_boundary], " \t\r\n");
        if (is_draft)
            try parseGmailDraft(model, account_index, json)
        else
            try parseGmailThread(model, account_index, json);
        cursor = next_boundary + delimiter.len;
    }
}

fn parseGmailDraftList(account: *mail.Account, body: []const u8) !void {
    const parsed = try std.json.parseFromSlice(GmailDraftList, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    account.gmail_draft_ref_count = 0;
    account.gmail_draft_next_ref = 0;
    for (parsed.value.drafts orelse &.{}) |reference| {
        if (account.gmail_draft_ref_count >= account.gmail_draft_refs.len) break;
        account.gmail_draft_refs[account.gmail_draft_ref_count].id.set(reference.id);
        account.gmail_draft_ref_count += 1;
    }
}

pub fn parseGmailDraft(model: *mail.Model, account_index: usize, body: []const u8) !void {
    const parsed = try std.json.parseFromSlice(GmailDraft, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const message = &parsed.value.message;
    var draft = mail.Draft{
        .account_index = account_index,
        .account_id = model.accounts[account_index].id,
        .provider = .gmail,
        // Gmail assigns a threadId to ordinary new drafts too, so it cannot be
        // used to infer reply intent after a fresh sync.
        .mode = .new,
        .remote = true,
    };
    draft.provider_draft_id.set(parsed.value.id);
    draft.provider_message_id.set(message.id);
    draft.source_thread_id.set(message.threadId);
    draft.source_rfc_message_id.set(headerValue(&message.payload, "In-Reply-To") orelse "");
    draft.source_references.set(headerValue(&message.payload, "References") orelse "");
    if (!draft.source_rfc_message_id.isEmpty()) draft.mode = .reply;
    draft.to.set(headerValue(&message.payload, "To") orelse "");
    draft.cc.set(headerValue(&message.payload, "Cc") orelse "");
    draft.bcc.set(headerValue(&message.payload, "Bcc") orelse "");
    draft.subject.set(headerValue(&message.payload, "Subject") orelse "(No subject)");
    draft.updated_at.set(message.internalDate orelse "");
    setGmailBody(&draft.body, &message.payload, message.snippet orelse "");
    draft.provider_content_read_only = gmailPayloadHasRichContent(&message.payload);
    _ = model.addDraft(draft);
}

pub fn parseGmailThread(model: *mail.Model, account_index: usize, body: []const u8) !void {
    const parsed = try std.json.parseFromSlice(GmailThread, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.messages.len == 0) return;
    const message = &parsed.value.messages[parsed.value.messages.len - 1];
    try addGmailMessage(model, account_index, message, parsed.value.id, parsed.value.snippet orelse "");
}

pub fn parseGmailMessage(model: *mail.Model, account_index: usize, body: []const u8) !void {
    const parsed = try std.json.parseFromSlice(GmailMessage, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try addGmailMessage(model, account_index, &parsed.value, parsed.value.threadId, "");
}

fn addGmailMessage(model: *mail.Model, account_index: usize, message: *const GmailMessage, provider_thread_id: []const u8, fallback_snippet: []const u8) !void {
    if (account_index >= model.account_count) return error.AccountNotFound;
    var thread = mail.MailThread{ .account_index = account_index, .provider = .gmail };
    thread.provider_thread_id.set(provider_thread_id);
    thread.provider_message_id.set(message.id);
    thread.rfc_message_id.set(headerValue(&message.payload, "Message-ID") orelse headerValue(&message.payload, "Message-Id") orelse "");
    thread.references.set(headerValue(&message.payload, "References") orelse "");
    thread.snippet.set(message.snippet orelse fallback_snippet);
    thread.received_at.set(message.internalDate orelse "");
    thread.received_at_ms = parseGmailTimestamp(message.internalDate orelse "");
    thread.category.set(gmailCategory(message.labelIds));
    thread.has_attachments = gmailPayloadHasAttachment(&message.payload);
    thread.subject.set(headerValue(&message.payload, "Subject") orelse "(No subject)");
    thread.sender.set(headerValue(&message.payload, "From") orelse model.accounts[account_index].emailSlice());
    thread.sender_email.set(mail.extractAddress(thread.senderSlice()));
    thread.reply_to.set(headerValue(&message.payload, "Reply-To") orelse "");
    thread.to_recipients.set(headerValue(&message.payload, "To") orelse "");
    thread.cc_recipients.set(headerValue(&message.payload, "Cc") orelse "");
    thread.unread = hasLabel(message.labelIds, "UNREAD");
    thread.starred = hasLabel(message.labelIds, "STARRED");
    thread.in_inbox = hasLabel(message.labelIds, "INBOX");
    thread.trashed = hasLabel(message.labelIds, "TRASH");
    thread.archived = !thread.in_inbox and !thread.trashed and
        !hasLabel(message.labelIds, "SENT") and !hasLabel(message.labelIds, "DRAFT") and !hasLabel(message.labelIds, "SPAM");
    setGmailBody(&thread.body, &message.payload, "");
    thread.body_loaded = !thread.body.isEmpty();
    _ = model.addThread(thread);
}

pub fn parseOutlookMessages(model: *mail.Model, account_index: usize, folder: OutlookFolder, body: []const u8) !void {
    const parsed = try std.json.parseFromSlice(OutlookMessageList, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    for (parsed.value.value) |message| {
        var thread = mail.MailThread{ .account_index = account_index, .provider = .microsoft };
        // Treat Graph messages as independent rows. A conversation can span
        // inbox, sent, archive, and trash, so collapsing by conversationId
        // would lose folder/read state and make later mutations ambiguous.
        thread.provider_thread_id.set(message.id);
        thread.provider_message_id.set(message.id);
        thread.subject.set(message.subject orelse "(No subject)");
        if (message.from) |sender| {
            thread.sender.set(sender.emailAddress.name orelse sender.emailAddress.address);
            thread.sender_email.set(sender.emailAddress.address);
        } else {
            thread.sender.set(model.accounts[account_index].emailSlice());
            thread.sender_email.set(model.accounts[account_index].emailSlice());
        }
        if (message.replyTo) |recipients| {
            if (recipients.len > 0) thread.reply_to.set(recipients[0].emailAddress.address);
        }
        setOutlookRecipients(&thread.to_recipients, message.toRecipients orelse &.{});
        setOutlookRecipients(&thread.cc_recipients, message.ccRecipients orelse &.{});
        thread.snippet.set(message.bodyPreview orelse "");
        thread.received_at.set(message.receivedDateTime orelse "");
        thread.received_at_ms = parseIso8601Timestamp(message.receivedDateTime orelse "");
        thread.has_attachments = message.hasAttachments orelse false;
        if (message.categories) |categories| {
            if (categories.len > 0) thread.category.set(categories[0]);
        }
        thread.unread = !(message.isRead orelse false);
        thread.starred = if (message.flag) |flag| std.mem.eql(u8, flag.flagStatus orelse "", "flagged") else false;
        thread.in_inbox = folder == .inbox;
        thread.trashed = folder == .trash;
        thread.archived = folder == .archive;
        if (message.body) |message_body| {
            if (std.ascii.eqlIgnoreCase(message_body.contentType, "html")) {
                var plain_buffer: [8192]u8 = undefined;
                const plain = stripHtml(message_body.content, &plain_buffer);
                thread.body.set(plain);
            } else {
                thread.body.set(message_body.content);
            }
        }
        if (thread.body.isEmpty()) thread.body.set(thread.snippetSlice());
        thread.body_loaded = true;
        _ = model.addThread(thread);
    }
}

fn gmailCategory(labels: ?[]const []const u8) []const u8 {
    const values = labels orelse return "";
    for (values) |label| {
        if (std.mem.eql(u8, label, "Label_customers")) return "Customers";
        if (std.mem.eql(u8, label, "Label_ops")) return "Ops/Review";
        if (std.mem.eql(u8, label, "Label_marketing")) return "Marketing";
        if (std.mem.eql(u8, label, "Label_newsletters")) return "Newsletter";
        if (std.mem.eql(u8, label, "Label_receipts")) return "Receipts";
        if (std.mem.eql(u8, label, "Label_travel")) return "Travel";
    }
    return "";
}

fn gmailPayloadHasAttachment(payload: *const GmailPayload) bool {
    if (payload.filename) |filename| {
        if (filename.len > 0) return true;
    }
    if (payload.parts) |parts| {
        for (parts) |*part| if (gmailPayloadHasAttachment(part)) return true;
    }
    return false;
}

fn parseGmailTimestamp(value: []const u8) i64 {
    return std.fmt.parseInt(i64, value, 10) catch 0;
}

fn parseIso8601Timestamp(value: []const u8) i64 {
    if (value.len < 19 or value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':') return 0;
    const year = std.fmt.parseInt(i64, value[0..4], 10) catch return 0;
    const month = std.fmt.parseInt(i64, value[5..7], 10) catch return 0;
    const day = std.fmt.parseInt(i64, value[8..10], 10) catch return 0;
    const hour = std.fmt.parseInt(i64, value[11..13], 10) catch return 0;
    const minute = std.fmt.parseInt(i64, value[14..16], 10) catch return 0;
    const second = std.fmt.parseInt(i64, value[17..19], 10) catch return 0;
    const days = daysFromCivil(year, month, day);
    var milliseconds = (days * 86_400 + hour * 3_600 + minute * 60 + second) * 1_000;
    if (value.len > 20 and value[19] == '.') {
        var fraction: i64 = 0;
        var digits: usize = 0;
        var index: usize = 20;
        while (index < value.len and digits < 3 and std.ascii.isDigit(value[index])) : (index += 1) {
            fraction = fraction * 10 + (value[index] - '0');
            digits += 1;
        }
        while (digits < 3) : (digits += 1) fraction *= 10;
        milliseconds += fraction;
    }
    return milliseconds;
}

fn daysFromCivil(year_value: i64, month_value: i64, day: i64) i64 {
    var year = year_value;
    if (month_value <= 2) year -= 1;
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const adjusted_month = month_value + (if (month_value > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * adjusted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146_097 + day_of_era - 719_468;
}

pub fn parseOutlookDrafts(model: *mail.Model, account_index: usize, body: []const u8) !void {
    const parsed = try std.json.parseFromSlice(OutlookMessageList, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    for (parsed.value.value) |message| {
        var draft = mail.Draft{
            .account_index = account_index,
            .account_id = model.accounts[account_index].id,
            .provider = .microsoft,
            .remote = true,
        };
        draft.provider_draft_id.set(message.id);
        draft.provider_message_id.set(message.id);
        draft.source_thread_id.set(message.conversationId);
        draft.subject.set(message.subject orelse "(No subject)");
        setOutlookRecipients(&draft.to, message.toRecipients orelse &.{});
        setOutlookRecipients(&draft.cc, message.ccRecipients orelse &.{});
        setOutlookRecipients(&draft.bcc, message.bccRecipients orelse &.{});
        draft.updated_at.set(message.receivedDateTime orelse "");
        if (message.body) |message_body| {
            if (std.ascii.eqlIgnoreCase(message_body.contentType, "html")) {
                var plain_buffer: [16 * 1024]u8 = undefined;
                draft.body.set(stripHtml(message_body.content, &plain_buffer));
            } else {
                draft.body.set(message_body.content);
            }
        }
        draft.provider_content_read_only = (message.hasAttachments orelse false) or
            (if (message.body) |message_body| std.ascii.eqlIgnoreCase(message_body.contentType, "html") else false);
        if (draft.body.isEmpty()) draft.body.set(message.bodyPreview orelse "");
        _ = model.addDraft(draft);
    }
}

fn responseOk(response: native_sdk.EffectResponse) bool {
    return response.outcome == .ok and response.status >= 200 and response.status < 300 and !response.truncated;
}

fn failAccount(account: *mail.Account, message: []const u8) void {
    account.sync_state = .failed;
    account.gmail_in_flight = 0;
    account.gmail_draft_in_flight = 0;
    account.error_message.set(message);
}

fn finishOutlookSync(model: *mail.Model, account: *mail.Account) void {
    if (account.outlook_pending != 0) return;
    if (account.sync_state == .failed) return;
    account.sync_state = if (account.error_message.isEmpty()) .ready else .partial;
    updateSyncStatus(model);
}

fn finishGmailSync(model: *mail.Model, account: *mail.Account) void {
    if (!account.gmail_threads_done or !account.gmail_drafts_done) return;
    if (account.sync_state == .failed) return;
    account.sync_state = if (account.error_message.isEmpty()) .ready else .partial;
    updateSyncStatus(model);
}

pub fn timeoutSync(model: *mail.Model) void {
    if (!model.syncInFlight()) return;
    model.sync_generation +%= 1;
    if (model.sync_generation == 0) model.sync_generation = 1;
    for (model.accounts[0..model.account_count]) |*account| {
        if (account.sync_state != .loading) continue;
        account.gmail_in_flight = 0;
        account.gmail_draft_in_flight = 0;
        account.gmail_threads_done = true;
        account.gmail_drafts_done = true;
        account.outlook_pending = 0;
        account.error_message.set("Synchronization timed out. Refresh to try again.");
        account.sync_state = .partial;
    }
    model.status_message.set("Mail synchronization timed out. Refresh to try again.");
}

fn outlookFolderPath(folder: OutlookFolder) []const u8 {
    return switch (folder) {
        .inbox => "inbox",
        .archive => "archive",
        .trash => "deleteditems",
        .drafts => "drafts",
    };
}

fn updateSyncStatus(model: *mail.Model) void {
    var loading = false;
    var failed = false;
    var partial = false;
    for (model.accounts[0..model.account_count]) |account| switch (account.sync_state) {
        .idle, .loading => loading = true,
        .failed => failed = true,
        .partial => partial = true,
        .ready => {},
    };
    if (loading) {
        model.status_message.set("Synchronizing Gmail and Outlook.");
    } else if (failed) {
        model.pruneStaleThreads();
        model.status_message.set("Some accounts could not synchronize.");
    } else if (partial) {
        model.pruneStaleThreads();
        model.status_message.set("Connected with partial mail results.");
    } else {
        model.pruneStaleThreads();
        model.status_message.set("Gmail and Outlook are connected.");
    }
}

fn hasLabel(labels: ?[]const []const u8, wanted: []const u8) bool {
    for (labels orelse &.{}) |label| {
        if (std.mem.eql(u8, label, wanted)) return true;
    }
    return false;
}

fn headerValue(payload: *const GmailPayload, wanted: []const u8) ?[]const u8 {
    for (payload.headers orelse &.{}) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, wanted)) return header.value;
    }
    return null;
}

fn findPlainBody(payload: *const GmailPayload) ?[]const u8 {
    if (payload.mimeType) |mime_type| {
        if (std.ascii.eqlIgnoreCase(mime_type, "text/plain")) {
            if (payload.body) |body| if (body.data) |data| return data;
        }
    }
    for (payload.parts orelse &.{}) |*part| {
        if (findPlainBody(part)) |data| return data;
    }
    return null;
}

fn findHtmlBody(payload: *const GmailPayload) ?[]const u8 {
    if (payload.mimeType) |mime_type| {
        if (std.ascii.eqlIgnoreCase(mime_type, "text/html")) {
            if (payload.body) |body| if (body.data) |data| return data;
        }
    }
    for (payload.parts orelse &.{}) |*part| {
        if (findHtmlBody(part)) |data| return data;
    }
    return null;
}

fn gmailPayloadHasRichContent(payload: *const GmailPayload) bool {
    if (payload.filename) |filename| if (filename.len != 0) return true;
    if (payload.mimeType) |mime_type| if (std.ascii.eqlIgnoreCase(mime_type, "text/html")) return true;
    for (payload.parts orelse &.{}) |*part| if (gmailPayloadHasRichContent(part)) return true;
    return false;
}

fn setGmailBody(output: anytype, payload: *const GmailPayload, fallback: []const u8) void {
    if (findPlainBody(payload)) |encoded| {
        var decoded: [16 * 1024]u8 = undefined;
        const size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded) catch 0;
        if (size > 0 and size <= decoded.len) {
            if (std.base64.url_safe_no_pad.Decoder.decode(decoded[0..size], encoded)) |_| {
                output.set(decoded[0..size]);
            } else |_| {}
        }
    }
    if (output.isEmpty()) {
        if (findHtmlBody(payload)) |encoded| {
            var decoded: [16 * 1024]u8 = undefined;
            const size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded) catch 0;
            if (size > 0 and size <= decoded.len) {
                if (std.base64.url_safe_no_pad.Decoder.decode(decoded[0..size], encoded)) |_| {
                    var plain: [16 * 1024]u8 = undefined;
                    output.set(stripHtml(decoded[0..size], &plain));
                } else |_| {}
            }
        }
    }
    if (output.isEmpty()) output.set(fallback);
}

fn stripHtml(source: []const u8, output: []u8) []const u8 {
    var out: usize = 0;
    var in_tag = false;
    var previous_space = false;
    for (source) |byte| {
        if (byte == '<') {
            in_tag = true;
            if (out > 0 and !previous_space and out < output.len) {
                output[out] = ' ';
                out += 1;
                previous_space = true;
            }
            continue;
        }
        if (byte == '>') {
            in_tag = false;
            continue;
        }
        if (in_tag or out >= output.len) continue;
        const normalized: u8 = if (std.ascii.isWhitespace(byte)) ' ' else byte;
        if (normalized == ' ' and previous_space) continue;
        output[out] = normalized;
        out += 1;
        previous_space = normalized == ' ';
    }
    return std.mem.trim(u8, output[0..out], " ");
}

fn setOutlookRecipients(output: anytype, recipients: []const OutlookRecipient) void {
    var buffer: [1024]u8 = undefined;
    var length: usize = 0;
    for (recipients) |recipient| {
        const address = recipient.emailAddress.address;
        const separator = if (length == 0) "" else ", ";
        if (length + separator.len + address.len > buffer.len) break;
        @memcpy(buffer[length .. length + separator.len], separator);
        length += separator.len;
        @memcpy(buffer[length .. length + address.len], address);
        length += address.len;
    }
    output.set(buffer[0..length]);
}

test "gmail parser maps headers labels and decoded body" {
    var model = mail.initialModel();
    const fixture =
        \\{"id":"thread-1","snippet":"hello","messages":[{"id":"message-1","threadId":"thread-1","labelIds":["INBOX","UNREAD","STARRED"],"snippet":"hello","payload":{"mimeType":"text/plain","headers":[{"name":"From","value":"Alex <alex@example.com>"},{"name":"Subject","value":"Release checklist"}],"body":{"data":"SGVsbG8gd29ybGQ"}}}]}
    ;
    try parseGmailThread(&model, 0, fixture);
    try std.testing.expectEqual(@as(usize, 1), model.thread_count);
    try std.testing.expectEqualStrings("Release checklist", model.threads[0].subjectSlice());
    try std.testing.expectEqualStrings("Hello world", model.threads[0].bodySlice());
    try std.testing.expect(model.threads[0].unread);
    try std.testing.expect(model.threads[0].starred);
    try std.testing.expect(model.threads[0].body_loaded);
}

test "gmail inbox sync requests metadata instead of full thread bodies" {
    var model = mail.emptyModel();
    model.addAccount(.gmail, "person@example.com", "Person", "token", "https://gmail.googleapis.com");
    var fx = @import("main.zig").Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    startInitialSync(&model, &fx, @import("main.zig").Effects.responseMsg(.initial_response), @import("main.zig").Effects.hostMsg(.authorized_initial_response));
    var response = native_sdk.EffectResponse{
        .key = model.sync_generation * generation_key_stride + initial_key_base,
        .outcome = .ok,
        .status = 200,
    };
    response.body = "{\"threads\":[{\"id\":\"thread-large\"}]}";
    handleInitialResponse(&model, response, &fx, @import("main.zig").Effects.responseMsg(.gmail_detail_response), @import("main.zig").Effects.hostMsg(.authorized_gmail_detail_response));

    var found = false;
    for (0..fx.pendingFetchCount()) |index| {
        const request = fx.pendingFetchAt(index) orelse continue;
        if (!std.mem.endsWith(u8, request.url, "/batch/gmail/v1")) continue;
        found = true;
        try std.testing.expectEqual(std.http.Method.POST, request.method);
        try std.testing.expect(std.mem.indexOf(u8, request.body, "/threads/thread-large?") != null);
        try std.testing.expect(std.mem.indexOf(u8, request.body, "format=metadata") != null);
        try std.testing.expect(std.mem.indexOf(u8, request.body, "format=full") == null);
        try std.testing.expect(std.mem.indexOf(u8, request.body, "metadataHeaders=Subject") != null);
    }
    try std.testing.expect(found);
}

test "gmail sync prioritizes inbox refs before background refs" {
    var model = mail.emptyModel();
    model.addAccount(.gmail, "person@example.com", "Person", "token", "https://gmail.googleapis.com");
    var fx = @import("main.zig").Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    startInitialSync(&model, &fx, @import("main.zig").Effects.responseMsg(.initial_response), @import("main.zig").Effects.hostMsg(.authorized_initial_response));

    const background = native_sdk.EffectResponse{
        .key = model.sync_generation * generation_key_stride + initial_key_base + gmail_background_list_folder_index * mail.max_accounts,
        .outcome = .ok,
        .status = 200,
        .body = "{\"threads\":[{\"id\":\"archive-first\"},{\"id\":\"inbox-first\"}]}",
    };
    handleInitialResponse(&model, background, &fx, @import("main.zig").Effects.responseMsg(.gmail_detail_response), @import("main.zig").Effects.hostMsg(.authorized_gmail_detail_response));
    try std.testing.expectEqual(@as(usize, 0), model.accounts[0].gmail_ref_count);

    const inbox = native_sdk.EffectResponse{
        .key = model.sync_generation * generation_key_stride + initial_key_base + gmail_inbox_list_folder_index * mail.max_accounts,
        .outcome = .ok,
        .status = 200,
        .body = "{\"threads\":[{\"id\":\"inbox-first\"}]}",
    };
    handleInitialResponse(&model, inbox, &fx, @import("main.zig").Effects.responseMsg(.gmail_detail_response), @import("main.zig").Effects.hostMsg(.authorized_gmail_detail_response));
    try std.testing.expectEqual(@as(usize, 2), model.accounts[0].gmail_ref_count);
    try std.testing.expectEqualStrings("inbox-first", model.accounts[0].gmail_refs[0].id.slice());
    try std.testing.expectEqualStrings("archive-first", model.accounts[0].gmail_refs[1].id.slice());
}

test "authorized Gmail metadata is fetched in one batch" {
    const wire = @import("auth/wire.zig");
    var model = mail.emptyModel();
    _ = model.addAuthorizedAccount(.gmail, "provider-id", "person@example.com", "Person", "gmail:provider-id", "https://gmail.googleapis.com");
    model.sync_generation = 1;
    const account = &model.accounts[0];
    account.sync_state = .loading;
    account.gmail_inbox_list_done = true;
    account.gmail_background_list_done = true;
    account.gmail_drafts_done = true;
    appendGmailRef(account, "message-one");
    appendGmailRef(account, "message-two");
    var fx = @import("main.zig").Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    scheduleNextGmailDetail(&model, 0, &fx, @import("main.zig").Effects.responseMsg(.gmail_detail_response), @import("main.zig").Effects.hostMsg(.authorized_gmail_detail_response));
    try std.testing.expectEqual(@as(usize, 1), fx.pendingHostCount());
    const pending = fx.pendingHostAt(0) orelse return error.BatchRequestMissing;
    const request = try wire.decodeRequest(pending.payload);
    try std.testing.expectEqual(wire.Method.post, request.method);
    try std.testing.expectEqualStrings("https://gmail.googleapis.com/batch/gmail/v1", request.url);
    try std.testing.expect(std.mem.startsWith(u8, request.content_type, "multipart/mixed; boundary="));
    try std.testing.expect(std.mem.indexOf(u8, request.body, "GET /gmail/v1/users/me/threads/message-one?") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.body, "GET /gmail/v1/users/me/threads/message-two?") != null);
    try std.testing.expectEqual(@as(usize, 2), account.gmail_in_flight);

    const batch_body =
        "--response_boundary\r\nContent-Type: application/http\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n" ++
        "{\"id\":\"message-one\",\"messages\":[{\"id\":\"message-one\",\"threadId\":\"thread-one\",\"labelIds\":[\"INBOX\",\"UNREAD\"],\"snippet\":\"First\",\"internalDate\":\"1000\",\"payload\":{\"headers\":[{\"name\":\"Subject\",\"value\":\"First message\"}]}}]}\r\n" ++
        "--response_boundary\r\nContent-Type: application/http\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n" ++
        "{\"id\":\"message-two\",\"messages\":[{\"id\":\"message-two\",\"threadId\":\"thread-two\",\"labelIds\":[\"INBOX\"],\"snippet\":\"Second\",\"internalDate\":\"2000\",\"payload\":{\"headers\":[{\"name\":\"Subject\",\"value\":\"Second message\"}]}}]}\r\n" ++
        "--response_boundary--\r\n";
    handleGmailDetailResponse(&model, .{
        .key = generation_key_stride + gmail_detail_key_base,
        .outcome = .ok,
        .status = 200,
        .body = batch_body,
    }, &fx, @import("main.zig").Effects.responseMsg(.gmail_detail_response), @import("main.zig").Effects.hostMsg(.authorized_gmail_detail_response));

    try std.testing.expectEqual(@as(usize, 0), account.gmail_in_flight);
    try std.testing.expectEqual(@as(usize, 2), model.thread_count);
    try std.testing.expectEqualStrings("First message", model.threads[0].subjectSlice());
    try std.testing.expectEqualStrings("Second message", model.threads[1].subjectSlice());
    try std.testing.expectEqual(.ready, account.sync_state);
}

test "gmail full body is fetched only for the opened message" {
    var model = mail.emptyModel();
    model.addAccount(.gmail, "person@example.com", "Person", "token", "https://gmail.googleapis.com");
    model.sync_generation = 3;
    var thread = mail.MailThread{ .account_index = 0, .provider = .gmail };
    thread.provider_thread_id.set("thread-1");
    thread.provider_message_id.set("message-1");
    thread.snippet.set("preview");
    _ = model.addThread(thread);
    var fx = @import("main.zig").Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    try std.testing.expect(fetchGmailBody(&model, 0, &fx, @import("main.zig").Effects.responseMsg(.gmail_body_response), @import("main.zig").Effects.hostMsg(.authorized_gmail_body_response)));
    try std.testing.expect(model.threads[0].body_loading);
    const request = fx.pendingFetchAt(0) orelse return error.FetchNotFound;
    try std.testing.expectEqualStrings("https://gmail.googleapis.com/gmail/v1/users/me/messages/message-1?format=full", request.url);

    var response = native_sdk.EffectResponse{
        .key = model.sync_generation * generation_key_stride + gmail_body_key_base,
        .outcome = .ok,
        .status = 200,
    };
    response.body =
        \\{"id":"message-1","threadId":"thread-1","payload":{"mimeType":"text/plain","headers":[],"body":{"data":"RnVsbCBtZXNzYWdl"}}}
    ;
    handleGmailBodyResponse(&model, response);
    try std.testing.expectEqualStrings("Full message", model.threads[0].bodySlice());
    try std.testing.expect(model.threads[0].body_loaded);
    try std.testing.expect(!model.threads[0].body_loading);
    try std.testing.expect(!model.threads[0].body_load_failed);
}

test "outlook parser strips html and maps flags" {
    var model = mail.initialModel();
    const fixture =
        \\{"value":[{"id":"message-1","conversationId":"conversation-1","subject":"Microsoft follow up","bodyPreview":"Ready","body":{"contentType":"html","content":"<p>Outlook <strong>ready</strong>.</p>"},"from":{"emailAddress":{"address":"alerts@example.com","name":"Alerts"}},"parentFolderId":"opaque-real-graph-folder-id","isRead":false,"flag":{"flagStatus":"flagged"}}]}
    ;
    try parseOutlookMessages(&model, 2, .archive, fixture);
    try std.testing.expectEqual(@as(usize, 1), model.thread_count);
    try std.testing.expectEqualStrings("Microsoft follow up", model.threads[0].subjectSlice());
    try std.testing.expect(mail.containsAsciiIgnoreCase(model.threads[0].bodySlice(), "Outlook ready"));
    try std.testing.expect(model.threads[0].starred);
    try std.testing.expect(model.threads[0].archived);
    try std.testing.expect(!model.threads[0].in_inbox);
}

test "stale sync responses are ignored after refresh" {
    var model = mail.initialModel();
    var fx = @import("main.zig").Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    startInitialSync(&model, &fx, @import("main.zig").Effects.responseMsg(.initial_response), @import("main.zig").Effects.hostMsg(.authorized_initial_response));
    const first_generation = model.sync_generation;
    startInitialSync(&model, &fx, @import("main.zig").Effects.responseMsg(.initial_response), @import("main.zig").Effects.hostMsg(.authorized_initial_response));
    try std.testing.expect(model.sync_generation != first_generation);

    var response = native_sdk.EffectResponse{ .key = first_generation * generation_key_stride + initial_key_base, .outcome = .ok, .status = 200 };
    response.body = "{\"threads\":[]}";
    handleInitialResponse(&model, response, &fx, @import("main.zig").Effects.responseMsg(.gmail_detail_response), @import("main.zig").Effects.hostMsg(.authorized_gmail_detail_response));
    try std.testing.expectEqual(.loading, model.accounts[0].sync_state);
}

test "gmail detail batch retries and reaches ready" {
    var model = mail.emptyModel();
    model.addAccount(.gmail, "person@example.com", "Person", "token", "https://gmail.googleapis.com");
    var fx = @import("main.zig").Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    startInitialSync(&model, &fx, @import("main.zig").Effects.responseMsg(.initial_response), @import("main.zig").Effects.hostMsg(.authorized_initial_response));
    const generation = model.sync_generation;

    var drafts = native_sdk.EffectResponse{
        .key = generation * generation_key_stride + initial_key_base + gmail_draft_list_folder_index * mail.max_accounts,
        .outcome = .ok,
        .status = 200,
    };
    drafts.body = "{\"drafts\":[]}";
    handleInitialResponse(&model, drafts, &fx, @import("main.zig").Effects.responseMsg(.gmail_detail_response), @import("main.zig").Effects.hostMsg(.authorized_gmail_detail_response));

    var threads = native_sdk.EffectResponse{
        .key = generation * generation_key_stride + initial_key_base,
        .outcome = .ok,
        .status = 200,
    };
    threads.body = "{\"threads\":[{\"id\":\"t0\"},{\"id\":\"t1\"},{\"id\":\"t2\"},{\"id\":\"t3\"},{\"id\":\"t4\"}]}";
    handleInitialResponse(&model, threads, &fx, @import("main.zig").Effects.responseMsg(.gmail_detail_response), @import("main.zig").Effects.hostMsg(.authorized_gmail_detail_response));
    var background = native_sdk.EffectResponse{
        .key = generation * generation_key_stride + initial_key_base + gmail_background_list_folder_index * mail.max_accounts,
        .outcome = .ok,
        .status = 200,
    };
    background.body = "{\"threads\":[]}";
    handleInitialResponse(&model, background, &fx, @import("main.zig").Effects.responseMsg(.gmail_detail_response), @import("main.zig").Effects.hostMsg(.authorized_gmail_detail_response));
    try std.testing.expectEqual(@as(usize, 5), model.accounts[0].gmail_in_flight);
    try std.testing.expectEqual(@as(usize, 5), model.accounts[0].gmail_next_ref);
    handleGmailDetailResponse(&model, .{
        .key = generation * generation_key_stride + gmail_detail_key_base,
        .outcome = .timed_out,
    }, &fx, @import("main.zig").Effects.responseMsg(.gmail_detail_response), @import("main.zig").Effects.hostMsg(.authorized_gmail_detail_response));
    try std.testing.expectEqual(@as(u8, 1), model.accounts[0].gmail_retry_counts[0]);
    try std.testing.expect(model.accounts[0].error_message.isEmpty());
    try std.testing.expectEqual(@as(usize, 5), model.accounts[0].gmail_in_flight);

    var batch_buffer: [8192]u8 = undefined;
    var batch_len: usize = 0;
    for (0..5) |index| {
        const part = try std.fmt.bufPrint(batch_buffer[batch_len..],
            "--test_response\r\nContent-Type: application/http\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{{\"id\":\"t{d}\",\"messages\":[{{\"id\":\"m{d}\",\"threadId\":\"t{d}\",\"labelIds\":[\"INBOX\"],\"payload\":{{\"headers\":[]}}}}]}}\r\n",
            .{ index, index, index },
        );
        batch_len += part.len;
    }
    const closing = try std.fmt.bufPrint(batch_buffer[batch_len..], "--test_response--\r\n", .{});
    batch_len += closing.len;
    handleGmailDetailResponse(&model, .{
        .key = generation * generation_key_stride + gmail_detail_key_base,
        .outcome = .ok,
        .status = 200,
        .body = batch_buffer[0..batch_len],
    }, &fx, @import("main.zig").Effects.responseMsg(.gmail_detail_response), @import("main.zig").Effects.hostMsg(.authorized_gmail_detail_response));
    try std.testing.expectEqual(@as(usize, 0), model.accounts[0].gmail_in_flight);
    try std.testing.expectEqual(@as(usize, 5), model.thread_count);
    try std.testing.expectEqual(.ready, model.accounts[0].sync_state);
}

test "gmail detail keys do not overlap between accounts after one hundred messages" {
    var model = mail.emptyModel();
    model.addAccount(.gmail, "first@example.com", "First", "token", "https://gmail.googleapis.com");
    model.addAccount(.gmail, "second@example.com", "Second", "token", "https://gmail.googleapis.com");
    model.sync_generation = 1;
    for (model.accounts[0..model.account_count]) |*account| account.sync_state = .loading;
    model.accounts[0].gmail_ref_count = mail.max_gmail_refs;
    model.accounts[0].gmail_next_ref = mail.max_gmail_refs;
    model.accounts[0].gmail_in_flight = 1;
    model.accounts[0].gmail_drafts_done = true;
    model.accounts[1].gmail_ref_count = 2;
    model.accounts[1].gmail_next_ref = 1;
    model.accounts[1].gmail_in_flight = 1;

    var fx = @import("main.zig").Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    const response = native_sdk.EffectResponse{
        .key = generation_key_stride + gmail_detail_key_base + mail.max_gmail_refs - 1,
        .outcome = .rejected,
    };
    handleGmailDetailResponse(&model, response, &fx, @import("main.zig").Effects.responseMsg(.gmail_detail_response), @import("main.zig").Effects.hostMsg(.authorized_gmail_detail_response));

    try std.testing.expectEqual(@as(usize, 1), model.accounts[0].gmail_in_flight);
    try std.testing.expectEqual(@as(u8, 1), model.accounts[0].gmail_retry_counts[mail.max_gmail_refs - 1]);
    try std.testing.expectEqual(@as(usize, 1), model.accounts[1].gmail_in_flight);
    try std.testing.expectEqual(@as(u8, 0), model.accounts[1].gmail_retry_counts[0]);
}

test "outlook move response keeps the replacement message id" {
    var model = mail.initialModel();
    var thread = mail.MailThread{ .account_index = 2, .provider = .microsoft };
    thread.provider_thread_id.set("conversation-move");
    thread.provider_message_id.set("old-message");
    _ = model.addThread(thread);
    const key = model.beginMutation(0).?;
    var response = native_sdk.EffectResponse{ .key = key, .outcome = .ok, .status = 200 };
    response.body = "{\"id\":\"new-message\"}";
    handleMutationResponse(&model, response);
    try std.testing.expectEqualStrings("new-message", model.threads[0].providerMessageID());
    try std.testing.expect(!model.pending_mutations[0].active);
}

test "gmail trash uses the canonical thread trash endpoint" {
    var account = mail.Account{ .provider = .gmail };
    account.base_url.set("http://127.0.0.1:4402");
    var thread = mail.MailThread{ .provider = .gmail };
    thread.provider_thread_id.set("thread-trash");
    var url_buffer: [512]u8 = undefined;
    var body_buffer: [512]u8 = undefined;
    const request = try gmailMutationRequest(.trash, &account, &thread, &url_buffer, &body_buffer);
    try std.testing.expectEqualStrings("http://127.0.0.1:4402/gmail/v1/users/me/threads/thread-trash/trash", request.url);
    try std.testing.expectEqualStrings("{}", request.body);
}

test "outlook messages in one conversation remain independent rows" {
    var model = mail.initialModel();
    const fixture =
        \\{"value":[{"id":"new","conversationId":"shared","subject":"New","receivedDateTime":"2026-07-18T10:00:00Z","parentFolderId":"inbox"},{"id":"old","conversationId":"shared","subject":"Old","receivedDateTime":"2026-07-18T09:00:00Z","parentFolderId":"archive"}]}
    ;
    try parseOutlookMessages(&model, 2, .inbox, fixture);
    try std.testing.expectEqual(@as(usize, 2), model.thread_count);
    try std.testing.expectEqualStrings("new", model.threads[0].providerThreadID());
    try std.testing.expectEqualStrings("old", model.threads[1].providerThreadID());
}

test "gmail remote draft parser restores recipients subject body and provider ids" {
    var model = mail.initialModel();
    const fixture =
        \\{"id":"draft-1","message":{"id":"draft-message-1","threadId":"thread-1","labelIds":["DRAFT"],"snippet":"Saved body","internalDate":"1784365200000","payload":{"mimeType":"text/plain","headers":[{"name":"To","value":"Customer <customer@example.com>"},{"name":"Cc","value":"ops@example.com"},{"name":"Bcc","value":"audit@example.com"},{"name":"Subject","value":"Re: Saved work"},{"name":"In-Reply-To","value":"<original@example.com>"},{"name":"References","value":"<root@example.com>"}],"body":{"data":"U2F2ZWQgYm9keQ"}}}}
    ;
    try parseGmailDraft(&model, 0, fixture);
    try std.testing.expectEqual(@as(usize, 1), model.draft_count);
    try std.testing.expectEqualStrings("draft-1", model.drafts[0].provider_draft_id.slice());
    try std.testing.expectEqualStrings("customer@example.com", mail.extractAddress(model.drafts[0].to.slice()));
    try std.testing.expectEqualStrings("Saved body", model.drafts[0].body.slice());
    try std.testing.expectEqual(.reply, model.drafts[0].mode);
    try std.testing.expectEqualStrings("<original@example.com>", model.drafts[0].source_rfc_message_id.slice());
    try std.testing.expectEqualStrings("<root@example.com>", model.drafts[0].source_references.slice());
    try std.testing.expect(model.drafts[0].remote);
}

test "outlook remote draft parser restores graph recipients and plain body" {
    var model = mail.initialModel();
    const fixture =
        \\{"value":[{"id":"graph-draft-1","conversationId":"conversation-1","subject":"Graph draft","bodyPreview":"Hello","body":{"contentType":"html","content":"<p>Hello <strong>Graph</strong></p>"},"toRecipients":[{"emailAddress":{"address":"to@example.com","name":"To"}}],"ccRecipients":[{"emailAddress":{"address":"cc@example.com"}}],"bccRecipients":[{"emailAddress":{"address":"bcc@example.com"}}],"receivedDateTime":"2026-07-18T10:00:00Z"}]}
    ;
    try parseOutlookDrafts(&model, 2, fixture);
    try std.testing.expectEqual(@as(usize, 1), model.draft_count);
    try std.testing.expectEqualStrings("graph-draft-1", model.drafts[0].provider_draft_id.slice());
    try std.testing.expectEqualStrings("to@example.com", model.drafts[0].to.slice());
    try std.testing.expectEqualStrings("bcc@example.com", model.drafts[0].bcc.slice());
    try std.testing.expect(mail.containsAsciiIgnoreCase(model.drafts[0].body.slice(), "Hello Graph"));
}
