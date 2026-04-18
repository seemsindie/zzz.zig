//! i18n: translation lookup, placeholder interpolation, and pluralization.
//!
//! Translations can be either **compiled into the binary** via a comptime
//! `Translations` literal, or **loaded at runtime** from `.po` (GNU gettext)
//! or JSON bytes via `loadPo` / `loadJson` (typically fed via `@embedFile`
//! so there's still no file I/O at startup).
//!
//! At runtime, `t(locale, key, args)` returns the translation for `key` in
//! `locale`, falling back to the default locale then to the raw key. `tn` adds
//! count-based plural selection.
//!
//! A process-global catalog can be registered with `setGlobal`, after which
//! `ctx.t(key, args)` / `ctx.tn(key, n, args)` can be called directly from a
//! handler — they read the locale from `ctx.assigns["locale"]` (populated by
//! `localeMiddleware`).
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

// ── Global catalog + request helpers ───────────────────────────────────

/// Process-wide catalog pointer used by `ctx.t` / `ctx.tn`. Set once during
/// app startup (typically right after loading translations) and leave alone.
var global_catalog: ?*const Translations = null;

pub fn setGlobal(catalog: *const Translations) void {
    global_catalog = catalog;
}

pub fn getGlobal() ?*const Translations {
    return global_catalog;
}

// ── Runtime loaders: .po and JSON ──────────────────────────────────────

/// A loaded translation set with its backing memory. Call `deinit` when the
/// process no longer needs translations (typically never, in a web server).
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    /// Fully-initialised Translations backed by `arena`. Usable as long as
    /// `Loaded` lives.
    translations: Translations,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
    }
};

/// Load a single-locale `.po` (GNU gettext) file. Attach additional locales
/// via `mergePo` on the returned `Loaded` before calling `setGlobal`.
///
/// Supported features: `msgid` / `msgstr`, `msgid_plural` / `msgstr[N]`,
/// `#`-prefixed comments, multi-line concatenated strings. Unsupported:
/// `msgctxt` (context) and fuzzy-translation markers — those are silently
/// ignored so a stock gettext extract still loads.
pub fn loadPo(allocator: Allocator, locale_code: []const u8, bytes: []const u8) !Loaded {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var entries = std.ArrayList(Translations.Entry).empty;
    try parsePoInto(aa, bytes, &entries);

    const locales = try aa.alloc(Translations.Locale, 1);
    locales[0] = .{
        .code = try aa.dupe(u8, locale_code),
        .entries = try entries.toOwnedSlice(aa),
    };

    return .{
        .arena = arena,
        .translations = .{
            .locales = locales,
            .default_locale = locales[0].code,
        },
    };
}

/// Load a JSON translations file of the following shape:
///
/// ```json
/// {
///   "default_locale": "en",
///   "locales": {
///     "en": {
///       "hello": "Hello",
///       "items": { "0": "no items", "1": "1 item", "other": "{count} items" }
///     },
///     "fr": { "hello": "Bonjour" }
///   }
/// }
/// ```
///
/// A string value is a plain entry. An object value is a plural entry, where
/// numeric keys become exact-count forms and `"other"` becomes the fallback.
pub fn loadJson(allocator: Allocator, bytes: []const u8) !Loaded {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, aa, bytes, .{});
    const root = switch (parsed) {
        .object => |o| o,
        else => return error.InvalidTranslationsJson,
    };

    const default_code: []const u8 = blk: {
        if (root.get("default_locale")) |v| switch (v) {
            .string => |s| break :blk try aa.dupe(u8, s),
            else => {},
        };
        break :blk try aa.dupe(u8, "en");
    };

    const locales_obj = switch (root.get("locales") orelse return error.InvalidTranslationsJson) {
        .object => |o| o,
        else => return error.InvalidTranslationsJson,
    };

    var locales = try std.ArrayList(Translations.Locale).initCapacity(aa, locales_obj.count());
    var it = locales_obj.iterator();
    while (it.next()) |kv| {
        const locale_entries = switch (kv.value_ptr.*) {
            .object => |o| o,
            else => return error.InvalidTranslationsJson,
        };
        var entries = std.ArrayList(Translations.Entry).empty;
        var eit = locale_entries.iterator();
        while (eit.next()) |ev| {
            try entries.append(aa, try jsonEntryToEntry(aa, ev.key_ptr.*, ev.value_ptr.*));
        }
        try locales.append(aa, .{
            .code = try aa.dupe(u8, kv.key_ptr.*),
            .entries = try entries.toOwnedSlice(aa),
        });
    }

    return .{
        .arena = arena,
        .translations = .{
            .locales = try locales.toOwnedSlice(aa),
            .default_locale = default_code,
        },
    };
}

