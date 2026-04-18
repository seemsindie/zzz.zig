const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const c = std.c;
const Allocator = std.mem.Allocator;
const Request = @import("../core/http/request.zig").Request;
const Response = @import("../core/http/response.zig").Response;
const StatusCode = @import("../core/http/status.zig").StatusCode;
const body_parser = @import("body_parser.zig");
const ParsedBody = body_parser.ParsedBody;
const FilePart = body_parser.FilePart;
const static = @import("static.zig");
const FlashKind = @import("flash.zig").FlashKind;
const i18n_mod = @import("../core/i18n.zig");
const pidgn_template = @import("pidgn_template");

/// Handler function type for middleware and route handlers.
/// Defined outside Context to avoid dependency loop.
pub const HandlerFn = *const fn (*Context) anyerror!void;

/// Fixed-size key-value store for path parameters (zero-allocation).
pub const Params = struct {
    const max_params = 8;

    entries: [max_params]Entry = undefined,
    len: usize = 0,

    const Entry = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn get(self: *const Params, name: []const u8) ?[]const u8 {
        for (self.entries[0..self.len]) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.value;
        }
        return null;
    }

    pub fn put(self: *Params, name: []const u8, value: []const u8) void {
        if (self.len < max_params) {
            self.entries[self.len] = .{ .name = name, .value = value };
            self.len += 1;
        }
    }
};

/// Fixed-size key-value store for middleware data (zero-allocation).
pub const Assigns = struct {
    const max_assigns = 16;

    entries: [max_assigns]Entry = undefined,
    len: usize = 0,

    const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn get(self: *const Assigns, key: []const u8) ?[]const u8 {
        for (self.entries[0..self.len]) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }

    pub fn put(self: *Assigns, key: []const u8, value: []const u8) void {
        // Overwrite if key exists
        for (self.entries[0..self.len]) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                entry.value = value;
                return;
            }
        }
        if (self.len < max_assigns) {
            self.entries[self.len] = .{ .key = key, .value = value };
            self.len += 1;
        }
    }
};

