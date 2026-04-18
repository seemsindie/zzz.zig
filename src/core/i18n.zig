//! i18n: translation lookup, placeholder interpolation, and pluralization.
//!
//! Translations are compiled into the binary via a comptime-provided map. At
//! runtime, `t(locale, key, args)` returns the translation for `key` in
//! `locale`, falling back to the default locale then to the raw key. `tn` adds
//! CLDR-inspired plural selection.
//!
//! Locale detection (Accept-Language) lives in `middleware/locale.zig`; wiring
//! those together is documented in the i18n section of the framework docs.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Translations = struct {
    /// Array of locale catalogs. Exactly one entry's `code` must match
    /// `default_locale` or you'll get a runtime miss on fallback.
    locales: []const Locale,
    default_locale: []const u8 = "en",

    pub const Locale = struct {
        code: []const u8,
        entries: []const Entry,
    };

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
        /// Optional per-count variants used by `tn`. A `Plural` with count=0
        /// acts as the "other" / default form.
        plurals: []const Plural = &.{},
    };

    pub const Plural = struct {
        /// Which count this form covers. Use `other_count` to mark the
        /// default / fallback form.
        count: u32,
        value: []const u8,
    };

    pub const other_count: u32 = std.math.maxInt(u32);
};

/// Look up `key` in the given locale, falling back to the default locale and
/// finally to the raw key. Returns the raw slice (no interpolation).
pub fn lookup(tr: Translations, locale: []const u8, key: []const u8) []const u8 {
    if (findEntry(tr, locale, key)) |e| return e.value;
    if (findEntry(tr, tr.default_locale, key)) |e| return e.value;
    return key;
}

/// `lookup` + `{name}`-style placeholder interpolation. `args` is a struct
/// whose field names match placeholders. Missing placeholders are left as-is.
pub fn t(allocator: Allocator, tr: Translations, locale: []const u8, key: []const u8, args: anytype) ![]u8 {
    const raw = lookup(tr, locale, key);
    return interpolate(allocator, raw, args);
}

/// Plural-aware lookup. Picks the entry whose `count` matches `n`, else the
/// `other_count` form, else the plain `value`, else the key.
pub fn tn(
    allocator: Allocator,
    tr: Translations,
    locale: []const u8,
    key: []const u8,
    n: u32,
    args: anytype,
) ![]u8 {
    const raw = pluralLookup(tr, locale, key, n) orelse pluralLookup(tr, tr.default_locale, key, n) orelse key;
    return interpolate(allocator, raw, args);
}

fn findEntry(tr: Translations, locale: []const u8, key: []const u8) ?*const Translations.Entry {
    for (tr.locales) |loc| {
        if (!std.mem.eql(u8, loc.code, locale)) continue;
        for (loc.entries) |*e| {
            if (std.mem.eql(u8, e.key, key)) return e;
        }
    }
    return null;
}

fn pluralLookup(tr: Translations, locale: []const u8, key: []const u8, n: u32) ?[]const u8 {
    const e = findEntry(tr, locale, key) orelse return null;
    // Exact count match wins.
    for (e.plurals) |p| if (p.count == n) return p.value;
    // Then the "other" form.
    for (e.plurals) |p| if (p.count == Translations.other_count) return p.value;
    // Else the plain value (useful when you only have a single form).
    return if (e.value.len > 0) e.value else null;
}

