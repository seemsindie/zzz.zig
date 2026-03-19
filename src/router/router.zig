const std = @import("std");
const Allocator = std.mem.Allocator;
const Method = @import("../core/http/request.zig").Method;
const Request = @import("../core/http/request.zig").Request;
const Response = @import("../core/http/response.zig").Response;
const StatusCode = @import("../core/http/status.zig").StatusCode;
const Context = @import("../middleware/context.zig").Context;
const HandlerFn = @import("../middleware/context.zig").HandlerFn;
const Params = @import("../middleware/context.zig").Params;
const route_mod = @import("route.zig");
const Segment = route_mod.Segment;
const ws_middleware = @import("../middleware/websocket.zig");
const WsConfig = ws_middleware.WsConfig;
const channel_middleware = @import("../middleware/channel.zig");
const ChannelConfig = channel_middleware.ChannelConfig;

/// Security scheme definition for OpenAPI spec generation.
pub const SecurityScheme = struct {
    name: []const u8,
    type: SecurityType = .http,
    scheme: ?[]const u8 = null, // "bearer", "basic"
    bearer_format: ?[]const u8 = null, // "JWT"
    in: ?ApiKeyIn = null, // for apiKey
    param_name: ?[]const u8 = null, // for apiKey
    description: []const u8 = "",

    pub const SecurityType = enum { http, apiKey, openIdConnect };
    pub const ApiKeyIn = enum { header, query, cookie };
};

/// Documentation for a query parameter in an API route.
pub const QueryParamDoc = struct {
    name: []const u8,
    description: []const u8 = "",
    required: bool = false,
    schema_type: []const u8 = "string",
};

/// API documentation annotation for a route. Used by the swagger spec generator.
/// Only routes with an `ApiDoc` attached (via `.doc()`) appear in the generated OpenAPI spec.
pub const ApiDoc = struct {
    summary: []const u8 = "",
    description: []const u8 = "",
    tag: []const u8 = "",
    request_body: ?type = null,
    response_body: ?type = null,
    query_params: []const QueryParamDoc = &.{},
    security: []const []const u8 = &.{},
};

/// A route definition tuple used in the config DSL.
pub const RouteDef = struct {
    method: Method,
    pattern: []const u8,
    handler: HandlerFn,
    middleware: []const HandlerFn = &.{},
    name: []const u8 = "",
    api_doc: ?ApiDoc = null,

    /// Give this route a name for reverse URL generation.
    /// Usage: `Router.get("/users/:id", getUser).named("user_path")`
    pub fn named(self: RouteDef, comptime route_name: []const u8) RouteDef {
        return .{
            .method = self.method,
            .pattern = self.pattern,
            .handler = self.handler,
            .middleware = self.middleware,
            .name = route_name,
            .api_doc = self.api_doc,
        };
    }

    /// Attach API documentation to this route for OpenAPI spec generation.
    /// Only routes with `.doc()` will appear in the generated Swagger spec.
    ///
    /// When used with `Router.typed()`, auto-detected request/response types are
    /// preserved unless explicitly overridden in the provided `ApiDoc`.
    /// Usage: `Router.typed(.POST, "/users", handler).doc(.{ .summary = "Create user", .tag = "Users" })`
    pub fn doc(self: RouteDef, comptime api_doc: ApiDoc) RouteDef {
        // Merge: preserve auto-detected types from typed() unless overridden
        const merged = comptime blk: {
            var result = api_doc;
            if (self.api_doc) |existing| {
                if (result.request_body == null and existing.request_body != null) {
                    result.request_body = existing.request_body;
                }
                if (result.response_body == null and existing.response_body != null) {
                    result.response_body = existing.response_body;
                }
            }
            break :blk result;
        };
        return .{
            .method = self.method,
            .pattern = self.pattern,
            .handler = self.handler,
            .middleware = self.middleware,
            .name = self.name,
            .api_doc = merged,
        };
    }
};

/// Controller configuration for grouping related routes.
pub const ControllerConfig = struct {
    /// URL prefix prepended to all routes (e.g. "/api/users").
    prefix: []const u8 = "",
    /// Swagger tag auto-applied to all documented routes.
    tag: []const u8 = "",
    /// Middleware applied to all routes in this controller.
    middleware: []const HandlerFn = &.{},
};

/// A Controller groups related routes under a shared prefix, tag, and middleware.
/// Returns a type with a `routes` field containing the expanded `[]const RouteDef`.
///
/// Usage:
///   pub const ctrl = Controller.define(.{
///       .prefix = "/api/users",
///       .tag = "Users",
///   }, &.{
///       Router.get("/", listUsers).doc(.{ .summary = "List users" }),
///       Router.get("/:id", getUser).doc(.{ .summary = "Get user" }),
///       Router.post("/", createUser).doc(.{ .summary = "Create user" }),
///   });
///   // ctrl.routes is []const RouteDef with prefixed patterns and auto-tagged docs
pub const Controller = struct {
    pub fn define(comptime config: ControllerConfig, comptime defs: []const RouteDef) type {
        return struct {
            pub const prefix = config.prefix;
            pub const tag = config.tag;
            pub const routes: []const RouteDef = buildRoutes(config, defs);
        };
    }

    fn buildRoutes(comptime config: ControllerConfig, comptime defs: []const RouteDef) []const RouteDef {
        comptime {
            var result: [defs.len]RouteDef = undefined;
            for (defs, 0..) |r, i| {
                var api_doc = r.api_doc;
                // Auto-apply tag if controller has one and route's doc has no tag
                if (config.tag.len > 0) {
                    if (api_doc) |d| {
                        if (d.tag.len == 0) {
                            var updated = d;
                            updated.tag = config.tag;
                            api_doc = updated;
                        }
                    }
                }
                result[i] = .{
                    .method = r.method,
                    .pattern = config.prefix ++ r.pattern,
                    .handler = r.handler,
                    .middleware = config.middleware ++ r.middleware,
                    .name = r.name,
                    .api_doc = api_doc,
                };
            }
            const final = result;
            return &final;
        }
    }
};

