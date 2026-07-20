// Standalone root for the pure outbound provider suite. Keeping the root at
// `src/providers` lets nested provider modules share the neutral outbound
// definitions without depending on the Native SDK application module.
test {
    _ = @import("outbound.zig");
    _ = @import("gmail/mime.zig");
    _ = @import("gmail/outbound.zig");
    _ = @import("outlook/outbound.zig");
}
