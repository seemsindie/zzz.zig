//! Security response headers: Content-Security-Policy and Strict-Transport-Security.
//!
//! Each middleware emits one header, configured at comptime. Apply both to
//! harden a typical HTML app:
//! ```zig
//! const App = pidgn.Router.define(.{
//!     .middleware = &.{
//!         pidgn.csp(.{ .policy = "default-src 'self'; img-src 'self' data:" }),
//!         pidgn.hsts(.{ .max_age = 31_536_000, .include_subdomains = true }),
//!     },
//!     .routes = routes,
//! });
//! ```
const std = @import("std");
const Context = @import("context.zig").Context;
const HandlerFn = @import("context.zig").HandlerFn;

// ── Content-Security-Policy ────────────────────────────────────────────

pub const CspConfig = struct {
    /// Full policy string (e.g. "default-src 'self'; script-src 'self' 'unsafe-inline'").
    /// If empty, a conservative default is used.
    policy: []const u8 = "default-src 'self'",
    /// If true, emit Content-Security-Policy-Report-Only instead (browsers
    /// report violations but do not block them). Useful for staged rollouts.
    report_only: bool = false,
};

pub fn csp(comptime config: CspConfig) HandlerFn {
    const header_name = if (config.report_only)
        "Content-Security-Policy-Report-Only"
    else
        "Content-Security-Policy";

    const S = struct {
        fn handle(ctx: *Context) anyerror!void {
            ctx.response.headers.append(ctx.allocator, header_name, config.policy) catch {};
            try ctx.next();
        }
    };
    return &S.handle;
}

// ── Strict-Transport-Security ──────────────────────────────────────────

pub const HstsConfig = struct {
    /// Seconds browsers will remember to use HTTPS. 31536000 = 1 year.
    max_age: u64 = 31_536_000,
    include_subdomains: bool = true,
    /// Setting this true submits the site for inclusion in the HSTS preload
    /// list — only enable once your entire domain tree is HTTPS-only.
    preload: bool = false,
};

pub fn hsts(comptime config: HstsConfig) HandlerFn {
    const S = struct {
        // Build the header value at comptime so runtime stays zero-alloc.
        const value: []const u8 = buildValue(config);

        fn buildValue(comptime c: HstsConfig) []const u8 {
            comptime var out: []const u8 = std.fmt.comptimePrint("max-age={d}", .{c.max_age});
            if (c.include_subdomains) out = out ++ "; includeSubDomains";
            if (c.preload) out = out ++ "; preload";
            return out;
        }

        fn handle(ctx: *Context) anyerror!void {
            ctx.response.headers.append(ctx.allocator, "Strict-Transport-Security", value) catch {};
            try ctx.next();
        }
    };
    return &S.handle;
}

// ── Tests ──────────────────────────────────────────────────────────────

const Request = @import("../core/http/request.zig").Request;
const StatusCode = @import("../core/http/status.zig").StatusCode;
const Router = @import("../router/router.zig").Router;

test "csp sets Content-Security-Policy header" {
    const H = struct {
        fn h(ctx: *Context) !void {
            ctx.text(.ok, "ok");
        }
    };
    const App = Router.define(.{
        .middleware = &.{csp(.{ .policy = "default-src 'self'; img-src *" })},
        .routes = &.{Router.get("/", H.h)},
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req: Request = .{ .method = .GET, .path = "/" };
    defer req.deinit(alloc);
    var resp = try App.handler(alloc, &req);
    defer resp.deinit(alloc);
    try std.testing.expectEqualStrings(
        "default-src 'self'; img-src *",
        resp.headers.get("Content-Security-Policy").?,
    );
    try std.testing.expect(resp.headers.get("Content-Security-Policy-Report-Only") == null);
}

test "csp report_only emits report-only header" {
    const H = struct {
        fn h(ctx: *Context) !void {
            ctx.text(.ok, "ok");
        }
    };
    const App = Router.define(.{
        .middleware = &.{csp(.{ .policy = "default-src 'self'", .report_only = true })},
        .routes = &.{Router.get("/", H.h)},
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req: Request = .{ .method = .GET, .path = "/" };
    defer req.deinit(alloc);
    var resp = try App.handler(alloc, &req);
    defer resp.deinit(alloc);
    try std.testing.expect(resp.headers.get("Content-Security-Policy") == null);
    try std.testing.expectEqualStrings(
        "default-src 'self'",
        resp.headers.get("Content-Security-Policy-Report-Only").?,
    );
}

test "hsts default includes subdomains and a year of max-age" {
    const H = struct {
        fn h(ctx: *Context) !void {
            ctx.text(.ok, "ok");
        }
    };
    const App = Router.define(.{
        .middleware = &.{hsts(.{})},
        .routes = &.{Router.get("/", H.h)},
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req: Request = .{ .method = .GET, .path = "/" };
    defer req.deinit(alloc);
    var resp = try App.handler(alloc, &req);
    defer resp.deinit(alloc);
    const val = resp.headers.get("Strict-Transport-Security").?;
    try std.testing.expectEqualStrings("max-age=31536000; includeSubDomains", val);
}

test "hsts preload flag" {
    const H = struct {
        fn h(ctx: *Context) !void {
            ctx.text(.ok, "ok");
        }
    };
    const App = Router.define(.{
        .middleware = &.{hsts(.{ .max_age = 63_072_000, .preload = true })},
        .routes = &.{Router.get("/", H.h)},
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req: Request = .{ .method = .GET, .path = "/" };
    defer req.deinit(alloc);
    var resp = try App.handler(alloc, &req);
    defer resp.deinit(alloc);
    try std.testing.expectEqualStrings(
        "max-age=63072000; includeSubDomains; preload",
        resp.headers.get("Strict-Transport-Security").?,
    );
}
