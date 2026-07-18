const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const mail = @import("model.zig");
const providers = @import("providers.zig");
const outbound = @import("app/outbound.zig");
const native_services = @import("platform/native_services.zig");
const oauth_wire = @import("auth/wire.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

pub const canvas_label = "mail-canvas";
pub const window_width: f32 = 1280;
pub const window_height: f32 = 780;
pub const window_min_width: f32 = 860;
pub const window_min_height: f32 = 560;

const app_permissions = [_][]const u8{
    native_sdk.security.permission_command,
    native_sdk.security.permission_view,
    native_sdk.security.permission_network,
    native_sdk.security.permission_credentials,
};
const oauth_external_urls = [_][]const u8{
    "https://accounts.google.com/*",
    "https://login.microsoftonline.com/*",
    "http://127.0.0.1:4402/*",
    "http://127.0.0.1:4403/*",
};
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
    connect_gmail,
    connect_outlook,
    cancel_oauth,
    disconnect_selected,
    oauth_response: native_sdk.EffectHostResult,
    disconnect_response: native_sdk.EffectHostResult,
    oauth_restore_response: native_sdk.EffectHostResult,
    sidebar_resized: f32,
    list_resized: f32,
    archive_selected,
    trash_selected,
    toggle_read_selected,
    toggle_star_selected,
    snooze_selected,
    open_selected_window,
    activate_selected,
    close_window: usize,
    compose_new,
    compose_reply,
    compose_reply_all,
    compose_forward,
    compose_close,
    compose_discard,
    compose_toggle_cc_bcc,
    compose_select_account: usize,
    compose_to_edit: canvas.TextInputEvent,
    compose_cc_edit: canvas.TextInputEvent,
    compose_bcc_edit: canvas.TextInputEvent,
    compose_subject_edit: canvas.TextInputEvent,
    compose_body_edit: canvas.TextInputEvent,
    compose_save,
    compose_save_close,
    compose_send,
    open_draft: usize,
    compose_autosave: native_sdk.EffectTimer,
    outbound_response: native_sdk.EffectResponse,
    initial_response: native_sdk.EffectResponse,
    gmail_detail_response: native_sdk.EffectResponse,
    mutation_response: native_sdk.EffectResponse,
    authorized_initial_response: native_sdk.EffectHostResult,
    authorized_gmail_detail_response: native_sdk.EffectHostResult,
    authorized_mutation_response: native_sdk.EffectHostResult,
    authorized_outbound_response: native_sdk.EffectHostResult,

    pub const view_unbound = .{
        "select_next",
        "select_previous",
        "activate_selected",
        "focus_search",
        "close_window",
        "initial_response",
        "gmail_detail_response",
        "mutation_response",
        "oauth_response",
        "disconnect_response",
        "oauth_restore_response",
        "authorized_initial_response",
        "authorized_gmail_detail_response",
        "authorized_mutation_response",
        "authorized_outbound_response",
        "compose_close",
        "compose_autosave",
        "outbound_response",
    };
};

pub const Model = mail.Model;
pub const MailApp = native_sdk.UiAppWithFeatures(Model, Msg, .{ .runtime_markup = builtin.mode == .Debug });
pub const Effects = MailApp.Effects;
pub const app_markup = @embedFile("app.native");
pub const compose_markup = @embedFile("ui/compose.native");
pub const CompiledAppView = canvas.CompiledMarkupView(Model, Msg, app_markup);
pub const CompiledComposeView = canvas.CompiledMarkupView(Model, Msg, compose_markup);

pub fn initialModel() Model {
    return mail.initialModel();
}

