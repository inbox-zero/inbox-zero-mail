const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const mail = @import("model.zig");
const providers = @import("providers.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

pub const canvas_label = "mail-canvas";
pub const window_width: f32 = 1280;
pub const window_height: f32 = 780;
pub const window_min_width: f32 = 860;
pub const window_min_height: f32 = 560;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{
        .label = canvas_label,
        .kind = .gpu_surface,
        .fill = true,
        .role = "Inbox Zero Mail canvas",
        .accessibility_label = "Inbox Zero Mail",
        .gpu_backend = if (builtin.os.tag == .macos) .metal else .software,
        .gpu_pixel_format = .bgra8_unorm,
        .gpu_present_mode = .timer,
        .gpu_alpha_mode = .@"opaque",
        .gpu_color_space = .srgb,
        .gpu_vsync = true,
    },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Inbox Zero Mail",
    .width = window_width,
    .height = window_height,
    .min_width = window_min_width,
    .min_height = window_min_height,
    .restore_state = true,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

pub const Msg = union(enum) {
    select_account: usize,
    set_filter: mail.InboxFilter,
    select_thread: usize,
    select_next,
    select_previous,
    search_edit: canvas.TextInputEvent,
    focus_search,
    refresh,
    sidebar_resized: f32,
    list_resized: f32,
    archive_selected,
    trash_selected,
    toggle_read_selected,
    toggle_star_selected,
    snooze_selected,
    open_selected_window,
    close_window: usize,
    initial_response: native_sdk.EffectResponse,
    gmail_detail_response: native_sdk.EffectResponse,
    mutation_response: native_sdk.EffectResponse,

    pub const view_unbound = .{
        "select_next",
        "select_previous",
        "focus_search",
        "close_window",
        "initial_response",
        "gmail_detail_response",
        "mutation_response",
    };
};

pub const Model = mail.Model;
pub const MailApp = native_sdk.UiAppWithFeatures(Model, Msg, .{ .runtime_markup = builtin.mode == .Debug });
pub const Effects = MailApp.Effects;
pub const app_markup = @embedFile("app.native");
pub const CompiledAppView = canvas.CompiledMarkupView(Model, Msg, app_markup);

pub fn initialModel() Model {
    return mail.initialModel();
}

pub fn boot(model: *Model, fx: *Effects) void {
    providers.startInitialSync(model, fx, Effects.responseMsg(.initial_response));
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .select_account => |index| model.selectAccount(index),
        .set_filter => |filter| model.selectFilter(filter),
        .select_thread => |index| model.selectThread(index),
        .select_next => model.selectRelative(1),
        .select_previous => model.selectRelative(-1),
        .search_edit => |edit| {
            model.search_buffer.apply(edit);
            model.search_requested = false;
            model.reconcileSelection();
        },
        .focus_search => model.search_requested = true,
        .refresh => {
            model.status_message.set("Refreshing all accounts.");
            providers.startInitialSync(model, fx, Effects.responseMsg(.initial_response));
        },
        .sidebar_resized => |fraction| model.sidebar_split = fraction,
        .list_resized => |fraction| model.list_split = fraction,
        .archive_selected => performMutation(model, .archive, fx),
        .trash_selected => performMutation(model, .trash, fx),
        .toggle_read_selected => performMutation(model, .toggle_read, fx),
        .toggle_star_selected => performMutation(model, .toggle_star, fx),
        .snooze_selected => {
            if (model.selectedMut()) |thread| {
                thread.snoozed = !thread.snoozed;
                model.status_message.set(if (thread.snoozed) "Message snoozed locally." else "Message returned from snooze.");
                model.reconcileSelection();
            }
        },
        .open_selected_window => model.openSelectedWindow(),
        .close_window => |index| model.closeWindow(index),
        .initial_response => |response| providers.handleInitialResponse(model, response, fx, Effects.responseMsg(.gmail_detail_response)),
        .gmail_detail_response => |response| providers.handleGmailDetailResponse(model, response, fx, Effects.responseMsg(.gmail_detail_response)),
        .mutation_response => |response| providers.handleMutationResponse(model, response),
    }
}

fn performMutation(model: *Model, operation: providers.MutationOperation, fx: *Effects) void {
    if (!model.hasSelection()) return;
    const thread_index = model.selected_thread;
    const key = model.beginMutation(thread_index) orelse {
        model.status_message.set("Too many mail actions are already running.");
        return;
    };
    const thread = &model.threads[thread_index];
    const account = &model.accounts[thread.account_index];
    if (!providers.fetchMutation(fx, key, thread.provider, operation, account, thread, Effects.responseMsg(.mutation_response))) {
        model.finishMutation(key, false);
        return;
    }
    switch (operation) {
        .archive => {
            thread.in_inbox = false;
            thread.archived = true;
            model.status_message.set("Archived message.");
        },
        .trash => {
            thread.in_inbox = false;
            thread.archived = false;
            thread.trashed = true;
            model.status_message.set("Moved message to trash.");
        },
        .toggle_read => {
            thread.unread = !thread.unread;
            model.status_message.set(if (thread.unread) "Marked message unread." else "Marked message read.");
        },
        .toggle_star => {
            thread.starred = !thread.starred;
            model.status_message.set(if (thread.starred) "Starred message." else "Removed star.");
        },
    }
    model.reconcileSelection();
}

