const std = @import("std");
const RouteDef = @import("../router/router.zig").RouteDef;
const SecurityScheme = @import("../router/router.zig").SecurityScheme;
const schema_mod = @import("schema.zig");
const jsonSchema = schema_mod.jsonSchema;
const typeBaseName = schema_mod.typeBaseName;
const escapeJsonString = schema_mod.escapeJsonString;

/// Configuration for OpenAPI spec generation.
pub const SpecConfig = struct {
    title: []const u8 = "API Documentation",
    description: []const u8 = "",
    version: []const u8 = "1.0.0",
    server_url: []const u8 = "/",
    security_schemes: []const SecurityScheme = &.{},
};

/// Generate a complete OpenAPI 3.1.0 JSON spec from annotated routes at compile time.
/// Only routes with `.doc()` annotations are included.
pub fn generateSpec(comptime config: SpecConfig, comptime routes: []const RouteDef) []const u8 {
    comptime {
        @setEvalBranchQuota(200_000);
        var result: []const u8 = "{\"openapi\":\"3.1.0\",\"info\":{\"title\":\"" ++
            escapeJsonString(config.title) ++ "\"";

        if (config.description.len > 0) {
            result = result ++ ",\"description\":\"" ++ escapeJsonString(config.description) ++ "\"";
        }

        result = result ++ ",\"version\":\"" ++ escapeJsonString(config.version) ++ "\"}";

        // Servers
        result = result ++ ",\"servers\":[{\"url\":\"" ++ escapeJsonString(config.server_url) ++ "\"}]";

        // Paths
        result = result ++ ",\"paths\":{";

        // Collect unique paths from documented routes
        const doc_routes = getDocumentedRoutes(routes);

        if (doc_routes.len > 0) {
            const unique_paths = getUniquePaths(doc_routes);
            var path_first = true;

            for (unique_paths) |path| {
                if (!path_first) {
                    result = result ++ ",";
                }
                result = result ++ "\"" ++ convertPattern(path) ++ "\":{";

                // Add all methods for this path
                var method_first = true;
                for (doc_routes) |r| {
                    if (std.mem.eql(u8, r.pattern, path)) {
                        if (!method_first) {
                            result = result ++ ",";
                        }
                        result = result ++ generateOperation(r);
                        method_first = false;
                    }
                }

                result = result ++ "}";
                path_first = false;
            }
        }

        result = result ++ "}";

        // Components (schemas + securitySchemes)
        const schema_types = collectSchemaTypes(doc_routes);
        const has_schemas = schema_types.len > 0;
        const has_security_schemes = config.security_schemes.len > 0;

        if (has_schemas or has_security_schemes) {
            result = result ++ ",\"components\":{";
            var components_first = true;

            if (has_schemas) {
                result = result ++ "\"schemas\":{";
                var schema_first = true;
                for (schema_types) |st| {
                    if (!schema_first) {
                        result = result ++ ",";
                    }
                    result = result ++ "\"" ++ st.name ++ "\":" ++ st.schema;
                    schema_first = false;
                }
                result = result ++ "}";
                components_first = false;
            }

            if (has_security_schemes) {
                if (!components_first) {
                    result = result ++ ",";
                }
                result = result ++ "\"securitySchemes\":{" ++ generateSecuritySchemes(config.security_schemes) ++ "}";
            }

            result = result ++ "}";
        }

        result = result ++ "}";
        return result;
    }
}

const SchemaEntry = struct {
    name: []const u8,
    schema: []const u8,
};

fn collectSchemaTypes(comptime doc_routes: []const RouteDef) []const SchemaEntry {
    comptime {
        var entries: [64]SchemaEntry = undefined;
        var count: usize = 0;

        for (doc_routes) |r| {
            const api_doc = r.api_doc.?;

            if (api_doc.request_body) |T| {
                const name = typeBaseName(T);
                if (!hasSchemaName(entries[0..count], name)) {
                    entries[count] = .{ .name = name, .schema = jsonSchema(T) };
                    count += 1;
                }
            }

            if (api_doc.response_body) |T| {
                const name = typeBaseName(T);
                if (!hasSchemaName(entries[0..count], name)) {
                    entries[count] = .{ .name = name, .schema = jsonSchema(T) };
                    count += 1;
                }
            }
        }

        const result = entries[0..count].*;
        return &result;
    }
}

