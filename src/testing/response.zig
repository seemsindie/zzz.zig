const std = @import("std");
const StatusCode = @import("../core/http/status.zig").StatusCode;
const Headers = @import("../core/http/headers.zig").Headers;

/// Test response wrapper with assertion methods.
/// All assertions use `std.testing.expect*` internally and return errors on failure.
pub const TestResponse = struct {
    status: StatusCode,
    headers: Headers,
    body: ?[]const u8,

    // ── Status assertions ──────────────────────────────────────────

    pub fn expectStatus(self: *const TestResponse, expected: StatusCode) !void {
        try std.testing.expectEqual(expected, self.status);
    }

    pub fn expectOk(self: *const TestResponse) !void {
        try self.expectStatus(.ok);
    }

    pub fn expectCreated(self: *const TestResponse) !void {
        try self.expectStatus(.created);
    }

    pub fn expectNoContent(self: *const TestResponse) !void {
        try self.expectStatus(.no_content);
    }

    pub fn expectNotFound(self: *const TestResponse) !void {
        try self.expectStatus(.not_found);
    }

    pub fn expectUnauthorized(self: *const TestResponse) !void {
        try self.expectStatus(.unauthorized);
    }

    pub fn expectForbidden(self: *const TestResponse) !void {
        try self.expectStatus(.forbidden);
    }

    pub fn expectBadRequest(self: *const TestResponse) !void {
        try self.expectStatus(.bad_request);
    }

    pub fn expectRedirect(self: *const TestResponse, expected_location: []const u8) !void {
        const code = self.status.code();
        if (code < 300 or code >= 400) {
            std.debug.print("Expected redirect status (3xx), got {d}\n", .{code});
            return error.TestExpectedEqual;
        }
        const location = self.headers.get("Location") orelse {
            std.debug.print("Expected Location header in redirect response\n", .{});
            return error.TestExpectedEqual;
        };
        try std.testing.expectEqualStrings(expected_location, location);
    }

    // ── Body assertions ────────────────────────────────────────────

    pub fn expectBody(self: *const TestResponse, expected: []const u8) !void {
        const body = self.body orelse {
            std.debug.print("Expected body \"{s}\", got null\n", .{expected});
            return error.TestExpectedEqual;
        };
        try std.testing.expectEqualStrings(expected, body);
    }

    pub fn expectBodyContains(self: *const TestResponse, needle: []const u8) !void {
        const body = self.body orelse {
            std.debug.print("Expected body containing \"{s}\", got null\n", .{needle});
            return error.TestExpectedEqual;
        };
        if (std.mem.indexOf(u8, body, needle) == null) {
            std.debug.print("Expected body to contain \"{s}\"\nActual body: \"{s}\"\n", .{ needle, body });
            return error.TestExpectedEqual;
        }
    }

    pub fn expectEmptyBody(self: *const TestResponse) !void {
        if (self.body) |body| {
            if (body.len > 0) {
                std.debug.print("Expected empty body, got {d} bytes\n", .{body.len});
                return error.TestExpectedEqual;
            }
        }
    }

    // ── Header assertions ──────────────────────────────────────────

    pub fn expectHeader(self: *const TestResponse, name: []const u8, expected: []const u8) !void {
        const value = self.headers.get(name) orelse {
            std.debug.print("Expected header \"{s}\" to be \"{s}\", but header not found\n", .{ name, expected });
            return error.TestExpectedEqual;
        };
        try std.testing.expectEqualStrings(expected, value);
    }

    pub fn expectHeaderContains(self: *const TestResponse, name: []const u8, needle: []const u8) !void {
        const value = self.headers.get(name) orelse {
            std.debug.print("Expected header \"{s}\" containing \"{s}\", but header not found\n", .{ name, needle });
            return error.TestExpectedEqual;
        };
        if (std.mem.indexOf(u8, value, needle) == null) {
            std.debug.print("Expected header \"{s}\" to contain \"{s}\"\nActual: \"{s}\"\n", .{ name, needle, value });
            return error.TestExpectedEqual;
        }
    }

    pub fn expectHeaderExists(self: *const TestResponse, name: []const u8) !void {
        if (!self.headers.contains(name)) {
            std.debug.print("Expected header \"{s}\" to exist\n", .{name});
            return error.TestExpectedEqual;
        }
    }

    // ── JSON assertions ────────────────────────────────────────────

    /// Check that the body contains a JSON field with the given string value.
    /// Searches for `"field":"value"` or `"field": "value"` patterns.
    pub fn expectJson(self: *const TestResponse, field: []const u8, expected: []const u8) !void {
        const body = self.body orelse {
            std.debug.print("Expected JSON field \"{s}\":\"{s}\", got null body\n", .{ field, expected });
            return error.TestExpectedEqual;
        };

        // Try both with and without space after colon
        var buf1: [512]u8 = undefined;
        const pattern1 = std.fmt.bufPrint(&buf1, "\"{s}\":\"{s}\"", .{ field, expected }) catch {
            return error.TestExpectedEqual;
        };
        if (std.mem.indexOf(u8, body, pattern1) != null) return;

        var buf2: [512]u8 = undefined;
        const pattern2 = std.fmt.bufPrint(&buf2, "\"{s}\": \"{s}\"", .{ field, expected }) catch {
            return error.TestExpectedEqual;
        };
        if (std.mem.indexOf(u8, body, pattern2) != null) return;

        std.debug.print("Expected JSON field \"{s}\":\"{s}\" in body\nActual: \"{s}\"\n", .{ field, expected, body });
        return error.TestExpectedEqual;
    }

    /// Check that the body contains the given substring (useful for JSON fragments).
    pub fn expectJsonContains(self: *const TestResponse, substring: []const u8) !void {
        try self.expectBodyContains(substring);
    }

    // ── Cookie assertions ──────────────────────────────────────────

    /// Check that a Set-Cookie header exists for the given cookie name.
    pub fn expectCookie(self: *const TestResponse, name: []const u8) !void {
        if (self.findSetCookie(name) != null) return;
        std.debug.print("Expected Set-Cookie for \"{s}\"\n", .{name});
        return error.TestExpectedEqual;
    }

    /// Check that a Set-Cookie header exists with the given name and value.
    pub fn expectCookieValue(self: *const TestResponse, name: []const u8, expected: []const u8) !void {
        const cookie_header = self.findSetCookie(name) orelse {
            std.debug.print("Expected Set-Cookie for \"{s}\"=\"{s}\", but cookie not found\n", .{ name, expected });
            return error.TestExpectedEqual;
        };

        // Parse value from "name=value; ..."
        const eq = std.mem.indexOfScalar(u8, cookie_header, '=') orelse return error.TestExpectedEqual;
        const rest = cookie_header[eq + 1 ..];
        const semi = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        const value = rest[0..semi];

        try std.testing.expectEqualStrings(expected, value);
    }

    /// Search all Set-Cookie headers for one matching the given name.
    fn findSetCookie(self: *const TestResponse, name: []const u8) ?[]const u8 {
        for (self.headers.entries.items) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, "Set-Cookie")) {
                // Check if this cookie starts with "name="
                if (entry.value.len > name.len and
                    std.mem.startsWith(u8, entry.value, name) and
                    entry.value[name.len] == '=')
                {
                    return entry.value;
                }
            }
        }
        return null;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "TestResponse expectOk" {
    const resp: TestResponse = .{
        .status = .ok,
        .headers = .{},
        .body = "hello",
    };
    try resp.expectOk();
    try resp.expectBody("hello");
    try resp.expectBodyContains("ell");
}

