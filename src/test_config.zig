//! Test root for Config module — multi-environment config, DatabaseUrl parsing, mergeWithEnv.
//! Compiled as an independent test binary for parallel execution.

const std = @import("std");

pub const config = @import("config.zig");

test {
    std.testing.refAllDecls(@This());
}
