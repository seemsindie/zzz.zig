//! Test root for Env module — .env file parsing and environment variable support.
//! Compiled as an independent test binary for parallel execution.

const std = @import("std");

pub const env = @import("env.zig");

test {
    std.testing.refAllDecls(@This());
}
