const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");
const mail = @import("model.zig");

test {
    _ = @import("platform/native_services.zig");
}

const canvas = native_sdk.canvas;
const AppMarkup = canvas.MarkupView(main.Model, main.Msg);
const ComposeMarkup = canvas.MarkupView(main.Model, main.Msg);

fn buildTree(arena: std.mem.Allocator, model: *const main.Model) !main.MailApp.Ui.Tree {
    canvas.icons.registerAppIcons(&main.app_icons);
    var view = try AppMarkup.init(arena, main.app_markup);
    var ui = main.MailApp.Ui.init(arena);
    const node = view.build(&ui, model) catch |err| {
        if (err == error.MarkupBuild) {
            std.debug.print("app.native:{d}:{d}: {s}\n", .{ view.diagnostic.line, view.diagnostic.column, view.diagnostic.message });
        }
        return err;
    };
    return ui.finalize(node);
}

fn buildComposeTree(arena: std.mem.Allocator, model: *const main.Model) !main.MailApp.Ui.Tree {
    var view = try ComposeMarkup.init(arena, main.compose_markup);
    var ui = main.MailApp.Ui.init(arena);
    const node = try view.build(&ui, model);
    return ui.finalize(node);
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, wanted: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, wanted)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, wanted)) |found| return found;
    }
    return null;
}

fn findByLabel(widget: canvas.Widget, kind: canvas.WidgetKind, wanted: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.semantics.label, wanted)) return widget;
    for (widget.children) |child| {
        if (findByLabel(child, kind, wanted)) |found| return found;
    }
    return null;
}

test "compact inbox keeps the selected message available to the detail window" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model = main.initialModel();
    var thread = mail.MailThread{ .account_index = 0, .unread = true };
    thread.provider_thread_id.set("thread-release");
    thread.provider_message_id.set("message-release");
    thread.subject.set("Release checklist");
    thread.sender.set("ops@example.com");
    thread.snippet.set("Check archive and star.");
    thread.body.set("Everything is ready.");
    _ = model.addThread(thread);

    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var tree = try buildTree(arena, &model);
    const row = findByText(tree.root, .text, "Release checklist") orelse return error.WidgetNotFound;
    const parent = row;
    _ = parent;
    model.selectThread(0);
    tree = try buildTree(arena, &model);
    _ = findByText(tree.root, .text, "Release checklist") orelse return error.WidgetNotFound;
    try std.testing.expectEqualStrings("Everything is ready.", model.selectedBody());

    const item = findByLabel(tree.root, .list_item, model.visibleThreads(arena)[0].accessible) orelse return error.WidgetNotFound;
    try std.testing.expect(item.semantics.actions.press);
    try std.testing.expect(item.autofocus);
    const click_msg = tree.msgForPointer(item.id, .up) orelse return error.MessageNotFound;
    main.update(&model, click_msg, &fx);
    try std.testing.expect(model.reading_open);
    try std.testing.expectEqual(@as(usize, 0), model.open_window_count);
    tree = try buildTree(arena, &model);
    _ = findByLabel(tree.root, .button, "Back to inbox") orelse return error.WidgetNotFound;
    _ = findByText(tree.root, .text, "Everything is ready.") orelse return error.WidgetNotFound;
}