/// Router configuration.
pub const RouterConfig = struct {
    middleware: []const HandlerFn = &.{},
    routes: []const RouteDef = &.{},
};

/// The Router namespace — use `Router.define(config)` to create a routed app.
pub const Router = struct {
    // ── Route helper functions ─────────────────────────────────────────

    pub fn get(comptime pattern: []const u8, comptime handler: HandlerFn) RouteDef {
        return .{ .method = .GET, .pattern = pattern, .handler = handler };
    }

    pub fn post(comptime pattern: []const u8, comptime handler: HandlerFn) RouteDef {
        return .{ .method = .POST, .pattern = pattern, .handler = handler };
    }

    pub fn put(comptime pattern: []const u8, comptime handler: HandlerFn) RouteDef {
        return .{ .method = .PUT, .pattern = pattern, .handler = handler };
    }

    pub fn patch(comptime pattern: []const u8, comptime handler: HandlerFn) RouteDef {
        return .{ .method = .PATCH, .pattern = pattern, .handler = handler };
    }

    pub fn delete(comptime pattern: []const u8, comptime handler: HandlerFn) RouteDef {
        return .{ .method = .DELETE, .pattern = pattern, .handler = handler };
    }

    pub fn options(comptime pattern: []const u8, comptime handler: HandlerFn) RouteDef {
        return .{ .method = .OPTIONS, .pattern = pattern, .handler = handler };
    }

    pub fn head(comptime pattern: []const u8, comptime handler: HandlerFn) RouteDef {
        return .{ .method = .HEAD, .pattern = pattern, .handler = handler };
    }

    /// Route with an arbitrary method.
    pub fn route(comptime method: Method, comptime pattern: []const u8, comptime handler: HandlerFn) RouteDef {
        return .{ .method = method, .pattern = pattern, .handler = handler };
    }

    /// Route with auto-detected request/response types for Swagger documentation.
    ///
    /// Accepts richer handler signatures beyond the standard `HandlerFn`:
    /// - `fn(*Context) !void`           — passthrough (standard HandlerFn)
    /// - `fn(*Context) !ResponseType`   — auto-detect response body
    /// - `fn(*Context, RequestType) !void` — auto-detect request body (JSON parsed)
    /// - `fn(*Context, RequestType) !ResponseType` — auto-detect both
    ///
    /// The generated wrapper handles JSON parsing of the request body and JSON
    /// serialization of the response. ApiDoc types are set automatically.
    ///
    /// Usage:
    /// ```
    /// fn createUser(ctx: *zzz.Context, body: CreateUserRequest) !UserResponse {
    ///     _ = ctx;
    ///     return .{ .id = 1, .name = body.name };
    /// }
    /// Router.typed(.POST, "/api/users", createUser).doc(.{ .summary = "Create user", .tag = "Users" })
    /// ```
    pub fn typed(comptime method: Method, comptime pattern: []const u8, comptime handler: anytype) RouteDef {
        const info = analyzeTypedHandler(handler);
        return .{
            .method = method,
            .pattern = pattern,
            .handler = info.handler_fn,
            .api_doc = info.api_doc,
        };
    }

    /// Define a WebSocket route. Generates a GET handler that upgrades to WebSocket.
    pub fn ws(comptime pattern: []const u8, comptime config: WsConfig) RouteDef {
        return .{ .method = .GET, .pattern = pattern, .handler = ws_middleware.wsHandler(config) };
    }

    /// Define a channel WebSocket route (Phoenix-style channels).
    pub fn channel(comptime pattern: []const u8, comptime config: ChannelConfig) RouteDef {
        return .{ .method = .GET, .pattern = pattern, .handler = channel_middleware.channelHandler(config) };
    }

    /// RESTful resource handlers for auto-generating CRUD routes.
    pub const ResourceHandlers = struct {
        index: ?HandlerFn = null, // GET /prefix
        show: ?HandlerFn = null, // GET /prefix/:id
        create: ?HandlerFn = null, // POST /prefix
        update: ?HandlerFn = null, // PUT /prefix/:id
        delete_handler: ?HandlerFn = null, // DELETE /prefix/:id
        edit: ?HandlerFn = null, // GET /prefix/:id/edit
        new: ?HandlerFn = null, // GET /prefix/new
        middleware: []const HandlerFn = &.{},
    };

    /// Generate RESTful CRUD routes for a resource prefix.
    /// Returns a slice of RouteDefs that can be concatenated with `++`.
    ///
    /// Usage:
    ///   .routes = Router.resource("/api/users", .{ .index = listUsers, .show = getUser }) ++ &.{
    ///       Router.get("/", index),
    ///   },
    pub fn resource(comptime prefix: []const u8, comptime h: ResourceHandlers) []const RouteDef {
        comptime {
            var count = 0;
            if (h.index != null) count += 1;
            if (h.show != null) count += 1;
            if (h.create != null) count += 1;
            if (h.update != null) count += 1;
            if (h.delete_handler != null) count += 1;
            if (h.edit != null) count += 1;
            if (h.new != null) count += 1;

            var routes: [count]RouteDef = undefined;
            var i = 0;

            if (h.index) |handler| {
                routes[i] = .{ .method = .GET, .pattern = prefix, .handler = handler, .middleware = h.middleware };
                i += 1;
            }
            if (h.new) |handler| {
                routes[i] = .{ .method = .GET, .pattern = prefix ++ "/new", .handler = handler, .middleware = h.middleware };
                i += 1;
            }
            if (h.create) |handler| {
                routes[i] = .{ .method = .POST, .pattern = prefix, .handler = handler, .middleware = h.middleware };
                i += 1;
            }
            if (h.show) |handler| {
                routes[i] = .{ .method = .GET, .pattern = prefix ++ "/:id", .handler = handler, .middleware = h.middleware };
                i += 1;
            }
            if (h.edit) |handler| {
                routes[i] = .{ .method = .GET, .pattern = prefix ++ "/:id/edit", .handler = handler, .middleware = h.middleware };
                i += 1;
            }
            if (h.update) |handler| {
                routes[i] = .{ .method = .PUT, .pattern = prefix ++ "/:id", .handler = handler, .middleware = h.middleware };
                i += 1;
            }
            if (h.delete_handler) |handler| {
                routes[i] = .{ .method = .DELETE, .pattern = prefix ++ "/:id", .handler = handler, .middleware = h.middleware };
                i += 1;
            }

            const result = routes;
            return &result;
        }
    }

    /// Group routes under a common prefix with shared middleware.
    pub fn scope(
        comptime prefix: []const u8,
        comptime mw: []const HandlerFn,
        comptime routes: []const RouteDef,
    ) []const RouteDef {
        comptime {
            var expanded: [routes.len]RouteDef = undefined;
            for (routes, 0..) |r, i| {
                expanded[i] = .{
                    .method = r.method,
                    .pattern = prefix ++ r.pattern,
                    .handler = r.handler,
                    .middleware = mw ++ r.middleware,
                    .name = r.name,
                    .api_doc = r.api_doc,
                };
            }
            const result = expanded;
            return &result;
        }
    }

    /// Define a router from a comptime config. Returns a type with a `handler`
    /// function matching the `Handler` signature expected by `Server`.
    pub fn define(comptime config: RouterConfig) type {
        return struct {
            /// Handler function compatible with Server's Handler type.
            pub fn handler(allocator: Allocator, req: *const Request) anyerror!Response {
                return dispatch(config, allocator, req);
            }

            /// Look up a route's pattern by name at compile time.
            /// Usage: `const pattern = App.pathFor("user_path");`
            pub fn pathFor(comptime route_name: []const u8) []const u8 {
                return comptime blk: {
                    for (config.routes) |r| {
                        if (r.name.len > 0 and std.mem.eql(u8, r.name, route_name)) {
                            break :blk r.pattern;
                        }
                    }
                    @compileError("unknown route name: " ++ route_name);
                };
            }

            /// Build a URL by substituting params into a named route's pattern.
            /// Params should be a struct with fields matching the route's parameters.
            /// Example: `App.buildPath("user_path", &buf, .{ .id = "42" })`
            pub fn buildPath(
                comptime route_name: []const u8,
                buf: []u8,
                params: anytype,
            ) ?[]const u8 {
                const segments = comptime route_mod.compilePattern(pathFor(route_name));

                if (segments.len == 0) {
                    if (buf.len < 1) return null;
                    buf[0] = '/';
                    return buf[0..1];
                }

                var pos: usize = 0;
                inline for (segments) |seg| {
                    switch (seg) {
                        .static => |lit| {
                            if (pos + 1 + lit.len > buf.len) return null;
                            buf[pos] = '/';
                            pos += 1;
                            @memcpy(buf[pos..][0..lit.len], lit);
                            pos += lit.len;
                        },
                        .param => |name| {
                            const value: []const u8 = @field(params, name);
                            if (pos + 1 + value.len > buf.len) return null;
                            buf[pos] = '/';
                            pos += 1;
                            @memcpy(buf[pos..][0..value.len], value);
                            pos += value.len;
                        },
                        .wildcard => |name| {
                            const value: []const u8 = @field(params, name);
                            if (pos + 1 + value.len > buf.len) return null;
                            buf[pos] = '/';
                            pos += 1;
                            @memcpy(buf[pos..][0..value.len], value);
                            pos += value.len;
                        },
                    }
                }

                return buf[0..pos];
            }

            /// Look up a named route at runtime and substitute params to build a URL.
            /// Unlike `buildPath`, this accepts runtime route names via `std.mem.eql`.
            /// Returns an allocator-owned string, or `null` if the route is not found
            /// or a required parameter is missing.
            pub fn urlFor(allocator: Allocator, route_name: []const u8, params: *const Params) ?[]const u8 {
                inline for (config.routes) |r| {
                    if (r.name.len > 0 and std.mem.eql(u8, r.name, route_name)) {
                        return substitutePattern(allocator, r.pattern, params);
                    }
                }
                return null;
            }

            fn substitutePattern(allocator: Allocator, comptime pattern: []const u8, params: *const Params) ?[]const u8 {
                const segments = comptime route_mod.compilePattern(pattern);

                if (segments.len == 0) {
                    return allocator.dupe(u8, "/") catch return null;
                }

                var buf: [512]u8 = undefined;
                var pos: usize = 0;

                inline for (segments) |seg| {
                    switch (seg) {
                        .static => |lit| {
                            if (pos + 1 + lit.len > buf.len) return null;
                            buf[pos] = '/';
                            pos += 1;
                            @memcpy(buf[pos..][0..lit.len], lit);
                            pos += lit.len;
                        },
                        .param => |name| {
                            const value = params.get(name) orelse return null;
                            if (pos + 1 + value.len > buf.len) return null;
                            buf[pos] = '/';
                            pos += 1;
                            @memcpy(buf[pos..][0..value.len], value);
                            pos += value.len;
                        },
                        .wildcard => |name| {
                            const value = params.get(name) orelse return null;
                            if (pos + 1 + value.len > buf.len) return null;
                            buf[pos] = '/';
                            pos += 1;
                            @memcpy(buf[pos..][0..value.len], value);
                            pos += value.len;
                        },
                    }
                }

                return allocator.dupe(u8, buf[0..pos]) catch return null;
            }
        };
    }
};

