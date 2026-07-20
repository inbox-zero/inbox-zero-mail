const std = @import("std");

pub const Config = struct {
    gmail_client_id: []const u8 = "",
    gmail_client_secret: []const u8 = "",
    outlook_client_id: []const u8 = "",
};

const max_config_bytes = 16 * 1024;

/// Loads the optional OAuth configuration bundled with a release. Environment
/// variables are applied by main.zig after this file is read, so developers and
/// source builds can always override packaged values.
pub fn load(init: std.process.Init) Config {
    const allocator = std.heap.page_allocator;

    if (init.environ_map.get("INBOX_ZERO_OAUTH_CONFIG")) |path| {
        if (readConfig(init.io, allocator, path)) |config| return config;
    }
    if (readConfig(init.io, allocator, "assets/oauth.json")) |config| return config;

    const executable_path = std.process.executablePathAlloc(init.io, allocator) catch return .{};
    defer allocator.free(executable_path);
    const executable_dir = std.fs.path.dirname(executable_path) orelse return .{};

    // macOS: App.app/Contents/MacOS/<binary> -> Contents/Resources/assets
    const macos_path = std.fs.path.join(allocator, &.{ executable_dir, "..", "Resources", "assets", "oauth.json" }) catch return .{};
    defer allocator.free(macos_path);
    if (readConfig(init.io, allocator, macos_path)) |config| return config;

    // Windows/Linux: <package>/bin/<binary> -> <package>/resources/assets
    const desktop_path = std.fs.path.join(allocator, &.{ executable_dir, "..", "resources", "assets", "oauth.json" }) catch return .{};
    defer allocator.free(desktop_path);
    return readConfig(init.io, allocator, desktop_path) orelse .{};
}

fn readConfig(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ?Config {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_config_bytes)) catch return null;
    defer allocator.free(bytes);
    return std.json.parseFromSliceLeaky(Config, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch null;
}

test "release OAuth config parses Gmail with optional Outlook" {
    const parsed = try std.json.parseFromSlice(Config, std.testing.allocator,
        \\{"gmail_client_id":"desktop.apps.googleusercontent.com","gmail_client_secret":"installed-secret"}
    , .{ .allocate = .alloc_always });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("desktop.apps.googleusercontent.com", parsed.value.gmail_client_id);
    try std.testing.expectEqualStrings("installed-secret", parsed.value.gmail_client_secret);
    try std.testing.expectEqualStrings("", parsed.value.outlook_client_id);
}