test "keyboard map covers the keyboard-first inbox actions" {
    const base = canvas.WidgetKeyboardEvent{ .phase = .key_down };
    var key = base;
    key.key = "j";
    try std.testing.expectEqual(main.Msg.navigate_next, main.onKey(key).?);
    key.key = "k";
    try std.testing.expectEqual(main.Msg.navigate_previous, main.onKey(key).?);
    key.key = "arrowdown";
    try std.testing.expectEqual(main.Msg.navigate_next, main.onKey(key).?);
    key.key = "arrowup";
    try std.testing.expectEqual(main.Msg.navigate_previous, main.onKey(key).?);
    key.key = "enter";
    try std.testing.expectEqual(main.Msg.activate_context, main.onKey(key).?);
    key.key = "escape";
    try std.testing.expectEqual(main.Msg.escape_context, main.onKey(key).?);
    key.key = "tab";
    try std.testing.expectEqual(main.Msg.cycle_split_next, main.onKey(key).?);
    key.modifiers.shift = true;
    try std.testing.expectEqual(main.Msg.cycle_split_previous, main.onKey(key).?);
    key.modifiers.shift = false;
    key.key = "e";
    try std.testing.expectEqual(main.Msg.archive_selected, main.onKey(key).?);
    key.key = "d";
    try std.testing.expectEqual(main.Msg{ .set_filter = .drafts }, main.onKey(key).?);
    key.key = "u";
    key.modifiers.shift = true;
    try std.testing.expectEqual(main.Msg.toggle_read_selected, main.onKey(key).?);
}

test "keyboard messages navigate the visible inbox through update" {
    var model = main.initialModel();
    var first = mail.MailThread{ .account_index = 0 };
    first.provider_thread_id.set("keyboard-one");
    _ = model.addThread(first);
    var second = mail.MailThread{ .account_index = 1 };
    second.provider_thread_id.set("keyboard-two");
    _ = model.addThread(second);
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .select_next, &fx);
    try std.testing.expectEqual(@as(usize, 1), model.selected_thread);
    main.update(&model, .select_previous, &fx);
    try std.testing.expectEqual(@as(usize, 0), model.selected_thread);
    main.update(&model, .activate_selected, &fx);
    try std.testing.expect(model.reading_open);
    try std.testing.expectEqual(@as(usize, 0), model.open_window_count);
    main.update(&model, .close_reading, &fx);
    try std.testing.expect(!model.reading_open);
}

test "boot starts all configured account fetches through fake effects" {
    var model = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.boot(&model, &fx);
    try std.testing.expectEqual(@as(usize, 8), fx.pendingFetchCount());
    var gmail_requests: usize = 0;
    var outlook_folder_requests: usize = 0;
    for (0..8) |index| {
        const request = fx.pendingFetchAt(index) orelse return error.FetchNotFound;
        try std.testing.expect(request.url.len > 0);
        try std.testing.expectEqual(std.http.Method.GET, request.method);
        if (std.mem.indexOf(u8, request.url, "/gmail/v1/") != null) {
            gmail_requests += 1;
            try std.testing.expect(std.mem.indexOf(u8, request.url, "labelIds=INBOX") == null);
        }
        if (std.mem.indexOf(u8, request.url, "/mailFolders/") != null) outlook_folder_requests += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), gmail_requests);
    try std.testing.expectEqual(@as(usize, 4), outlook_folder_requests);
}

test "selected messages can be declared as independent windows" {
    var model = main.initialModel();
    var first = mail.MailThread{ .account_index = 0 };
    first.provider_thread_id.set("one");
    first.subject.set("First window");
    _ = model.addThread(first);
    var second = mail.MailThread{ .account_index = 1 };
    second.provider_thread_id.set("two");
    second.subject.set("Second window");
    _ = model.addThread(second);
    model.selectThread(0);
    model.openSelectedWindow();
    model.selectThread(1);
    model.openSelectedWindow();

    var scratch: main.MailApp.WindowsScratch = .{};
    const windows = main.mailWindows(&model, &scratch);
    try std.testing.expectEqual(@as(usize, 2), windows.len);
    try std.testing.expectEqualStrings("First window", windows[0].title);
    try std.testing.expectEqualStrings("Second window", windows[1].title);
    try std.testing.expect(!std.mem.eql(u8, windows[0].canvas_label, windows[1].canvas_label));
}

