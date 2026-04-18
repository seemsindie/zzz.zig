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
pub const flash = @import("middleware/flash.zig");
pub const secure_cookies = @import("middleware/secure_cookies.zig");
pub const security_headers = @import("middleware/security_headers.zig");
pub const pagination = @import("middleware/pagination.zig");
pub const sanitize = @import("middleware/sanitize.zig");
pub const form_builder = @import("middleware/form_builder.zig");
pub const user_agent = @import("middleware/user_agent.zig");
pub const locale = @import("middleware/locale.zig");
pub const ip_access = @import("middleware/ip_access.zig");
pub const action_log = @import("middleware/action_log.zig");
pub const throttle_mw = @import("middleware/throttle.zig");
pub const range_mw = @import("middleware/range.zig");
pub const geoip = @import("middleware/geoip.zig");
pub const websocket = @import("middleware/websocket.zig");
pub const channel = @import("middleware/channel.zig");
pub const pidgn_js = @import("middleware/pidgn_js.zig");
pub const structured_logger = @import("middleware/structured_logger.zig");
pub const request_id = @import("middleware/request_id.zig");
pub const telemetry = @import("middleware/telemetry.zig");
pub const metrics = @import("middleware/metrics.zig");
pub const health = @import("middleware/health.zig");

test {
    std.testing.refAllDecls(@This());
}