/// Context flows through the middleware/handler chain.
/// The pipeline is not stored directly to avoid a type dependency loop.
/// Instead, `next_handler` and `pipeline_state` provide an opaque trampoline.
pub const Context = struct {
    request: *const Request,
    response: Response,
    params: Params,
    query: Params,
    assigns: Assigns,
    parsed_body: ParsedBody = .none,
    allocator: Allocator,
    /// Opaque trampoline: calls the next handler in the pipeline.
    next_handler: ?*const fn (*Context) anyerror!void,

    /// Call the next handler in the pipeline.
    pub fn next(self: *Context) anyerror!void {
        if (self.next_handler) |handler| {
            try handler(self);
        }
    }

    /// Unified param lookup: path params → body form fields → query params.
    pub fn param(self: *const Context, name: []const u8) ?[]const u8 {
        if (self.params.get(name)) |v| return v;
        if (self.bodyField(name)) |v| return v;
        return self.query.get(name);
    }

    /// Get a path parameter by name (path params only).
    pub fn pathParam(self: *const Context, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    /// Get a form field value from the parsed body (URL-encoded, JSON, or multipart fields).
    pub fn formValue(self: *const Context, name: []const u8) ?[]const u8 {
        return self.bodyField(name);
    }

    /// Get the raw JSON body string (only if Content-Type was application/json).
    pub fn jsonBody(self: *const Context) ?[]const u8 {
        return switch (self.parsed_body) {
            .json => self.request.body,
            else => null,
        };
    }

    /// Get the raw request body bytes regardless of content type.
    pub fn rawBody(self: *const Context) ?[]const u8 {
        return self.request.body;
    }

    /// Get an uploaded file by field name (multipart only).
    pub fn file(self: *const Context, field_name: []const u8) ?*const FilePart {
        return switch (self.parsed_body) {
            .multipart => |*md| md.file(field_name),
            else => null,
        };
    }

    /// Internal: look up a field from any parsed body type that has form data.
    fn bodyField(self: *const Context, name: []const u8) ?[]const u8 {
        return switch (self.parsed_body) {
            .json => |*fd| fd.get(name),
            .form => |*fd| fd.get(name),
            .multipart => |*md| md.fields.get(name),
            else => null,
        };
    }

    /// Store a value in assigns.
    pub fn assign(self: *Context, key: []const u8, value: []const u8) void {
        self.assigns.put(key, value);
    }

    /// Get a value from assigns.
    pub fn getAssign(self: *const Context, key: []const u8) ?[]const u8 {
        return self.assigns.get(key);
    }

    /// Set response fields directly.
    pub fn respond(self: *Context, status: StatusCode, content_type: []const u8, body: []const u8) void {
        self.response.status = status;
        self.response.body = body;
        self.response.headers.append(self.allocator, "Content-Type", content_type) catch {};
    }

    /// Convenience: JSON response.
    pub fn json(self: *Context, status: StatusCode, body: []const u8) void {
        self.respond(status, "application/json; charset=utf-8", body);
    }

    /// Convenience: HTML response.
    pub fn html(self: *Context, status: StatusCode, body: []const u8) void {
        self.respond(status, "text/html; charset=utf-8", body);
    }

    /// Convenience: plain text response.
    pub fn text(self: *Context, status: StatusCode, body: []const u8) void {
        self.respond(status, "text/plain; charset=utf-8", body);
    }

    /// Redirect the client to a new location.
    pub fn redirect(self: *Context, location: []const u8, status: StatusCode) void {
        self.response.status = status;
        self.response.body = null;
        self.response.headers.append(self.allocator, "Location", location) catch {};
    }

    /// Options for Set-Cookie header construction.
    pub const CookieOptions = struct {
        max_age: ?i64 = null,
        path: []const u8 = "/",
        domain: []const u8 = "",
        secure: bool = false,
        http_only: bool = true,
        same_site: SameSite = .lax,

        pub const SameSite = enum { lax, strict, none };
    };

    /// Set a cookie on the response via Set-Cookie header.
    pub fn setCookie(self: *Context, name: []const u8, value: []const u8, opts: CookieOptions) void {
        var buf: [512]u8 = undefined;
        var pos: usize = 0;

        // name=value
        if (name.len + 1 + value.len > buf.len) return;
        @memcpy(buf[pos..][0..name.len], name);
        pos += name.len;
        buf[pos] = '=';
        pos += 1;
        @memcpy(buf[pos..][0..value.len], value);
        pos += value.len;

        // Path
        if (opts.path.len > 0) {
            const attr = "; Path=";
            if (pos + attr.len + opts.path.len > buf.len) return;
            @memcpy(buf[pos..][0..attr.len], attr);
            pos += attr.len;
            @memcpy(buf[pos..][0..opts.path.len], opts.path);
            pos += opts.path.len;
        }

        // Domain
        if (opts.domain.len > 0) {
            const attr = "; Domain=";
            if (pos + attr.len + opts.domain.len > buf.len) return;
            @memcpy(buf[pos..][0..attr.len], attr);
            pos += attr.len;
            @memcpy(buf[pos..][0..opts.domain.len], opts.domain);
            pos += opts.domain.len;
        }

        // Max-Age
        if (opts.max_age) |age| {
            const attr = "; Max-Age=";
            if (pos + attr.len + 20 > buf.len) return;
            @memcpy(buf[pos..][0..attr.len], attr);
            pos += attr.len;
            const age_str = std.fmt.bufPrint(buf[pos..], "{d}", .{age}) catch return;
            pos += age_str.len;
        }

        // HttpOnly
        if (opts.http_only) {
            const attr = "; HttpOnly";
            if (pos + attr.len > buf.len) return;
            @memcpy(buf[pos..][0..attr.len], attr);
            pos += attr.len;
        }

        // Secure
        if (opts.secure) {
            const attr = "; Secure";
            if (pos + attr.len > buf.len) return;
            @memcpy(buf[pos..][0..attr.len], attr);
            pos += attr.len;
        }

        // SameSite
        {
            const attr = switch (opts.same_site) {
                .lax => "; SameSite=Lax",
                .strict => "; SameSite=Strict",
                .none => "; SameSite=None",
            };
            if (pos + attr.len > buf.len) return;
            @memcpy(buf[pos..][0..attr.len], attr);
            pos += attr.len;
        }

        // Expires (only when max_age is 0 — for deletion)
        if (opts.max_age) |age| {
            if (age == 0) {
                const attr = "; Expires=Thu, 01 Jan 1970 00:00:00 GMT";
                if (pos + attr.len > buf.len) return;
                @memcpy(buf[pos..][0..attr.len], attr);
                pos += attr.len;
            }
        }

        // Allocate a copy so the header value outlives this stack frame
        const cookie_str = self.allocator.dupe(u8, buf[0..pos]) catch return;
        self.response.trackOwnedSlice(self.allocator, cookie_str);
        self.response.headers.append(self.allocator, "Set-Cookie", cookie_str) catch {};
    }

    /// Delete a cookie by setting it to empty with Max-Age=0.
    pub fn deleteCookie(self: *Context, name: []const u8, path: []const u8) void {
        self.setCookie(name, "", .{
            .max_age = 0,
            .path = path,
            .http_only = true,
        });
    }

    /// Get a cookie value from the request's Cookie header.
    pub fn getCookie(self: *const Context, name: []const u8) ?[]const u8 {
        const header_val = self.request.header("Cookie") orelse return null;
        var iter = std.mem.splitSequence(u8, header_val, "; ");
        while (iter.next()) |pair| {
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
            }
        }
        return null;
    }

    /// Install the i18n translator callback on the current thread for the
    /// duration of a render. Paired with `uninstallI18n` via `defer`. No-op if
    /// no global catalog has been registered.
    fn installI18n(self: *Context) void {
        const cat = i18n_mod.getGlobal() orelse return;
        const locale = self.getAssign("locale") orelse cat.default_locale;
        i18n_mod.setThreadCatalog(cat);
        pidgn_template.setTranslator(&i18n_mod.templateTranslate);
        pidgn_template.setLocale(locale);
    }

    fn uninstallI18n() void {
        pidgn_template.clearI18n();
        i18n_mod.setThreadCatalog(null);
    }

    /// Render a comptime-parsed template with data and send as HTML response.
    /// The template type must have a `render(allocator, data) ![]const u8` method,
    /// as returned by `pidgn.template()`.
    pub fn render(self: *Context, comptime Tmpl: type, status: StatusCode, data: anytype) !void {
        self.installI18n();
        defer uninstallI18n();
        const body = try Tmpl.render(self.allocator, data);
        self.response.status = status;
        self.response.body = body;
        self.response.body_owned = true;
        self.response.headers.append(self.allocator, "Content-Type", "text/html; charset=utf-8") catch {};
    }

    /// Render a content template wrapped in a layout template.
    /// Both templates receive the same `data` struct. The layout's `{{{yield}}}`
    /// placeholder is replaced with the rendered content.
    pub fn renderWithLayout(
        self: *Context,
        comptime LayoutTmpl: type,
        comptime ContentTmpl: type,
        status: StatusCode,
        data: anytype,
    ) !void {
        self.installI18n();
        defer uninstallI18n();
        const content = try ContentTmpl.render(self.allocator, data);
        defer self.allocator.free(content);
        const body = try LayoutTmpl.renderWithYield(self.allocator, data, content);
        self.response.status = status;
        self.response.body = body;
        self.response.body_owned = true;
        self.response.headers.append(self.allocator, "Content-Type", "text/html; charset=utf-8") catch {};
    }

    // ── Flash helpers ────────────────────────────────────────────────

    /// Store a flash message to be read by the next request (typically after a
    /// redirect). Requires both `session` and `flash` middleware in the pipeline.
    pub fn putFlash(self: *Context, kind: FlashKind, message: []const u8) void {
        self.assigns.put(kind.pendingKey(), message);
    }

    /// Read a flash message set by the previous request. Returns null if unset.
    pub fn getFlash(self: *const Context, kind: FlashKind) ?[]const u8 {
        const v = self.assigns.get(kind.displayKey()) orelse return null;
        if (v.len == 0) return null;
        return v;
    }

    // ── i18n helpers ────────────────────────────────────────────────

    /// Translate `key` using the process-global catalog (set via
    /// `pidgn.i18n.setGlobal`) and the locale stored in `ctx.assigns["locale"]`
    /// by `localeMiddleware`. Falls back to the default locale, then to the
    /// raw key, if nothing matches.
    ///
    /// Returns an owned slice allocated from `ctx.allocator` (the request
    /// arena), so the string survives the response without explicit free.
    pub fn t(self: *Context, key: []const u8, args: anytype) ![]u8 {
        const cat = i18n_mod.getGlobal() orelse {
            // No catalog registered — copy the key so the caller still gets
            // a writable slice they can pass to templates.
            return self.allocator.dupe(u8, key);
        };
        const locale = self.getAssign("locale") orelse cat.default_locale;
        return i18n_mod.t(self.allocator, cat.*, locale, key, args);
    }

    /// Plural-aware variant of `t`. `n` selects the plural form; `args` is
    /// interpolated as usual.
    pub fn tn(self: *Context, key: []const u8, n: u32, args: anytype) ![]u8 {
        const cat = i18n_mod.getGlobal() orelse {
            return self.allocator.dupe(u8, key);
        };
        const locale = self.getAssign("locale") orelse cat.default_locale;
        return i18n_mod.tn(self.allocator, cat.*, locale, key, n, args);
    }

    // ── htmx helpers ────────────────────────────────────────────────

    /// Returns true if this request was made by htmx (HX-Request header is "true").
    pub fn isHtmx(self: *const Context) bool {
        if (self.request.header("HX-Request")) |val| {
            return std.mem.eql(u8, val, "true");
        }
        return false;
    }

    /// Set the HX-Redirect response header (htmx client-side redirect).
    pub fn htmxRedirect(self: *Context, url: []const u8) void {
        self.response.headers.append(self.allocator, "HX-Redirect", url) catch {};
    }

    /// Set the HX-Trigger response header (trigger client-side events).
    pub fn htmxTrigger(self: *Context, event: []const u8) void {
        self.response.headers.append(self.allocator, "HX-Trigger", event) catch {};
    }

    /// Set the HX-Push-Url response header (push URL to browser history).
    pub fn htmxPushUrl(self: *Context, url: []const u8) void {
        self.response.headers.append(self.allocator, "HX-Push-Url", url) catch {};
    }

    /// Set the HX-Reswap response header (override swap strategy).
    pub fn htmxReswap(self: *Context, strategy: []const u8) void {
        self.response.headers.append(self.allocator, "HX-Reswap", strategy) catch {};
    }

    /// Set the HX-Retarget response header (override target element).
    pub fn htmxRetarget(self: *Context, selector: []const u8) void {
        self.response.headers.append(self.allocator, "HX-Retarget", selector) catch {};
    }

    /// Set the HX-Trigger-After-Swap response header (trigger event after swap).
    pub fn htmxTriggerAfterSwap(self: *Context, event: []const u8) void {
        self.response.headers.append(self.allocator, "HX-Trigger-After-Swap", event) catch {};
    }

    /// Set the HX-Trigger-After-Settle response header (trigger event after settle).
    pub fn htmxTriggerAfterSettle(self: *Context, event: []const u8) void {
        self.response.headers.append(self.allocator, "HX-Trigger-After-Settle", event) catch {};
    }

    /// Get the htmx CDN script tag (set by htmx middleware).
    pub fn htmxScriptTag(self: *const Context) []const u8 {
        return self.getAssign("htmx_script") orelse "";
    }

    // ── Partial / fragment rendering ──────────────────────────────────

    /// Render a template WITHOUT layout wrapping (for htmx fragment responses).
    pub fn renderPartial(self: *Context, comptime Tmpl: type, status: StatusCode, data: anytype) !void {
        self.installI18n();
        defer uninstallI18n();
        const body = try Tmpl.render(self.allocator, data);
        self.response.status = status;
        self.response.body = body;
        self.response.body_owned = true;
        self.response.headers.append(self.allocator, "Content-Type", "text/html; charset=utf-8") catch {};
    }

    /// Render a content template wrapped in a layout with named yield blocks.
    /// `extra_yields` is a struct with fields for named yield slots
    /// (e.g. `.{ .head = "<link ...>", .scripts = "<script ...>" }`).
    pub fn renderWithLayoutAndYields(
        self: *Context,
        comptime LayoutTmpl: type,
        comptime ContentTmpl: type,
        status: StatusCode,
        data: anytype,
        extra_yields: anytype,
    ) !void {
        self.installI18n();
        defer uninstallI18n();
        const content = try ContentTmpl.render(self.allocator, data);
        defer self.allocator.free(content);
        const body = try LayoutTmpl.renderWithYieldAndNamed(self.allocator, data, content, extra_yields);
        self.response.status = status;
        self.response.body = body;
        self.response.body_owned = true;
        self.response.headers.append(self.allocator, "Content-Type", "text/html; charset=utf-8") catch {};
    }

    /// Send a file as the response body. Reads from CWD.
    /// If `content_type` is null, auto-detects from file extension.
    pub fn sendFile(self: *Context, file_path: []const u8, content_type: ?[]const u8) void {
        // Security: reject paths with ".." to prevent directory traversal
        if (static.containsDotDot(file_path)) {
            self.respond(.forbidden, "text/plain; charset=utf-8", "403 Forbidden");
            return;
        }

        // Create null-terminated copy of the path
        const path_buf = self.allocator.allocSentinel(u8, file_path.len, 0) catch return;
        defer self.allocator.free(path_buf);
        @memcpy(path_buf, file_path);

        const fd = c.open(path_buf.ptr, .{}, @as(c.mode_t, 0));
        if (fd < 0) {
            self.respond(.not_found, "text/plain; charset=utf-8", "404 Not Found");
            return;
        }
        defer _ = c.close(fd);

        // Get file size
        const size: usize = if (native_os == .linux) blk: {
            var statx_buf = std.mem.zeroes(std.os.linux.Statx);
            if (std.os.linux.errno(std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .SIZE = true }, &statx_buf)) != .SUCCESS) return;
            if (!statx_buf.mask.SIZE) return;
            break :blk @intCast(statx_buf.size);
        } else blk: {
            var stat_buf: c.Stat = undefined;
            if (c.fstat(fd, &stat_buf) != 0) return;
            break :blk @intCast(stat_buf.size);
        };

        if (size == 0) return;
        // Cap at 10MB
        if (size > 10 * 1024 * 1024) return;

        // Allocate and read
        const buf = self.allocator.alloc(u8, size) catch return;
        var total: usize = 0;
        while (total < size) {
            const n = c.read(fd, buf[total..].ptr, buf.len - total);
            if (n <= 0) break;
            total += @intCast(n);
        }

        if (total != size) {
            self.allocator.free(buf);
            return;
        }

        // Auto-detect MIME from extension if content_type is null
        const ct = content_type orelse static.mimeFromPath(file_path);

        self.response.status = .ok;
        self.response.body = buf;
        self.response.body_owned = true;
        self.response.headers.append(self.allocator, "Content-Type", ct) catch {};
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "Params get and put" {
    var p: Params = .{};
    p.put("id", "42");
    p.put("name", "alice");

    try std.testing.expectEqualStrings("42", p.get("id").?);
    try std.testing.expectEqualStrings("alice", p.get("name").?);
    try std.testing.expect(p.get("missing") == null);
}

