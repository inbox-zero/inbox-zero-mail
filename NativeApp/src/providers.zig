const std = @import("std");
const native_sdk = @import("native_sdk");
const mail = @import("model.zig");

pub const initial_key_base: u64 = 100;
pub const gmail_detail_key_base: u64 = 1_000;
const generation_key_stride: u64 = 100_000;

const GmailThreadReference = struct {
    id: []const u8,
};

const GmailThreadList = struct {
    threads: ?[]const GmailThreadReference = null,
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
    parentFolderId: ?[]const u8 = null,
    receivedDateTime: ?[]const u8 = null,
    isRead: ?bool = null,
    flag: ?OutlookFlag = null,
};

const OutlookMessageList = struct {
    value: []const OutlookMessage,
};

const OutlookMutationReceipt = struct {
    id: ?[]const u8 = null,
};

pub fn startInitialSync(model: *mail.Model, fx: anytype, on_response: anytype) void {
    const generation = model.resetForSync();
    for (model.accounts[0..model.account_count], 0..) |*account, index| {
        account.sync_state = .loading;
        account.gmail_ref_count = 0;
        account.gmail_next_ref = 0;
        account.gmail_in_flight = false;
        account.error_message = .{};
        var url_buffer: [512]u8 = undefined;
        const url = switch (account.provider) {
            .gmail => std.fmt.bufPrint(&url_buffer, "{s}/gmail/v1/users/me/threads?maxResults=50&labelIds=INBOX", .{account.baseUrl()}) catch {
                account.sync_state = .failed;
                continue;
            },
            .microsoft => std.fmt.bufPrint(&url_buffer, "{s}/v1.0/me/messages?%24top=50&%24orderby=receivedDateTime%20desc", .{account.baseUrl()}) catch {
                account.sync_state = .failed;
                continue;
            },
        };
        fetchAuthorized(fx, generation * generation_key_stride + initial_key_base + index, .GET, url, account.tokenSlice(), "", on_response);
    }
}

pub fn handleInitialResponse(model: *mail.Model, response: native_sdk.EffectResponse, fx: anytype, detail_response: anytype) void {
    const generation = response.key / generation_key_stride;
    if (generation != model.sync_generation) return;
    const local_key = response.key % generation_key_stride;
    if (local_key < initial_key_base or local_key >= gmail_detail_key_base) return;
    const account_index: usize = @intCast(local_key - initial_key_base);
    if (account_index >= model.account_count) return;
    const account = &model.accounts[account_index];
    if (!responseOk(response)) {
        failAccount(account, "Initial provider sync failed.");
        return;
    }
    switch (account.provider) {
        .gmail => {
            parseGmailList(account, response.body) catch {
                failAccount(account, "Gmail returned an unreadable thread list.");
                return;
            };
            scheduleNextGmailDetail(model, account_index, fx, detail_response);
        },
        .microsoft => {
            parseOutlookMessages(model, account_index, response.body) catch {
                failAccount(account, "Outlook returned unreadable messages.");
                return;
            };
            account.sync_state = .ready;
            model.reconcileSelection();
            model.status_message.set("Gmail and Outlook are connected.");
        },
    }
}

pub fn handleGmailDetailResponse(model: *mail.Model, response: native_sdk.EffectResponse, fx: anytype, detail_response: anytype) void {
    const generation = response.key / generation_key_stride;
    if (generation != model.sync_generation) return;
    const local_key = response.key % generation_key_stride;
    if (local_key < gmail_detail_key_base) return;
    const encoded = local_key - gmail_detail_key_base;
    const account_index: usize = @intCast(encoded / 100);
    if (account_index >= model.account_count) return;
    const account = &model.accounts[account_index];
    account.gmail_in_flight = false;
    if (!responseOk(response)) {
        failAccount(account, "A Gmail thread could not be loaded.");
        return;
    }
    parseGmailThread(model, account_index, response.body) catch {
        failAccount(account, "Gmail returned an unreadable thread.");
        return;
    };
    scheduleNextGmailDetail(model, account_index, fx, detail_response);
    model.reconcileSelection();
}

