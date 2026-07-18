const std = @import("std");
const native_sdk = @import("native_sdk");
const mail = @import("model.zig");
const transport = @import("platform/effects_transport.zig");

pub const initial_key_base: u64 = 100;
pub const gmail_detail_key_base: u64 = 1_000;
pub const gmail_draft_detail_key_base: u64 = 10_000;
const generation_key_stride: u64 = 100_000;
const gmail_draft_list_folder_index: usize = 10;

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
    const generation = model.resetForSync();
    model.resetRemoteDrafts();
    for (model.accounts[0..model.account_count], 0..) |*account, index| {
        account.sync_state = .loading;
        account.gmail_ref_count = 0;
        account.gmail_next_ref = 0;
        account.gmail_in_flight = false;
        account.gmail_threads_done = false;
        account.gmail_draft_ref_count = 0;
        account.gmail_draft_next_ref = 0;
        account.gmail_draft_in_flight = false;
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
                fetchAuthorized(fx, key, .GET, url, account, "", on_response, on_authorized_response);
            }
            continue;
        }
        const url = std.fmt.bufPrint(&url_buffer, "{s}/gmail/v1/users/me/threads?maxResults=128&includeSpamTrash=true", .{account.baseUrl()}) catch {
            account.sync_state = .failed;
            continue;
        };
        fetchAuthorized(fx, generation * generation_key_stride + initial_key_base + index, .GET, url, account, "", on_response, on_authorized_response);
        const drafts_url = std.fmt.bufPrint(&url_buffer, "{s}/gmail/v1/users/me/drafts?maxResults=50", .{account.baseUrl()}) catch {
            account.error_message.set("Could not build the Gmail drafts URL.");
            account.gmail_drafts_done = true;
            continue;
        };
        const draft_key = generation * generation_key_stride + initial_key_base + gmail_draft_list_folder_index * mail.max_accounts + index;
        fetchAuthorized(fx, draft_key, .GET, drafts_url, account, "", on_response, on_authorized_response);
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
            if (folder_index == gmail_draft_list_folder_index) account.gmail_drafts_done = true else account.gmail_threads_done = true;
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
            } else {
                parseGmailList(account, response.body) catch {
                    account.error_message.set("Gmail returned an unreadable thread list.");
                    account.gmail_threads_done = true;
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
    const account_index: usize = @intCast(encoded / 100);
    if (account_index >= model.account_count) return;
    const account = &model.accounts[account_index];
    if (is_draft) account.gmail_draft_in_flight = false else account.gmail_in_flight = false;
    if (!responseOk(response)) {
        account.error_message.set(if (is_draft) "One or more Gmail drafts could not be loaded." else "One or more Gmail threads could not be loaded.");
        if (is_draft)
            scheduleNextGmailDraftDetail(model, account_index, fx, detail_response, authorized_detail_response)
        else
            scheduleNextGmailDetail(model, account_index, fx, detail_response, authorized_detail_response);
        updateSyncStatus(model);
        return;
    }
    if (is_draft) {
        parseGmailDraft(model, account_index, response.body) catch {
            account.error_message.set("One or more Gmail drafts were unreadable.");
            scheduleNextGmailDraftDetail(model, account_index, fx, detail_response, authorized_detail_response);
            updateSyncStatus(model);
            return;
        };
        scheduleNextGmailDraftDetail(model, account_index, fx, detail_response, authorized_detail_response);
    } else {
        parseGmailThread(model, account_index, response.body) catch {
            account.error_message.set("One or more Gmail threads were unreadable.");
            scheduleNextGmailDetail(model, account_index, fx, detail_response, authorized_detail_response);
            updateSyncStatus(model);
            return;
        };
        scheduleNextGmailDetail(model, account_index, fx, detail_response, authorized_detail_response);
    }
    model.reconcileSelection();
    updateSyncStatus(model);
}

pub fn fetchMutation(fx: anytype, key: u64, provider: mail.ProviderKind, operation: MutationOperation, account: *const mail.Account, thread: *const mail.MailThread, on_response: anytype, on_authorized_response: anytype) bool {
    var url_buffer: [512]u8 = undefined;
    var body_buffer: [512]u8 = undefined;
    const request = switch (provider) {
        .gmail => gmailMutationRequest(operation, account, thread, &url_buffer, &body_buffer),
        .microsoft => outlookMutationRequest(operation, account, thread, &url_buffer, &body_buffer),
    } catch return false;
    fetchAuthorized(fx, key, request.method, request.url, account, request.body, on_response, on_authorized_response);
    return true;
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

fn fetchAuthorized(fx: anytype, key: u64, method: std.http.Method, url: []const u8, account: *const mail.Account, body: []const u8, on_response: anytype, on_authorized_response: anytype) void {
    _ = transport.fetchAuthorized(fx, key, .{
        .method = method,
        .url = url,
        .content_type = if (body.len > 0) "application/json" else null,
        .body = if (body.len > 0) body else null,
    }, account.tokenSlice(), account.credential_key.slice(), on_response, on_authorized_response);
}

fn scheduleNextGmailDetail(model: *mail.Model, account_index: usize, fx: anytype, detail_response: anytype, authorized_detail_response: anytype) void {
    const account = &model.accounts[account_index];
    if (account.gmail_in_flight) return;
    if (account.gmail_next_ref >= account.gmail_ref_count) {
        account.gmail_threads_done = true;
        finishGmailSync(model, account);
        updateSyncStatus(model);
        return;
    }
    const ref_index = account.gmail_next_ref;
    const reference = &account.gmail_refs[ref_index];
    account.gmail_next_ref += 1;
    account.gmail_in_flight = true;
    var url_buffer: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buffer, "{s}/gmail/v1/users/me/threads/{s}?format=full", .{ account.baseUrl(), reference.id.slice() }) catch {
        failAccount(account, "Could not build a Gmail detail URL.");
        updateSyncStatus(model);
        return;
    };
    const key = model.sync_generation * generation_key_stride + gmail_detail_key_base + account_index * 100 + ref_index;
    fetchAuthorized(fx, key, .GET, url, account, "", detail_response, authorized_detail_response);
}

fn scheduleNextGmailDraftDetail(model: *mail.Model, account_index: usize, fx: anytype, detail_response: anytype, authorized_detail_response: anytype) void {
    const account = &model.accounts[account_index];
    if (account.gmail_draft_in_flight) return;
    if (account.gmail_draft_next_ref >= account.gmail_draft_ref_count) {
        account.gmail_drafts_done = true;
        finishGmailSync(model, account);
        updateSyncStatus(model);
        return;
    }
    const ref_index = account.gmail_draft_next_ref;
    const reference = &account.gmail_draft_refs[ref_index];
    account.gmail_draft_next_ref += 1;
    account.gmail_draft_in_flight = true;
    var url_buffer: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buffer, "{s}/gmail/v1/users/me/drafts/{s}?format=full", .{ account.baseUrl(), reference.id.slice() }) catch {
        account.error_message.set("Could not build a Gmail draft detail URL.");
        account.gmail_drafts_done = true;
        finishGmailSync(model, account);
        updateSyncStatus(model);
        return;
    };
    const key = model.sync_generation * generation_key_stride + gmail_draft_detail_key_base + account_index * 100 + ref_index;
    fetchAuthorized(fx, key, .GET, url, account, "", detail_response, authorized_detail_response);
}