fn productionInitialModel(init: std.process.Init) Model {
    const value = init.environ_map.get("INBOX_ZERO_EMULATE") orelse return mail.emptyModel();
    if (std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true")) return mail.initialModel();
    return mail.emptyModel();
}

fn oauthSettings(init: std.process.Init) native_services.OAuthSettings {
    const emulate_value = init.environ_map.get("INBOX_ZERO_EMULATE") orelse "";
    const emulate = std.mem.eql(u8, emulate_value, "1") or std.ascii.eqlIgnoreCase(emulate_value, "true");
    return .{
        .emulate = emulate,
        .gmail_client_id = init.environ_map.get(if (emulate) "INBOX_ZERO_GMAIL_EMULATOR_CLIENT_ID" else "INBOX_ZERO_GMAIL_CLIENT_ID") orelse "",
        .gmail_client_secret = init.environ_map.get(if (emulate) "INBOX_ZERO_GMAIL_EMULATOR_CLIENT_SECRET" else "INBOX_ZERO_GMAIL_CLIENT_SECRET") orelse "",
        .microsoft_client_id = init.environ_map.get(if (emulate) "INBOX_ZERO_OUTLOOK_EMULATOR_CLIENT_ID" else "INBOX_ZERO_OUTLOOK_CLIENT_ID") orelse "",
        .microsoft_client_secret = init.environ_map.get(if (emulate) "INBOX_ZERO_OUTLOOK_EMULATOR_CLIENT_SECRET" else "INBOX_ZERO_OUTLOOK_CLIENT_SECRET") orelse "",
    };
}

pub fn boot(model: *Model, fx: *Effects) void {
    if (model.account_count > 0) {
        providers.startInitialSync(model, fx, Effects.responseMsg(.initial_response), Effects.hostMsg(.authorized_initial_response));
        return;
    }
    model.restore_failed = false;
    model.restore_pending = mail.max_accounts;
    for (0..mail.max_accounts) |index| {
        var payload = [_]u8{'0'};
        payload[0] += @intCast(index);
        fx.hostRequest(.{
            .key = 0x6000_0000_0000_0000 + index,
            .name = oauth_wire.service_restore,
            .payload = &payload,
            .on_result = Effects.hostMsg(.oauth_restore_response),
        });
    }
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
            providers.startInitialSync(model, fx, Effects.responseMsg(.initial_response), Effects.hostMsg(.authorized_initial_response));
        },
        .connect_gmail => beginOAuth(model, fx, .gmail),
        .connect_outlook => beginOAuth(model, fx, .microsoft),
        .cancel_oauth => {
            if (!model.oauth_busy or model.oauth_key == 0) return;
            model.status_message.set("Cancelling authorization.");
            fx.hostRequest(.{ .key = model.oauth_key, .name = oauth_wire.service_cancel, .payload = "", .on_result = Effects.hostMsg(.oauth_response) });
        },
        .disconnect_selected => {
            const request = model.beginDisconnect() orelse return;
            model.status_message.set("Disconnecting account.");
            fx.hostRequest(.{ .key = request.key, .name = oauth_wire.service_disconnect, .payload = request.session_key, .on_result = Effects.hostMsg(.disconnect_response) });
        },
        .oauth_response => |result| handleOAuthResult(model, result, fx),
        .oauth_restore_response => |result| handleRestoreResult(model, result, fx),
        .disconnect_response => |result| {
            if (result.key != model.disconnect_key) return;
            if (!result.ok) {
                model.oauth_busy = false;
                model.disconnect_key = 0;
                model.disconnect_account_id = .{};
                model.status_message.set("The account could not be disconnected.");
                return;
            }
            model.removeDisconnectedAccount();
            model.status_message.set("Account disconnected and credential removed.");
            if (model.account_count > 0) providers.startInitialSync(model, fx, Effects.responseMsg(.initial_response), Effects.hostMsg(.authorized_initial_response));
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
        .activate_selected => model.activateSelected(),
        .close_window => |index| model.closeWindow(index),
        .compose_new => if (!model.composeBusy()) model.beginNewCompose(),
        .compose_reply => if (!model.composeBusy()) model.beginMessageCompose(.reply),
        .compose_reply_all => if (!model.composeBusy()) model.beginMessageCompose(.reply_all),
        .compose_forward => if (!model.composeBusy()) model.beginMessageCompose(.forward),
        .compose_close => outbound.save(model, fx, Effects.responseMsg(.outbound_response), Effects.hostMsg(.authorized_outbound_response), true),
        .compose_discard => outbound.discard(model, fx, Effects.responseMsg(.outbound_response), Effects.hostMsg(.authorized_outbound_response)),
        .compose_toggle_cc_bcc => model.composer.cc_bcc_visible = !model.composer.cc_bcc_visible,
        .compose_select_account => |index| {
            if (!model.composeAccountLocked() and index < model.account_count) {
                model.composer.account_index = index;
                model.composer.account_id = model.accounts[index].id;
                model.composer.markEdited();
            }
        },
        .compose_to_edit => |edit| applyComposeEdit(model, fx, .to, edit),
        .compose_cc_edit => |edit| applyComposeEdit(model, fx, .cc, edit),
        .compose_bcc_edit => |edit| applyComposeEdit(model, fx, .bcc, edit),
        .compose_subject_edit => |edit| applyComposeEdit(model, fx, .subject, edit),
        .compose_body_edit => |edit| applyComposeEdit(model, fx, .body, edit),
        .compose_save => outbound.save(model, fx, Effects.responseMsg(.outbound_response), Effects.hostMsg(.authorized_outbound_response), false),
        .compose_save_close => outbound.save(model, fx, Effects.responseMsg(.outbound_response), Effects.hostMsg(.authorized_outbound_response), true),
        .compose_send => outbound.send(model, fx, Effects.responseMsg(.outbound_response), Effects.hostMsg(.authorized_outbound_response)),
        .open_draft => |id| if (!model.composeBusy()) model.openDraftById(id),
        .compose_autosave => |timer| if (timer.outcome == .fired and model.composer.dirty)
            outbound.save(model, fx, Effects.responseMsg(.outbound_response), Effects.hostMsg(.authorized_outbound_response), false),
        .outbound_response => |response| {
            const sync_was_in_flight = model.syncInFlight();
            if (outbound.handleResponse(model, response, fx, Effects.responseMsg(.outbound_response), Effects.hostMsg(.authorized_outbound_response)) and sync_was_in_flight) {
                providers.startInitialSync(model, fx, Effects.responseMsg(.initial_response), Effects.hostMsg(.authorized_initial_response));
            }
        },
        .initial_response => |response| providers.handleInitialResponse(model, response, fx, Effects.responseMsg(.gmail_detail_response), Effects.hostMsg(.authorized_gmail_detail_response)),
        .gmail_detail_response => |response| providers.handleGmailDetailResponse(model, response, fx, Effects.responseMsg(.gmail_detail_response), Effects.hostMsg(.authorized_gmail_detail_response)),
        .mutation_response => |response| providers.handleMutationResponse(model, response),
        .authorized_initial_response => |result| {
            providers.handleInitialResponse(model, authorizedResponse(result), fx, Effects.responseMsg(.gmail_detail_response), Effects.hostMsg(.authorized_gmail_detail_response));
            showReconnectIfNeeded(model, result);
        },
        .authorized_gmail_detail_response => |result| {
            providers.handleGmailDetailResponse(model, authorizedResponse(result), fx, Effects.responseMsg(.gmail_detail_response), Effects.hostMsg(.authorized_gmail_detail_response));
            showReconnectIfNeeded(model, result);
        },
        .authorized_mutation_response => |result| {
            providers.handleMutationResponse(model, authorizedResponse(result));
            showReconnectIfNeeded(model, result);
        },
        .authorized_outbound_response => |result| {
            const sync_was_in_flight = model.syncInFlight();
            if (outbound.handleResponse(model, authorizedResponse(result), fx, Effects.responseMsg(.outbound_response), Effects.hostMsg(.authorized_outbound_response)) and sync_was_in_flight) {
                providers.startInitialSync(model, fx, Effects.responseMsg(.initial_response), Effects.hostMsg(.authorized_initial_response));
            }
            showReconnectIfNeeded(model, result);
        },
    }
}

