//! Minimal User-Agent parser.
//!
//! Heuristic-based — recognises the common browsers and OSes, and flags
//! crawlers. Not a substitute for a database-backed parser if you need
//! precise version tracking, but good enough for routing, logging, and
//! simple analytics.
const std = @import("std");
const Context = @import("context.zig").Context;

pub const Browser = enum { chrome, firefox, safari, edge, opera, other, unknown };
pub const Os = enum { windows, macos, linux, android, ios, other, unknown };

pub const UserAgent = struct {
    browser: Browser,
    os: Os,
    is_mobile: bool,
    is_bot: bool,
    raw: []const u8,
};

/// Parse a raw User-Agent header string.
pub fn parse(raw: []const u8) UserAgent {
    if (raw.len == 0) {
        return .{ .browser = .unknown, .os = .unknown, .is_mobile = false, .is_bot = false, .raw = raw };
    }

    const is_bot = looksLikeBot(raw);

    // Order matters: Edge includes "Chrome", Chrome includes "Safari", etc.
    const browser: Browser = if (is_bot)
        .other
    else if (contains(raw, "Edg/") or contains(raw, "Edge/"))
        .edge
    else if (contains(raw, "OPR/") or contains(raw, "Opera"))
        .opera
    else if (contains(raw, "Firefox/"))
        .firefox
    else if (contains(raw, "Chrome/"))
        .chrome
    else if (contains(raw, "Safari/"))
        .safari
    else
        .unknown;

    const os: Os = if (contains(raw, "Android"))
        .android
    else if (contains(raw, "iPhone") or contains(raw, "iPad") or contains(raw, "iOS"))
        .ios
    else if (contains(raw, "Mac OS X") or contains(raw, "Macintosh"))
        .macos
    else if (contains(raw, "Windows"))
        .windows
    else if (contains(raw, "Linux"))
        .linux
    else
        .unknown;

    const is_mobile = contains(raw, "Mobile") or os == .android or os == .ios;

    return .{ .browser = browser, .os = os, .is_mobile = is_mobile, .is_bot = is_bot, .raw = raw };
}

/// Parse the User-Agent from a request context.
pub fn fromContext(ctx: *const Context) UserAgent {
    return parse(ctx.request.header("User-Agent") orelse "");
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn looksLikeBot(raw: []const u8) bool {
    const markers = [_][]const u8{
        "bot",      "Bot",      "crawler",   "Crawler", "spider",
        "Spider",   "slurp",    "Slurp",     "curl/",   "wget/",
        "Googlebot", "Bingbot", "DuckDuckBot", "facebookexternalhit",
    };
    for (markers) |m| if (contains(raw, m)) return true;
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "chrome on macos" {
    const ua = parse("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
    try std.testing.expectEqual(Browser.chrome, ua.browser);
    try std.testing.expectEqual(Os.macos, ua.os);
    try std.testing.expect(!ua.is_mobile);
    try std.testing.expect(!ua.is_bot);
}

test "safari on iphone is mobile" {
    const ua = parse("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1");
    try std.testing.expectEqual(Browser.safari, ua.browser);
    try std.testing.expectEqual(Os.ios, ua.os);
    try std.testing.expect(ua.is_mobile);
}

test "firefox on linux" {
    const ua = parse("Mozilla/5.0 (X11; Linux x86_64; rv:121.0) Gecko/20100101 Firefox/121.0");
    try std.testing.expectEqual(Browser.firefox, ua.browser);
    try std.testing.expectEqual(Os.linux, ua.os);
}

test "edge wins over chrome" {
    const ua = parse("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0");
    try std.testing.expectEqual(Browser.edge, ua.browser);
    try std.testing.expectEqual(Os.windows, ua.os);
}

test "googlebot is a bot" {
    const ua = parse("Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)");
    try std.testing.expect(ua.is_bot);
}

test "empty UA is unknown" {
    const ua = parse("");
    try std.testing.expectEqual(Browser.unknown, ua.browser);
    try std.testing.expectEqual(Os.unknown, ua.os);
}

test "curl is a bot" {
    const ua = parse("curl/8.0.1");
    try std.testing.expect(ua.is_bot);
}
