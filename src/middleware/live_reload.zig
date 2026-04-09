const std = @import("std");
const Context = @import("context.zig").Context;
const HandlerFn = @import("context.zig").HandlerFn;


/// Configuration for the live reload middleware.
pub const LiveReloadConfig = struct {
    /// WebSocket endpoint path.
    endpoint: []const u8 = "/__pidgn/live-reload",
};

/// Client-side JavaScript that connects to the live-reload WebSocket.
/// Handles CSS hot-reload (no full page refresh) and full page reload.
/// Auto-reconnects with exponential backoff.
const client_script =
    \\<script>
    \\(function() {
    \\  var alive = true;
    \\  function check() {
    \\    var c = new AbortController();
    \\    var t = setTimeout(function() { c.abort(); }, 1500);
    \\    fetch(location.href, {method:'HEAD',cache:'no-store',signal:c.signal}).then(function(r) {
    \\      clearTimeout(t);
    \\      if (!r.ok) throw new Error();
    \\      if (!alive) { location.reload(); return; }
    \\      setTimeout(check, 300);
    \\    }).catch(function() {
    \\      clearTimeout(t);
    \\      alive = false;
    \\      setTimeout(check, 300);
    \\    });
    \\  }
    \\  setTimeout(check, 300);
    \\})();
    \\</script>
;

/// Middleware that injects the live-reload client script into HTML responses.
/// Place this AFTER gzipCompress in the middleware stack (closer to the route handler)
/// so the script is injected before compression.
pub fn liveReload(comptime config: LiveReloadConfig) HandlerFn {
    _ = config; // reserved for future use (custom endpoint)
    const S = struct {
        fn handle(ctx: *Context) anyerror!void {
            // Run the rest of the pipeline first
            try ctx.next();

            // Only inject into HTML responses
            const ct = ctx.response.headers.get("Content-Type") orelse return;
            if (!std.mem.startsWith(u8, ct, "text/html")) return;

            const body = ctx.response.body orelse return;

            // Find </body> insertion point
            const inject_pos = std.mem.indexOf(u8, body, "</body>") orelse return;

            // Build new body with injected script
            const new_body = ctx.allocator.alloc(u8, body.len + client_script.len) catch return;
            @memcpy(new_body[0..inject_pos], body[0..inject_pos]);
            @memcpy(new_body[inject_pos..][0..client_script.len], client_script);
            @memcpy(new_body[inject_pos + client_script.len ..], body[inject_pos..]);

            // Free old body if owned
            if (ctx.response.body_owned) {
                ctx.allocator.free(@constCast(body));
            }

            ctx.response.body = new_body;
            ctx.response.body_owned = true;
        }
    };
    return &S.handle;
}

/// WebSocket route handler for the live-reload endpoint.
/// Use this with `pidgn.Router.get("/__pidgn/live-reload", liveReloadWs())`.
///
/// The WebSocket subscribes to the "__live_reload" PubSub topic.
/// To trigger a reload, broadcast to this topic from your file watcher:
///   PubSub.broadcast("__live_reload", "{\"type\":\"reload\"}");
///   PubSub.broadcast("__live_reload", "{\"type\":\"css\"}");
pub fn liveReloadWs() HandlerFn {
    const PubSub = @import("../core/channel/pubsub.zig").PubSub;
    const WebSocket = @import("../core/websocket/connection.zig").WebSocket;
    const Response = @import("../core/http/response.zig").Response;

    const topic = "__live_reload";

    const S = struct {
        fn onOpen(ws: *WebSocket) void {
            _ = PubSub.subscribe(topic, ws);
        }

        fn onClose(ws: *WebSocket, _: u16, _: []const u8) void {
            PubSub.unsubscribeAll(ws);
        }

        fn handle(ctx: *Context) anyerror!void {
            if (!ctx.request.isWebSocketUpgrade()) {
                ctx.respond(.bad_request, "text/plain; charset=utf-8", "400 Bad Request: Not a WebSocket upgrade request");
                return;
            }

            ctx.response.status = .switching_protocols;

            const ws_upgrade = ctx.allocator.create(Response.WebSocketUpgrade) catch {
                ctx.respond(.internal_server_error, "text/plain; charset=utf-8", "500 Internal Server Error");
                return;
            };
            ws_upgrade.* = .{
                .handler = .{
                    .on_open = &onOpen,
                    .on_close = &onClose,
                },
                .params = ctx.params,
                .query = ctx.query,
                .assigns = ctx.assigns,
            };

            ctx.response.ws_handler = ws_upgrade;
        }
    };
    return &S.handle;
}