/// Analyze a typed handler function and generate a wrapper HandlerFn + ApiDoc.
///
/// Inspects the handler's parameter and return types at comptime to:
/// 1. Auto-detect request body type (second parameter, JSON-parsed)
/// 2. Auto-detect response body type (non-void return, JSON-serialized)
/// 3. Generate a wrapper that conforms to the standard `HandlerFn` signature
fn analyzeTypedHandler(comptime handler: anytype) struct { handler_fn: HandlerFn, api_doc: ?ApiDoc } {
    const H = @TypeOf(handler);

    // If already a standard HandlerFn, passthrough
    if (H == HandlerFn) {
        return .{ .handler_fn = handler, .api_doc = null };
    }

    const fn_info = @typeInfo(H).@"fn";
    const params = fn_info.params;
    const return_type = fn_info.return_type.?;

    // Validate: first param must be *Context
    if (params.len == 0) {
        @compileError("typed handler must accept *Context as first parameter");
    }
    if (params[0].type != *Context) {
        @compileError("typed handler first parameter must be *Context, got " ++ @typeName(params[0].type.?));
    }
    if (params.len > 2) {
        @compileError("typed handler accepts at most 2 parameters (*Context and optional RequestType)");
    }

    // Unwrap error union to get payload type
    const return_payload = comptime blk: {
        if (@typeInfo(return_type) == .error_union) {
            break :blk @typeInfo(return_type).error_union.payload;
        }
        break :blk return_type;
    };

    const has_request_type = params.len == 2;
    const RequestType = if (has_request_type) params[1].type.? else void;
    const has_response_type = return_payload != void;
    const ResponseType = if (has_response_type) return_payload else void;

    // Build ApiDoc with auto-detected types
    const api_doc: ?ApiDoc = if (has_request_type or has_response_type) ApiDoc{
        .request_body = if (has_request_type) RequestType else null,
        .response_body = if (has_response_type) ResponseType else null,
    } else null;

    // If the handler is already a standard signature, no wrapper needed
    if (!has_request_type and !has_response_type) {
        return .{
            .handler_fn = @ptrCast(&handler),
            .api_doc = api_doc,
        };
    }

    // Generate wrapper
    const S = struct {
        fn handle(ctx: *Context) anyerror!void {
            if (has_request_type) {
                const body_bytes = ctx.request.body orelse {
                    ctx.respond(.bad_request, "application/json; charset=utf-8", "{\"error\":\"request body required\"}");
                    return;
                };
                const parsed = std.json.parseFromSlice(RequestType, ctx.allocator, body_bytes, .{}) catch {
                    ctx.respond(.bad_request, "application/json; charset=utf-8", "{\"error\":\"invalid request body\"}");
                    return;
                };
                defer parsed.deinit();

                if (has_response_type) {
                    const result: ResponseType = try handler(ctx, parsed.value);
                    const json_bytes = std.json.Stringify.valueAlloc(ctx.allocator, result, .{}) catch {
                        ctx.respond(.internal_server_error, "application/json; charset=utf-8", "{\"error\":\"serialization failed\"}");
                        return;
                    };
                    ctx.json(.ok, json_bytes);
                    ctx.response.body_owned = true;
                } else {
                    try handler(ctx, parsed.value);
                }
            } else {
                // No request type, but has response type
                const result: ResponseType = try handler(ctx);
                const json_bytes = std.json.Stringify.valueAlloc(ctx.allocator, result, .{}) catch {
                    ctx.respond(.internal_server_error, "application/json; charset=utf-8", "{\"error\":\"serialization failed\"}");
                    return;
                };
                ctx.json(.ok, json_bytes);
                ctx.response.body_owned = true;
            }
        }
    };

    return .{
        .handler_fn = &S.handle,
        .api_doc = api_doc,
    };
}