fn showReconnectIfNeeded(model: *Model, result: native_sdk.EffectHostResult) void {
    if (result.ok) {
        if (oauth_wire.decodeResponse(result.bytes)) |decoded| {
            if (decoded.outcome == .authorization_failed or decoded.outcome == .session_not_found) {
                model.status_message.set("Authorization expired or could not be saved. Reconnect this account.");
            }
        } else |_| {}
    }
}

pub fn authorizedResponse(result: native_sdk.EffectHostResult) native_sdk.EffectResponse {
    if (!result.ok) return .{ .key = result.key, .outcome = .rejected };
    const decoded = oauth_wire.decodeResponse(result.bytes) catch return .{ .key = result.key, .outcome = .protocol_failed };
    const outcome: native_sdk.EffectFetchOutcome = switch (decoded.outcome) {
        .ok => .ok,
        .connect_failed => .connect_failed,
        .tls_failed => .tls_failed,
        .timeout => .timed_out,
        .cancelled => .cancelled,
        .invalid_request, .session_not_found, .authorization_failed, .response_too_large, .internal_error => .rejected,
        .protocol_failed => .protocol_failed,
    };
    return .{
        .key = result.key,
        .outcome = outcome,
        .status = if (outcome == .ok) decoded.status else 0,
        .body = if (outcome == .ok) decoded.body else "",
        .truncated = outcome == .ok and decoded.truncated,
    };
}

