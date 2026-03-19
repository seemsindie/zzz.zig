//! Test root for swagger module — OpenAPI spec generation and Swagger UI.
//! Compiled as an independent test binary for parallel execution.

const std = @import("std");

pub const swagger_root = @import("swagger/root.zig");

test {
    std.testing.refAllDecls(@This());
}
