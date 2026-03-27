const std = @import("std");
const native_os = @import("builtin").os.tag;
const Context = @import("context.zig").Context;
const HandlerFn = @import("context.zig").HandlerFn;
const Method = @import("../core/http/request.zig").Method;

pub const MetricsConfig = struct {
    path: []const u8 = "/metrics",
};

/// Metrics middleware — collects request counts, status codes, method counts,
/// and latency. Serves Prometheus exposition format at the configured path.
pub fn metrics(comptime config: MetricsConfig) HandlerFn {
    const S = struct {
        var request_count: u64 = 0;
        // 0=1xx, 1=2xx, 2=3xx, 3=4xx, 4=5xx, 5=other
        var status_counts: [6]u64 = .{ 0, 0, 0, 0, 0, 0 };
        // one per Method enum value (GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS, CONNECT, TRACE)
        var method_counts: [9]u64 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        var latency_sum_us: u64 = 0;
        var latency_count: u64 = 0;

        fn statusBucket(code: u16) usize {
            return switch (code / 100) {
                1 => 0,
                2 => 1,
                3 => 2,
                4 => 3,
                5 => 4,
                else => 5,
            };
        }

        fn methodIndex(method: Method) usize {
            return @intFromEnum(method);
        }

        fn handle(ctx: *Context) anyerror!void {
            if (ctx.request.method == .GET and std.mem.eql(u8, ctx.request.path, config.path)) {
                // Serve metrics
                const req_count = @atomicLoad(u64, &request_count, .monotonic);
                const lat_sum = @atomicLoad(u64, &latency_sum_us, .monotonic);
                const lat_count = @atomicLoad(u64, &latency_count, .monotonic);

                var status_snap: [6]u64 = undefined;
                for (0..6) |i| {
                    status_snap[i] = @atomicLoad(u64, &status_counts[i], .monotonic);
                }

                var method_snap: [9]u64 = undefined;
                for (0..9) |i| {
                    method_snap[i] = @atomicLoad(u64, &method_counts[i], .monotonic);
                }

                var buf: [2048]u8 = undefined;
                const result = std.fmt.bufPrint(&buf,
                    \\# HELP pidgn_requests_total Total number of HTTP requests.
                    \\# TYPE pidgn_requests_total counter
                    \\pidgn_requests_total {d}
                    \\# HELP pidgn_requests_by_status HTTP requests by status class.
                    \\# TYPE pidgn_requests_by_status counter
                    \\pidgn_requests_by_status{{class="1xx"}} {d}
                    \\pidgn_requests_by_status{{class="2xx"}} {d}
                    \\pidgn_requests_by_status{{class="3xx"}} {d}
                    \\pidgn_requests_by_status{{class="4xx"}} {d}
                    \\pidgn_requests_by_status{{class="5xx"}} {d}
                    \\pidgn_requests_by_status{{class="other"}} {d}
                    \\# HELP pidgn_requests_by_method HTTP requests by method.
                    \\# TYPE pidgn_requests_by_method counter
                    \\pidgn_requests_by_method{{method="GET"}} {d}
                    \\pidgn_requests_by_method{{method="HEAD"}} {d}
                    \\pidgn_requests_by_method{{method="POST"}} {d}
                    \\pidgn_requests_by_method{{method="PUT"}} {d}
                    \\pidgn_requests_by_method{{method="DELETE"}} {d}
                    \\pidgn_requests_by_method{{method="PATCH"}} {d}
                    \\pidgn_requests_by_method{{method="OPTIONS"}} {d}
                    \\pidgn_requests_by_method{{method="CONNECT"}} {d}
                    \\pidgn_requests_by_method{{method="TRACE"}} {d}
                    \\# HELP pidgn_request_duration_us_sum Sum of request durations in microseconds.
                    \\# TYPE pidgn_request_duration_us_sum counter
                    \\pidgn_request_duration_us_sum {d}
                    \\# HELP pidgn_request_duration_us_count Number of timed requests.
                    \\# TYPE pidgn_request_duration_us_count counter
                    \\pidgn_request_duration_us_count {d}
                    \\
                , .{
                    req_count,
                    status_snap[0],
                    status_snap[1],
                    status_snap[2],
                    status_snap[3],
                    status_snap[4],
                    status_snap[5],
                    method_snap[0],
                    method_snap[1],
                    method_snap[2],
                    method_snap[3],
                    method_snap[4],
                    method_snap[5],
                    method_snap[6],
                    method_snap[7],
                    method_snap[8],
                    lat_sum,
                    lat_count,
                }) catch {
                    ctx.text(.internal_server_error, "metrics format error");
                    return;
                };

                const duped = ctx.allocator.dupe(u8, result) catch {
                    ctx.text(.internal_server_error, "metrics alloc error");
                    return;
                };
                ctx.response.trackOwnedSlice(ctx.allocator, duped);
                ctx.respond(.ok, "text/plain; charset=utf-8", duped);
                return;
            }

            // Track the request
            const start = getMonotonicNs();
            try ctx.next();
            const elapsed_ns = getMonotonicNs() - start;
            const elapsed_us: u64 = @intCast(@divTrunc(elapsed_ns, 1000));

            _ = @atomicRmw(u64, &request_count, .Add, 1, .monotonic);
            _ = @atomicRmw(u64, &status_counts[statusBucket(ctx.response.status.code())], .Add, 1, .monotonic);
            _ = @atomicRmw(u64, &method_counts[methodIndex(ctx.request.method)], .Add, 1, .monotonic);
            _ = @atomicRmw(u64, &latency_sum_us, .Add, elapsed_us, .monotonic);
            _ = @atomicRmw(u64, &latency_count, .Add, 1, .monotonic);
        }
    };
    return &S.handle;
}