fn beginOAuth(model: *Model, fx: *Effects, provider: mail.ProviderKind) void {
    const key = model.beginOAuth() orelse {
        model.status_message.set(if (model.account_count >= mail.max_accounts) "The four-account limit has been reached." else "An account connection is already in progress.");
        return;
    };
    model.status_message.set(if (provider == .gmail) "Continue with Google in your browser." else "Continue with Microsoft in your browser.");
    fx.hostRequest(.{
        .key = key,
        .name = oauth_wire.service_begin,
        .payload = if (provider == .gmail) "gmail" else "microsoft",
        .on_result = Effects.hostMsg(.oauth_response),
    });
}

fn handleOAuthResult(model: *Model, result: native_sdk.EffectHostResult, fx: *Effects) void {
    if (result.key != model.oauth_key) return;
    model.finishOAuth();
    if (!result.ok) {
        if (std.mem.eql(u8, result.bytes, "client_not_configured"))
            model.status_message.set("OAuth is not configured for this provider. Set its desktop client ID.")
        else if (std.mem.eql(u8, result.bytes, "credentials_unavailable"))
            model.status_message.set("Secure OS credential storage is unavailable.")
        else
            model.status_message.set(if (result.bytes.len > 0) result.bytes else "The account could not be connected.");
        return;
    }
    const account_result = oauth_wire.decodeAccountResult(result.bytes) catch {
        model.status_message.set("The provider returned invalid account metadata.");
        return;
    };
    const provider: mail.ProviderKind = if (account_result.provider == .gmail) .gmail else .microsoft;
    const index = model.addAuthorizedAccount(provider, account_result.provider_account_id, account_result.email, account_result.display_name, account_result.session_key, account_result.api_base_url) orelse {
        model.status_message.set("The four-account limit has been reached.");
        return;
    };
    model.selectAccount(index);
    model.status_message.set("Account connected. Synchronizing mail.");
    providers.startInitialSync(model, fx, Effects.responseMsg(.initial_response), Effects.hostMsg(.authorized_initial_response));
}

fn handleRestoreResult(model: *Model, result: native_sdk.EffectHostResult, fx: *Effects) void {
    if (result.key < 0x6000_0000_0000_0000 or result.key >= 0x6000_0000_0000_0000 + mail.max_accounts) return;
    if (model.restore_pending > 0) model.restore_pending -= 1;
    if (result.ok) {
        const metadata = oauth_wire.decodeAccountResult(result.bytes) catch {
            model.status_message.set("A saved account record was invalid and was skipped.");
            return finishRestore(model, fx);
        };
        const provider: mail.ProviderKind = if (metadata.provider == .gmail) .gmail else .microsoft;
        _ = model.addAuthorizedAccount(provider, metadata.provider_account_id, metadata.email, metadata.display_name, metadata.session_key, metadata.api_base_url);
    } else if (!std.mem.eql(u8, result.bytes, "session_not_found")) {
        model.restore_failed = true;
    }
    finishRestore(model, fx);
}

fn finishRestore(model: *Model, fx: *Effects) void {
    if (model.restore_pending != 0) return;
    if (model.account_count == 0) {
        model.status_message.set(if (model.restore_failed) "Saved accounts could not be restored. Check OAuth configuration and credential storage." else "Connect Gmail or Outlook to get started.");
        return;
    }
    model.status_message.set(if (model.restore_failed) "Some saved accounts could not be restored. Synchronizing the available accounts." else "Restored saved accounts. Synchronizing mail.");
    providers.startInitialSync(model, fx, Effects.responseMsg(.initial_response), Effects.hostMsg(.authorized_initial_response));
}

const ComposeField = enum { to, cc, bcc, subject, body };