fn jsonEntryToEntry(
    aa: Allocator,
    key: []const u8,
    value: std.json.Value,
) !Translations.Entry {
    switch (value) {
        .string => |s| return .{ .key = try aa.dupe(u8, key), .value = try aa.dupe(u8, s) },
        .object => |o| {
            var plurals = std.ArrayList(Translations.Plural).empty;
            var fallback: []const u8 = "";
            var it = o.iterator();
            while (it.next()) |kv| {
                const v = switch (kv.value_ptr.*) {
                    .string => |s| s,
                    else => return error.InvalidTranslationsJson,
                };
                if (std.mem.eql(u8, kv.key_ptr.*, "other")) {
                    try plurals.append(aa, .{
                        .count = Translations.other_count,
                        .value = try aa.dupe(u8, v),
                    });
                    fallback = v;
                } else {
                    const n = std.fmt.parseInt(u32, kv.key_ptr.*, 10) catch
                        return error.InvalidTranslationsJson;
                    try plurals.append(aa, .{ .count = n, .value = try aa.dupe(u8, v) });
                }
            }
            return .{
                .key = try aa.dupe(u8, key),
                .value = try aa.dupe(u8, fallback),
                .plurals = try plurals.toOwnedSlice(aa),
            };
        },
        else => return error.InvalidTranslationsJson,
    }
}

// ── .po parser ────────────────────────────────────────────────────────

fn parsePoInto(aa: Allocator, bytes: []const u8, entries: *std.ArrayList(Translations.Entry)) !void {
    var it = std.mem.splitScalar(u8, bytes, '\n');
    var current_msgid: []const u8 = "";
    var current_plural_key: []const u8 = "";
    var current_msgstr: []const u8 = "";
    var current_plurals = std.ArrayList(Translations.Plural).empty;
    var has_plural = false;

    var state: enum { none, msgid, msgid_plural, msgstr, msgstr_n } = .none;
    var current_plural_index: u32 = 0;

    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') {
            // End of an entry on a blank line.
            if (line.len == 0 and current_msgid.len > 0) {
                try flushPoEntry(aa, entries, current_msgid, current_msgstr, &current_plurals, has_plural);
                current_msgid = "";
                current_plural_key = "";
                current_msgstr = "";
                current_plurals = std.ArrayList(Translations.Plural).empty;
                has_plural = false;
                state = .none;
            }
            continue;
        }

        // Continuation line: starts with a quote, belongs to the previous field.
        if (line[0] == '"') {
            const chunk = try unescapePo(aa, line);
            switch (state) {
                .msgid => current_msgid = try concat(aa, current_msgid, chunk),
                .msgid_plural => current_plural_key = try concat(aa, current_plural_key, chunk),
                .msgstr => current_msgstr = try concat(aa, current_msgstr, chunk),
                .msgstr_n => {
                    const last_idx = current_plurals.items.len - 1;
                    current_plurals.items[last_idx].value = try concat(aa, current_plurals.items[last_idx].value, chunk);
                },
                else => {},
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "msgid_plural ")) {
            has_plural = true;
            state = .msgid_plural;
            current_plural_key = try unescapePoQuoted(aa, line[13..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "msgid ")) {
            state = .msgid;
            current_msgid = try unescapePoQuoted(aa, line[6..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "msgstr[")) {
            // msgstr[N] "..."
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const n = std.fmt.parseInt(u32, line[7..close], 10) catch continue;
            current_plural_index = n;
            const after = std.mem.trim(u8, line[close + 1 ..], " \t");
            const v = try unescapePoQuoted(aa, after);
            try current_plurals.append(aa, .{ .count = mapPoIndex(n, has_plural), .value = v });
            state = .msgstr_n;
            continue;
        }
        if (std.mem.startsWith(u8, line, "msgstr ")) {
            state = .msgstr;
            current_msgstr = try unescapePoQuoted(aa, line[7..]);
            continue;
        }
    }

    // Flush trailing entry (no blank line at EOF).
    if (current_msgid.len > 0) {
        try flushPoEntry(aa, entries, current_msgid, current_msgstr, &current_plurals, has_plural);
    }
}

