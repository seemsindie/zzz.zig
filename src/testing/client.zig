const std = @import("std");
const Allocator = std.mem.Allocator;
const Request = @import("../core/http/request.zig").Request;
const Method = @import("../core/http/request.zig").Method;
const Response = @import("../core/http/response.zig").Response;
const StatusCode = @import("../core/http/status.zig").StatusCode;
const Headers = @import("../core/http/headers.zig").Headers;
const TestResponse = @import("response.zig").TestResponse;
const CookieJar = @import("cookie_jar.zig").CookieJar;
const request_builder = @import("request_builder.zig");

/// HTTP test client for testing pidgn applications without a real TCP connection.
/// Generic over the App type (returned by `Router.define()`).
///
/// Example:
/// ```
/// var client = pidgn.testing.TestClient(App).init(std.testing.allocator);
/// defer client.deinit();
/// const resp = try client.get("/");
/// try resp.expectOk();
/// ```
pub fn TestClient(comptime App: type) type {
    return struct {
        const Self = @This();

        pub const HeaderEntry = struct {
            name: []const u8,
            value: []const u8,
        };

        arena: std.heap.ArenaAllocator,
        backing_allocator: Allocator,
        cookie_jar: CookieJar,
        default_headers: [8]HeaderEntry,
        default_headers_len: usize,
        follow_redirects: bool,
        max_redirects: u8,

        /// Accumulated responses that need cleanup.
        responses: [32]Response,
        response_count: usize,

        pub fn init(backing_allocator: Allocator) Self {
            return .{
                .arena = std.heap.ArenaAllocator.init(backing_allocator),
                .backing_allocator = backing_allocator,
                .cookie_jar = .{},
                .default_headers = undefined,
                .default_headers_len = 0,
                .follow_redirects = true,
                .max_redirects = 5,
                .responses = undefined,
                .response_count = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.cleanupResponses();
            self.arena.deinit();
        }

        fn cleanupResponses(self: *Self) void {
            for (self.responses[0..self.response_count]) |*resp| {
                resp.deinit(self.arena.allocator());
            }
            self.response_count = 0;
        }

        // ── Simple helpers ─────────────────────────────────────────

        pub fn get(self: *Self, path: []const u8) !TestResponse {
            return self.dispatch(.GET, path, null, null, null, &.{});
        }

        pub fn post(self: *Self, path: []const u8, body: ?[]const u8) !TestResponse {
            return self.dispatch(.POST, path, null, body, null, &.{});
        }

        pub fn put(self: *Self, path: []const u8, body: ?[]const u8) !TestResponse {
            return self.dispatch(.PUT, path, null, body, null, &.{});
        }

        pub fn patch(self: *Self, path: []const u8, body: ?[]const u8) !TestResponse {
            return self.dispatch(.PATCH, path, null, body, null, &.{});
        }

        pub fn delete(self: *Self, path: []const u8) !TestResponse {
            return self.dispatch(.DELETE, path, null, null, null, &.{});
        }

        // ── JSON/Form helpers ──────────────────────────────────────

        pub fn postJson(self: *Self, path: []const u8, json_body: []const u8) !TestResponse {
            return self.dispatch(.POST, path, null, json_body, "application/json", &.{});
        }

        pub fn putJson(self: *Self, path: []const u8, json_body: []const u8) !TestResponse {
            return self.dispatch(.PUT, path, null, json_body, "application/json", &.{});
        }

        pub fn patchJson(self: *Self, path: []const u8, json_body: []const u8) !TestResponse {
            return self.dispatch(.PATCH, path, null, json_body, "application/json", &.{});
        }

        pub fn postForm(self: *Self, path: []const u8, form_body: []const u8) !TestResponse {
            return self.dispatch(.POST, path, null, form_body, "application/x-www-form-urlencoded", &.{});
        }

        // ── Builder ────────────────────────────────────────────────

        /// Start building a complex request with a chainable API.
        pub fn request(self: *Self, method: Method, path: []const u8) request_builder.RequestBuilder(App) {
            return .{
                .client = self,
                .method = method,
                .path = path,
            };
        }

        // ── Default headers ────────────────────────────────────────

        /// Set a default header that will be included in every request.
        pub fn setDefaultHeader(self: *Self, name: []const u8, value: []const u8) void {
            // Replace existing
            for (self.default_headers[0..self.default_headers_len]) |*h| {
                if (std.ascii.eqlIgnoreCase(h.name, name)) {
                    h.value = value;
                    return;
                }
            }
            if (self.default_headers_len < 8) {
                self.default_headers[self.default_headers_len] = .{ .name = name, .value = value };
                self.default_headers_len += 1;
            }
        }

        // ── Reset ──────────────────────────────────────────────────

        /// Reset the client state: clear cookie jar, responses, and arena.
        pub fn reset(self: *Self) void {
            self.cleanupResponses();
            self.cookie_jar.reset();
            _ = self.arena.reset(.retain_capacity);
        }

        // ── Core dispatch ──────────────────────────────────────────

        pub fn dispatch(
            self: *Self,
            method: Method,
            path: []const u8,
            query_string: ?[]const u8,
            body: ?[]const u8,
            content_type: ?[]const u8,
            extra_headers: []const HeaderEntry,
        ) !TestResponse {
            return self.dispatchInternal(method, path, query_string, body, content_type, extra_headers, 0);
        }

        fn dispatchInternal(
            self: *Self,
            method: Method,
            path: []const u8,
            query_string: ?[]const u8,
            body: ?[]const u8,
            content_type: ?[]const u8,
            extra_headers: []const HeaderEntry,
            redirect_count: u8,
        ) !TestResponse {
            const alloc = self.arena.allocator();

            // Build the request
            var req: Request = .{
                .method = method,
                .path = path,
                .query_string = query_string,
                .body = body,
            };

            // Add content type if specified
            if (content_type) |ct| {
                try req.headers.append(alloc, "Content-Type", ct);
            }

            // Add default headers
            for (self.default_headers[0..self.default_headers_len]) |h| {
                try req.headers.append(alloc, h.name, h.value);
            }

            // Add extra headers from builder
            for (extra_headers) |h| {
                try req.headers.append(alloc, h.name, h.value);
            }

            // Add cookies from jar
            var cookie_buf: [2048]u8 = undefined;
            const cookie_len = self.cookie_jar.buildCookieHeader(path, &cookie_buf);
            if (cookie_len > 0) {
                const cookie_str = try alloc.dupe(u8, cookie_buf[0..cookie_len]);
                try req.headers.append(alloc, "Cookie", cookie_str);
            }

            // Call the app handler
            var resp = try App.handler(alloc, &req);

            // Capture Set-Cookie headers into the jar
            for (resp.headers.entries.items) |entry| {
                if (std.ascii.eqlIgnoreCase(entry.name, "Set-Cookie")) {
                    self.cookie_jar.parseSetCookie(entry.value);
                }
            }

            // Handle redirects
            if (self.follow_redirects and redirect_count < self.max_redirects) {
                const code = resp.status.code();
                if (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) {
                    if (resp.headers.get("Location")) |location| {
                        // 303 changes method to GET (per HTTP spec)
                        const redirect_method: Method = if (code == 303) .GET else method;
                        // 303 drops the body
                        const redirect_body: ?[]const u8 = if (code == 303) null else body;
                        const redirect_ct: ?[]const u8 = if (code == 303) null else content_type;

                        return self.dispatchInternal(
                            redirect_method,
                            location,
                            null,
                            redirect_body,
                            redirect_ct,
                            extra_headers,
                            redirect_count + 1,
                        );
                    }
                }
            }

            // Track response for cleanup
            if (self.response_count < 32) {
                self.responses[self.response_count] = resp;
                self.response_count += 1;
            }

            return .{
                .status = resp.status,
                .headers = resp.headers,
                .body = resp.body,
            };
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Context = @import("../middleware/context.zig").Context;
const Router = @import("../router/router.zig").Router;

test "TestClient basic GET" {
    const App = Router.define(.{
        .routes = &.{
            Router.get("/", struct {
                fn handle(ctx: *Context) !void {
                    ctx.text(.ok, "hello");
                }
            }.handle),
        },
    });

    var client = TestClient(App).init(testing.allocator);
    defer client.deinit();

    const resp = try client.get("/");
    try resp.expectOk();
    try resp.expectBody("hello");
}

test "TestClient POST with body" {
    const App = Router.define(.{
        .routes = &.{
            Router.post("/echo", struct {
                fn handle(ctx: *Context) !void {
                    const body = ctx.request.body orelse "no body";
                    ctx.text(.ok, body);
                }
            }.handle),
        },
    });

    var client = TestClient(App).init(testing.allocator);
    defer client.deinit();

    const resp = try client.post("/echo", "hello world");
    try resp.expectOk();
    try resp.expectBody("hello world");
}

test "TestClient POST JSON" {
    const App = Router.define(.{
        .routes = &.{
            Router.post("/api/data", struct {
                fn handle(ctx: *Context) !void {
                    const ct = ctx.request.header("Content-Type") orelse "none";
                    if (std.mem.indexOf(u8, ct, "application/json") != null) {
                        ctx.json(.created, ctx.request.body orelse "{}");
                    } else {
                        ctx.text(.bad_request, "expected json");
                    }
                }
            }.handle),
        },
    });

    var client = TestClient(App).init(testing.allocator);
    defer client.deinit();

    const resp = try client.postJson("/api/data", "{\"name\":\"alice\"}");
    try resp.expectCreated();
    try resp.expectJson("name", "alice");
}

test "TestClient 404" {
    const App = Router.define(.{
        .routes = &.{
            Router.get("/exists", struct {
                fn handle(ctx: *Context) !void {
                    ctx.text(.ok, "yes");
                }
            }.handle),
        },
    });

    var client = TestClient(App).init(testing.allocator);
    defer client.deinit();

    const resp = try client.get("/missing");
    try resp.expectNotFound();
}

test "TestClient default headers" {
    const App = Router.define(.{
        .routes = &.{
            Router.get("/check", struct {
                fn handle(ctx: *Context) !void {
                    const auth = ctx.request.header("Authorization") orelse "none";
                    ctx.text(.ok, auth);
                }
            }.handle),
        },
    });

    var client = TestClient(App).init(testing.allocator);
    defer client.deinit();
    client.setDefaultHeader("Authorization", "Bearer token123");

    const resp = try client.get("/check");
    try resp.expectOk();
    try resp.expectBody("Bearer token123");
}

test "TestClient cookie persistence" {
    const App = Router.define(.{
        .routes = &.{
            Router.post("/login", struct {
                fn handle(ctx: *Context) !void {
                    ctx.setCookie("session", "abc123", .{});
                    ctx.text(.ok, "logged in");
                }
            }.handle),
            Router.get("/profile", struct {
                fn handle(ctx: *Context) !void {
                    const session = ctx.getCookie("session") orelse "none";
                    ctx.text(.ok, session);
                }
            }.handle),
        },
    });

    var client = TestClient(App).init(testing.allocator);
    defer client.deinit();

    const login_resp = try client.post("/login", null);
    try login_resp.expectOk();

    const profile_resp = try client.get("/profile");
    try profile_resp.expectOk();
    try profile_resp.expectBody("abc123");
}

test "TestClient redirect following" {
    const App = Router.define(.{
        .routes = &.{
            Router.get("/old", struct {
                fn handle(ctx: *Context) !void {
                    ctx.redirect("/new", .found);
                }
            }.handle),
            Router.get("/new", struct {
                fn handle(ctx: *Context) !void {
                    ctx.text(.ok, "new page");
                }
            }.handle),
        },
    });

    var client = TestClient(App).init(testing.allocator);
    defer client.deinit();

    const resp = try client.get("/old");
    try resp.expectOk();
    try resp.expectBody("new page");
}

test "TestClient redirect disabled" {
    const App = Router.define(.{
        .routes = &.{
            Router.get("/old", struct {
                fn handle(ctx: *Context) !void {
                    ctx.redirect("/new", .found);
                }
            }.handle),
            Router.get("/new", struct {
                fn handle(ctx: *Context) !void {
                    ctx.text(.ok, "new page");
                }
            }.handle),
        },
    });

    var client = TestClient(App).init(testing.allocator);
    defer client.deinit();
    client.follow_redirects = false;

    const resp = try client.get("/old");
    try resp.expectRedirect("/new");
}

test "TestClient request builder" {
    const App = Router.define(.{
        .routes = &.{
            Router.post("/api/upload", struct {
                fn handle(ctx: *Context) !void {
                    const custom = ctx.request.header("X-Custom") orelse "none";
                    ctx.text(.ok, custom);
                }
            }.handle),
        },
    });

    var client = TestClient(App).init(testing.allocator);
    defer client.deinit();

    var builder = client.request(.POST, "/api/upload");
    const resp = try builder.header("X-Custom", "test-value").jsonBody("{\"key\":\"val\"}").send();
    try resp.expectOk();
    try resp.expectBody("test-value");
}

test "TestClient PUT and DELETE" {
    const App = Router.define(.{
        .routes = &.{
            Router.put("/items/:id", struct {
                fn handle(ctx: *Context) !void {
                    const id = ctx.param("id") orelse "?";
                    ctx.text(.ok, id);
                }
            }.handle),
            Router.delete("/items/:id", struct {
                fn handle(ctx: *Context) !void {
                    ctx.text(.no_content, "");
                }
            }.handle),
        },
    });

    var client = TestClient(App).init(testing.allocator);
    defer client.deinit();

    const put_resp = try client.put("/items/42", "data");
    try put_resp.expectOk();
    try put_resp.expectBody("42");

    const del_resp = try client.delete("/items/42");
    try del_resp.expectNoContent();
}

test "TestClient reset clears state" {
    const App = Router.define(.{
        .routes = &.{
            Router.post("/login", struct {
                fn handle(ctx: *Context) !void {
                    ctx.setCookie("session", "abc", .{});
                    ctx.text(.ok, "ok");
                }
            }.handle),
            Router.get("/check", struct {
                fn handle(ctx: *Context) !void {
                    const session = ctx.getCookie("session") orelse "none";
                    ctx.text(.ok, session);
                }
            }.handle),
        },
    });

    var client = TestClient(App).init(testing.allocator);
    defer client.deinit();

    _ = try client.post("/login", null);
    client.reset();

    const resp = try client.get("/check");
    try resp.expectBody("none");
}
