//! Per-request audit/action-log middleware.
//!
//! Distinct from `structuredLogger` (which targets debugging): this writes a
//! compact per-action record suitable for compliance trails. Each record
//! captures method, path, status, client IP, and a user identifier that the
//! handler populates via `ctx.assign("audit_user", ...)`.
//!
//! Pluggable sink: pass any `Sink` struct with a `write([]const u8) void`
//! method (e.g., a DB writer or a file writer). A stderr sink is provided
//! for convenience.
const std = @import("std");
const native_os = @import("builtin").os.tag;
const Context = @import("context.zig").Context;
const HandlerFn = @import("context.zig").HandlerFn;

fn unixTs() i64 {
    if (native_os == .linux) {
        const linux = std.os.linux;
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(linux.CLOCK.REALTIME, &ts);
        return ts.sec;
    }
    const c = std.c;
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.REALTIME, &ts);
    return ts.sec;
}

pub const ActionLogConfig = struct {
    /// Where entries are flushed. Must have `fn write(line: []const u8) void`.
    sink: type,
    /// Key in ctx.assigns where the handler stored a user id (or similar).
    user_assign_key: []const u8 = "audit_user",
    /// Header containing the client IP (usually X-Forwarded-For behind a proxy).
    client_ip_header: []const u8 = "X-Forwarded-For",
};

pub fn actionLog(comptime config: ActionLogConfig) HandlerFn {
    const S = struct {
        fn handle(ctx: *Context) anyerror!void {
            try ctx.next();

            const user = ctx.getAssign(config.user_assign_key) orelse "-";
            const ip_raw = ctx.request.header(config.client_ip_header) orelse "-";
            const ip = firstIp(ip_raw);
            const method = @tagName(ctx.request.method);
            const path = ctx.request.path;
            const status = @intFromEnum(ctx.response.status);
            const ts = unixTs();

            var buf: [1024]u8 = undefined;
            const line = std.fmt.bufPrint(
                &buf,
                "{d} {s} {s} {d} user={s} ip={s}\n",
                .{ ts, method, path, status, user, ip },
            ) catch return;
            _ = config.sink.write(line);
        }
    };
    return &S.handle;
}

fn firstIp(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (std.mem.indexOfScalar(u8, trimmed, ',')) |c| {
        return std.mem.trim(u8, trimmed[0..c], " \t");
    }
    return trimmed;
}

/// Built-in stderr sink. Good enough for development and container stdout
/// collection; production setups should supply their own sink (DB or file).
pub const StderrSink = struct {
    pub fn write(line: []const u8) void {
        var buf: [4096]u8 = undefined;
        var w = std.fs.File.stderr().writer(&buf);
        w.interface.writeAll(line) catch {};
        w.interface.flush() catch {};
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

const Request = @import("../core/http/request.zig").Request;
const StatusCode = @import("../core/http/status.zig").StatusCode;
const Router = @import("../router/router.zig").Router;

// Test-only sink that accumulates into a static buffer.
const CaptureSink = struct {
    var buf: [4096]u8 = undefined;
    var len: usize = 0;

    pub fn write(line: []const u8) void {
        const copy_len = @min(line.len, buf.len - len);
        @memcpy(buf[len .. len + copy_len], line[0..copy_len]);
        len += copy_len;
    }

    fn reset() void {
        len = 0;
    }
    fn captured() []const u8 {
        return buf[0..len];
    }
};

test "action log emits method path status user ip" {
    CaptureSink.reset();

    const H = struct {
        fn h(ctx: *Context) !void {
            ctx.assign("audit_user", "alice");
            ctx.text(.ok, "ok");
        }
    };
    const App = Router.define(.{
        .middleware = &.{actionLog(.{ .sink = CaptureSink })},
        .routes = &.{Router.get("/things", H.h)},
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req: Request = .{ .method = .GET, .path = "/things" };
    try req.headers.append(alloc, "X-Forwarded-For", "1.2.3.4, 10.0.0.1");
    defer req.deinit(alloc);
    var resp = try App.handler(alloc, &req);
    defer resp.deinit(alloc);

    const line = CaptureSink.captured();
    try std.testing.expect(std.mem.indexOf(u8, line, "GET /things") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "user=alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "ip=1.2.3.4") != null);
}

test "action log missing user renders dash" {
    CaptureSink.reset();

    const H = struct {
        fn h(ctx: *Context) !void {
            ctx.text(.ok, "ok");
        }
    };
    const App = Router.define(.{
        .middleware = &.{actionLog(.{ .sink = CaptureSink })},
        .routes = &.{Router.get("/", H.h)},
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req: Request = .{ .method = .GET, .path = "/" };
    defer req.deinit(alloc);
    var resp = try App.handler(alloc, &req);
    defer resp.deinit(alloc);

    const line = CaptureSink.captured();
    try std.testing.expect(std.mem.indexOf(u8, line, "user=-") != null);
}