fn flushPoEntry(
    aa: Allocator,
    entries: *std.ArrayList(Translations.Entry),
    msgid: []const u8,
    msgstr: []const u8,
    plurals: *std.ArrayList(Translations.Plural),
    has_plural: bool,
) !void {
    // Skip gettext header entry (empty msgid).
    if (msgid.len == 0) return;
    if (has_plural) {
        try entries.append(aa, .{
            .key = try aa.dupe(u8, msgid),
            .value = msgstr,
            .plurals = try plurals.toOwnedSlice(aa),
        });
    } else {
        try entries.append(aa, .{
            .key = try aa.dupe(u8, msgid),
            .value = msgstr,
        });
    }
}

/// Map a po msgstr[N] index to our plural-count value. `[0]` is the singular
/// (count=1), `[1]` is typically the "other" fallback. More complex CLDR rules
/// aren't fully expressible in our schema — callers wanting per-count forms
/// should use JSON which supports explicit numeric keys.
fn mapPoIndex(idx: u32, _: bool) u32 {
    return switch (idx) {
        0 => 1, // singular
        1 => Translations.other_count, // plural / "other"
        else => Translations.other_count + idx, // preserve distinctness
    };
}

fn unescapePoQuoted(aa: Allocator, input: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t");
    if (trimmed.len < 2 or trimmed[0] != '"' or trimmed[trimmed.len - 1] != '"') {
        return "";
    }
    return unescapePo(aa, trimmed);
}

fn unescapePo(aa: Allocator, quoted: []const u8) ![]const u8 {
    // quoted starts with '"' and ends with '"'.
    if (quoted.len < 2) return "";
    const inner = quoted[1 .. quoted.len - 1];
    var out = try std.ArrayList(u8).initCapacity(aa, inner.len);
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const ch = inner[i];
        if (ch == '\\' and i + 1 < inner.len) {
            const next = inner[i + 1];
            const decoded: u8 = switch (next) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                '"' => '"',
                else => next,
            };
            try out.append(aa, decoded);
            i += 1;
        } else {
            try out.append(aa, ch);
        }
    }
    return out.toOwnedSlice(aa);
}