test "three message windows and one composer fit the Native SDK window budget" {
    var model = main.initialModel();
    for (0..3) |index| {
        var thread = mail.MailThread{ .account_index = index };
        var id_buffer: [32]u8 = undefined;
        thread.provider_thread_id.set(std.fmt.bufPrint(&id_buffer, "window-{d}", .{index}) catch "window");
        thread.subject.set(std.fmt.bufPrint(&id_buffer, "Message {d}", .{index}) catch "Message");
        _ = model.addThread(thread);
        model.selectThread(index);
        model.openSelectedWindow();
    }
    model.beginNewCompose();
    var scratch: main.MailApp.WindowsScratch = .{};
    const windows = main.mailWindows(&model, &scratch);
    try std.testing.expectEqual(@as(usize, 4), windows.len);
    try std.testing.expectEqualStrings("compose", windows[3].label);
    try std.testing.expectEqualStrings("compose-canvas", windows[3].canvas_label);
}

test "inbox windows keep independent presentation state over one shared mail store" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.addAccount(.gmail, "alpha@example.com", "Alpha", "", "");
    model.addAccount(.microsoft, "beta@example.com", "Beta", "", "");

    var alpha = mail.MailThread{ .account_index = 0, .unread = true };
    alpha.provider_thread_id.set("alpha-thread");
    alpha.subject.set("Alpha message");
    _ = model.addThread(alpha);

    var beta = mail.MailThread{ .account_index = 1 };
    beta.provider_thread_id.set("beta-thread");
    beta.subject.set("Beta message");
    _ = model.addThread(beta);

    model.openInboxWindow(mail.max_accounts);
    model.openInboxWindow(0);
    try std.testing.expectEqual(@as(usize, 2), model.inbox_window_count);

    const all_id = model.inbox_windows[0].id;
    const alpha_id = model.inbox_windows[1].id;
    model.setInboxWindowFilter(.{ .window_id = alpha_id, .filter = .unread });

    try std.testing.expectEqual(mail.InboxFilter.all, model.inbox_windows[0].filter);
    try std.testing.expectEqual(mail.InboxFilter.unread, model.inbox_windows[1].filter);
    try std.testing.expectEqual(@as(usize, 2), model.inboxWindowThreads(&model.inbox_windows[0], arena).len);
    try std.testing.expectEqual(@as(usize, 1), model.inboxWindowThreads(&model.inbox_windows[1], arena).len);
    try std.testing.expectEqualStrings("Alpha message", model.inboxWindowThreads(&model.inbox_windows[1], arena)[0].subject);

    const main_selection = model.selected_thread;
    model.openInboxWindowThread(.{ .window_id = all_id, .thread_id = model.threads[1].id.value });
    try std.testing.expect(model.inbox_windows[0].reading);
    try std.testing.expectEqual(model.threads[1].id.value, model.inbox_windows[0].selected_thread_id.value);
    try std.testing.expectEqual(main_selection, model.selected_thread);
    model.closeInboxWindowThread(all_id);
    try std.testing.expect(!model.inbox_windows[0].reading);
    try std.testing.expectEqual(model.threads[1].id.value, model.inbox_windows[0].selected_thread_id.value);

    model.closeInboxWindow(all_id);
    try std.testing.expectEqual(@as(usize, 1), model.inbox_window_count);
    try std.testing.expectEqual(alpha_id, model.inbox_windows[0].id);
    try std.testing.expectEqual(@as(usize, 2), model.thread_count);
}

