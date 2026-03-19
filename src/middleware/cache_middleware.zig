const std = @import("std");
const Context = @import("context.zig").Context;
const HandlerFn = @import("context.zig").HandlerFn;
const StatusCode = @import("../core/http/status.zig").StatusCode;
const cache_mod = @import("../core/cache.zig");

/// Cached response entry.
const CachedResponse = struct {
    body: [4096]u8 = undefined,
    body_len: usize = 0,
    content_type: [128]u8 = undefined,
    content_type_len: usize = 0,
};

/// Configuration for the response cache middleware.
pub const CacheConfig = struct {
    /// Paths eligible for caching (prefix match).
    cacheable_prefixes: []const []const u8 = &.{"/"},
    /// Default TTL in seconds.
    default_ttl_s: u32 = 300,
};

/// Global response cache instance.
var response_cache: cache_mod.Cache(CachedResponse) = .{};

/// Create a response cache middleware.
pub fn cacheMiddleware(comptime config: CacheConfig) HandlerFn {
    const S = struct {
        fn handle(ctx: *Context) anyerror!void {
            // Only cache GET requests
            if (ctx.request.method != .GET) {
                try ctx.next();
                return;
            }

            // Check if path is cacheable
            const path = ctx.request.path;
            var cacheable = false;
            inline for (config.cacheable_prefixes) |prefix| {
                if (path.len >= prefix.len and std.mem.eql(u8, path[0..prefix.len], prefix)) {
                    cacheable = true;
                    break;
                }
            }
            if (!cacheable) {
                try ctx.next();
                return;
            }

            // Check Cache-Control: no-cache
            if (ctx.request.header("Cache-Control")) |cc| {
                if (std.mem.indexOf(u8, cc, "no-cache") != null) {
                    try ctx.next();
                    return;
                }
            }

            // Try cache lookup
            if (response_cache.get(path)) |cached| {
                ctx.response.status = .ok;
                ctx.response.body = cached.body[0..cached.body_len];
                ctx.response.headers.append(ctx.allocator, "Content-Type", cached.content_type[0..cached.content_type_len]) catch {};
                ctx.response.headers.append(ctx.allocator, "X-Cache", "HIT") catch {};
                return;
            }

            // Cache miss — call downstream
            try ctx.next();

            // Cache the response if 200 OK and body fits
            if (ctx.response.status == .ok) {
                if (ctx.response.body) |body| {
                    if (body.len <= 4096) {
                        var entry: CachedResponse = .{};
                        entry.body_len = body.len;
                        @memcpy(entry.body[0..body.len], body);

                        if (ctx.response.headers.get("Content-Type")) |ct| {
                            if (ct.len <= 128) {
                                entry.content_type_len = ct.len;
                                @memcpy(entry.content_type[0..ct.len], ct);
                            }
                        }

                        response_cache.put(path, entry, config.default_ttl_s * 1000);
                    }
                }
                ctx.response.headers.append(ctx.allocator, "X-Cache", "MISS") catch {};
            }
        }
    };
    return &S.handle;
}

/// Get a reference to the global response cache (for manual invalidation).
pub fn getResponseCache() *cache_mod.Cache(CachedResponse) {
    return &response_cache;
}