pub fn fetchMutation(fx: anytype, key: u64, provider: mail.ProviderKind, operation: MutationOperation, account: *const mail.Account, thread: *const mail.MailThread, on_response: anytype) bool {
    var url_buffer: [512]u8 = undefined;
    var body_buffer: [512]u8 = undefined;
    const request = switch (provider) {
        .gmail => gmailMutationRequest(operation, account, thread, &url_buffer, &body_buffer),
        .microsoft => outlookMutationRequest(operation, account, thread, &url_buffer, &body_buffer),
    } catch return false;
    fetchAuthorized(fx, key, request.method, request.url, account.tokenSlice(), request.body, on_response);
    return true;
}

pub fn handleMutationResponse(model: *mail.Model, response: native_sdk.EffectResponse) void {
    const success = responseOk(response);
    if (success) {
        for (&model.pending_mutations) |*pending| {
            if (!pending.active or pending.key != response.key or pending.thread_index >= model.thread_count) continue;
            const thread = &model.threads[pending.thread_index];
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
    const url = try std.fmt.bufPrint(url_buffer, "{s}/gmail/v1/users/me/threads/{s}/modify", .{ account.baseUrl(), thread.providerThreadID() });
    const body = switch (operation) {
        .archive => try std.fmt.bufPrint(body_buffer, "{{\"addLabelIds\":[],\"removeLabelIds\":[\"INBOX\"]}}", .{}),
        .trash => try std.fmt.bufPrint(body_buffer, "{{\"addLabelIds\":[\"TRASH\"],\"removeLabelIds\":[\"INBOX\"]}}", .{}),
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

fn fetchAuthorized(fx: anytype, key: u64, method: std.http.Method, url: []const u8, token: []const u8, body: []const u8, on_response: anytype) void {
    var authorization_buffer: [256]u8 = undefined;
    const authorization = std.fmt.bufPrint(&authorization_buffer, "Bearer {s}", .{token}) catch return;
    const headers = if (body.len > 0)
        &[_]std.http.Header{
            .{ .name = "authorization", .value = authorization },
            .{ .name = "content-type", .value = "application/json" },
        }
    else
        &[_]std.http.Header{.{ .name = "authorization", .value = authorization }};
    fx.fetch(.{
        .key = key,
        .method = method,
        .url = url,
        .headers = headers,
        .body = if (body.len > 0) body else null,
        .timeout_ms = 15_000,
        .on_response = on_response,
    });
}

fn scheduleNextGmailDetail(model: *mail.Model, account_index: usize, fx: anytype, detail_response: anytype) void {
    const account = &model.accounts[account_index];
    if (account.gmail_in_flight) return;
    if (account.gmail_next_ref >= account.gmail_ref_count) {
        account.sync_state = .ready;
        model.status_message.set("Gmail and Outlook are connected.");
        return;
    }
    const ref_index = account.gmail_next_ref;
    const reference = &account.gmail_refs[ref_index];
    account.gmail_next_ref += 1;
    account.gmail_in_flight = true;
    var url_buffer: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buffer, "{s}/gmail/v1/users/me/threads/{s}?format=full", .{ account.baseUrl(), reference.id.slice() }) catch {
        failAccount(account, "Could not build a Gmail detail URL.");
        return;
    };
    const key = model.sync_generation * generation_key_stride + gmail_detail_key_base + account_index * 100 + ref_index;
    fetchAuthorized(fx, key, .GET, url, account.tokenSlice(), "", detail_response);
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

pub fn parseGmailThread(model: *mail.Model, account_index: usize, body: []const u8) !void {
    const parsed = try std.json.parseFromSlice(GmailThread, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.messages.len == 0) return;
    const message = &parsed.value.messages[parsed.value.messages.len - 1];
    var thread = mail.MailThread{ .account_index = account_index, .provider = .gmail };
    thread.provider_thread_id.set(parsed.value.id);
    thread.provider_message_id.set(message.id);
    thread.snippet.set(message.snippet orelse parsed.value.snippet orelse "");
    thread.received_at.set(message.internalDate orelse "");
    thread.subject.set(headerValue(&message.payload, "Subject") orelse "(No subject)");
    thread.sender.set(headerValue(&message.payload, "From") orelse model.accounts[account_index].emailSlice());
    thread.unread = hasLabel(message.labelIds, "UNREAD");
    thread.starred = hasLabel(message.labelIds, "STARRED");
    thread.in_inbox = hasLabel(message.labelIds, "INBOX");
    thread.trashed = hasLabel(message.labelIds, "TRASH");
    thread.archived = !thread.in_inbox and !thread.trashed;
    if (findPlainBody(&message.payload)) |encoded| {
        var decoded: [8192]u8 = undefined;
        const size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded) catch 0;
        if (size > 0 and size <= decoded.len) {
            if (std.base64.url_safe_no_pad.Decoder.decode(decoded[0..size], encoded)) |_| {
                thread.body.set(decoded[0..size]);
            } else |_| {}
        }
    }
    if (thread.body.isEmpty()) thread.body.set(thread.snippetSlice());
    _ = model.addThread(thread);
}

pub fn parseOutlookMessages(model: *mail.Model, account_index: usize, body: []const u8) !void {
    const parsed = try std.json.parseFromSlice(OutlookMessageList, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    for (parsed.value.value) |message| {
        var thread = mail.MailThread{ .account_index = account_index, .provider = .microsoft };
        thread.provider_thread_id.set(message.conversationId);
        thread.provider_message_id.set(message.id);
        thread.subject.set(message.subject orelse "(No subject)");
        if (message.from) |sender| {
            thread.sender.set(sender.emailAddress.name orelse sender.emailAddress.address);
        } else {
            thread.sender.set(model.accounts[account_index].emailSlice());
        }
        thread.snippet.set(message.bodyPreview orelse "");
        thread.received_at.set(message.receivedDateTime orelse "");
        thread.unread = !(message.isRead orelse false);
        thread.starred = if (message.flag) |flag| std.mem.eql(u8, flag.flagStatus orelse "", "flagged") else false;
        const folder = message.parentFolderId orelse "inbox";
        thread.in_inbox = std.ascii.eqlIgnoreCase(folder, "inbox");
        thread.trashed = std.ascii.eqlIgnoreCase(folder, "deleteditems");
        thread.archived = std.ascii.eqlIgnoreCase(folder, "archive");
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

fn responseOk(response: native_sdk.EffectResponse) bool {
    return response.outcome == .ok and response.status >= 200 and response.status < 300 and !response.truncated;
}

fn failAccount(account: *mail.Account, message: []const u8) void {
    account.sync_state = .failed;
    account.gmail_in_flight = false;
    account.error_message.set(message);
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
        \\{"value":[{"id":"message-1","conversationId":"conversation-1","subject":"Microsoft follow up","bodyPreview":"Ready","body":{"contentType":"html","content":"<p>Outlook <strong>ready</strong>.</p>"},"from":{"emailAddress":{"address":"alerts@example.com","name":"Alerts"}},"parentFolderId":"inbox","isRead":false,"flag":{"flagStatus":"flagged"}}]}
    ;
    try parseOutlookMessages(&model, 2, fixture);
    try std.testing.expectEqual(@as(usize, 1), model.thread_count);
    try std.testing.expectEqualStrings("Microsoft follow up", model.threads[0].subjectSlice());
    try std.testing.expect(mail.containsAsciiIgnoreCase(model.threads[0].bodySlice(), "Outlook ready"));
    try std.testing.expect(model.threads[0].starred);
}

test "stale sync responses are ignored after refresh" {
    var model = mail.initialModel();
    var fx = @import("main.zig").Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    startInitialSync(&model, &fx, @import("main.zig").Effects.responseMsg(.initial_response));
    const first_generation = model.sync_generation;
    startInitialSync(&model, &fx, @import("main.zig").Effects.responseMsg(.initial_response));
    try std.testing.expect(model.sync_generation != first_generation);

    var response = native_sdk.EffectResponse{ .key = first_generation * generation_key_stride + initial_key_base, .outcome = .ok, .status = 200 };
    response.body = "{\"threads\":[]}";
    handleInitialResponse(&model, response, &fx, @import("main.zig").Effects.responseMsg(.gmail_detail_response));
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