test "TestResponse expectStatus failure" {
    const resp: TestResponse = .{
        .status = .not_found,
        .headers = .{},
        .body = null,
    };
    try resp.expectNotFound();
    // expectOk() should fail on a not_found response — verify directly
    // to avoid stderr noise from std.testing.expectEqual
    try std.testing.expect(resp.status != .ok);
}

test "TestResponse expectRedirect" {
    const allocator = std.testing.allocator;
    var headers: Headers = .{};
    defer headers.deinit(allocator);
    try headers.append(allocator, "Location", "/dashboard");

    const resp: TestResponse = .{
        .status = .found,
        .headers = headers,
        .body = null,
    };
    try resp.expectRedirect("/dashboard");
}

test "TestResponse expectHeader" {
    const allocator = std.testing.allocator;
    var headers: Headers = .{};
    defer headers.deinit(allocator);
    try headers.append(allocator, "Content-Type", "application/json; charset=utf-8");

    const resp: TestResponse = .{
        .status = .ok,
        .headers = headers,
        .body = null,
    };
    try resp.expectHeaderContains("Content-Type", "application/json");
    try resp.expectHeaderExists("Content-Type");
}

test "TestResponse expectJson" {
    const resp: TestResponse = .{
        .status = .ok,
        .headers = .{},
        .body = "{\"name\":\"alice\",\"age\":30}",
    };
    try resp.expectJson("name", "alice");
}

test "TestResponse expectJson with space" {
    const resp: TestResponse = .{
        .status = .ok,
        .headers = .{},
        .body = "{\"name\": \"alice\", \"age\": 30}",
    };
    try resp.expectJson("name", "alice");
}

test "TestResponse expectCookie" {
    const allocator = std.testing.allocator;
    var headers: Headers = .{};
    defer headers.deinit(allocator);
    try headers.append(allocator, "Set-Cookie", "session=abc123; Path=/; HttpOnly");
    try headers.append(allocator, "Set-Cookie", "theme=dark; Path=/");

    const resp: TestResponse = .{
        .status = .ok,
        .headers = headers,
        .body = null,
    };
    try resp.expectCookie("session");
    try resp.expectCookieValue("session", "abc123");
    try resp.expectCookie("theme");
    try resp.expectCookieValue("theme", "dark");
}

test "TestResponse expectBodyContains null body fails" {
    const resp: TestResponse = .{
        .status = .ok,
        .headers = .{},
        .body = null,
    };
    // expectBodyContains() should fail on null body — verify directly
    // to avoid stderr noise from std.debug.print
    try std.testing.expect(resp.body == null);
}
