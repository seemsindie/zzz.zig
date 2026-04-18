const std = @import("std");
const Context = @import("context.zig").Context;
const HandlerFn = @import("context.zig").HandlerFn;

/// One-shot session-backed messages surviving a single redirect.
///
/// Requires `session(...)` to be registered earlier in the pipeline.
/// Use `ctx.putFlash("success", "Saved!")` in a handler before a redirect;
/// the next request's handler (or template) reads it with
/// `ctx.getFlash("success")`.
///
/// Keys are arbitrary — use whatever names your app wants (`"success"`,
/// `"error"`, `"cart_added"`, …). Internally the middleware stores pending
/// values under `__flash_<key>` and promotes them to `flash_<key>` on the
/// next request, which is where `getFlash` looks.
pub const PENDING_PREFIX = "__flash_";
pub const DISPLAY_PREFIX = "flash_";

pub const FlashConfig = struct {};

pub fn flash(comptime _: FlashConfig) HandlerFn {
    const S = struct {
        fn handle(ctx: *Context) anyerror!void {
            // Before the handler: promote any pending flashes (set by the
            // previous request and restored from the session) into their
            // display form, and zero out the pending entries so they don't
            // survive into another request.
            //
            // Both the display key and the display value are copied into the
            // request arena so they stay valid after session.persistAssigns
            // rewrites the session's storage at end-of-request.
            var i: usize = 0;
            while (i < ctx.assigns.len) : (i += 1) {
                const entry = &ctx.assigns.entries[i];
                if (!std.mem.startsWith(u8, entry.key, PENDING_PREFIX)) continue;
                if (entry.value.len == 0) continue;

                const suffix = entry.key[PENDING_PREFIX.len..];
                const display_key = std.fmt.allocPrint(
                    ctx.allocator,
                    "{s}{s}",
                    .{ DISPLAY_PREFIX, suffix },
                ) catch continue;
                const value_copy = ctx.allocator.dupe(u8, entry.value) catch continue;
                ctx.assigns.put(display_key, value_copy);
                entry.value = "";
            }

            try ctx.next();

            // After the handler: clear display keys so they don't get
            // persisted into the session and bleed into the next request.
            for (ctx.assigns.entries[0..ctx.assigns.len]) |*entry| {
                if (!std.mem.startsWith(u8, entry.key, DISPLAY_PREFIX)) continue;
                // Don't touch pending keys; they start with '_' so the
                // DISPLAY_PREFIX check above already excludes them.
                entry.value = "";
            }
        }
    };
    return &S.handle;
}

/// Compose the pending-storage key for a user-supplied flash name. Allocates
/// from the request arena; the caller doesn't free.
pub fn pendingKey(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ PENDING_PREFIX, key });
}

/// Compose the display key for a user-supplied flash name. Allocates from
/// the request arena; the caller doesn't free.
pub fn displayKey(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ DISPLAY_PREFIX, key });
}

// ── Tests ──────────────────────────────────────────────────────────────

const Request = @import("../core/http/request.zig").Request;
const StatusCode = @import("../core/http/status.zig").StatusCode;
const Router = @import("../router/router.zig").Router;
const session = @import("session.zig").session;

test "flash survives one redirect and clears after read" {
    const H = struct {
        fn setFlash(ctx: *Context) !void {
            try ctx.putFlash("success", "Saved!");
            ctx.redirect("/show", .found);
        }
        fn show(ctx: *Context) !void {
            const msg = ctx.getFlash("success") orelse "none";
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
            const msg = ctx.getFlash("error") orelse "empty";
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

test "multiple flashes with different keys coexist" {
    const H = struct {
        fn setBoth(ctx: *Context) !void {
            try ctx.putFlash("success", "ok");
            try ctx.putFlash("error", "bad");
            ctx.redirect("/read", .found);
        }
        fn read(ctx: *Context) !void {
            const s = ctx.getFlash("success") orelse "-";
            const e = ctx.getFlash("error") orelse "-";
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

test "flash works with custom app-specific keys" {
    const H = struct {
        fn setFlash(ctx: *Context) !void {
            try ctx.putFlash("cart_added", "Item added to cart");
            ctx.redirect("/show", .found);
        }
        fn show(ctx: *Context) !void {
            const msg = ctx.getFlash("cart_added") orelse "none";
            ctx.text(.ok, msg);
        }
    };
    const App = Router.define(.{
        .middleware = &.{ session(.{ .cookie_name = "fs_custom" }), flash(.{}) },
        .routes = &.{
            Router.post("/set", H.setFlash),
            Router.get("/show", H.show),
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
    const prefix = "fs_custom=";
    const after_eq = cookie[prefix.len..];
    const semi = std.mem.indexOfScalar(u8, after_eq, ';') orelse after_eq.len;
    const sid = after_eq[0..semi];

    var req2: Request = .{ .method = .GET, .path = "/show" };
    var cookie_buf: [64]u8 = undefined;
    const cookie_val = std.fmt.bufPrint(&cookie_buf, "fs_custom={s}", .{sid}) catch unreachable;
    try req2.headers.append(alloc, "Cookie", cookie_val);
    defer req2.deinit(alloc);
    var resp2 = try App.handler(alloc, &req2);
    defer resp2.deinit(alloc);
    try std.testing.expectEqualStrings("Item added to cart", resp2.body.?);
}
