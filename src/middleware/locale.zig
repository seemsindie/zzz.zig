//! Accept-Language negotiation and locale detection middleware.
//!
//! Typical flow:
//! 1. Register `localeMiddleware(.{.available = &.{"en", "fr", "de"}, .default = "en"})`
//!    in the pipeline.
//! 2. Handlers read `ctx.getAssign("locale")` or `ctx.getLocale()`.
//! 3. Detection order: `?lang=` query → `locale` cookie → Accept-Language header
//!    → configured default.
const std = @import("std");
const Context = @import("context.zig").Context;
const HandlerFn = @import("context.zig").HandlerFn;

pub const LocaleConfig = struct {
    /// Ordered list of locales this app ships translations for. Matching is
    /// prefix-based: a request for `en-US` matches an available `en`.
    available: []const []const u8,
    default: []const u8 = "en",
    /// Name of the cookie that overrides Accept-Language. Empty = disabled.
    cookie_name: []const u8 = "locale",
    /// Query string parameter that overrides everything. Empty = disabled.
    query_param: []const u8 = "lang",
};

pub fn localeMiddleware(comptime config: LocaleConfig) HandlerFn {
    if (config.available.len == 0) @compileError("LocaleConfig.available must be non-empty");
    const S = struct {
        fn handle(ctx: *Context) anyerror!void {
            const picked = detect(ctx, config);
            ctx.assign("locale", picked);
            try ctx.next();
        }
    };
    return &S.handle;
}

/// Resolve the best locale for this request without wiring a middleware.
pub fn detect(ctx: *const Context, comptime config: LocaleConfig) []const u8 {
    // Query param has highest priority.
    if (config.query_param.len > 0) {
        if (ctx.query.get(config.query_param)) |v| {
            if (match(v, config.available)) |m| return m;
        }
    }
    // Then cookie.
    if (config.cookie_name.len > 0) {
        if (ctx.getCookie(config.cookie_name)) |v| {
            if (match(v, config.available)) |m| return m;
        }
    }
    // Then Accept-Language header.
    if (ctx.request.header("Accept-Language")) |h| {
        if (negotiate(h, config.available)) |m| return m;
    }
    return config.default;
}

/// Parse an Accept-Language header and pick the highest-quality locale that
/// matches one of `available`. Returns null if nothing matches.
pub fn negotiate(header_value: []const u8, available: []const []const u8) ?[]const u8 {
    // Accept-Language: fr-CH, fr;q=0.9, en;q=0.8, de;q=0.7, *;q=0.5
    var best: ?[]const u8 = null;
    var best_q: f32 = -1.0;

    var iter = std.mem.splitScalar(u8, header_value, ',');
    while (iter.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len == 0) continue;

        var tag = trimmed;
        var q: f32 = 1.0;
        if (std.mem.indexOfScalar(u8, trimmed, ';')) |semi| {
            tag = std.mem.trim(u8, trimmed[0..semi], " \t");
            const rest = trimmed[semi + 1 ..];
            if (std.mem.indexOf(u8, rest, "q=")) |qpos| {
                const qstr = std.mem.trim(u8, rest[qpos + 2 ..], " \t");
                q = std.fmt.parseFloat(f32, qstr) catch 1.0;
            }
        }

        if (q <= 0.0) continue;
        if (match(tag, available)) |m| {
            if (q > best_q) {
                best = m;
                best_q = q;
            }
        }
    }
    return best;
}

/// Return the matching available locale for `tag` using prefix matching.
fn match(tag: []const u8, available: []const []const u8) ?[]const u8 {
    // Exact match first.
    for (available) |a| if (eqlAscii(a, tag)) return a;
    // Then prefix match (e.g. "en" matches "en-US").
    const dash = std.mem.indexOfScalar(u8, tag, '-');
    const primary = if (dash) |d| tag[0..d] else tag;
    for (available) |a| if (eqlAscii(a, primary)) return a;
    return null;
}

fn eqlAscii(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const xl = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const yl = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (xl != yl) return false;
    }
    return true;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "negotiate picks highest q that matches" {
    const avail = [_][]const u8{ "en", "fr", "de" };
    const got = negotiate("fr-CH, fr;q=0.9, en;q=0.8, *;q=0.5", &avail);
    try std.testing.expectEqualStrings("fr", got.?);
}

test "negotiate returns null when nothing matches" {
    const avail = [_][]const u8{ "en", "fr" };
    const got = negotiate("ja, zh;q=0.9", &avail);
    try std.testing.expect(got == null);
}

test "negotiate prefix match en-US -> en" {
    const avail = [_][]const u8{"en"};
    const got = negotiate("en-US", &avail);
    try std.testing.expectEqualStrings("en", got.?);
}

test "negotiate skips q=0 entries" {
    const avail = [_][]const u8{ "en", "fr" };
    const got = negotiate("fr;q=0, en;q=0.5", &avail);
    try std.testing.expectEqualStrings("en", got.?);
}

const Request = @import("../core/http/request.zig").Request;
const StatusCode = @import("../core/http/status.zig").StatusCode;
const Router = @import("../router/router.zig").Router;

test "middleware sets locale assign from Accept-Language" {
    const H = struct {
        fn h(ctx: *Context) !void {
            const locale = ctx.getAssign("locale") orelse "?";
            ctx.text(.ok, locale);
        }
    };
    const App = Router.define(.{
        .middleware = &.{localeMiddleware(.{
            .available = &.{ "en", "fr", "de" },
            .default = "en",
        })},
        .routes = &.{Router.get("/", H.h)},
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var req: Request = .{ .method = .GET, .path = "/" };
    try req.headers.append(alloc, "Accept-Language", "de-DE, de;q=0.9, en;q=0.5");
    defer req.deinit(alloc);
    var resp = try App.handler(alloc, &req);
    defer resp.deinit(alloc);
    try std.testing.expectEqualStrings("de", resp.body.?);
}

test "middleware query param overrides Accept-Language" {
    const H = struct {
        fn h(ctx: *Context) !void {
            const locale = ctx.getAssign("locale") orelse "?";
            ctx.text(.ok, locale);
        }
    };
    const App = Router.define(.{
        .middleware = &.{localeMiddleware(.{
            .available = &.{ "en", "fr" },
            .default = "en",
        })},
        .routes = &.{Router.get("/", H.h)},
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var req: Request = .{ .method = .GET, .path = "/", .query_string = "lang=fr" };
    try req.headers.append(alloc, "Accept-Language", "en");
    defer req.deinit(alloc);
    var resp = try App.handler(alloc, &req);
    defer resp.deinit(alloc);
    try std.testing.expectEqualStrings("fr", resp.body.?);
}
