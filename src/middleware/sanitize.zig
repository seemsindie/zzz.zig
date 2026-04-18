//! Input sanitization primitives.
//!
//! None of these mutate input — they write a sanitized copy to the supplied
//! allocator. Intended for sanitizing user-supplied data before storage or
//! rendering outside of the template engine (which already HTML-escapes).
const std = @import("std");

/// Escape HTML-special characters so the result is safe to splice into
/// element text or an attribute value. Returns a newly-allocated slice.
pub fn escapeHtml(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, input.len);
    for (input) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&#39;"),
            else => try out.append(allocator, ch),
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Remove anything between `<` and `>`. Naive — for cases where you want to
/// strip markup entirely rather than render it. Does not decode entities.
pub fn stripTags(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, input.len);
    var in_tag = false;
    for (input) |ch| {
        if (in_tag) {
            if (ch == '>') in_tag = false;
        } else {
            if (ch == '<') {
                in_tag = true;
            } else {
                try out.append(allocator, ch);
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Collapse runs of ASCII whitespace into a single space and trim the ends.
pub fn normalizeWhitespace(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, input.len);
    var prev_ws = true; // treat start as whitespace to trim leading
    for (input) |ch| {
        const is_ws = ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0B or ch == 0x0C;
        if (is_ws) {
            if (!prev_ws) try out.append(allocator, ' ');
            prev_ws = true;
        } else {
            try out.append(allocator, ch);
            prev_ws = false;
        }
    }
    // Trim trailing space (only one possible due to our logic).
    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        _ = out.pop();
    }
    return out.toOwnedSlice(allocator);
}

// ── Tests ──────────────────────────────────────────────────────────────

test "escapeHtml escapes all five specials" {
    const got = try escapeHtml(std.testing.allocator, "a <b> & \"c\" 'd'");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("a &lt;b&gt; &amp; &quot;c&quot; &#39;d&#39;", got);
}

test "escapeHtml preserves plain text" {
    const got = try escapeHtml(std.testing.allocator, "hello world");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hello world", got);
}

test "stripTags removes markup" {
    const got = try stripTags(std.testing.allocator, "<b>hi</b> <a href=\"x\">click</a>");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hi click", got);
}

test "normalizeWhitespace collapses and trims" {
    const got = try normalizeWhitespace(std.testing.allocator, "  hello \t\n world  \t");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hello world", got);
}

test "normalizeWhitespace empty" {
    const got = try normalizeWhitespace(std.testing.allocator, "   \n\t  ");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("", got);
}
