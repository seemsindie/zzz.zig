//! Test root for template module — template engine and HTML escaping.
//! Compiled as an independent test binary for parallel execution.

const std = @import("std");

pub const engine = @import("template/engine.zig");
pub const html_escape = @import("template/html_escape.zig");

test {
    std.testing.refAllDecls(@This());
}