/// Generate a comptime chain of pipeline functions and return the entry point.
fn makePipelineEntry(comptime pipeline: []const HandlerFn) *const fn (*Context) anyerror!void {
    if (pipeline.len == 0) {
        const S = struct {
            fn noop(_: *Context) anyerror!void {}
        };
        return &S.noop;
    }
    return makePipelineStep(pipeline, 0);
}

fn makePipelineStep(comptime pipeline: []const HandlerFn, comptime index: usize) *const fn (*Context) anyerror!void {
    const S = struct {
        fn run(ctx: *Context) anyerror!void {
            // Set next_handler for ctx.next() to call
            if (index + 1 < pipeline.len) {
                ctx.next_handler = comptime makePipelineStep(pipeline, index + 1);
            } else {
                ctx.next_handler = null;
            }
            try pipeline[index](ctx);
        }
    };
    return &S.run;
}

/// The route dispatcher — runs as the terminal handler in the global middleware pipeline.
/// Matches routes, builds per-route middleware chain, runs it.
fn makeRouteDispatcher(comptime config: RouterConfig) HandlerFn {
    const S = struct {
        fn handle(ctx: *Context) anyerror!void {
            @setEvalBranchQuota(10_000);
            const path = ctx.request.path;
            const method = ctx.request.method;
            const also_try_get = (method == .HEAD);

            // Try each route
            inline for (config.routes) |route_def| {
                const segments = comptime route_mod.compilePattern(route_def.pattern);

                if (route_def.method == method or (also_try_get and route_def.method == .GET)) {
                    if (route_mod.matchSegments(segments, path)) |match_params| {
                        ctx.params = match_params;

                        // Build per-route pipeline: route middleware ++ handler
                        const route_pipeline = comptime route_def.middleware ++ &[_]HandlerFn{route_def.handler};

                        if (route_pipeline.len > 0) {
                            const entry = comptime makePipelineEntry(route_pipeline);
                            // Save and restore next_handler so route pipeline chains correctly
                            const saved = ctx.next_handler;
                            try entry(ctx);
                            ctx.next_handler = saved;
                        }

                        return;
                    }
                }
            }

            // No match — check if path matches with a different method (405)
            var path_matches = false;
            var allow_buf: [128]u8 = undefined;
            var allow_pos: usize = 0;

            inline for (config.routes) |route_def| {
                const segments = comptime route_mod.compilePattern(route_def.pattern);
                if (route_mod.matchSegments(segments, path) != null) {
                    path_matches = true;
                    const mname = comptime route_def.method.toString();
                    if (allow_pos > 0 and allow_pos + 2 < allow_buf.len) {
                        allow_buf[allow_pos] = ',';
                        allow_buf[allow_pos + 1] = ' ';
                        allow_pos += 2;
                    }
                    if (allow_pos + mname.len <= allow_buf.len) {
                        @memcpy(allow_buf[allow_pos..][0..mname.len], mname);
                        allow_pos += mname.len;
                    }
                }
            }

            if (path_matches) {
                ctx.response.status = .method_not_allowed;
                ctx.response.headers.append(ctx.allocator, "Allow", allow_buf[0..allow_pos]) catch {};
                ctx.respond(.method_not_allowed, "text/plain; charset=utf-8", "405 Method Not Allowed");
                return;
            }

            // 404
            ctx.respond(.not_found, "text/plain; charset=utf-8", "404 Not Found");
        }
    };
    return &S.handle;
}

