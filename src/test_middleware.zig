//! Test root for middleware module — all built-in middleware.
//! Compiled as an independent test binary for parallel execution.

const std = @import("std");

pub const context = @import("middleware/context.zig");
pub const body_parser = @import("middleware/body_parser.zig");
pub const session = @import("middleware/session.zig");
pub const csrf = @import("middleware/csrf.zig");
pub const cors = @import("middleware/cors.zig");
pub const auth = @import("middleware/auth.zig");
pub const rate_limit = @import("middleware/rate_limit.zig");
pub const compress = @import("middleware/compress.zig");
pub const logger = @import("middleware/logger.zig");
pub const static_files = @import("middleware/static.zig");
pub const error_handler = @import("middleware/error_handler.zig");
pub const htmx = @import("middleware/htmx.zig");
pub const websocket = @import("middleware/websocket.zig");
pub const channel = @import("middleware/channel.zig");
pub const zzz_js = @import("middleware/zzz_js.zig");
pub const structured_logger = @import("middleware/structured_logger.zig");
pub const request_id = @import("middleware/request_id.zig");
pub const telemetry = @import("middleware/telemetry.zig");
pub const metrics = @import("middleware/metrics.zig");
pub const health = @import("middleware/health.zig");

test {
    std.testing.refAllDecls(@This());
}