/// Replace `{name}` placeholders in `template` with the corresponding field
/// from `args`. Supports `[]const u8` fields and numeric fields (formatted
/// with `{d}`). Unknown placeholders are emitted verbatim.
pub fn interpolate(allocator: Allocator, template: []const u8, args: anytype) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, template.len);

    const T = @TypeOf(args);
    const is_void_args = T == @TypeOf(.{});

    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') {
            if (std.mem.indexOfScalarPos(u8, template, i + 1, '}')) |close| {
                const name = template[i + 1 .. close];
                var handled = false;
                if (!is_void_args) {
                    inline for (std.meta.fields(T)) |f| {
                        if (std.mem.eql(u8, f.name, name)) {
                            const v = @field(args, f.name);
                            try writeArg(allocator, &out, v);
                            handled = true;
                        }
                    }
                }
                if (!handled) try out.appendSlice(allocator, template[i .. close + 1]);
                i = close + 1;
                continue;
            }
        }
        try out.append(allocator, template[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn writeArg(allocator: Allocator, out: *std.ArrayList(u8), v: anytype) !void {
    const V = @TypeOf(v);
    if (V == []const u8 or V == []u8) {
        try out.appendSlice(allocator, v);
        return;
    }
    if (@typeInfo(V) == .int or @typeInfo(V) == .comptime_int) {
        var buf: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d}", .{v});
        try out.appendSlice(allocator, s);
        return;
    }
    if (@typeInfo(V) == .float or @typeInfo(V) == .comptime_float) {
        var buf: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d}", .{v});
        try out.appendSlice(allocator, s);
        return;
    }
    @compileError("unsupported i18n arg type: " ++ @typeName(V));
}

// ── Tests ──────────────────────────────────────────────────────────────

test "lookup and fallback" {
    const tr = Translations{
        .default_locale = "en",
        .locales = &.{
            .{ .code = "en", .entries = &.{
                .{ .key = "hello", .value = "Hello" },
                .{ .key = "bye", .value = "Goodbye" },
            } },
            .{ .code = "fr", .entries = &.{
                .{ .key = "hello", .value = "Bonjour" },
            } },
        },
    };

    try std.testing.expectEqualStrings("Bonjour", lookup(tr, "fr", "hello"));
    // Fallback to en when fr missing a key.
    try std.testing.expectEqualStrings("Goodbye", lookup(tr, "fr", "bye"));
    // Unknown key returns the key itself.
    try std.testing.expectEqualStrings("missing", lookup(tr, "en", "missing"));
}

test "t interpolates named args" {
    const tr = Translations{
        .default_locale = "en",
        .locales = &.{
            .{ .code = "en", .entries = &.{
                .{ .key = "greet", .value = "Hello, {name}! You have {count} messages." },
            } },
        },
    };

    const got = try t(std.testing.allocator, tr, "en", "greet", .{
        .name = @as([]const u8, "Ivan"),
        .count = @as(u32, 3),
    });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("Hello, Ivan! You have 3 messages.", got);
}

test "t leaves unknown placeholder intact" {
    const tr = Translations{
        .default_locale = "en",
        .locales = &.{
            .{ .code = "en", .entries = &.{
                .{ .key = "x", .value = "Value: {missing}" },
            } },
        },
    };
    const got = try t(std.testing.allocator, tr, "en", "x", .{});
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("Value: {missing}", got);
}

test "tn picks exact plural then other" {
    const tr = Translations{
        .default_locale = "en",
        .locales = &.{
            .{ .code = "en", .entries = &.{
                .{
                    .key = "items",
                    .value = "items",
                    .plurals = &.{
                        .{ .count = 0, .value = "no items" },
                        .{ .count = 1, .value = "1 item" },
                        .{ .count = Translations.other_count, .value = "{count} items" },
                    },
                },
            } },
        },
    };

    const zero = try tn(std.testing.allocator, tr, "en", "items", 0, .{});
    defer std.testing.allocator.free(zero);
    try std.testing.expectEqualStrings("no items", zero);

    const one = try tn(std.testing.allocator, tr, "en", "items", 1, .{});
    defer std.testing.allocator.free(one);
    try std.testing.expectEqualStrings("1 item", one);

    const many = try tn(std.testing.allocator, tr, "en", "items", 5, .{ .count = @as(u32, 5) });
    defer std.testing.allocator.free(many);
    try std.testing.expectEqualStrings("5 items", many);
}

test "interpolate without args struct" {
    const got = try interpolate(std.testing.allocator, "hello world", .{});
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hello world", got);
}