/// Internal dispatch: run global middleware pipeline with route dispatcher as terminal handler.
fn dispatch(
    comptime config: RouterConfig,
    allocator: Allocator,
    req: *const Request,
) anyerror!Response {
    // Build pipeline: global middleware ++ route dispatcher
    const route_dispatcher = comptime makeRouteDispatcher(config);
    const pipeline = comptime config.middleware ++ &[_]HandlerFn{route_dispatcher};
    const entry = comptime makePipelineEntry(pipeline);

    var ctx: Context = .{
        .request = req,
        .response = .{},
        .params = .{},
        .query = parseQuery(req.query_string),
        .assigns = .{},
        .allocator = allocator,
        .next_handler = null,
    };

    entry(&ctx) catch |err| {
        ctx.response.deinit(allocator);
        return err;
    };

    // HEAD: clear body but keep headers
    if (req.method == .HEAD) {
        ctx.response.body = null;
    }

    return ctx.response;
}

/// Parse a query string into Params. E.g. "foo=bar&baz=qux"
fn parseQuery(query_string: ?[]const u8) Params {
    var params: Params = .{};
    const qs = query_string orelse return params;
    if (qs.len == 0) return params;

    var pos: usize = 0;
    while (pos < qs.len) {
        const amp = std.mem.indexOfScalarPos(u8, qs, pos, '&') orelse qs.len;
        const pair = qs[pos..amp];
        pos = amp + 1;

        if (pair.len == 0) continue;

        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            params.put(pair[0..eq], pair[eq + 1 ..]);
        } else {
            params.put(pair, "");
        }
    }
    return params;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "Router.define basic routing" {
    const testing = std.testing;

    const IndexHandler = struct {
        fn handle(ctx: *Context) !void {
            ctx.text(.ok, "index");
        }
    };
    const HelloHandler = struct {
        fn handle(ctx: *Context) !void {
            ctx.text(.ok, "hello");
        }
    };
    const UserHandler = struct {
        fn handle(ctx: *Context) !void {
            const id = ctx.param("id") orelse "unknown";
            ctx.text(.ok, id);
        }
    };

    const App = Router.define(.{
        .routes = &.{
            Router.get("/", IndexHandler.handle),
            Router.get("/hello", HelloHandler.handle),
            Router.get("/users/:id", UserHandler.handle),
            Router.post("/users", HelloHandler.handle),
        },
    });

    // GET /
    {
        var req: Request = .{ .method = .GET, .path = "/" };
        defer req.deinit(testing.allocator);
        var resp = try App.handler(testing.allocator, &req);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(StatusCode.ok, resp.status);
        try testing.expectEqualStrings("index", resp.body.?);
    }

    // GET /hello
    {
        var req: Request = .{ .method = .GET, .path = "/hello" };
        defer req.deinit(testing.allocator);
        var resp = try App.handler(testing.allocator, &req);
        defer resp.deinit(testing.allocator);
        try testing.expectEqualStrings("hello", resp.body.?);
    }

    // GET /users/42 — param extraction
    {
        var req: Request = .{ .method = .GET, .path = "/users/42" };
        defer req.deinit(testing.allocator);
        var resp = try App.handler(testing.allocator, &req);
        defer resp.deinit(testing.allocator);
        try testing.expectEqualStrings("42", resp.body.?);
    }

    // GET /missing — 404
    {
        var req: Request = .{ .method = .GET, .path = "/missing" };
        defer req.deinit(testing.allocator);
        var resp = try App.handler(testing.allocator, &req);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(StatusCode.not_found, resp.status);
    }

    // POST /hello — 405
    {
        var req: Request = .{ .method = .POST, .path = "/hello" };
        defer req.deinit(testing.allocator);
        var resp = try App.handler(testing.allocator, &req);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(StatusCode.method_not_allowed, resp.status);
        try testing.expect(resp.headers.get("Allow") != null);
    }
}

