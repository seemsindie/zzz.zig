//! Sliding-window request throttle.
//!
//! Complements the existing token-bucket `rateLimit` middleware. Where
//! `rateLimit` refills the full bucket when a window elapses (bursty), this
//! uses a true sliding window over the last N seconds — smoother, fairer, and
//! more accurate for traffic shaping.
//!
//! Tracks up to 256 distinct client keys. Each key stores up to
//! `max_requests` timestamps in a ring buffer; old entries are evicted on
//! each check. Responds 429 when the window is full.
const std = @import("std");
const native_os = @import("builtin").os.tag;
const Context = @import("context.zig").Context;
const HandlerFn = @import("context.zig").HandlerFn;

fn nowNs() i128 {
    if (native_os == .linux) {
        const linux = std.os.linux;
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
        return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    }
    const c = std.c;
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

pub const ThrottleConfig = struct {
    max_requests: u32 = 60,
    window_seconds: u32 = 60,
    key_header: []const u8 = "X-Forwarded-For",
};

pub fn throttle(comptime config: ThrottleConfig) HandlerFn {
    const S = struct {
        const max_clients = 256;

        const Entry = struct {
            key: [64]u8 = .{0} ** 64,
            key_len: usize = 0,
            // Ring buffer of request timestamps (ns since monotonic epoch).
            stamps: [config.max_requests]i128 = .{0} ** config.max_requests,
            head: usize = 0,
            count: usize = 0,
        };

        var entries: [max_clients]Entry = [_]Entry{.{}} ** max_clients;
        var entries_len: usize = 0;

        fn find(key: []const u8) ?*Entry {
            const k = key[0..@min(key.len, 64)];
            for (entries[0..entries_len]) |*e| {
                if (e.key_len == k.len and std.mem.eql(u8, e.key[0..e.key_len], k)) return e;
            }
            return null;
        }

        fn create(key: []const u8) ?*Entry {
            if (entries_len >= max_clients) return null;
            const e = &entries[entries_len];
            const k = key[0..@min(key.len, 64)];
            @memcpy(e.key[0..k.len], k);
            e.key_len = k.len;
            e.head = 0;
            e.count = 0;
            entries_len += 1;
            return e;
        }

        fn handle(ctx: *Context) anyerror!void {
            const key = ctx.request.header(config.key_header) orelse "unknown";
            const entry = find(key) orelse create(key) orelse {
                // Store full: fail open so we don't DoS legitimate traffic.
                try ctx.next();
                return;
            };

            const now: i128 = nowNs();
            const window_ns: i128 = @as(i128, config.window_seconds) * std.time.ns_per_s;
            const cutoff = now - window_ns;

            // Evict stamps older than the cutoff from the tail.
            while (entry.count > 0) {
                const tail = (entry.head + config.max_requests - entry.count) % config.max_requests;
                if (entry.stamps[tail] > cutoff) break;
                entry.count -= 1;
            }

            if (entry.count >= config.max_requests) {
                ctx.respond(.too_many_requests, "text/plain; charset=utf-8", "429 Too Many Requests");
                var buf: [16]u8 = undefined;
                const retry = std.fmt.bufPrint(&buf, "{d}", .{config.window_seconds}) catch "60";
                ctx.response.headers.append(ctx.allocator, "Retry-After", retry) catch {};
                return;
            }

            // Record this request.
            entry.stamps[entry.head] = now;
            entry.head = (entry.head + 1) % config.max_requests;
            if (entry.count < config.max_requests) entry.count += 1;

            try ctx.next();
        }
    };
    return &S.handle;
}

// ── Tests ──────────────────────────────────────────────────────────────

const Request = @import("../core/http/request.zig").Request;
const StatusCode = @import("../core/http/status.zig").StatusCode;
const Router = @import("../router/router.zig").Router;

test "throttle allows up to max then 429s" {
    const H = struct {
        fn h(ctx: *Context) !void {
            ctx.text(.ok, "ok");
        }
    };
    const App = Router.define(.{
        .middleware = &.{throttle(.{ .max_requests = 3, .window_seconds = 60 })},
        .routes = &.{Router.get("/", H.h)},
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // First three: OK.
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var req: Request = .{ .method = .GET, .path = "/" };
        try req.headers.append(alloc, "X-Forwarded-For", "5.5.5.5");
        defer req.deinit(alloc);
        var resp = try App.handler(alloc, &req);
        defer resp.deinit(alloc);
        try std.testing.expectEqual(StatusCode.ok, resp.status);
    }

    // Fourth: throttled.
    var req4: Request = .{ .method = .GET, .path = "/" };
    try req4.headers.append(alloc, "X-Forwarded-For", "5.5.5.5");
    defer req4.deinit(alloc);
    var resp4 = try App.handler(alloc, &req4);
    defer resp4.deinit(alloc);
    try std.testing.expectEqual(StatusCode.too_many_requests, resp4.status);
    try std.testing.expect(resp4.headers.get("Retry-After") != null);
}

test "throttle keys are isolated per client" {
    const H = struct {
        fn h(ctx: *Context) !void {
            ctx.text(.ok, "ok");
        }
    };
    const App = Router.define(.{
        .middleware = &.{throttle(.{ .max_requests = 1, .window_seconds = 60 })},
        .routes = &.{Router.get("/", H.h)},
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var reqA: Request = .{ .method = .GET, .path = "/" };
    try reqA.headers.append(alloc, "X-Forwarded-For", "1.1.1.1");
    defer reqA.deinit(alloc);
    var respA = try App.handler(alloc, &reqA);
    defer respA.deinit(alloc);
    try std.testing.expectEqual(StatusCode.ok, respA.status);

    var reqB: Request = .{ .method = .GET, .path = "/" };
    try reqB.headers.append(alloc, "X-Forwarded-For", "2.2.2.2");
    defer reqB.deinit(alloc);
    var respB = try App.handler(alloc, &reqB);
    defer respB.deinit(alloc);
    try std.testing.expectEqual(StatusCode.ok, respB.status);
}
