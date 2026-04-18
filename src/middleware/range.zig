//! HTTP Range request support (RFC 7233 subset).
//!
//! Handlers that serve byte-addressable resources (videos, downloads) can call
//! `respondWithRange(ctx, data, content_type)` to honor a `Range: bytes=...`
//! header — responding 206 Partial Content with a `Content-Range` header when
//! the client asked for a byte range, or 200 with the full body otherwise.
//!
//! Only single-range requests are supported; multipart/byteranges is not.
const std = @import("std");
const Context = @import("context.zig").Context;

pub const Range = struct {
    start: u64,
    end_inclusive: u64,
    total: u64,

    pub fn len(self: Range) u64 {
        return self.end_inclusive + 1 - self.start;
    }
};

/// Parse a `Range: bytes=START-END` header. Returns null if the header is
/// absent, malformed, or unsatisfiable for the given total size. Supports
/// the three valid forms: `START-END`, `START-`, and `-SUFFIX_LENGTH`.
pub fn parse(header_value: ?[]const u8, total: u64) ?Range {
    const v = header_value orelse return null;
    if (!std.mem.startsWith(u8, v, "bytes=")) return null;
    const spec = v[6..];

    // Only single-range.
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return null;

    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
    const start_s = spec[0..dash];
    const end_s = spec[dash + 1 ..];

    if (start_s.len == 0) {
        // Suffix form: -N means the last N bytes.
        const n = std.fmt.parseInt(u64, end_s, 10) catch return null;
        if (n == 0 or total == 0) return null;
        const start = if (n >= total) 0 else total - n;
        return .{ .start = start, .end_inclusive = total - 1, .total = total };
    }

    const start = std.fmt.parseInt(u64, start_s, 10) catch return null;
    if (start >= total) return null;

    const end_inclusive = if (end_s.len == 0)
        total - 1
    else blk: {
        const e = std.fmt.parseInt(u64, end_s, 10) catch return null;
        break :blk @min(e, total - 1);
    };
    if (end_inclusive < start) return null;
    return .{ .start = start, .end_inclusive = end_inclusive, .total = total };
}

/// Respond with either 200 + full body or 206 + byte slice based on the
/// request's Range header. Always sets `Accept-Ranges: bytes`.
///
/// `data` is borrowed — the slice's lifetime must cover the response send.
pub fn respondWithRange(ctx: *Context, data: []const u8, content_type: []const u8) void {
    ctx.response.headers.append(ctx.allocator, "Accept-Ranges", "bytes") catch {};
    ctx.response.headers.append(ctx.allocator, "Content-Type", content_type) catch {};

    const hdr = ctx.request.header("Range");
    if (parse(hdr, data.len)) |r| {
        ctx.response.status = .partial_content;
        ctx.response.body = data[r.start .. r.end_inclusive + 1];

        var buf: [64]u8 = undefined;
        const cr = std.fmt.bufPrint(&buf, "bytes {d}-{d}/{d}", .{ r.start, r.end_inclusive, r.total }) catch return;
        const cr_owned = ctx.allocator.dupe(u8, cr) catch return;
        ctx.response.trackOwnedSlice(ctx.allocator, cr_owned);
        ctx.response.headers.append(ctx.allocator, "Content-Range", cr_owned) catch {};
        return;
    }

    // Range header missing, invalid, or unsatisfiable — serve the full body.
    // For an unsatisfiable Range we could return 416; we opt for 200 to stay
    // compatible with naive clients that send speculative Range headers.
    ctx.response.status = .ok;
    ctx.response.body = data;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "parse start-end range" {
    const r = parse("bytes=10-19", 100).?;
    try std.testing.expectEqual(@as(u64, 10), r.start);
    try std.testing.expectEqual(@as(u64, 19), r.end_inclusive);
    try std.testing.expectEqual(@as(u64, 10), r.len());
}

test "parse start- range" {
    const r = parse("bytes=50-", 100).?;
    try std.testing.expectEqual(@as(u64, 50), r.start);
    try std.testing.expectEqual(@as(u64, 99), r.end_inclusive);
}

test "parse suffix -N range" {
    const r = parse("bytes=-20", 100).?;
    try std.testing.expectEqual(@as(u64, 80), r.start);
    try std.testing.expectEqual(@as(u64, 99), r.end_inclusive);
}

test "parse rejects start beyond total" {
    try std.testing.expect(parse("bytes=200-", 100) == null);
}

test "parse rejects multi-range" {
    try std.testing.expect(parse("bytes=0-10,20-30", 100) == null);
}

test "parse rejects wrong prefix" {
    try std.testing.expect(parse("items=0-10", 100) == null);
    try std.testing.expect(parse(null, 100) == null);
}

const Request = @import("../core/http/request.zig").Request;
const StatusCode = @import("../core/http/status.zig").StatusCode;

test "respondWithRange 206 with Content-Range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req: Request = .{};
    try req.headers.append(alloc, "Range", "bytes=2-5");
    defer req.deinit(alloc);

    var ctx: Context = .{
        .request = &req,
        .response = .{},
        .params = .{},
        .query = .{},
        .assigns = .{},
        .allocator = alloc,
        .next_handler = null,
    };

    respondWithRange(&ctx, "abcdefghij", "text/plain");
    try std.testing.expectEqual(StatusCode.partial_content, ctx.response.status);
    try std.testing.expectEqualStrings("cdef", ctx.response.body.?);
    try std.testing.expectEqualStrings("bytes 2-5/10", ctx.response.headers.get("Content-Range").?);
    try std.testing.expectEqualStrings("bytes", ctx.response.headers.get("Accept-Ranges").?);
}

test "respondWithRange 200 without Range header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req: Request = .{};
    defer req.deinit(alloc);

    var ctx: Context = .{
        .request = &req,
        .response = .{},
        .params = .{},
        .query = .{},
        .assigns = .{},
        .allocator = alloc,
        .next_handler = null,
    };

    respondWithRange(&ctx, "hello", "text/plain");
    try std.testing.expectEqual(StatusCode.ok, ctx.response.status);
    try std.testing.expectEqualStrings("hello", ctx.response.body.?);
}