fn hasSchemaName(comptime entries: []const SchemaEntry, comptime name: []const u8) bool {
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return true;
    }
    return false;
}

fn getDocumentedRoutes(comptime routes: []const RouteDef) []const RouteDef {
    comptime {
        var count: usize = 0;
        for (routes) |r| {
            if (r.api_doc != null) count += 1;
        }

        var result: [count]RouteDef = undefined;
        var i: usize = 0;
        for (routes) |r| {
            if (r.api_doc != null) {
                result[i] = r;
                i += 1;
            }
        }
        const final = result;
        return &final;
    }
}

fn getUniquePaths(comptime doc_routes: []const RouteDef) []const []const u8 {
    comptime {
        var paths: [64][]const u8 = undefined;
        var count: usize = 0;

        for (doc_routes) |r| {
            var found = false;
            for (paths[0..count]) |p| {
                if (std.mem.eql(u8, p, r.pattern)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                paths[count] = r.pattern;
                count += 1;
            }
        }

        const result = paths[0..count].*;
        return &result;
    }
}

/// Convert pidgn route pattern `:param` to OpenAPI pattern `{param}`.
fn convertPattern(comptime pattern: []const u8) []const u8 {
    comptime {
        var result: []const u8 = "";
        var i: usize = 0;
        while (i < pattern.len) {
            if (pattern[i] == ':') {
                // Find end of param name
                var end = i + 1;
                while (end < pattern.len and pattern[end] != '/') {
                    end += 1;
                }
                result = result ++ "{" ++ pattern[i + 1 .. end] ++ "}";
                i = end;
            } else {
                result = result ++ &[_]u8{pattern[i]};
                i += 1;
            }
        }
        return result;
    }
}

/// Extract path parameters from a pidgn pattern.
fn extractPathParams(comptime pattern: []const u8) []const []const u8 {
    comptime {
        var params: [16][]const u8 = undefined;
        var count: usize = 0;
        var i: usize = 0;

        while (i < pattern.len) {
            if (pattern[i] == ':') {
                var end = i + 1;
                while (end < pattern.len and pattern[end] != '/') {
                    end += 1;
                }
                params[count] = pattern[i + 1 .. end];
                count += 1;
                i = end;
            } else {
                i += 1;
            }
        }

        const result = params[0..count].*;
        return &result;
    }
}

/// Convert Method enum to lowercase HTTP method string for OpenAPI.
fn methodStr(comptime method: @import("../core/http/request.zig").Method) []const u8 {
    return switch (method) {
        .GET => "get",
        .POST => "post",
        .PUT => "put",
        .PATCH => "patch",
        .DELETE => "delete",
        .OPTIONS => "options",
        .HEAD => "head",
        .CONNECT => "connect",
        .TRACE => "trace",
    };
}

fn generateOperation(comptime r: RouteDef) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        const api_doc = r.api_doc.?;
        var result: []const u8 = "\"" ++ methodStr(r.method) ++ "\":{";

        // Summary
        if (api_doc.summary.len > 0) {
            result = result ++ "\"summary\":\"" ++ escapeJsonString(api_doc.summary) ++ "\"";
        } else {
            result = result ++ "\"summary\":\"" ++ methodStr(r.method) ++ " " ++ convertPattern(r.pattern) ++ "\"";
        }

        // Description
        if (api_doc.description.len > 0) {
            result = result ++ ",\"description\":\"" ++ escapeJsonString(api_doc.description) ++ "\"";
        }

        // OperationId (from route name or pattern)
        if (r.name.len > 0) {
            result = result ++ ",\"operationId\":\"" ++ escapeJsonString(r.name) ++ "\"";
        }

        // Tags
        if (api_doc.tag.len > 0) {
            result = result ++ ",\"tags\":[\"" ++ escapeJsonString(api_doc.tag) ++ "\"]";
        }

        // Parameters (path params + query params)
        const path_params = extractPathParams(r.pattern);
        if (path_params.len > 0 or api_doc.query_params.len > 0) {
            result = result ++ ",\"parameters\":[";
            var param_first = true;

            // Path parameters
            for (path_params) |p| {
                if (!param_first) result = result ++ ",";
                result = result ++ "{\"name\":\"" ++ escapeJsonString(p) ++ "\",\"in\":\"path\",\"required\":true,\"schema\":{\"type\":\"string\"}}";
                param_first = false;
            }

            // Query parameters
            for (api_doc.query_params) |qp| {
                if (!param_first) result = result ++ ",";
                result = result ++ "{\"name\":\"" ++ escapeJsonString(qp.name) ++ "\",\"in\":\"query\"";
                if (qp.description.len > 0) {
                    result = result ++ ",\"description\":\"" ++ escapeJsonString(qp.description) ++ "\"";
                }
                if (qp.required) {
                    result = result ++ ",\"required\":true";
                }
                result = result ++ ",\"schema\":{\"type\":\"" ++ escapeJsonString(qp.schema_type) ++ "\"}}";
                param_first = false;
            }

            result = result ++ "]";
        }

        // Request body
        if (api_doc.request_body) |T| {
            const ref_name = typeBaseName(T);
            result = result ++ ",\"requestBody\":{\"required\":true,\"content\":{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/" ++ ref_name ++ "\"}}}}";
        }

        // Responses
        result = result ++ ",\"responses\":{\"200\":{\"description\":\"Successful response\"";
        if (api_doc.response_body) |T| {
            const ref_name = typeBaseName(T);
            result = result ++ ",\"content\":{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/" ++ ref_name ++ "\"}}}";
        }
        result = result ++ "}}";

        // Per-operation security
        if (api_doc.security.len > 0) {
            result = result ++ ",\"security\":[" ++ generateOperationSecurity(api_doc.security) ++ "]";
        }

        result = result ++ "}";
        return result;
    }
}