fn getMonotonicNs() i128 {
    if (native_os == .linux) {
        const linux = std.os.linux;
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
        return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    } else {
        const c = std.c;
        var ts: c.timespec = undefined;
        _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
        return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const Request = @import("../core/http/request.zig").Request;
const StatusCode = @import("../core/http/status.zig").StatusCode;

test "metrics serves at /metrics" {
    const handler = comptime metrics(.{});

    var req: Request = .{ .method = .GET, .path = "/metrics" };
    defer req.deinit(std.testing.allocator);

    var ctx: Context = .{
        .request = &req,
        .response = .{},
        .params = .{},
        .query = .{},
        .assigns = .{},
        .allocator = std.testing.allocator,
        .next_handler = null,
    };
    defer ctx.response.deinit(std.testing.allocator);

    try handler(&ctx);
    try std.testing.expectEqual(StatusCode.ok, ctx.response.status);
    try std.testing.expect(ctx.response.body != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx.response.body.?, "pidgn_requests_total") != null);
}

test "metrics increments counters" {
    const handler = comptime metrics(.{ .path = "/test-metrics" });

    const OkHandler = struct {
        fn handle(ctx: *Context) anyerror!void {
            ctx.text(.ok, "ok");
        }
    };

    // Make a normal request to increment counters
    {
        var req: Request = .{ .method = .GET, .path = "/api/test" };
        defer req.deinit(std.testing.allocator);

        var ctx: Context = .{
            .request = &req,
            .response = .{},
            .params = .{},
            .query = .{},
            .assigns = .{},
            .allocator = std.testing.allocator,
            .next_handler = &OkHandler.handle,
        };
        defer ctx.response.deinit(std.testing.allocator);

        try handler(&ctx);
        try std.testing.expectEqual(StatusCode.ok, ctx.response.status);
    }

    // Now check metrics
    {
        var req: Request = .{ .method = .GET, .path = "/test-metrics" };
        defer req.deinit(std.testing.allocator);

        var ctx: Context = .{
            .request = &req,
            .response = .{},
            .params = .{},
            .query = .{},
            .assigns = .{},
            .allocator = std.testing.allocator,
            .next_handler = null,
        };
        defer ctx.response.deinit(std.testing.allocator);

        try handler(&ctx);
        try std.testing.expect(ctx.response.body != null);
        // Should have at least 1 request counted
        try std.testing.expect(std.mem.indexOf(u8, ctx.response.body.?, "pidgn_requests_total") != null);
    }
}

test "metrics passes through non-matching paths" {
    const handler = comptime metrics(.{ .path = "/test-metrics-pass" });

    const OkHandler = struct {
        fn handle(ctx: *Context) anyerror!void {
            ctx.text(.ok, "next");
        }
    };

    var req: Request = .{ .method = .GET, .path = "/api/users" };
    defer req.deinit(std.testing.allocator);

    var ctx: Context = .{
        .request = &req,
        .response = .{},
        .params = .{},
        .query = .{},
        .assigns = .{},
        .allocator = std.testing.allocator,
        .next_handler = &OkHandler.handle,
    };
    defer ctx.response.deinit(std.testing.allocator);

    try handler(&ctx);
    try std.testing.expectEqualStrings("next", ctx.response.body.?);
}
