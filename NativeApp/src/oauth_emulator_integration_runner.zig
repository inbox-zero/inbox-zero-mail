const integration = @import("auth/oauth_emulator_integration.zig");

pub fn main() !void {
    try integration.main();
}