test "archive mutation is immediately reflected by every inbox window" {
    var model = main.initialModel();
    model.addAccount(.gmail, "alpha@example.com", "Alpha", "", "");

    var thread = mail.MailThread{ .account_index = 0, .unread = true };
    thread.provider_thread_id.set("shared-archive-thread");
    thread.provider_message_id.set("shared-archive-message");
    thread.subject.set("Shared archive");
    _ = model.addThread(thread);

    model.openInboxWindow(mail.max_accounts);
    model.openInboxWindow(0);
    try std.testing.expectEqual(@as(usize, 1), model.inboxWindowCount(&model.inbox_windows[0], .all));
    try std.testing.expectEqual(@as(usize, 1), model.inboxWindowCount(&model.inbox_windows[1], .all));

    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(&model, .archive_selected, &fx);

    try std.testing.expectEqual(@as(usize, 0), model.inboxWindowCount(&model.inbox_windows[0], .all));
    try std.testing.expectEqual(@as(usize, 0), model.inboxWindowCount(&model.inbox_windows[1], .all));
    try std.testing.expectEqual(@as(usize, 1), model.inboxWindowCount(&model.inbox_windows[0], .archive));
    try std.testing.expectEqual(@as(usize, 1), model.inboxWindowCount(&model.inbox_windows[1], .archive));
}

test "native commands expose new inbox window and command palette" {
    try std.testing.expectEqual(main.Msg.open_all_inbox_window, main.onCommand("mail.new-window").?);
    try std.testing.expectEqual(main.Msg.toggle_command_palette, main.onCommand("mail.command-palette").?);
    try std.testing.expectEqual(main.Msg.cycle_split_next, main.onCommand("mail.next-split").?);
    try std.testing.expectEqual(main.Msg.cycle_split_previous, main.onCommand("mail.previous-split").?);
}

test "command palette starts on a keyboard-operable command row" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model = main.initialModel();
    model.command_palette_open = true;

    const tree = try buildTree(arena, &model);
    const first = findByLabel(tree.root, .list_item, "Compose") orelse return error.WidgetNotFound;
    try std.testing.expect(first.autofocus);
    try std.testing.expect(first.semantics.actions.press);
    const enter = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "enter" };
    try std.testing.expectEqual(main.Msg.activate_context, tree.msgForKeyboard(first.id, enter).?);
}

test "command palette owns arrow navigation and activation" {
    var model = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    const inbox_selection = model.selected_thread;

    main.update(&model, .toggle_command_palette, &fx);
    main.update(&model, .navigate_next, &fx);
    try std.testing.expectEqual(@as(usize, 1), model.palette_selected);
    try std.testing.expectEqual(inbox_selection, model.selected_thread);

    main.update(&model, .activate_context, &fx);
    try std.testing.expect(!model.command_palette_open);
    try std.testing.expect(model.search_visible);
    try std.testing.expect(model.search_requested);
}

test "tab commands cycle the primary split inboxes" {
    var model = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    try std.testing.expectEqual(mail.InboxFilter.all, model.filter);
    main.update(&model, .cycle_split_next, &fx);
    try std.testing.expectEqual(mail.InboxFilter.unread, model.filter);
    main.update(&model, .cycle_split_previous, &fx);
    try std.testing.expectEqual(mail.InboxFilter.all, model.filter);
    main.update(&model, .cycle_split_previous, &fx);
    try std.testing.expectEqual(mail.InboxFilter.notifications, model.filter);
}

test "archive action queues the provider mutation and rolls back" {
    var model = main.initialModel();
    var thread = mail.MailThread{ .account_index = 0, .unread = true };
    thread.provider_thread_id.set("thread-archive");
    thread.provider_message_id.set("message-archive");
    _ = model.addThread(thread);
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .archive_selected, &fx);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());
    const request = fx.pendingFetchAt(0) orelse return error.FetchNotFound;
    try std.testing.expectEqual(std.http.Method.POST, request.method);
    try std.testing.expect(std.mem.endsWith(u8, request.url, "/gmail/v1/users/me/threads/thread-archive/modify"));
    try std.testing.expect(std.mem.indexOf(u8, request.body, "removeLabelIds") != null);
    try std.testing.expect(!model.threads[0].in_inbox);

    const key = model.pending_mutations[0].key;
    model.finishMutation(key, false);
    try std.testing.expect(model.threads[0].in_inbox);
    try std.testing.expect(!model.threads[0].archived);
}