fn parseGmailList(account: *mail.Account, body: []const u8) !void {
    const parsed = try std.json.parseFromSlice(GmailThreadList, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    account.gmail_ref_count = 0;
    account.gmail_next_ref = 0;
    for (parsed.value.threads orelse &.{}) |reference| {
        if (account.gmail_ref_count >= account.gmail_refs.len) break;
        account.gmail_refs[account.gmail_ref_count].id.set(reference.id);
        account.gmail_ref_count += 1;
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
    var thread = mail.MailThread{ .account_index = account_index, .provider = .gmail };
    thread.provider_thread_id.set(parsed.value.id);
    thread.provider_message_id.set(message.id);
    thread.rfc_message_id.set(headerValue(&message.payload, "Message-ID") orelse headerValue(&message.payload, "Message-Id") orelse "");
    thread.references.set(headerValue(&message.payload, "References") orelse "");
    thread.snippet.set(message.snippet orelse parsed.value.snippet orelse "");
    thread.received_at.set(message.internalDate orelse "");
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
    setGmailBody(&thread.body, &message.payload, thread.snippetSlice());
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
        _ = model.addThread(thread);
    }
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
    account.gmail_in_flight = false;
    account.error_message.set(message);
}

fn finishOutlookSync(model: *mail.Model, account: *mail.Account) void {
    if (account.outlook_pending != 0) return;
    account.sync_state = if (account.error_message.isEmpty()) .ready else .partial;
    updateSyncStatus(model);
}

fn finishGmailSync(model: *mail.Model, account: *mail.Account) void {
    if (!account.gmail_threads_done or !account.gmail_drafts_done) return;
    account.sync_state = if (account.error_message.isEmpty()) .ready else .partial;
    updateSyncStatus(model);
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
        model.status_message.set("Some accounts could not synchronize.");
    } else if (partial) {
        model.status_message.set("Connected with partial mail results.");
    } else {
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