pub fn onKey(keyboard: canvas.WidgetKeyboardEvent) ?Msg {
    if (keyboard.phase != .key_down) return null;
    const key = keyboard.key;
    if (keyboard.modifiers.hasNavigationModifier()) return null;
    if (keyboard.modifiers.shift) {
        if (std.ascii.eqlIgnoreCase(key, "u")) return .toggle_read_selected;
        return null;
    }
    if (std.ascii.eqlIgnoreCase(key, "j") or std.ascii.eqlIgnoreCase(key, "arrowdown")) return .select_next;
    if (std.ascii.eqlIgnoreCase(key, "k") or std.ascii.eqlIgnoreCase(key, "arrowup")) return .select_previous;
    if (std.ascii.eqlIgnoreCase(key, "enter") or std.ascii.eqlIgnoreCase(key, "o")) return .open_selected_window;
    if (std.ascii.eqlIgnoreCase(key, "e")) return .archive_selected;
    if (std.ascii.eqlIgnoreCase(key, "s")) return .toggle_star_selected;
    if (std.ascii.eqlIgnoreCase(key, "h")) return .snooze_selected;
    if (std.ascii.eqlIgnoreCase(key, "delete") or std.mem.eql(u8, key, "#")) return .trash_selected;
    if (std.mem.eql(u8, key, "/")) return .focus_search;
    return null;
}

pub fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, "mail.refresh")) return .refresh;
    if (std.mem.eql(u8, name, "mail.open-window")) return .open_selected_window;
    return null;
}

pub fn mailWindows(model: *const Model, scratch: *MailApp.WindowsScratch) []const MailApp.WindowDescriptor {
    var count: usize = 0;
    for (model.open_windows[0..model.open_window_count]) |thread_index| {
        if (thread_index >= model.thread_count or count >= scratch.windows.len) continue;
        const thread = &model.threads[thread_index];
        scratch.windows[count] = .{
            .label = thread.window_label.slice(),
            .canvas_label = thread.canvas_label.slice(),
            .title = thread.subjectSlice(),
            .width = 760,
            .height = 640,
            .min_width = 480,
            .min_height = 360,
            .on_close = Msg{ .close_window = thread_index },
        };
        count += 1;
    }
    return scratch.windows[0..count];
}

pub fn mailWindowView(ui: *MailApp.Ui, model: *const Model, window_label: []const u8) MailApp.Ui.Node {
    for (model.threads[0..model.thread_count]) |*thread| {
        if (std.mem.eql(u8, thread.window_label.slice(), window_label)) return detailWindow(ui, model, thread);
    }
    return ui.column(.{ .grow = 1, .padding = 24 }, .{
        ui.text(.{ .size = .heading }, "Message unavailable"),
        ui.text(.{ .wrap = true }, "The message backing this window is no longer in the synchronized store."),
    });
}

fn detailWindow(ui: *MailApp.Ui, model: *const Model, thread: *const mail.MailThread) MailApp.Ui.Node {
    const account = if (thread.account_index < model.account_count) model.accounts[thread.account_index].emailSlice() else "Unknown account";
    return ui.column(.{ .grow = 1, .style_tokens = .{ .background = .background } }, .{
        ui.column(.{ .padding = 20, .gap = 8, .style_tokens = .{ .background = .surface } }, .{
            ui.text(.{ .size = .heading, .wrap = true }, thread.subjectSlice()),
            ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, thread.senderSlice()),
        }),
        ui.el(.separator, .{}, .{}),
        ui.scroll(.{ .grow = 1 }, .{
            ui.column(.{ .padding = 24, .gap = 16 }, .{
                ui.text(.{ .wrap = true }, thread.bodySlice()),
            }),
        }),
        ui.el(.status_bar, .{ .text = ui.fmt("{s} | {s}", .{ account, if (thread.provider == .gmail) "Gmail" else "Outlook" }) }, .{}),
    });
}

pub fn main(init: std.process.Init) !void {
    const app_state = try MailApp.create(std.heap.page_allocator, .{
        .name = "inbox-zero-mail-native",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = boot,
        .on_key = onKey,
        .on_command = onCommand,
        .view = CompiledAppView.build,
        .markup = if (builtin.mode == .Debug)
            .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io }
        else
            null,
        .windows_fn = mailWindows,
        .window_view = mailWindowView,
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "inbox-zero-mail-native",
        .window_title = "Inbox Zero Mail",
        .bundle_id = "com.inboxzero.mail.native",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = true,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
    _ = @import("model.zig");
    _ = @import("providers.zig");
}