fn concat(aa: Allocator, a: []const u8, b: []const u8) ![]const u8 {
    if (a.len == 0) return b;
    if (b.len == 0) return a;
    const out = try aa.alloc(u8, a.len + b.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
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

test "loadJson parses plain and plural entries" {
    const json =
        \\{
        \\  "default_locale": "en",
        \\  "locales": {
        \\    "en": {
        \\      "hello": "Hello",
        \\      "items": { "0": "no items", "1": "1 item", "other": "{count} items" }
        \\    },
        \\    "fr": { "hello": "Bonjour" }
        \\  }
        \\}
    ;
    var loaded = try loadJson(std.testing.allocator, json);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("Hello", lookup(loaded.translations, "en", "hello"));
    try std.testing.expectEqualStrings("Bonjour", lookup(loaded.translations, "fr", "hello"));

    // Fallback to default when fr missing a key.
    try std.testing.expectEqualStrings(
        "{count} items",
        lookup(loaded.translations, "fr", "items"),
    );

    // Plurals.
    const one = try tn(std.testing.allocator, loaded.translations, "en", "items", 1, .{});
    defer std.testing.allocator.free(one);
    try std.testing.expectEqualStrings("1 item", one);

    const many = try tn(std.testing.allocator, loaded.translations, "en", "items", 5, .{ .count = @as(u32, 5) });
    defer std.testing.allocator.free(many);
    try std.testing.expectEqualStrings("5 items", many);
}

test "loadPo parses singular and plural entries" {
    const po =
        \\# English translations
        \\msgid ""
        \\msgstr "Content-Type: text/plain; charset=UTF-8\n"
        \\
        \\msgid "hello"
        \\msgstr "Hello"
        \\
        \\msgid "farewell"
        \\msgstr "Goodbye"
        \\
        \\msgid "items_singular"
        \\msgid_plural "items_plural"
        \\msgstr[0] "1 item"
        \\msgstr[1] "{count} items"
    ;
    var loaded = try loadPo(std.testing.allocator, "en", po);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("Hello", lookup(loaded.translations, "en", "hello"));
    try std.testing.expectEqualStrings("Goodbye", lookup(loaded.translations, "en", "farewell"));

    const one = try tn(std.testing.allocator, loaded.translations, "en", "items_singular", 1, .{});
    defer std.testing.allocator.free(one);
    try std.testing.expectEqualStrings("1 item", one);

    const many = try tn(std.testing.allocator, loaded.translations, "en", "items_singular", 9, .{ .count = @as(u32, 9) });
    defer std.testing.allocator.free(many);
    try std.testing.expectEqualStrings("9 items", many);
}

test "loadPo handles multi-line string continuations" {
    const po =
        \\msgid "multi"
        \\msgstr ""
        \\"first line "
        \\"second line"
    ;
    var loaded = try loadPo(std.testing.allocator, "en", po);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("first line second line", lookup(loaded.translations, "en", "multi"));
}

test "setGlobal stores catalog pointer" {
    const cat = Translations{
        .default_locale = "en",
        .locales = &.{
            .{ .code = "en", .entries = &.{
                .{ .key = "hi", .value = "hello" },
            } },
        },
    };
    setGlobal(&cat);
    defer global_catalog = null;

    const g = getGlobal().?;
    try std.testing.expectEqualStrings("hello", lookup(g.*, "en", "hi"));
}

// Verify ctx.t reads the global catalog and the locale from assigns.
test "ctx.t uses global catalog and assigns locale" {
    const Request = @import("../core/http/request.zig").Request;
    _ = @import("../core/http/status.zig").StatusCode;
    const Router = @import("../router/router.zig").Router;
    const Context = @import("../middleware/context.zig").Context;

    const cat = Translations{
        .default_locale = "en",
        .locales = &.{
            .{ .code = "en", .entries = &.{
                .{ .key = "greet", .value = "Hello, {name}!" },
            } },
            .{ .code = "fr", .entries = &.{
                .{ .key = "greet", .value = "Bonjour, {name} !" },
            } },
        },
    };
    setGlobal(&cat);
    defer global_catalog = null;

    const H = struct {
        fn h(ctx: *Context) !void {
            ctx.assign("locale", "fr");
            const msg = try ctx.t("greet", .{ .name = @as([]const u8, "Ivan") });
            ctx.text(.ok, msg);
        }
    };
    const App = Router.define(.{
        .routes = &.{Router.get("/", H.h)},
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var req: Request = .{ .method = .GET, .path = "/" };
    defer req.deinit(alloc);
    var resp = try App.handler(alloc, &req);
    defer resp.deinit(alloc);
    try std.testing.expectEqualStrings("Bonjour, Ivan !", resp.body.?);
}
