//! Pagination helpers for list endpoints.
//!
//! Parses `page` and `per_page` (or `limit`/`offset`) from the request query,
//! clamps to sensible bounds, and exposes derived offset/limit along with page
//! metadata so handlers can build response envelopes or navigation links.
//!
//! Typical usage:
//! ```zig
//! fn index(ctx: *Context) !void {
//!     const p = pidgn.pagination.fromQuery(ctx, .{});
//!     const rows = try db.all(Post, .limit(p.limit).offset(p.offset));
//!     const meta = p.meta(total_count);
//!     ...
//! }
//! ```
const std = @import("std");
const Context = @import("context.zig").Context;

pub const Options = struct {
    default_per_page: u32 = 20,
    max_per_page: u32 = 100,
    min_per_page: u32 = 1,
};

pub const Page = struct {
    page: u32,
    per_page: u32,
    offset: u32,
    limit: u32,

    pub const Meta = struct {
        page: u32,
        per_page: u32,
        total: u64,
        total_pages: u32,
        has_prev: bool,
        has_next: bool,
    };

    pub fn meta(self: Page, total: u64) Meta {
        const total_pages: u32 = if (self.per_page == 0)
            0
        else blk: {
            const divided = total / self.per_page;
            const has_remainder = total % self.per_page != 0;
            const tp = divided + @as(u64, if (has_remainder) 1 else 0);
            break :blk @intCast(@min(tp, std.math.maxInt(u32)));
        };
        return .{
            .page = self.page,
            .per_page = self.per_page,
            .total = total,
            .total_pages = total_pages,
            .has_prev = self.page > 1,
            .has_next = self.page < total_pages,
        };
    }
};

/// Parse pagination params from the query string. Never fails — invalid or
/// missing values fall back to defaults.
pub fn fromQuery(ctx: *const Context, opts: Options) Page {
    // Accept either page/per_page or offset/limit; page wins if both given.
    const page_raw = ctx.query.get("page");
    const per_page_raw = ctx.query.get("per_page") orelse ctx.query.get("limit");
    const offset_raw = ctx.query.get("offset");

    const per_page = clamp(
        parseU32(per_page_raw) orelse opts.default_per_page,
        opts.min_per_page,
        opts.max_per_page,
    );

    if (page_raw) |v| {
        const page = @max(parseU32(v) orelse 1, 1);
        return .{
            .page = page,
            .per_page = per_page,
            .offset = (page - 1) *| per_page,
            .limit = per_page,
        };
    }

    // offset/limit fallback
    const offset = parseU32(offset_raw) orelse 0;
    const page = (offset / per_page) + 1;
    return .{
        .page = page,
        .per_page = per_page,
        .offset = offset,
        .limit = per_page,
    };
}

fn parseU32(s: ?[]const u8) ?u32 {
    const v = s orelse return null;
    return std.fmt.parseInt(u32, v, 10) catch null;
}

fn clamp(v: u32, lo: u32, hi: u32) u32 {
    return @min(@max(v, lo), hi);
}

// ── Tests ──────────────────────────────────────────────────────────────

const Request = @import("../core/http/request.zig").Request;

fn makeCtx(alloc: std.mem.Allocator, req: *const Request) Context {
    return .{
        .request = req,
        .response = .{},
        .params = .{},
        .query = .{},
        .assigns = .{},
        .allocator = alloc,
        .next_handler = null,
    };
}

test "defaults when no params" {
    var req: Request = .{};
    defer req.deinit(std.testing.allocator);
    const ctx = makeCtx(std.testing.allocator, &req);
    const p = fromQuery(&ctx, .{});
    try std.testing.expectEqual(@as(u32, 1), p.page);
    try std.testing.expectEqual(@as(u32, 20), p.per_page);
    try std.testing.expectEqual(@as(u32, 0), p.offset);
}

test "page and per_page from query" {
    var req: Request = .{};
    defer req.deinit(std.testing.allocator);
    var ctx = makeCtx(std.testing.allocator, &req);
    ctx.query.put("page", "3");
    ctx.query.put("per_page", "25");
    const p = fromQuery(&ctx, .{});
    try std.testing.expectEqual(@as(u32, 3), p.page);
    try std.testing.expectEqual(@as(u32, 25), p.per_page);
    try std.testing.expectEqual(@as(u32, 50), p.offset);
    try std.testing.expectEqual(@as(u32, 25), p.limit);
}

test "per_page clamped to max" {
    var req: Request = .{};
    defer req.deinit(std.testing.allocator);
    var ctx = makeCtx(std.testing.allocator, &req);
    ctx.query.put("per_page", "9999");
    const p = fromQuery(&ctx, .{ .max_per_page = 100 });
    try std.testing.expectEqual(@as(u32, 100), p.per_page);
}

test "offset/limit fallback" {
    var req: Request = .{};
    defer req.deinit(std.testing.allocator);
    var ctx = makeCtx(std.testing.allocator, &req);
    ctx.query.put("offset", "40");
    ctx.query.put("limit", "20");
    const p = fromQuery(&ctx, .{});
    try std.testing.expectEqual(@as(u32, 40), p.offset);
    try std.testing.expectEqual(@as(u32, 20), p.limit);
    try std.testing.expectEqual(@as(u32, 3), p.page); // 40/20 + 1
}

test "meta total_pages and flags" {
    const p: Page = .{ .page = 2, .per_page = 10, .offset = 10, .limit = 10 };
    const m = p.meta(25);
    try std.testing.expectEqual(@as(u32, 3), m.total_pages);
    try std.testing.expect(m.has_prev);
    try std.testing.expect(m.has_next);

    const last = (Page{ .page = 3, .per_page = 10, .offset = 20, .limit = 10 }).meta(25);
    try std.testing.expect(last.has_prev);
    try std.testing.expect(!last.has_next);
}

test "invalid values fall back" {
    var req: Request = .{};
    defer req.deinit(std.testing.allocator);
    var ctx = makeCtx(std.testing.allocator, &req);
    ctx.query.put("page", "abc");
    ctx.query.put("per_page", "-5");
    const p = fromQuery(&ctx, .{});
    try std.testing.expectEqual(@as(u32, 1), p.page);
    try std.testing.expectEqual(@as(u32, 20), p.per_page);
}
