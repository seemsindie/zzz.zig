//! Test root for testing module — HTTP test client, WebSocket test client.
//! Compiled as an independent test binary for parallel execution.

const std = @import("std");

pub const testing_root = @import("testing/root.zig");

test {
    std.testing.refAllDecls(@This());
}
