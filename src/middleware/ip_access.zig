//! IP allowlist / blocklist middleware with CIDR support.
//!
//! Identifies the client IP from a configured header (default:
//! `X-Forwarded-For`) — this is header-based so it works behind a reverse
//! proxy. Only deploy `ipAllowlist` / `ipBlocklist` behind a proxy you trust
//! to set that header correctly.
//!
//! Supports IPv4 literal addresses and CIDR ranges (e.g. `10.0.0.0/8`).
//! IPv6 is accepted as an exact literal only; full IPv6 CIDR matching is
//! intentionally out of scope for this simple helper.
const std = @import("std");
const Context = @import("context.zig").Context;
const HandlerFn = @import("context.zig").HandlerFn;

pub const Mode = enum { allow, block };

pub const IpAccessConfig = struct {
    /// IPs or CIDR ranges to match against (e.g. "10.0.0.0/8", "1.2.3.4").
    rules: []const []const u8,
    /// In `.allow` mode, a match passes; a non-match returns 403.
    /// In `.block` mode, a match returns 403; a non-match passes.
    mode: Mode,
    /// Header to read the client IP from. Use `Remote-Addr` if you don't have
    /// a proxy.
    client_ip_header: []const u8 = "X-Forwarded-For",
    status_code: u16 = 403,
    body: []const u8 = "Forbidden",
};

pub fn ipAccess(comptime config: IpAccessConfig) HandlerFn {
    const S = struct {
        // Pre-parse rules at comptime; stored as a static array on the
        // comptime-generated struct so the runtime path is just a match loop.
        const parsed_rules: [config.rules.len]Rule = blk: {
            var list: [config.rules.len]Rule = undefined;
            for (config.rules, 0..) |r, i| {
                list[i] = parseRule(r) orelse @compileError("invalid IP rule: " ++ r);
            }
            break :blk list;
        };

        fn handle(ctx: *Context) anyerror!void {
            const raw = ctx.request.header(config.client_ip_header) orelse "";
            const ip = firstIp(raw);
            const matched = matchAny(ip, &parsed_rules);

            const should_deny = switch (config.mode) {
                .allow => !matched,
                .block => matched,
            };
            if (should_deny) {
                const status: @import("../core/http/status.zig").StatusCode = @enumFromInt(config.status_code);
                ctx.respond(status, "text/plain; charset=utf-8", config.body);
                return;
            }
            try ctx.next();
        }
    };
    return &S.handle;
}

/// Convenience: allowlist shortcut.
pub fn ipAllowlist(comptime config: IpAccessConfig) HandlerFn {
    var c = config;
    c.mode = .allow;
    return ipAccess(c);
}

/// Convenience: blocklist shortcut.
pub fn ipBlocklist(comptime config: IpAccessConfig) HandlerFn {
    var c = config;
    c.mode = .block;
    return ipAccess(c);
}

// ── Parsing ────────────────────────────────────────────────────────────

const Rule = union(enum) {
    v4_exact: u32,
    v4_cidr: struct { network: u32, mask: u32 },
    v6_exact: [16]u8, // stored zero-padded for simple equality matching
};

/// Pick the first comma-separated entry (X-Forwarded-For convention: client,
/// then each proxy). Trims whitespace.
fn firstIp(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (std.mem.indexOfScalar(u8, trimmed, ',')) |c| {
        return std.mem.trim(u8, trimmed[0..c], " \t");
    }
    return trimmed;
}

fn matchAny(ip: []const u8, rules: []const Rule) bool {
    const parsed = parseIp(ip) orelse return false;
    for (rules) |r| {
        switch (r) {
            .v4_exact => |addr| if (parsed == .v4 and parsed.v4 == addr) return true,
            .v4_cidr => |c| if (parsed == .v4 and (parsed.v4 & c.mask) == c.network) return true,
            .v6_exact => |addr| if (parsed == .v6 and std.mem.eql(u8, &parsed.v6, &addr)) return true,
        }
    }
    return false;
}

const Parsed = union(enum) {
    v4: u32,
    v6: [16]u8,
};

fn parseIp(s: []const u8) ?Parsed {
    if (parseIpv4(s)) |v| return .{ .v4 = v };
    if (parseIpv6(s)) |v| return .{ .v6 = v };
    return null;
}

fn parseIpv4(s: []const u8) ?u32 {
    var out: u32 = 0;
    var parts: usize = 0;
    var iter = std.mem.splitScalar(u8, s, '.');
    while (iter.next()) |p| {
        if (parts >= 4) return null;
        const n = std.fmt.parseInt(u8, p, 10) catch return null;
        out = (out << 8) | n;
        parts += 1;
    }
    if (parts != 4) return null;
    return out;
}

fn parseIpv6(s: []const u8) ?[16]u8 {
    // Accept exact textual form; don't expand :: — enough for equality matching.
    var out: [16]u8 = .{0} ** 16;
    var groups: [8]u16 = .{0} ** 8;
    var idx: usize = 0;
    var iter = std.mem.splitScalar(u8, s, ':');
    while (iter.next()) |g| {
        if (idx >= 8) return null;
        if (g.len == 0) return null; // disallow :: in this simple parser
        groups[idx] = std.fmt.parseInt(u16, g, 16) catch return null;
        idx += 1;
    }
    if (idx != 8) return null;
    for (groups, 0..) |g, i| {
        out[i * 2] = @intCast(g >> 8);
        out[i * 2 + 1] = @intCast(g & 0xff);
    }
    return out;
}

