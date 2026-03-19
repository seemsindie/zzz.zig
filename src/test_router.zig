//! Test root for router module — routing and pattern matching.
//! Compiled as an independent test binary for parallel execution.

const std = @import("std");

pub const router = @import("router/router.zig");
pub const route = @import("router/route.zig");

test {
    std.testing.refAllDecls(@This());
}