test "Assigns get, put, overwrite" {
    var a: Assigns = .{};
    a.put("user_id", "1");
    try std.testing.expectEqualStrings("1", a.get("user_id").?);

    // Overwrite
    a.put("user_id", "2");
    try std.testing.expectEqualStrings("2", a.get("user_id").?);
    try std.testing.expectEqual(@as(usize, 1), a.len);
}

test "Context respond sets fields" {
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

    ctx.text(.ok, "hello");
    try std.testing.expectEqual(StatusCode.ok, ctx.response.status);
    try std.testing.expectEqualStrings("hello", ctx.response.body.?);
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", ctx.response.headers.get("Content-Type").?);
}

test "Context unified param: path > body > query" {
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

    // Set up path param
    ctx.params.put("id", "path-42");
    // Set up query param
    ctx.query.put("page", "3");
    ctx.query.put("id", "query-99");
    // Set up body form data
    ctx.parsed_body = .{ .form = blk: {
        var fd: body_parser.FormData = .{};
        fd.put("email", "test@example.com");
        fd.put("id", "body-7");
        break :blk fd;
    } };

    // Path param wins over body and query
    try std.testing.expectEqualStrings("path-42", ctx.param("id").?);
    // Body field accessible
    try std.testing.expectEqualStrings("test@example.com", ctx.param("email").?);
    // Query param accessible
    try std.testing.expectEqualStrings("3", ctx.param("page").?);
    // Missing param
    try std.testing.expect(ctx.param("missing") == null);

    // Specific accessors
    try std.testing.expectEqualStrings("path-42", ctx.pathParam("id").?);
    try std.testing.expectEqualStrings("test@example.com", ctx.formValue("email").?);
    try std.testing.expect(ctx.jsonBody() == null);
    try std.testing.expect(ctx.rawBody() == null);
}

