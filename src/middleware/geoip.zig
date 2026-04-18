//! Geo-IP middleware with a pluggable provider.
//!
//! Pidgn doesn't ship a geo database — users wire their own (MaxMind,
//! ip-api, an in-memory CIDR map, whatever). Provide a struct with a
//! `lookup(ip: []const u8) ?GeoInfo` method and pass it as the config's
//! provider type. The middleware populates ctx.assigns with:
//!   - `geo_country` (ISO-3166-1 alpha-2)
//!   - `geo_region`
//!   - `geo_city`
const std = @import("std");
const Context = @import("context.zig").Context;
const HandlerFn = @import("context.zig").HandlerFn;

pub const GeoInfo = struct {
    country: []const u8 = "",
    region: []const u8 = "",
    city: []const u8 = "",
};

pub const GeoIpConfig = struct {
    /// A struct type with `pub fn lookup(ip: []const u8) ?GeoInfo`.
    provider: type,
    client_ip_header: []const u8 = "X-Forwarded-For",
};

pub fn geoIp(comptime config: GeoIpConfig) HandlerFn {
    const S = struct {
        fn handle(ctx: *Context) anyerror!void {
            const raw = ctx.request.header(config.client_ip_header) orelse "";
            const ip = firstIp(raw);
            if (ip.len > 0) {
                if (config.provider.lookup(ip)) |info| {
                    if (info.country.len > 0) ctx.assign("geo_country", info.country);
                    if (info.region.len > 0) ctx.assign("geo_region", info.region);
                    if (info.city.len > 0) ctx.assign("geo_city", info.city);
                }
            }
            try ctx.next();
        }
    };
    return &S.handle;
}

/// No-op provider. Always returns null. Useful as a placeholder before wiring
/// a real provider.
pub const NoopProvider = struct {
    pub fn lookup(ip: []const u8) ?GeoInfo {
        _ = ip;
        return null;
    }
};

fn firstIp(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (std.mem.indexOfScalar(u8, trimmed, ',')) |c| {
        return std.mem.trim(u8, trimmed[0..c], " \t");
    }
    return trimmed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const Request = @import("../core/http/request.zig").Request;
const StatusCode = @import("../core/http/status.zig").StatusCode;
const Router = @import("../router/router.zig").Router;

// Test provider: returns Canada for anything in the 24.x.x.x space, US for
// 1.x.x.x, null otherwise.
const StubProvider = struct {
    pub fn lookup(ip: []const u8) ?GeoInfo {
        if (std.mem.startsWith(u8, ip, "24.")) {
            return .{ .country = "CA", .region = "QC", .city = "Montreal" };
        }
        if (std.mem.startsWith(u8, ip, "1.")) {
            return .{ .country = "US", .region = "NY", .city = "New York" };
        }
        return null;
    }
};

test "geoip populates assigns from provider" {
    const H = struct {
        fn h(ctx: *Context) !void {
            const c = ctx.getAssign("geo_country") orelse "-";
            ctx.text(.ok, c);
        }
    };
    const App = Router.define(.{
        .middleware = &.{geoIp(.{ .provider = StubProvider })},
        .routes = &.{Router.get("/", H.h)},
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req: Request = .{ .method = .GET, .path = "/" };
    try req.headers.append(alloc, "X-Forwarded-For", "24.1.2.3");
    defer req.deinit(alloc);
    var resp = try App.handler(alloc, &req);
    defer resp.deinit(alloc);
    try std.testing.expectEqualStrings("CA", resp.body.?);
}

test "geoip leaves assigns unset when provider returns null" {
    const H = struct {
        fn h(ctx: *Context) !void {
            const c = ctx.getAssign("geo_country") orelse "none";
            ctx.text(.ok, c);
        }
    };
    const App = Router.define(.{
        .middleware = &.{geoIp(.{ .provider = StubProvider })},
        .routes = &.{Router.get("/", H.h)},
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req: Request = .{ .method = .GET, .path = "/" };
    try req.headers.append(alloc, "X-Forwarded-For", "99.99.99.99");
    defer req.deinit(alloc);
    var resp = try App.handler(alloc, &req);
    defer resp.deinit(alloc);
    try std.testing.expectEqualStrings("none", resp.body.?);
}
