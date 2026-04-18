//! Small HTML form-building helpers.
//!
//! These produce raw HTML strings so they compose with any rendering strategy
//! (string templates, renderPartial, direct writes). Values are HTML-escaped;
//! attribute values use `&quot;` encoding. For a full form-state abstraction
//! pair this with changesets from pidgn_db.
//!
//! Example inside a handler:
//! ```zig
//! const html = try pidgn.form.input(ctx.allocator, .{
//!     .name = "email", .type = "email", .value = current_user.email, .required = true,
//! });
//! ```
const std = @import("std");
const sanitize = @import("sanitize.zig");

pub const InputOpts = struct {
    name: []const u8,
    type: []const u8 = "text",
    value: []const u8 = "",
    id: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
    required: bool = false,
    disabled: bool = false,
    class: ?[]const u8 = null,
};

pub fn input(allocator: std.mem.Allocator, opts: InputOpts) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "<input");
    try appendAttr(allocator, &buf, "type", opts.type);
    try appendAttr(allocator, &buf, "name", opts.name);
    if (opts.id) |v| try appendAttr(allocator, &buf, "id", v);
    try appendAttr(allocator, &buf, "value", opts.value);
    if (opts.placeholder) |v| try appendAttr(allocator, &buf, "placeholder", v);
    if (opts.class) |v| try appendAttr(allocator, &buf, "class", v);
    if (opts.required) try buf.appendSlice(allocator, " required");
    if (opts.disabled) try buf.appendSlice(allocator, " disabled");
    try buf.appendSlice(allocator, ">");
    return buf.toOwnedSlice(allocator);
}

pub const TextareaOpts = struct {
    name: []const u8,
    value: []const u8 = "",
    id: ?[]const u8 = null,
    rows: ?u32 = null,
    cols: ?u32 = null,
    placeholder: ?[]const u8 = null,
    required: bool = false,
    class: ?[]const u8 = null,
};

pub fn textarea(allocator: std.mem.Allocator, opts: TextareaOpts) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "<textarea");
    try appendAttr(allocator, &buf, "name", opts.name);
    if (opts.id) |v| try appendAttr(allocator, &buf, "id", v);
    if (opts.placeholder) |v| try appendAttr(allocator, &buf, "placeholder", v);
    if (opts.class) |v| try appendAttr(allocator, &buf, "class", v);
    if (opts.rows) |v| try appendAttrInt(allocator, &buf, "rows", v);
    if (opts.cols) |v| try appendAttrInt(allocator, &buf, "cols", v);
    if (opts.required) try buf.appendSlice(allocator, " required");
    try buf.appendSlice(allocator, ">");
    const escaped = try sanitize.escapeHtml(allocator, opts.value);
    defer allocator.free(escaped);
    try buf.appendSlice(allocator, escaped);
    try buf.appendSlice(allocator, "</textarea>");
    return buf.toOwnedSlice(allocator);
}

pub const Option = struct { value: []const u8, label: []const u8 };
pub const SelectOpts = struct {
    name: []const u8,
    options: []const Option,
    selected: ?[]const u8 = null,
    id: ?[]const u8 = null,
    class: ?[]const u8 = null,
    required: bool = false,
};

pub fn select(allocator: std.mem.Allocator, opts: SelectOpts) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "<select");
    try appendAttr(allocator, &buf, "name", opts.name);
    if (opts.id) |v| try appendAttr(allocator, &buf, "id", v);
    if (opts.class) |v| try appendAttr(allocator, &buf, "class", v);
    if (opts.required) try buf.appendSlice(allocator, " required");
    try buf.appendSlice(allocator, ">");
    for (opts.options) |opt| {
        try buf.appendSlice(allocator, "<option");
        try appendAttr(allocator, &buf, "value", opt.value);
        if (opts.selected) |sel| {
            if (std.mem.eql(u8, sel, opt.value)) try buf.appendSlice(allocator, " selected");
        }
        try buf.appendSlice(allocator, ">");
        const escaped = try sanitize.escapeHtml(allocator, opt.label);
        defer allocator.free(escaped);
        try buf.appendSlice(allocator, escaped);
        try buf.appendSlice(allocator, "</option>");
    }
    try buf.appendSlice(allocator, "</select>");
    return buf.toOwnedSlice(allocator);
}

pub const CheckboxOpts = struct {
    name: []const u8,
    value: []const u8 = "1",
    checked: bool = false,
    id: ?[]const u8 = null,
    class: ?[]const u8 = null,
};

pub fn checkbox(allocator: std.mem.Allocator, opts: CheckboxOpts) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "<input type=\"checkbox\"");
    try appendAttr(allocator, &buf, "name", opts.name);
    try appendAttr(allocator, &buf, "value", opts.value);
    if (opts.id) |v| try appendAttr(allocator, &buf, "id", v);
    if (opts.class) |v| try appendAttr(allocator, &buf, "class", v);
    if (opts.checked) try buf.appendSlice(allocator, " checked");
    try buf.appendSlice(allocator, ">");
    return buf.toOwnedSlice(allocator);
}

/// Emit a hidden `_csrf_token` input. Pass the token from the csrf middleware.
pub fn csrfInput(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    return input(allocator, .{
        .type = "hidden",
        .name = "_csrf_token",
        .value = token,
    });
}

/// Emit a hidden field for HTTP verb spoofing (method-override).
pub fn methodInput(allocator: std.mem.Allocator, method: []const u8) ![]u8 {
    return input(allocator, .{
        .type = "hidden",
        .name = "_method",
        .value = method,
    });
}

fn appendAttr(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    try buf.append(allocator, ' ');
    try buf.appendSlice(allocator, name);
    try buf.appendSlice(allocator, "=\"");
    const escaped = try sanitize.escapeHtml(allocator, value);
    defer allocator.free(escaped);
    try buf.appendSlice(allocator, escaped);
    try buf.append(allocator, '"');
}

fn appendAttrInt(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), name: []const u8, value: u32) !void {
    try buf.append(allocator, ' ');
    try buf.appendSlice(allocator, name);
    try buf.appendSlice(allocator, "=\"");
    var numbuf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&numbuf, "{d}", .{value}) catch unreachable;
    try buf.appendSlice(allocator, s);
    try buf.append(allocator, '"');
}

// ── Tests ──────────────────────────────────────────────────────────────

test "input with required and value escaping" {
    const got = try input(std.testing.allocator, .{
        .name = "email",
        .type = "email",
        .value = "a&b",
        .required = true,
    });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        "<input type=\"email\" name=\"email\" value=\"a&amp;b\" required>",
        got,
    );
}

test "textarea escapes body" {
    const got = try textarea(std.testing.allocator, .{ .name = "bio", .value = "<script>x</script>" });
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "&lt;script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "<script>") == null);
}

test "select marks selected option" {
    const opts = [_]Option{
        .{ .value = "us", .label = "United States" },
        .{ .value = "ca", .label = "Canada" },
    };
    const got = try select(std.testing.allocator, .{
        .name = "country",
        .options = &opts,
        .selected = "ca",
    });
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "value=\"ca\" selected") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "value=\"us\" selected") == null);
}

test "checkbox checked flag" {
    const got = try checkbox(std.testing.allocator, .{ .name = "agree", .checked = true });
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.endsWith(u8, got, "checked>"));
}

test "csrfInput produces hidden field" {
    const got = try csrfInput(std.testing.allocator, "tok123");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "type=\"hidden\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "name=\"_csrf_token\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "value=\"tok123\"") != null);
}
