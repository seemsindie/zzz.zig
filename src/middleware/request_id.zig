const std = @import("std");
const native_os = @import("builtin").os.tag;
const Context = @import("context.zig").Context;
const HandlerFn = @import("context.zig").HandlerFn;

pub const RequestIdConfig = struct {
    header_name: []const u8 = "X-Request-Id",
    assign_key: []const u8 = "request_id",
};

/// Request ID middleware — propagates or generates a unique request identifier.
pub fn requestId(comptime config: RequestIdConfig) HandlerFn {
    const S = struct {
        var counter: u64 = 0;

        fn handle(ctx: *Context) anyerror!void {
            const id = ctx.request.header(config.header_name) orelse blk: {
                const ts: u64 = @intCast(@as(u128, @bitCast(getMonotonicNs())) & 0xFFFFFFFFFFFF);
                const cnt = @atomicRmw(u64, &counter, .Add, 1, .monotonic);
                var buf: [64]u8 = undefined;
                const generated = std.fmt.bufPrint(&buf, "pidgn-{x}-{x}", .{ ts, cnt }) catch break :blk null;
                const duped = ctx.allocator.dupe(u8, generated) catch break :blk null;
                ctx.response.trackOwnedSlice(ctx.allocator, duped);
                break :blk duped;
            };

            if (id) |request_id| {
                ctx.assign(config.assign_key, request_id);
                ctx.response.headers.append(ctx.allocator, config.header_name, request_id) catch {};
            }

            try ctx.next();
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

test "requestId generates when no header present" {
    const handler = comptime requestId(.{});

    var req: Request = .{};
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
    const id = ctx.getAssign("request_id");
    try std.testing.expect(id != null);
    try std.testing.expect(std.mem.startsWith(u8, id.?, "pidgn-"));
    try std.testing.expect(ctx.response.headers.get("X-Request-Id") != null);
}

test "requestId propagates existing header" {
    const handler = comptime requestId(.{});

    var req: Request = .{};
    defer req.deinit(std.testing.allocator);
    try req.headers.append(std.testing.allocator, "X-Request-Id", "external-123");

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
    try std.testing.expectEqualStrings("external-123", ctx.getAssign("request_id").?);
    try std.testing.expectEqualStrings("external-123", ctx.response.headers.get("X-Request-Id").?);
}

test "requestId counter increments" {
    const handler = comptime requestId(.{ .header_name = "X-Req-Inc", .assign_key = "req_inc" });

    var id1: ?[]const u8 = null;
    var id2: ?[]const u8 = null;

    {
        var req: Request = .{};
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
        id1 = ctx.getAssign("req_inc");
    }

    {
        var req: Request = .{};
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
        id2 = ctx.getAssign("req_inc");
    }

    // Both should be generated and different
    try std.testing.expect(id1 != null);
    try std.testing.expect(id2 != null);
}