/// Generate the contents of the "securitySchemes" object.
fn generateSecuritySchemes(comptime schemes: []const SecurityScheme) []const u8 {
    comptime {
        var result: []const u8 = "";
        var first = true;

        for (schemes) |s| {
            if (!first) {
                result = result ++ ",";
            }
            result = result ++ "\"" ++ escapeJsonString(s.name) ++ "\":{";

            result = result ++ "\"type\":\"" ++ switch (s.type) {
                .http => "http",
                .apiKey => "apiKey",
                .openIdConnect => "openIdConnect",
            } ++ "\"";

            if (s.scheme) |scheme| {
                result = result ++ ",\"scheme\":\"" ++ escapeJsonString(scheme) ++ "\"";
            }

            if (s.bearer_format) |bf| {
                result = result ++ ",\"bearerFormat\":\"" ++ escapeJsonString(bf) ++ "\"";
            }

            if (s.in) |in_val| {
                result = result ++ ",\"in\":\"" ++ switch (in_val) {
                    .header => "header",
                    .query => "query",
                    .cookie => "cookie",
                } ++ "\"";
            }

            if (s.param_name) |pn| {
                result = result ++ ",\"name\":\"" ++ escapeJsonString(pn) ++ "\"";
            }

            if (s.description.len > 0) {
                result = result ++ ",\"description\":\"" ++ escapeJsonString(s.description) ++ "\"";
            }

            result = result ++ "}";
            first = false;
        }

        return result;
    }
}

/// Generate the contents of a per-operation "security" array.
fn generateOperationSecurity(comptime names: []const []const u8) []const u8 {
    comptime {
        var result: []const u8 = "";
        var first = true;

        for (names) |name| {
            if (!first) {
                result = result ++ ",";
            }
            result = result ++ "{\"" ++ escapeJsonString(name) ++ "\":[]}";
            first = false;
        }

        return result;
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

test "convertPattern: simple path" {
    try std.testing.expectEqualStrings("/api/users", comptime convertPattern("/api/users"));
}

test "convertPattern: with params" {
    try std.testing.expectEqualStrings("/api/users/{id}", comptime convertPattern("/api/users/:id"));
    try std.testing.expectEqualStrings("/api/users/{id}/posts/{post_id}", comptime convertPattern("/api/users/:id/posts/:post_id"));
}

test "extractPathParams" {
    const params = comptime extractPathParams("/api/users/:id/posts/:post_id");
    try std.testing.expectEqual(@as(usize, 2), params.len);
    try std.testing.expectEqualStrings("id", params[0]);
    try std.testing.expectEqualStrings("post_id", params[1]);
}

test "extractPathParams: no params" {
    const params = comptime extractPathParams("/api/users");
    try std.testing.expectEqual(@as(usize, 0), params.len);
}

test "generateSpec: empty routes" {
    const spec = comptime generateSpec(.{ .title = "Test" }, &.{});
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"openapi\":\"3.1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"title\":\"Test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"paths\":{}") != null);
}