test "compose markup exposes native recipient subject body and send controls" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var model = main.initialModel();
    model.beginNewCompose();
    const tree = try buildComposeTree(arena_state.allocator(), &model);
    _ = findByText(tree.root, .text, "Compose") orelse return error.WidgetNotFound;
    _ = findByText(tree.root, .button, "Send") orelse return error.WidgetNotFound;
    _ = findByText(tree.root, .button, "Save draft") orelse return error.WidgetNotFound;
}

test "Gmail compose saves a provider draft then sends and removes it" {
    var model = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .compose_new, &fx);
    model.composer.to_buffer.set("customer@example.com");
    model.composer.subject_buffer.set("Native send");
    model.composer.body_buffer.set("Hello from Native SDK");
    main.update(&model, .compose_save, &fx);
    const created = fx.pendingFetchAt(0) orelse return error.FetchNotFound;
    try std.testing.expectEqual(std.http.Method.POST, created.method);
    try std.testing.expect(std.mem.endsWith(u8, created.url, "/gmail/v1/users/me/drafts"));
    try std.testing.expect(std.mem.indexOf(u8, created.body, "\"raw\"") != null);

    main.update(&model, .{ .outbound_response = .{
        .key = created.key,
        .outcome = .ok,
        .status = 201,
        .body = "{\"id\":\"draft-native-1\",\"message\":{\"id\":\"message-native-1\",\"threadId\":\"thread-native-1\"}}",
    } }, &fx);
    try std.testing.expectEqualStrings("draft-native-1", model.composer.provider_draft_id.slice());
    try std.testing.expectEqual(@as(usize, 1), model.draft_count);
    try std.testing.expect(model.drafts[0].remote);

    main.update(&model, .compose_send, &fx);
    // An unchanged provider draft is delivered directly so its original MIME
    // structure (including rich content and attachments) is not rewritten.
    const delivered = fx.pendingFetchAt(1) orelse return error.FetchNotFound;
    try std.testing.expectEqual(std.http.Method.POST, delivered.method);
    try std.testing.expect(std.mem.endsWith(u8, delivered.url, "/gmail/v1/users/me/drafts/send"));
    main.update(&model, .{ .outbound_response = .{
        .key = delivered.key,
        .outcome = .ok,
        .status = 200,
        .body = "{\"id\":\"sent-native-1\",\"threadId\":\"thread-native-1\"}",
    } }, &fx);
    try std.testing.expect(!model.composeOpen());
    try std.testing.expectEqual(@as(usize, 0), model.draft_count);
    try std.testing.expectEqualStrings("Email sent.", model.statusMessage());
}

test "Outlook reply creates a threaded draft before patching its content" {
    var model = main.initialModel();
    var thread = mail.MailThread{ .account_index = 2, .provider = .microsoft };
    thread.provider_thread_id.set("graph-message-1");
    thread.provider_message_id.set("graph-message-1");
    thread.sender.set("Partner");
    thread.sender_email.set("partner@example.com");
    thread.subject.set("Graph status");
    _ = model.addThread(thread);
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .compose_reply, &fx);
    model.composer.body_buffer.set("Thanks");
    main.update(&model, .compose_save, &fx);
    const created = fx.pendingFetchAt(0) orelse return error.FetchNotFound;
    try std.testing.expect(std.mem.endsWith(u8, created.url, "/v1.0/me/messages/graph-message-1/createReply"));
    main.update(&model, .{ .outbound_response = .{
        .key = created.key,
        .outcome = .ok,
        .status = 201,
        .body = "{\"id\":\"graph-draft-1\",\"conversationId\":\"graph-conversation-1\"}",
    } }, &fx);
    const patched = fx.pendingFetchAt(1) orelse return error.FetchNotFound;
    try std.testing.expectEqual(std.http.Method.PATCH, patched.method);
    try std.testing.expect(std.mem.endsWith(u8, patched.url, "/v1.0/me/messages/graph-draft-1"));
}