test "Router.define HEAD returns no body" {
    const testing = std.testing;

    const H = struct {
        fn handle(ctx: *Context) !void {
            ctx.text(.ok, "body content");
        }
    };

    const App = Router.define(.{
        .routes = &.{
            Router.get("/hello", H.handle),
        },
    });

    var req: Request = .{ .method = .HEAD, .path = "/hello" };
    defer req.deinit(testing.allocator);
    var resp = try App.handler(testing.allocator, &req);
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(StatusCode.ok, resp.status);
    try testing.expect(resp.body == null);
}

test "Router.define middleware pipeline" {
    const testing = std.testing;

    const AuthMiddleware = struct {
        fn handle(ctx: *Context) !void {
            ctx.assign("auth", "true");
            try ctx.next();
        }
    };
    const H = struct {
        fn handle(ctx: *Context) !void {
            const auth = ctx.getAssign("auth") orelse "false";
            ctx.text(.ok, auth);
        }
    };

    const App = Router.define(.{
        .middleware = &.{AuthMiddleware.handle},
        .routes = &.{
            Router.get("/", H.handle),
        },
    });

    var req: Request = .{ .method = .GET, .path = "/" };
    defer req.deinit(testing.allocator);
    var resp = try App.handler(testing.allocator, &req);
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("true", resp.body.?);
}

test "parseQuery" {
    const q = parseQuery("foo=bar&baz=qux&empty=");
    try std.testing.expectEqualStrings("bar", q.get("foo").?);
    try std.testing.expectEqualStrings("qux", q.get("baz").?);
    try std.testing.expectEqualStrings("", q.get("empty").?);
    try std.testing.expect(q.get("missing") == null);
}

test "Router.resource generates RESTful routes" {
    const testing = std.testing;

    const Handlers = struct {
        fn index(ctx: *Context) !void {
            ctx.json(.ok, "[\"list\"]");
        }
        fn show(ctx: *Context) !void {
            const id = ctx.param("id") orelse "0";
            ctx.text(.ok, id);
        }
        fn create(ctx: *Context) !void {
            ctx.json(.created, "{\"created\":true}");
        }
    };

    const App = Router.define(.{
        .routes = Router.resource("/api/items", .{
            .index = Handlers.index,
            .show = Handlers.show,
            .create = Handlers.create,
        }),
    });

    // GET /api/items — index
    {
        var req: Request = .{ .method = .GET, .path = "/api/items" };
        defer req.deinit(testing.allocator);
        var resp = try App.handler(testing.allocator, &req);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(StatusCode.ok, resp.status);
        try testing.expectEqualStrings("[\"list\"]", resp.body.?);
    }

    // GET /api/items/42 — show
    {
        var req: Request = .{ .method = .GET, .path = "/api/items/42" };
        defer req.deinit(testing.allocator);
        var resp = try App.handler(testing.allocator, &req);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(StatusCode.ok, resp.status);
        try testing.expectEqualStrings("42", resp.body.?);
    }

    // POST /api/items — create
    {
        var req: Request = .{ .method = .POST, .path = "/api/items" };
        defer req.deinit(testing.allocator);
        var resp = try App.handler(testing.allocator, &req);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(StatusCode.created, resp.status);
    }

    // DELETE /api/items/1 — not defined, should 405
    {
        var req: Request = .{ .method = .DELETE, .path = "/api/items/1" };
        defer req.deinit(testing.allocator);
        var resp = try App.handler(testing.allocator, &req);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(StatusCode.method_not_allowed, resp.status);
    }
}

