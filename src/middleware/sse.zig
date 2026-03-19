const std = @import("std");
const Context = @import("context.zig").Context;
const HandlerFn = @import("context.zig").HandlerFn;
const sse_mod = @import("../core/sse.zig");
pub const SseWriter = sse_mod.SseWriter;

/// Configuration for SSE middleware.
pub const SseConfig = struct {
    /// Additional headers to send with the SSE response.
    extra_headers: []const [2][]const u8 = &.{},
};

/// Create an SSE middleware that sets up the appropriate headers.
/// The downstream handler should use `ctx.getAssign("sse")` to check if SSE is active,
/// then use the SSE writer pattern to send events.
pub fn sseMiddleware(comptime config: SseConfig) HandlerFn {
    const S = struct {
        fn handle(ctx: *Context) anyerror!void {
            // Check Accept header for text/event-stream
            const accept = ctx.request.header("Accept") orelse "";
            if (std.mem.indexOf(u8, accept, "text/event-stream") == null) {
                try ctx.next();
                return;
            }

            // Set SSE response headers
            ctx.response.status = .ok;
            ctx.response.headers.append(ctx.allocator, "Content-Type", "text/event-stream") catch {};
            ctx.response.headers.append(ctx.allocator, "Cache-Control", "no-cache") catch {};
            ctx.response.headers.append(ctx.allocator, "Connection", "keep-alive") catch {};

            // Apply extra headers
            inline for (config.extra_headers) |header| {
                ctx.response.headers.append(ctx.allocator, header[0], header[1]) catch {};
            }

            // Mark this as an SSE context
            ctx.assign("sse", "true");

            try ctx.next();
        }
    };
    return &S.handle;
}