test "Outlook forward creates a provider-threaded draft before patching" {
    var model = main.initialModel();
    var thread = mail.MailThread{ .account_index = 2, .provider = .microsoft };
    thread.provider_thread_id.set("graph-forward-source");
    thread.provider_message_id.set("graph-forward-source");
    thread.sender.set("Partner");
    thread.subject.set("Forward this");
    thread.body.set("Original body");
    _ = model.addThread(thread);
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .compose_forward, &fx);
    model.composer.to_buffer.set("recipient@example.com");
    main.update(&model, .compose_save, &fx);
    const created = fx.pendingFetchAt(0) orelse return error.FetchNotFound;
    try std.testing.expect(std.mem.endsWith(u8, created.url, "/v1.0/me/messages/graph-forward-source/createForward"));
    main.update(&model, .{ .outbound_response = .{
        .key = created.key,
        .outcome = .ok,
        .status = 201,
        .body = "{\"id\":\"graph-forward-draft\",\"conversationId\":\"graph-conversation\"}",
    } }, &fx);
    const patched = fx.pendingFetchAt(1) orelse return error.FetchNotFound;
    try std.testing.expectEqual(std.http.Method.PATCH, patched.method);
    try std.testing.expect(std.mem.endsWith(u8, patched.url, "/v1.0/me/messages/graph-forward-draft"));
    try std.testing.expect(std.mem.indexOf(u8, patched.body, "Forwarded message") != null);
}

test "new compose never overwrites or discards the selected saved draft" {
    var model = main.initialModel();
    var existing = mail.Draft{ .account_index = 0, .account_id = model.accounts[0].id, .remote = true };
    existing.provider_draft_id.set("existing-provider-draft");
    existing.subject.set("Existing draft");
    const existing_index = model.addDraft(existing) orelse return error.DraftNotAdded;
    const existing_id = model.drafts[existing_index].id;
    model.selectDraft(existing_index);

    model.beginNewCompose();
    model.composer.to_buffer.set("new@example.com");
    model.composer.subject_buffer.set("Brand new message");
    _ = model.snapshotComposer(false);

    try std.testing.expectEqual(@as(usize, 2), model.draft_count);
    try std.testing.expectEqual(existing_id.value, model.drafts[existing_index].id.value);
    try std.testing.expectEqualStrings("Existing draft", model.drafts[existing_index].subject.slice());
    try std.testing.expect(model.composer.draft_id.isValid());
    try std.testing.expect(model.composer.draft_id.value != existing_id.value);

    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(&model, .compose_discard, &fx);
    try std.testing.expectEqual(@as(usize, 1), model.draft_count);
    try std.testing.expectEqual(existing_id.value, model.drafts[0].id.value);
}

test "a pending save blocks duplicate saves and a replacement composer" {
    var model = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .compose_new, &fx);
    model.composer.to_buffer.set("recipient@example.com");
    model.composer.subject_buffer.set("Pending save");
    main.update(&model, .compose_save_close, &fx);
    const operation_id = model.composer.operation_id;
    try std.testing.expect(!model.composeOpen());
    try std.testing.expect(model.composeBusy());
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());

    main.update(&model, .compose_save, &fx);
    main.update(&model, .compose_new, &fx);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());
    try std.testing.expectEqual(operation_id.value, model.composer.operation_id.value);
    try std.testing.expectEqualStrings("Pending save", model.composer.subject());

    const request = fx.pendingFetchAt(0) orelse return error.FetchNotFound;
    main.update(&model, .{ .outbound_response = .{
        .key = request.key,
        .outcome = .ok,
        .status = 201,
        .body = "{\"id\":\"saved-one\",\"message\":{\"id\":\"saved-message\"}}",
    } }, &fx);
    try std.testing.expect(!model.composeBusy());
    main.update(&model, .compose_new, &fx);
    try std.testing.expect(model.composeOpen());
}