fn applyComposeEdit(model: *Model, fx: *Effects, field: ComposeField, edit: canvas.TextInputEvent) void {
    switch (field) {
        .to => model.composer.applyTo(edit),
        .cc => model.composer.applyCc(edit),
        .bcc => model.composer.applyBcc(edit),
        .subject => model.composer.applySubject(edit),
        .body => model.composer.applyBody(edit),
    }
    outbound.scheduleAutosave(model, fx, Effects.timerMsg(.compose_autosave));
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
    if (!providers.fetchMutation(fx, key, thread.provider, operation, account, thread, Effects.responseMsg(.mutation_response), Effects.hostMsg(.authorized_mutation_response))) {
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
    if (std.ascii.eqlIgnoreCase(key, "enter") or std.ascii.eqlIgnoreCase(key, "o")) return .activate_selected;
    if (std.ascii.eqlIgnoreCase(key, "e")) return .archive_selected;
    if (std.ascii.eqlIgnoreCase(key, "s")) return .toggle_star_selected;
    if (std.ascii.eqlIgnoreCase(key, "h")) return .snooze_selected;
    if (std.ascii.eqlIgnoreCase(key, "delete") or std.mem.eql(u8, key, "#")) return .trash_selected;
    if (std.mem.eql(u8, key, "/")) return .focus_search;
    if (std.ascii.eqlIgnoreCase(key, "d")) return .{ .set_filter = .drafts };
    if (std.ascii.eqlIgnoreCase(key, "c")) return .compose_new;
    if (std.ascii.eqlIgnoreCase(key, "r")) return .compose_reply;
    if (std.ascii.eqlIgnoreCase(key, "a")) return .compose_reply_all;
    if (std.ascii.eqlIgnoreCase(key, "f")) return .compose_forward;
    return null;
}

pub fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, "mail.refresh")) return .refresh;
    if (std.mem.eql(u8, name, "mail.open-window")) return .open_selected_window;
    if (std.mem.eql(u8, name, "mail.compose")) return .compose_new;
    return null;
}

pub fn mailWindows(model: *const Model, scratch: *MailApp.WindowsScratch) []const MailApp.WindowDescriptor {
    var count: usize = 0;
    for (model.open_windows[0..model.open_window_count]) |message_id| {
        const thread_index = model.threadIndexById(message_id) orelse continue;
        if (count >= scratch.windows.len) continue;
        const thread = &model.threads[thread_index];
        scratch.windows[count] = .{
            .label = thread.window_label.slice(),
            .canvas_label = thread.canvas_label.slice(),
            .title = thread.subjectSlice(),
            .width = 760,
            .height = 640,
            .min_width = 480,
            .min_height = 360,
            .on_close = Msg{ .close_window = @intCast(message_id.value) },
        };
        count += 1;
    }
    if (model.composeOpen() and count < scratch.windows.len) {
        scratch.windows[count] = .{
            .label = "compose",
            .canvas_label = "compose-canvas",
            .title = model.composeTitle(),
            .width = 760,
            .height = 680,
            .min_width = 540,
            .min_height = 620,
            .on_close = .compose_close,
        };
        count += 1;
    }
    return scratch.windows[0..count];
}

pub fn mailWindowView(ui: *MailApp.Ui, model: *const Model, window_label: []const u8) MailApp.Ui.Node {
    if (std.mem.eql(u8, window_label, "compose")) return CompiledComposeView.build(ui, model);
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
    app_state.model = productionInitialModel(init);

    // RuntimeServices must outlive the runner: it owns the trusted boundary
    // for system-browser and OS-credential operations.
    var services = native_services.RuntimeServices(Effects).initWithOAuth(app_state.app(), &app_state.effects, oauthSettings(init));

    try runner.runWithOptions(services.app(), .{
        .app_name = "inbox-zero-mail-native",
        .window_title = "Inbox Zero Mail",
        .bundle_id = "com.inboxzero.mail.native",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = true,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{
                .allowed_origins = &.{ "zero://inline", "zero://app" },
                .external_links = .{ .action = .open_system_browser, .allowed_urls = &oauth_external_urls },
            },
        },
    }, init);
}

test {
    _ = @import("auth/callback.zig");
    _ = @import("auth/config.zig");
    _ = @import("auth/coordinator.zig");
    _ = @import("auth/pkce.zig");
    _ = @import("auth/session.zig");
    _ = @import("auth/wire.zig");
    _ = @import("tests.zig");
    _ = @import("model.zig");
    _ = @import("providers.zig");
    _ = @import("app/compose.zig");
    _ = @import("app/outbound.zig");
    _ = @import("providers/outbound_tests.zig");
}