test "Router.resource combined with other routes" {
    const testing = std.testing;

    const Handlers = struct {
        fn index(ctx: *Context) !void {
            ctx.text(.ok, "posts-index");
        }
        fn show(ctx: *Context) !void {
            ctx.text(.ok, "posts-show");
        }
        fn home(ctx: *Context) !void {
            ctx.text(.ok, "home");
        }
    };

    const App = Router.define(.{
        .routes = Router.resource("/posts", .{
            .index = Handlers.index,
            .show = Handlers.show,
        }) ++ &[_]RouteDef{
            Router.get("/", Handlers.home),
        },
    });

    // GET / — home
    {
        var req: Request = .{ .method = .GET, .path = "/" };
        defer req.deinit(testing.allocator);
        var resp = try App.handler(testing.allocator, &req);
        defer resp.deinit(testing.allocator);
        try testing.expectEqualStrings("home", resp.body.?);
    }

    // GET /posts — resource index
    {
        var req: Request = .{ .method = .GET, .path = "/posts" };
        defer req.deinit(testing.allocator);
        var resp = try App.handler(testing.allocator, &req);
        defer resp.deinit(testing.allocator);
        try testing.expectEqualStrings("posts-index", resp.body.?);
    }
}

test "RouteDef.named sets name" {
    const H = struct {
        fn handle(_: *Context) !void {}
    };
    const r = Router.get("/users/:id", H.handle).named("user_path");
    try std.testing.expectEqualStrings("user_path", r.name);
    try std.testing.expectEqualStrings("/users/:id", r.pattern);
}

test "Router.define pathFor resolves named routes" {
    const H = struct {
        fn handle(ctx: *Context) !void {
            ctx.text(.ok, "ok");
        }
    };

    const App = Router.define(.{
        .routes = &.{
            Router.get("/", H.handle).named("home"),
            Router.get("/users/:id", H.handle).named("user_path"),
            Router.get("/posts/:slug/comments", H.handle).named("post_comments"),
        },
    });

    try std.testing.expectEqualStrings("/", App.pathFor("home"));
    try std.testing.expectEqualStrings("/users/:id", App.pathFor("user_path"));
    try std.testing.expectEqualStrings("/posts/:slug/comments", App.pathFor("post_comments"));
}

test "Router.define buildPath substitutes params" {
    const H = struct {
        fn handle(ctx: *Context) !void {
            ctx.text(.ok, "ok");
        }
    };

    const App = Router.define(.{
        .routes = &.{
            Router.get("/", H.handle).named("home"),
            Router.get("/users/:id", H.handle).named("user_path"),
            Router.get("/users/:id/posts/:post_id", H.handle).named("user_post"),
        },
    });

    var buf: [128]u8 = undefined;

    // Root path
    const root = App.buildPath("home", &buf, .{});
    try std.testing.expectEqualStrings("/", root.?);

    // Single param
    const user = App.buildPath("user_path", &buf, .{ .id = "42" });
    try std.testing.expectEqualStrings("/users/42", user.?);

    // Multiple params
    const post = App.buildPath("user_post", &buf, .{ .id = "7", .post_id = "hello" });
    try std.testing.expectEqualStrings("/users/7/posts/hello", post.?);
}

test "Router.scope preserves route names" {
    const H = struct {
        fn handle(ctx: *Context) !void {
            ctx.text(.ok, "ok");
        }
    };

    const App = Router.define(.{
        .routes = Router.scope("/api", &.{}, &[_]RouteDef{
            Router.get("/users/:id", H.handle).named("api_user"),
        }),
    });

    try std.testing.expectEqualStrings("/api/users/:id", App.pathFor("api_user"));

    var buf: [128]u8 = undefined;
    const path = App.buildPath("api_user", &buf, .{ .id = "99" });
    try std.testing.expectEqualStrings("/api/users/99", path.?);
}

// ── Typed handler tests ────────────────────────────────────────────

test "Router.typed with standard HandlerFn passthrough" {
    const H = struct {
        fn handle(ctx: *Context) !void {
            ctx.text(.ok, "passthrough");
        }
    };
    const r = Router.typed(.GET, "/test", @as(HandlerFn, &H.handle));
    try std.testing.expectEqual(Method.GET, r.method);
    try std.testing.expectEqualStrings("/test", r.pattern);
    try std.testing.expect(r.api_doc == null);
}

test "Router.typed auto-detects response body type" {
    const TestResponse = struct {
        message: []const u8,
        code: u32,
    };
    const H = struct {
        fn handle(_: *Context) !TestResponse {
            return .{ .message = "ok", .code = 200 };
        }
    };
    const r = Router.typed(.GET, "/status", H.handle);
    try std.testing.expectEqual(Method.GET, r.method);
    try std.testing.expect(r.api_doc != null);
    const doc_val = r.api_doc.?;
    try std.testing.expect(doc_val.request_body == null);
    try std.testing.expect(doc_val.response_body == TestResponse);
}