test "failed save-and-close reopens the intact draft for recovery" {
    var model = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(&model, .compose_new, &fx);
    model.composer.to_buffer.set("recipient@example.com");
    model.composer.subject_buffer.set("Recover me");
    main.update(&model, .compose_save_close, &fx);
    const request = fx.pendingFetchAt(0) orelse return error.FetchNotFound;
    main.update(&model, .{ .outbound_response = .{
        .key = request.key,
        .outcome = .ok,
        .status = 500,
        .body = "server error",
    } }, &fx);
    try std.testing.expect(model.composeOpen());
    try std.testing.expectEqual(.failed, model.composer.state);
    try std.testing.expectEqualStrings("Recover me", model.composer.subject());
    try std.testing.expectEqual(@as(usize, 1), model.draft_count);
}

test "edits arriving during save are sent in a follow-up update" {
    var model = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .compose_new, &fx);
    model.composer.to_buffer.set("recipient@example.com");
    model.composer.subject_buffer.set("Revision one");
    model.composer.markEdited();
    main.update(&model, .compose_save, &fx);
    const created = fx.pendingFetchAt(0) orelse return error.FetchNotFound;
    model.composer.subject_buffer.set("Revision two");
    model.composer.markEdited();

    main.update(&model, .{ .outbound_response = .{
        .key = created.key,
        .outcome = .ok,
        .status = 201,
        .body = "{\"id\":\"revision-draft\",\"message\":{\"id\":\"revision-message\"}}",
    } }, &fx);
    try std.testing.expectEqual(@as(usize, 2), fx.pendingFetchCount());
    try std.testing.expect(model.composer.dirty);
    try std.testing.expectEqual(.saving, model.composer.state);
    const updated = fx.pendingFetchAt(1) orelse return error.FetchNotFound;
    try std.testing.expectEqual(std.http.Method.PUT, updated.method);

    main.update(&model, .{ .outbound_response = .{
        .key = updated.key,
        .outcome = .ok,
        .status = 200,
        .body = "{\"id\":\"revision-draft\",\"message\":{\"id\":\"revision-message\"}}",
    } }, &fx);
    try std.testing.expect(!model.composer.dirty);
    try std.testing.expectEqual(.saved, model.composer.state);
    try std.testing.expectEqualStrings("Revision two", model.drafts[model.selected_draft].subject.slice());
}

test "draft search and keyboard navigation operate on visible drafts" {
    var model = main.initialModel();
    var first = mail.Draft{ .account_index = 0, .account_id = model.accounts[0].id };
    first.subject.set("Quarterly plan");
    _ = model.addDraft(first);
    var second = mail.Draft{ .account_index = 1, .account_id = model.accounts[1].id };
    second.subject.set("Customer follow-up");
    _ = model.addDraft(second);
    model.selectFilter(.drafts);
    model.search_buffer.set("customer");
    model.reconcileSelection();
    try std.testing.expectEqual(@as(usize, 1), model.visibleDraftCount());
    try std.testing.expectEqual(@as(usize, 1), model.selected_draft);
    model.selectRelative(-1);
    try std.testing.expectEqual(@as(usize, 1), model.selected_draft);
}

test "reply targets Reply-To ahead of From" {
    var model = main.initialModel();
    var thread = mail.MailThread{ .account_index = 0, .provider = .gmail };
    thread.provider_thread_id.set("reply-to-thread");
    thread.provider_message_id.set("reply-to-message");
    thread.sender_email.set("sender@example.com");
    thread.reply_to.set("Replies <reply-here@example.com>");
    thread.subject.set("Reply target");
    _ = model.addThread(thread);
    model.beginMessageCompose(.reply);
    try std.testing.expectEqualStrings("Replies <reply-here@example.com>", model.composer.to());
}

