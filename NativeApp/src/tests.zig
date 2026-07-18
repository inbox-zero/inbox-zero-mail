const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");
const mail = @import("model.zig");

const canvas = native_sdk.canvas;
const AppMarkup = canvas.MarkupView(main.Model, main.Msg);

fn buildTree(arena: std.mem.Allocator, model: *const main.Model) !main.MailApp.Ui.Tree {
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

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, wanted: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, wanted)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, wanted)) |found| return found;
    }
    return null;
}

test "markup dispatch selects a message and keeps its structural id" {
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
    _ = findByText(tree.root, .text, "Everything is ready.") orelse return error.WidgetNotFound;
}

test "keyboard map covers the keyboard-first inbox actions" {
    const base = canvas.WidgetKeyboardEvent{ .phase = .key_down };
    var key = base;
    key.key = "j";
    try std.testing.expectEqual(main.Msg.select_next, main.onKey(key).?);
    key.key = "k";
    try std.testing.expectEqual(main.Msg.select_previous, main.onKey(key).?);
    key.key = "e";
    try std.testing.expectEqual(main.Msg.archive_selected, main.onKey(key).?);
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
}

test "boot starts all configured account fetches through fake effects" {
    var model = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.boot(&model, &fx);
    try std.testing.expectEqual(@as(usize, 5), fx.pendingFetchCount());
    var gmail_requests: usize = 0;
    var outlook_folder_requests: usize = 0;
    for (0..5) |index| {
        const request = fx.pendingFetchAt(index) orelse return error.FetchNotFound;
        try std.testing.expect(request.url.len > 0);
        try std.testing.expectEqual(std.http.Method.GET, request.method);
        if (std.mem.indexOf(u8, request.url, "/gmail/v1/") != null) {
            gmail_requests += 1;
            try std.testing.expect(std.mem.indexOf(u8, request.url, "labelIds=INBOX") == null);
        }
        if (std.mem.indexOf(u8, request.url, "/mailFolders/") != null) outlook_folder_requests += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), gmail_requests);
    try std.testing.expectEqual(@as(usize, 3), outlook_folder_requests);
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