test "generateSpec: skips undocumented routes" {
    const Context = @import("../middleware/context.zig").Context;
    const H = struct {
        fn handle(_: *Context) anyerror!void {}
    };

    const spec = comptime generateSpec(.{}, &[_]RouteDef{
        .{ .method = .GET, .pattern = "/", .handler = &H.handle },
        .{ .method = .GET, .pattern = "/about", .handler = &H.handle },
    });
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"paths\":{}") != null);
}

test "generateSpec: includes documented routes" {
    const Context = @import("../middleware/context.zig").Context;
    const H = struct {
        fn handle(_: *Context) anyerror!void {}
    };

    const StatusResponse = struct {
        status: []const u8,
        version: []const u8,
    };

    const spec = comptime generateSpec(.{ .title = "Test API" }, &[_]RouteDef{
        .{ .method = .GET, .pattern = "/", .handler = &H.handle },
        .{
            .method = .GET,
            .pattern = "/api/status",
            .handler = &H.handle,
            .name = "api_status",
            .api_doc = .{
                .summary = "Health check",
                .tag = "System",
                .response_body = StatusResponse,
            },
        },
    });
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"/api/status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"Health check\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"System\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"StatusResponse\"") != null);
    // Undocumented route should not appear
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"/\":{") == null);
}

test "generateSpec: path params converted" {
    const Context = @import("../middleware/context.zig").Context;
    const H = struct {
        fn handle(_: *Context) anyerror!void {}
    };

    const spec = comptime generateSpec(.{}, &[_]RouteDef{
        .{
            .method = .GET,
            .pattern = "/api/users/:id",
            .handler = &H.handle,
            .api_doc = .{ .summary = "Get user" },
        },
    });
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"/api/users/{id}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"in\":\"path\"") != null);
}

test "generateSpec: securitySchemes appear when configured" {
    const Context = @import("../middleware/context.zig").Context;
    const H = struct {
        fn handle(_: *Context) anyerror!void {}
    };

    const spec = comptime generateSpec(.{
        .title = "Secure API",
        .security_schemes = &.{
            .{ .name = "bearerAuth", .type = .http, .scheme = "bearer", .bearer_format = "JWT" },
            .{ .name = "apiKeyAuth", .type = .apiKey, .in = .header, .param_name = "X-API-Key" },
        },
    }, &[_]RouteDef{
        .{
            .method = .GET,
            .pattern = "/api/status",
            .handler = &H.handle,
            .api_doc = .{ .summary = "Status" },
        },
    });
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"securitySchemes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"bearerAuth\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"scheme\":\"bearer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"bearerFormat\":\"JWT\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"apiKeyAuth\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"in\":\"header\"") != null);
}

test "generateSpec: per-operation security array" {
    const Context = @import("../middleware/context.zig").Context;
    const H = struct {
        fn handle(_: *Context) anyerror!void {}
    };

    const spec = comptime generateSpec(.{
        .security_schemes = &.{
            .{ .name = "bearerAuth", .type = .http, .scheme = "bearer" },
        },
    }, &[_]RouteDef{
        .{
            .method = .GET,
            .pattern = "/api/me",
            .handler = &H.handle,
            .api_doc = .{ .summary = "Current user", .security = &.{"bearerAuth"} },
        },
    });
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"security\":[{\"bearerAuth\":[]}]") != null);
}

test "generateSpec: no security output when not configured" {
    const Context = @import("../middleware/context.zig").Context;
    const H = struct {
        fn handle(_: *Context) anyerror!void {}
    };

    const spec = comptime generateSpec(.{}, &[_]RouteDef{
        .{
            .method = .GET,
            .pattern = "/api/public",
            .handler = &H.handle,
            .api_doc = .{ .summary = "Public endpoint" },
        },
    });
    try std.testing.expect(std.mem.indexOf(u8, spec, "securitySchemes") == null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"security\"") == null);
}