test "Router.typed auto-detects both request and response types" {
    const CreateRequest = struct {
        name: []const u8,
        email: []const u8,
    };
    const CreateResponse = struct {
        id: u32,
        name: []const u8,
    };
    const H = struct {
        fn handle(_: *Context, _: CreateRequest) !CreateResponse {
            return .{ .id = 1, .name = "test" };
        }
    };
    const r = Router.typed(.POST, "/users", H.handle);
    try std.testing.expectEqual(Method.POST, r.method);
    try std.testing.expect(r.api_doc != null);
    const doc_val = r.api_doc.?;
    try std.testing.expect(doc_val.request_body == CreateRequest);
    try std.testing.expect(doc_val.response_body == CreateResponse);
}

test "Router.typed auto-detects request body only" {
    const UpdateRequest = struct {
        name: []const u8,
    };
    const H = struct {
        fn handle(_: *Context, _: UpdateRequest) !void {}
    };
    const r = Router.typed(.PUT, "/users/:id", H.handle);
    try std.testing.expect(r.api_doc != null);
    const doc_val = r.api_doc.?;
    try std.testing.expect(doc_val.request_body == UpdateRequest);
    try std.testing.expect(doc_val.response_body == null);
}

test "RouteDef.doc merge preserves auto-detected types" {
    const Req = struct { name: []const u8 };
    const Resp = struct { id: u32 };
    const H = struct {
        fn handle(_: *Context, _: Req) !Resp {
            return .{ .id = 1 };
        }
    };
    const r = Router.typed(.POST, "/users", H.handle).doc(.{
        .summary = "Create user",
        .tag = "Users",
    });
    try std.testing.expect(r.api_doc != null);
    const doc_val = r.api_doc.?;
    // Auto-detected types preserved through merge
    try std.testing.expect(doc_val.request_body == Req);
    try std.testing.expect(doc_val.response_body == Resp);
    // Manually provided fields applied
    try std.testing.expectEqualStrings("Create user", doc_val.summary);
    try std.testing.expectEqualStrings("Users", doc_val.tag);
}

test "RouteDef.doc explicit types override auto-detected" {
    const OrigResp = struct { id: u32 };
    const OverrideResp = struct { id: u32, extra: []const u8 };
    const H = struct {
        fn handle(_: *Context) !OrigResp {
            return .{ .id = 1 };
        }
    };
    const r = Router.typed(.GET, "/users", H.handle).doc(.{
        .summary = "List users",
        .response_body = OverrideResp,
    });
    try std.testing.expect(r.api_doc != null);
    const doc_val = r.api_doc.?;
    // Explicit override wins
    try std.testing.expect(doc_val.response_body == OverrideResp);
}

test "Router.typed response handler executes correctly" {
    const testing_alloc = std.testing.allocator;
    const TestResp = struct {
        status: []const u8,
    };
    const H = struct {
        fn handle(ctx: *Context) !TestResp {
            _ = ctx;
            return .{ .status = "ok" };
        }
    };
    const App = Router.define(.{
        .routes = &.{
            Router.typed(.GET, "/health", H.handle),
        },
    });

    var req: Request = .{ .method = .GET, .path = "/health" };
    defer req.deinit(testing_alloc);
    var resp = try App.handler(testing_alloc, &req);
    defer resp.deinit(testing_alloc);
    try std.testing.expectEqual(StatusCode.ok, resp.status);
    // Body should be JSON-serialized
    try std.testing.expect(resp.body != null);
    const body = resp.body.?;
    try std.testing.expect(std.mem.indexOf(u8, body, "\"status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"ok\"") != null);
}

test "Router.define urlFor single param" {
    const H = struct {
        fn handle(ctx: *Context) !void {
            ctx.text(.ok, "ok");
        }
    };

    const App = Router.define(.{
        .routes = &.{
            Router.get("/users/:id", H.handle).named("user_path"),
            Router.get("/users/:id/posts/:post_id", H.handle).named("user_post"),
        },
    });

    var params: Params = .{};
    params.put("id", "42");

    const url = App.urlFor(std.testing.allocator, "user_path", &params);
    defer if (url) |u| std.testing.allocator.free(u);
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("/users/42", url.?);
}

test "Router.define urlFor multi param" {
    const H = struct {
        fn handle(ctx: *Context) !void {
            ctx.text(.ok, "ok");
        }
    };

    const App = Router.define(.{
        .routes = &.{
            Router.get("/users/:id/posts/:post_id", H.handle).named("user_post"),
        },
    });

    var params: Params = .{};
    params.put("id", "7");
    params.put("post_id", "hello");

    const url = App.urlFor(std.testing.allocator, "user_post", &params);
    defer if (url) |u| std.testing.allocator.free(u);
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("/users/7/posts/hello", url.?);
}

test "Router.define urlFor unknown route returns null" {
    const H = struct {
        fn handle(ctx: *Context) !void {
            ctx.text(.ok, "ok");
        }
    };

    const App = Router.define(.{
        .routes = &.{
            Router.get("/users/:id", H.handle).named("user_path"),
        },
    });

    var params: Params = .{};
    const url = App.urlFor(std.testing.allocator, "nonexistent", &params);
    try std.testing.expect(url == null);
}

test "Router.define urlFor missing param returns null" {
    const H = struct {
        fn handle(ctx: *Context) !void {
            ctx.text(.ok, "ok");
        }
    };

    const App = Router.define(.{
        .routes = &.{
            Router.get("/users/:id", H.handle).named("user_path"),
        },
    });

    var params: Params = .{};
    // No "id" param set
    const url = App.urlFor(std.testing.allocator, "user_path", &params);
    try std.testing.expect(url == null);
}