test "draft capacity stops outbound creation without losing the composer" {
    var model = main.initialModel();
    for (0..mail.max_drafts) |index| {
        var draft = mail.Draft{ .account_index = 0, .account_id = model.accounts[0].id };
        var subject: [32]u8 = undefined;
        draft.subject.set(std.fmt.bufPrint(&subject, "Draft {d}", .{index}) catch "Draft");
        _ = model.addDraft(draft);
    }
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(&model, .compose_new, &fx);
    model.composer.to_buffer.set("recipient@example.com");
    model.composer.subject_buffer.set("One too many");
    main.update(&model, .compose_save, &fx);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingFetchCount());
    try std.testing.expectEqual(.failed, model.composer.state);
    try std.testing.expect(model.composeOpen());
    try std.testing.expectEqual(@as(usize, mail.max_drafts), model.draft_count);
}

test "stale refresh draft cannot overwrite a newer local snapshot" {
    var model = main.initialModel();
    var local = mail.Draft{ .account_index = 0, .account_id = model.accounts[0].id, .remote = false };
    local.provider_draft_id.set("shared-provider-id");
    local.subject.set("New local revision");
    const index = model.addDraft(local) orelse return error.DraftNotAdded;
    const stable_id = model.drafts[index].id;

    var stale = mail.Draft{ .account_index = 0, .account_id = model.accounts[0].id, .remote = true };
    stale.provider_draft_id.set("shared-provider-id");
    stale.subject.set("Old provider revision");
    _ = model.addDraft(stale);

    try std.testing.expectEqual(@as(usize, 1), model.draft_count);
    try std.testing.expectEqual(stable_id.value, model.drafts[0].id.value);
    try std.testing.expectEqualStrings("New local revision", model.drafts[0].subject.slice());
    try std.testing.expect(!model.drafts[0].remote);
}

test "disconnect removes the requested account even if selection changes" {
    var model = main.initialModel();
    const removed_id = model.accounts[0].id;
    const retained_id = model.accounts[1].id;
    model.accounts[0].credential_key.set("gmail:test-account");
    model.selectAccount(0);
    _ = model.beginDisconnect() orelse return error.DisconnectNotStarted;
    model.beginNewCompose();
    try std.testing.expectEqual(removed_id.value, model.composer.account_id.value);

    model.selectAccount(1);
    model.removeDisconnectedAccount();

    try std.testing.expect(model.accountIndexById(removed_id) == null);
    try std.testing.expect(model.accountIndexById(retained_id) != null);
    try std.testing.expect(!model.composeOpen());
    try std.testing.expectEqual(@as(u64, 0), model.disconnect_key);
    try std.testing.expect(!model.disconnect_account_id.isValid());
}

test "restore distinguishes empty slots from credential failures" {
    var model = mail.emptyModel();
    model.restore_pending = mail.max_accounts;
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    for (0..mail.max_accounts) |index| {
        const bytes: []const u8 = if (index == 1) "credentials_unavailable" else "session_not_found";
        main.update(&model, .{ .oauth_restore_response = .{
            .key = 0x6000_0000_0000_0000 + index,
            .ok = false,
            .bytes = bytes,
        } }, &fx);
    }

    try std.testing.expect(model.restore_failed);
    try std.testing.expect(std.mem.indexOf(u8, model.status_message.slice(), "could not be restored") != null);
}

test "OAuth authorization can be cancelled without leaving the model busy" {
    var model = mail.emptyModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    model.oauth_busy = true;
    model.oauth_key = 77;

    main.update(&model, .cancel_oauth, &fx);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingHostCount());
    const request = fx.pendingHostAt(0) orelse return error.CancelRequestMissing;
    try std.testing.expectEqual(@as(u64, 77), request.key);
    try std.testing.expectEqualStrings("inbox-zero.oauth.cancel.v1", request.name);

    main.update(&model, .{ .oauth_response = .{ .key = 77, .ok = false, .bytes = "Authorization cancelled." } }, &fx);
    try std.testing.expect(!model.oauth_busy);
    try std.testing.expectEqualStrings("Authorization cancelled.", model.status_message.slice());
}
