const std = @import("std");
const Context = @import("context.zig").Context;
const HandlerFn = @import("context.zig").HandlerFn;

/// One-shot session-backed messages surviving a single redirect.
///
/// Requires `session(...)` to be registered earlier in the pipeline.
/// Use `ctx.putFlash(.success, "Saved!")` in a handler before a redirect;
/// the next request's handler (or template) reads it with `ctx.getFlash(.success)`.
pub const FlashKind = enum {
    success,
    err,
    notice,
    warning,
    info,

    /// Pending-storage key: survives across a redirect via the session.
    pub fn pendingKey(self: FlashKind) []const u8 {
        return switch (self) {
            .success => "__flash_success",
            .err => "__flash_error",
            .notice => "__flash_notice",
            .warning => "__flash_warning",
            .info => "__flash_info",
        };
    }

    /// Display key: populated by the middleware for the current request
    /// so handlers and templates can read it without touching the session.
    pub fn displayKey(self: FlashKind) []const u8 {
        return switch (self) {
            .success => "flash_success",
            .err => "flash_error",
            .notice => "flash_notice",
            .warning => "flash_warning",
            .info => "flash_info",
        };
    }
};

pub const FlashConfig = struct {};

pub fn flash(comptime _: FlashConfig) HandlerFn {
    const S = struct {
        fn handle(ctx: *Context) anyerror!void {
            // Promote pending flashes (stored by the previous request) into
            // display keys and clear the pending entries so they don't survive
            // further than this request.
            inline for (std.meta.tags(FlashKind)) |kind| {
                if (ctx.getAssign(kind.pendingKey())) |v| {
                    if (v.len > 0) ctx.assigns.put(kind.displayKey(), v);
                    ctx.assigns.put(kind.pendingKey(), "");
                }
            }

            try ctx.next();

            // Clear display keys so they don't get persisted into the session
            // and bleed into the next request.
            inline for (std.meta.tags(FlashKind)) |kind| {
                if (ctx.getAssign(kind.displayKey())) |v| {
                    if (v.len > 0) ctx.assigns.put(kind.displayKey(), "");
                }
            }
        }
    };
    return &S.handle;
}

// ── Tests ──────────────────────────────────────────────────────────────

const Request = @import("../core/http/request.zig").Request;
const StatusCode = @import("../core/http/status.zig").StatusCode;
const Router = @import("../router/router.zig").Router;
const session = @import("session.zig").session;

test "flash survives one redirect and clears after read" {
    const H = struct {
        fn setFlash(ctx: *Context) !void {
            ctx.putFlash(.success, "Saved!");
            ctx.redirect("/show", .found);
        }
        fn show(ctx: *Context) !void {
            const msg = ctx.getFlash(.success) orelse "none";
            ctx.text(.ok, msg);
        }
    };
    const App = Router.define(.{
        .middleware = &.{ session(.{ .cookie_name = "fs_sess" }), flash(.{}) },
        .routes = &.{
            Router.post("/set", H.setFlash),
            Router.get("/show", H.show),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Request 1: handler sets the flash and redirects.
    var req1: Request = .{ .method = .POST, .path = "/set" };
    defer req1.deinit(alloc);
    var resp1 = try App.handler(alloc, &req1);
    defer resp1.deinit(alloc);
    try std.testing.expectEqual(StatusCode.found, resp1.status);

    const cookie = resp1.headers.get("Set-Cookie").?;
    const prefix = "fs_sess=";
    const after_eq = cookie[prefix.len..];
    const semi = std.mem.indexOfScalar(u8, after_eq, ';') orelse after_eq.len;
    const sid = after_eq[0..semi];

    // Request 2: reads the flash.
    var req2: Request = .{ .method = .GET, .path = "/show" };
    var cookie_buf: [64]u8 = undefined;
    const cookie_val = std.fmt.bufPrint(&cookie_buf, "fs_sess={s}", .{sid}) catch unreachable;
    try req2.headers.append(alloc, "Cookie", cookie_val);
    defer req2.deinit(alloc);
    var resp2 = try App.handler(alloc, &req2);
    defer resp2.deinit(alloc);
    try std.testing.expectEqualStrings("Saved!", resp2.body.?);

    // Request 3: flash should be gone.
    var req3: Request = .{ .method = .GET, .path = "/show" };
    var cookie_buf3: [64]u8 = undefined;
    const cookie_val3 = std.fmt.bufPrint(&cookie_buf3, "fs_sess={s}", .{sid}) catch unreachable;
    try req3.headers.append(alloc, "Cookie", cookie_val3);
    defer req3.deinit(alloc);
    var resp3 = try App.handler(alloc, &req3);
    defer resp3.deinit(alloc);
    try std.testing.expectEqualStrings("none", resp3.body.?);
}

test "getFlash returns null when no flash set" {
    const H = struct {
        fn h(ctx: *Context) !void {
            const msg = ctx.getFlash(.err) orelse "empty";
            ctx.text(.ok, msg);
        }
    };
    const App = Router.define(.{
        .middleware = &.{ session(.{ .cookie_name = "fs_empty" }), flash(.{}) },
        .routes = &.{Router.get("/", H.h)},
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req: Request = .{ .method = .GET, .path = "/" };
    defer req.deinit(alloc);
    var resp = try App.handler(alloc, &req);
    defer resp.deinit(alloc);
    try std.testing.expectEqualStrings("empty", resp.body.?);
}

test "multiple flash kinds coexist" {
    const H = struct {
        fn setBoth(ctx: *Context) !void {
            ctx.putFlash(.success, "ok");
            ctx.putFlash(.err, "bad");
            ctx.redirect("/read", .found);
        }
        fn read(ctx: *Context) !void {
            const s = ctx.getFlash(.success) orelse "-";
            const e = ctx.getFlash(.err) orelse "-";
            var buf: [64]u8 = undefined;
            const out = std.fmt.bufPrint(&buf, "{s}|{s}", .{ s, e }) catch unreachable;
            ctx.text(.ok, ctx.allocator.dupe(u8, out) catch unreachable);
        }
    };
    const App = Router.define(.{
        .middleware = &.{ session(.{ .cookie_name = "fs_multi" }), flash(.{}) },
        .routes = &.{
            Router.post("/set", H.setBoth),
            Router.get("/read", H.read),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req1: Request = .{ .method = .POST, .path = "/set" };
    defer req1.deinit(alloc);
    var resp1 = try App.handler(alloc, &req1);
    defer resp1.deinit(alloc);

    const cookie = resp1.headers.get("Set-Cookie").?;
    const prefix = "fs_multi=";
    const after_eq = cookie[prefix.len..];
    const semi = std.mem.indexOfScalar(u8, after_eq, ';') orelse after_eq.len;
    const sid = after_eq[0..semi];

    var req2: Request = .{ .method = .GET, .path = "/read" };
    var cookie_buf: [64]u8 = undefined;
    const cookie_val = std.fmt.bufPrint(&cookie_buf, "fs_multi={s}", .{sid}) catch unreachable;
    try req2.headers.append(alloc, "Cookie", cookie_val);
    defer req2.deinit(alloc);
    var resp2 = try App.handler(alloc, &req2);
    defer resp2.deinit(alloc);
    try std.testing.expectEqualStrings("ok|bad", resp2.body.?);
}