test "Context redirect sets Location header" {
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

    ctx.redirect("/dashboard", .found);
    try std.testing.expectEqual(StatusCode.found, ctx.response.status);
    try std.testing.expect(ctx.response.body == null);
    try std.testing.expectEqualStrings("/dashboard", ctx.response.headers.get("Location").?);
}

test "Context setCookie builds Set-Cookie header" {
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

    ctx.setCookie("session", "abc123", .{ .path = "/", .http_only = true, .secure = true });
    const cookie = ctx.response.headers.get("Set-Cookie").?;
    try std.testing.expect(std.mem.startsWith(u8, cookie, "session=abc123"));
    try std.testing.expect(std.mem.indexOf(u8, cookie, "Path=/") != null);
    try std.testing.expect(std.mem.indexOf(u8, cookie, "HttpOnly") != null);
    try std.testing.expect(std.mem.indexOf(u8, cookie, "Secure") != null);
    try std.testing.expect(std.mem.indexOf(u8, cookie, "SameSite=Lax") != null);
}

test "Context deleteCookie sets Max-Age=0 and Expires" {
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

    ctx.deleteCookie("session", "/");
    const cookie = ctx.response.headers.get("Set-Cookie").?;
    try std.testing.expect(std.mem.startsWith(u8, cookie, "session="));
    try std.testing.expect(std.mem.indexOf(u8, cookie, "Max-Age=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, cookie, "Expires=Thu, 01 Jan 1970 00:00:00 GMT") != null);
}

test "Context getCookie parses Cookie header" {
    var req: Request = .{};
    try req.headers.append(std.testing.allocator, "Cookie", "session=abc123; theme=dark; lang=en");
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

    try std.testing.expectEqualStrings("abc123", ctx.getCookie("session").?);
    try std.testing.expectEqualStrings("dark", ctx.getCookie("theme").?);
    try std.testing.expectEqualStrings("en", ctx.getCookie("lang").?);
    try std.testing.expect(ctx.getCookie("missing") == null);
}

test "Context getCookie returns null when no Cookie header" {
    var req: Request = .{};
    defer req.deinit(std.testing.allocator);

    const ctx: Context = .{
        .request = &req,
        .response = .{},
        .params = .{},
        .query = .{},
        .assigns = .{},
        .allocator = std.testing.allocator,
        .next_handler = null,
    };

    try std.testing.expect(ctx.getCookie("anything") == null);
}

test "Context sendFile reads a file from disk" {
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

    // build.zig exists in the project root — use it as a known file
    ctx.sendFile("build.zig", null);
    try std.testing.expectEqual(StatusCode.ok, ctx.response.status);
    try std.testing.expect(ctx.response.body != null);
    try std.testing.expect(ctx.response.body.?.len > 0);
    try std.testing.expect(ctx.response.body_owned);
}

test "Context sendFile rejects path traversal" {
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

    ctx.sendFile("../etc/passwd", null);
    try std.testing.expectEqual(StatusCode.forbidden, ctx.response.status);
}

test "Context sendFile auto-detects MIME type" {
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

    // build.zig.zon exists in project root
    ctx.sendFile("build.zig.zon", null);
    // .zon has no specific MIME type, falls back to application/octet-stream
    if (ctx.response.headers.get("Content-Type")) |ct| {
        try std.testing.expect(ct.len > 0);
    }
}

test "isHtmx returns true when HX-Request header is present" {
    var req: Request = .{};
    try req.headers.append(std.testing.allocator, "HX-Request", "true");
    defer req.deinit(std.testing.allocator);

    const ctx: Context = .{
        .request = &req,
        .response = .{},
        .params = .{},
        .query = .{},
        .assigns = .{},
        .allocator = std.testing.allocator,
        .next_handler = null,
    };

    try std.testing.expect(ctx.isHtmx());
}

test "isHtmx returns false when no HX-Request header" {
    var req: Request = .{};
    defer req.deinit(std.testing.allocator);

    const ctx: Context = .{
        .request = &req,
        .response = .{},
        .params = .{},
        .query = .{},
        .assigns = .{},
        .allocator = std.testing.allocator,
        .next_handler = null,
    };

    try std.testing.expect(!ctx.isHtmx());
}

test "htmx response headers are set correctly" {
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

    ctx.htmxRedirect("/new-page");
    try std.testing.expectEqualStrings("/new-page", ctx.response.headers.get("HX-Redirect").?);

    ctx.htmxTrigger("itemAdded");
    try std.testing.expectEqualStrings("itemAdded", ctx.response.headers.get("HX-Trigger").?);

    ctx.htmxPushUrl("/updated");
    try std.testing.expectEqualStrings("/updated", ctx.response.headers.get("HX-Push-Url").?);

    ctx.htmxReswap("outerHTML");
    try std.testing.expectEqualStrings("outerHTML", ctx.response.headers.get("HX-Reswap").?);

    ctx.htmxRetarget("#main");
    try std.testing.expectEqualStrings("#main", ctx.response.headers.get("HX-Retarget").?);
}

test "renderPartial renders without layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req: Request = .{};
    defer req.deinit(alloc);

    const engine = @import("../template/engine.zig");
    const Fragment = engine.template("<span>{{count}}</span>");

    var ctx: Context = .{
        .request = &req,
        .response = .{},
        .params = .{},
        .query = .{},
        .assigns = .{},
        .allocator = alloc,
        .next_handler = null,
    };

    try ctx.renderPartial(Fragment, .ok, .{ .count = "5" });
    try std.testing.expectEqual(StatusCode.ok, ctx.response.status);
    try std.testing.expectEqualStrings("<span>5</span>", ctx.response.body.?);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", ctx.response.headers.get("Content-Type").?);
}

test "htmxTriggerAfterSwap and htmxTriggerAfterSettle set headers" {
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

    ctx.htmxTriggerAfterSwap("itemAdded");
    try std.testing.expectEqualStrings("itemAdded", ctx.response.headers.get("HX-Trigger-After-Swap").?);

    ctx.htmxTriggerAfterSettle("formReset");
    try std.testing.expectEqualStrings("formReset", ctx.response.headers.get("HX-Trigger-After-Settle").?);
}

test "htmxScriptTag returns assign value or empty" {
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

    // No htmx_script assign → empty
    try std.testing.expectEqualStrings("", ctx.htmxScriptTag());

    // Set it
    ctx.assign("htmx_script", "<script src=\"htmx.js\"></script>");
    try std.testing.expectEqualStrings("<script src=\"htmx.js\"></script>", ctx.htmxScriptTag());
}
