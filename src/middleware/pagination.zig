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

// ── Cursor pagination ──────────────────────────────────────────────────

/// Opaque cursor handed to the client between page fetches. Encoding is
/// URL-safe base64 of whatever opaque bytes the handler produced (typically
/// the sort-key of the last row on the page — a timestamp, a compound ID, etc).
///
/// Pidgn doesn't prescribe what the decoded bytes represent; it just decodes
/// the base64 envelope so handlers get a clean slice to parse into their own
/// shape. Encoding back to base64 is handled by `encodeCursor`.
pub const Cursor = struct {
    /// Requested page size (clamped).
    limit: u32,
    /// Raw cursor value from the client, or null if none (first page).
    raw: ?[]const u8,
    /// The raw cursor, URL-safe-base64-decoded. Caller-owned.
    decoded: ?[]u8,

    pub fn deinit(self: *Cursor, allocator: std.mem.Allocator) void {
        if (self.decoded) |d| allocator.free(d);
    }
};

pub const CursorOptions = struct {
    default_per_page: u32 = 20,
    max_per_page: u32 = 100,
    min_per_page: u32 = 1,
    /// Query param holding the cursor. Default matches REST convention.
    cursor_param: []const u8 = "cursor",
    /// Query param for page size. Both `per_page` and `limit` are accepted.
    per_page_param: []const u8 = "per_page",
};

const base64_url = std.base64.url_safe_no_pad;

/// Parse cursor pagination params from the query string. The decoded cursor
/// bytes are allocated from `allocator` — call `Cursor.deinit` when done.
pub fn cursorFromQuery(
    allocator: std.mem.Allocator,
    ctx: *const Context,
    opts: CursorOptions,
) !Cursor {
    const per_page_raw = ctx.query.get(opts.per_page_param) orelse ctx.query.get("limit");
    const limit = clamp(
        parseU32(per_page_raw) orelse opts.default_per_page,
        opts.min_per_page,
        opts.max_per_page,
    );

    const raw = ctx.query.get(opts.cursor_param);
    var decoded: ?[]u8 = null;
    if (raw) |r| {
        if (r.len > 0) {
            const dec_len = base64_url.Decoder.calcSizeForSlice(r) catch null;
            if (dec_len) |n| {
                const buf = try allocator.alloc(u8, n);
                base64_url.Decoder.decode(buf, r) catch {
                    allocator.free(buf);
                    return error.InvalidCursor;
                };
                decoded = buf;
            } else {
                return error.InvalidCursor;
            }
        }
    }

    return .{ .limit = limit, .raw = raw, .decoded = decoded };
}

/// Encode opaque bytes as a URL-safe-base64 cursor token suitable for the
/// `?cursor=...` query param.
pub fn encodeCursor(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const n = base64_url.Encoder.calcSize(raw.len);
    const out = try allocator.alloc(u8, n);
    _ = base64_url.Encoder.encode(out, raw);
    return out;
}

/// Build a cursor from a numeric ID, the simplest common case.
pub fn encodeIntCursor(allocator: std.mem.Allocator, id: i64) ![]u8 {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable;
    return encodeCursor(allocator, s);
}

/// Decode a numeric-ID cursor produced by `encodeIntCursor`. Returns null
/// when the cursor is missing or unparseable (i.e. first page or malformed).
pub fn decodeIntCursor(cursor: *const Cursor) ?i64 {
    const d = cursor.decoded orelse return null;
    return std.fmt.parseInt(i64, d, 10) catch null;
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

// ── Cursor pagination tests ────────────────────────────────────────────

test "cursor: first page has no cursor, default limit" {
    var req: Request = .{};
    defer req.deinit(std.testing.allocator);
    const ctx = makeCtx(std.testing.allocator, &req);

    var c = try cursorFromQuery(std.testing.allocator, &ctx, .{});
    defer c.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 20), c.limit);
    try std.testing.expect(c.raw == null);
    try std.testing.expect(c.decoded == null);
}

test "cursor: decoded bytes match round-trip" {
    const token = try encodeCursor(std.testing.allocator, "user:42:stamp:170000");
    defer std.testing.allocator.free(token);

    var req: Request = .{};
    defer req.deinit(std.testing.allocator);
    var ctx = makeCtx(std.testing.allocator, &req);
    ctx.query.put("cursor", token);
    ctx.query.put("per_page", "50");

    var c = try cursorFromQuery(std.testing.allocator, &ctx, .{});
    defer c.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 50), c.limit);
    try std.testing.expectEqualStrings("user:42:stamp:170000", c.decoded.?);
}

test "cursor: int cursor round-trip" {
    const token = try encodeIntCursor(std.testing.allocator, 12345);
    defer std.testing.allocator.free(token);

    var req: Request = .{};
    defer req.deinit(std.testing.allocator);
    var ctx = makeCtx(std.testing.allocator, &req);
    ctx.query.put("cursor", token);

    var c = try cursorFromQuery(std.testing.allocator, &ctx, .{});
    defer c.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 12345), decodeIntCursor(&c).?);
}

test "cursor: malformed cursor rejected" {
    var req: Request = .{};
    defer req.deinit(std.testing.allocator);
    var ctx = makeCtx(std.testing.allocator, &req);
    // Not valid URL-safe base64 (contains '#'), but calcSizeForSlice tolerates
    // length; decode will fail — which we surface as error.InvalidCursor.
    ctx.query.put("cursor", "not$$base64@@@");
    try std.testing.expectError(error.InvalidCursor, cursorFromQuery(std.testing.allocator, &ctx, .{}));
}

test "cursor: limit clamped to max" {
    var req: Request = .{};
    defer req.deinit(std.testing.allocator);
    var ctx = makeCtx(std.testing.allocator, &req);
    ctx.query.put("per_page", "9999");

    var c = try cursorFromQuery(std.testing.allocator, &ctx, .{ .max_per_page = 100 });
    defer c.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 100), c.limit);
}