fn parseRule(raw: []const u8) ?Rule {
    if (std.mem.indexOfScalar(u8, raw, '/')) |slash| {
        const addr_part = raw[0..slash];
        const prefix_s = raw[slash + 1 ..];
        const v4 = parseIpv4(addr_part) orelse return null;
        const prefix = std.fmt.parseInt(u6, prefix_s, 10) catch return null;
        if (prefix > 32) return null;
        const mask: u32 = if (prefix == 0) 0 else @truncate(@as(u64, 0xFFFFFFFF) << @intCast(32 - prefix));
        return .{ .v4_cidr = .{ .network = v4 & mask, .mask = mask } };
    }
    if (parseIpv4(raw)) |v| return .{ .v4_exact = v };
    if (parseIpv6(raw)) |v| return .{ .v6_exact = v };
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────

const Request = @import("../core/http/request.zig").Request;
const StatusCode = @import("../core/http/status.zig").StatusCode;
const Router = @import("../router/router.zig").Router;

test "parseIpv4 round-trip" {
    try std.testing.expectEqual(@as(u32, 0x01020304), parseIpv4("1.2.3.4").?);
    try std.testing.expect(parseIpv4("256.0.0.0") == null);
    try std.testing.expect(parseIpv4("1.2.3") == null);
}

test "cidr rule: 10.0.0.0/8 matches 10.x.x.x" {
    const rule = parseRule("10.0.0.0/8").?;
    const ip1 = Parsed{ .v4 = parseIpv4("10.5.6.7").? };
    const ip2 = Parsed{ .v4 = parseIpv4("11.0.0.1").? };
    try std.testing.expect(matchAny("10.5.6.7", &.{rule}));
    try std.testing.expect(!matchAny("11.0.0.1", &.{rule}));
    _ = ip1;
    _ = ip2;
}

test "allowlist blocks non-matching ips" {
    const H = struct {
        fn h(ctx: *Context) !void {
            ctx.text(.ok, "ok");
        }
    };
    const App = Router.define(.{
        .middleware = &.{ipAllowlist(.{ .rules = &.{"10.0.0.0/8"}, .mode = .allow })},
        .routes = &.{Router.get("/", H.h)},
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Inside the allowed network.
    var req1: Request = .{ .method = .GET, .path = "/" };
    try req1.headers.append(alloc, "X-Forwarded-For", "10.1.2.3");
    defer req1.deinit(alloc);
    var resp1 = try App.handler(alloc, &req1);
    defer resp1.deinit(alloc);
    try std.testing.expectEqual(StatusCode.ok, resp1.status);

    // Outside the allowed network.
    var req2: Request = .{ .method = .GET, .path = "/" };
    try req2.headers.append(alloc, "X-Forwarded-For", "11.0.0.1");
    defer req2.deinit(alloc);
    var resp2 = try App.handler(alloc, &req2);
    defer resp2.deinit(alloc);
    try std.testing.expectEqual(StatusCode.forbidden, resp2.status);
}

test "blocklist blocks matching ips" {
    const H = struct {
        fn h(ctx: *Context) !void {
            ctx.text(.ok, "ok");
        }
    };
    const App = Router.define(.{
        .middleware = &.{ipBlocklist(.{ .rules = &.{"1.2.3.4"}, .mode = .block })},
        .routes = &.{Router.get("/", H.h)},
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req1: Request = .{ .method = .GET, .path = "/" };
    try req1.headers.append(alloc, "X-Forwarded-For", "1.2.3.4");
    defer req1.deinit(alloc);
    var resp1 = try App.handler(alloc, &req1);
    defer resp1.deinit(alloc);
    try std.testing.expectEqual(StatusCode.forbidden, resp1.status);

    var req2: Request = .{ .method = .GET, .path = "/" };
    try req2.headers.append(alloc, "X-Forwarded-For", "1.2.3.5");
    defer req2.deinit(alloc);
    var resp2 = try App.handler(alloc, &req2);
    defer resp2.deinit(alloc);
    try std.testing.expectEqual(StatusCode.ok, resp2.status);
}

test "X-Forwarded-For takes the leftmost entry" {
    const H = struct {
        fn h(ctx: *Context) !void {
            ctx.text(.ok, "ok");
        }
    };
    const App = Router.define(.{
        .middleware = &.{ipBlocklist(.{ .rules = &.{"1.2.3.4"}, .mode = .block })},
        .routes = &.{Router.get("/", H.h)},
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Bad client, passed through two proxies.
    var req: Request = .{ .method = .GET, .path = "/" };
    try req.headers.append(alloc, "X-Forwarded-For", "1.2.3.4, 10.0.0.1, 10.0.0.2");
    defer req.deinit(alloc);
    var resp = try App.handler(alloc, &req);
    defer resp.deinit(alloc);
    try std.testing.expectEqual(StatusCode.forbidden, resp.status);
}
