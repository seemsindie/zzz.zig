const std = @import("std");
const native_os = @import("builtin").os.tag;
const Context = @import("context.zig").Context;
const HandlerFn = @import("context.zig").HandlerFn;
const Assigns = @import("context.zig").Assigns;

/// Session middleware configuration.
pub const SessionConfig = struct {
    cookie_name: []const u8 = "pidgn_session",
    max_age: i64 = 86400, // 1 day
    path: []const u8 = "/",
    http_only: bool = true,
    secure: bool = false,
};

/// A single session entry: maps a 32-char hex ID to an Assigns snapshot.
/// Values are deep-copied into `value_store` so they survive across requests.
const SessionEntry = struct {
    id: [32]u8,
    data: Assigns = .{},
    active: bool = false,
    /// Static buffer holding copies of assign value data.
    value_store: [2048]u8 = undefined,
    value_store_len: usize = 0,

    /// Deep-copy assigns into this entry, copying value bytes into value_store.
    /// Keys are assumed to be string literals (static lifetime) and are not copied.
    /// Uses a staging buffer to avoid @memcpy aliasing when values already point
    /// into value_store (loaded from a previous persist).
    fn persistAssigns(self: *SessionEntry, assigns: *const Assigns) void {
        // Stage into a temp buffer to avoid aliasing with value_store
        var staging: [2048]u8 = undefined;
        var staging_len: usize = 0;
        var count: usize = 0;
        var keys: [16][]const u8 = undefined;
        var offsets: [16]usize = undefined;
        var lengths: [16]usize = undefined;

        for (assigns.entries[0..assigns.len]) |kv| {
            if (std.mem.eql(u8, kv.key, "session_id")) continue;
            if (staging_len + kv.value.len <= staging.len and count < 16) {
                keys[count] = kv.key;
                offsets[count] = staging_len;
                lengths[count] = kv.value.len;
                @memcpy(staging[staging_len .. staging_len + kv.value.len], kv.value);
                staging_len += kv.value.len;
                count += 1;
            }
        }

        // Copy from staging to value_store (guaranteed no aliasing)
        @memcpy(self.value_store[0..staging_len], staging[0..staging_len]);
        self.value_store_len = staging_len;

        // Rebuild data with slices pointing into value_store
        self.data = .{};
        for (0..count) |i| {
            self.data.put(keys[i], self.value_store[offsets[i] .. offsets[i] + lengths[i]]);
        }
    }
};

/// Create a session middleware with the given config.
/// Returns a HandlerFn that can be used in the middleware pipeline.
///
/// The session store is a comptime-generated static variable — one per config.
/// Each unique config produces its own isolated store (effectively a singleton).
pub fn session(comptime config: SessionConfig) HandlerFn {
    const S = struct {
        const max_sessions = 256;
        var store: [max_sessions]SessionEntry = initStore();
        var store_len: usize = 0;
        var csprng: std.Random.DefaultCsprng = initCsprng();
        var seeded: bool = false;

        fn initStore() [max_sessions]SessionEntry {
            var entries: [max_sessions]SessionEntry = undefined;
            for (&entries) |*e| {
                e.active = false;
                e.id = .{0} ** 32;
                e.data = .{};
            }
            return entries;
        }

        fn initCsprng() std.Random.DefaultCsprng {
            // Initialized with zeros; re-seeded at runtime on first use.
            return std.Random.DefaultCsprng.init(.{0} ** std.Random.DefaultCsprng.secret_seed_length);
        }

        fn ensureSeeded() void {
            if (seeded) return;
            var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
            fillEntropy(&seed);
            csprng = std.Random.DefaultCsprng.init(seed);
            seeded = true;
        }

        fn fillEntropy(buf: []u8) void {
            // Use OS-provided cryptographic randomness
            switch (native_os) {
                .macos, .ios, .tvos, .watchos, .visionos, .driverkit => {
                    std.c.arc4random_buf(buf.ptr, buf.len);
                },
                .linux => {
                    // Use the getrandom syscall
                    const linux = std.os.linux;
                    _ = linux.getrandom(buf.ptr, buf.len, 0);
                },
                else => {
                    // Fallback: use monotonic clock as entropy source (not ideal)
                    const c = std.c;
                    var ts: c.timespec = undefined;
                    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
                    const nanos: u64 = @intCast(@as(i128, ts.sec) * std.time.ns_per_s + ts.nsec);
                    const bytes = std.mem.asBytes(&nanos);
                    var i: usize = 0;
                    while (i < buf.len) : (i += 1) {
                        buf[i] = bytes[i % bytes.len] +% @as(u8, @truncate(i));
                    }
                },
            }
        }

        fn generateId() [32]u8 {
            ensureSeeded();
            var raw: [16]u8 = undefined;
            csprng.fill(&raw);
            return std.fmt.bytesToHex(raw, .lower);
        }

        fn findSession(id: []const u8) ?*SessionEntry {
            if (id.len != 32) return null;
            for (store[0..store_len]) |*entry| {
                if (entry.active and std.mem.eql(u8, &entry.id, id)) return entry;
            }
            return null;
        }

        fn createSession() ?*SessionEntry {
            if (store_len < max_sessions) {
                const entry = &store[store_len];
                entry.id = generateId();
                entry.data = .{};
                entry.active = true;
                store_len += 1;
                return entry;
            }
            // Store is full — evict the oldest entry
            store[0].id = generateId();
            store[0].data = .{};
            store[0].value_store_len = 0;
            store[0].active = true;
            return &store[0];
        }

        fn handle(ctx: *Context) anyerror!void {
            const session_id = ctx.getCookie(config.cookie_name);

            var entry: *SessionEntry = undefined;

            if (session_id) |sid| {
                if (findSession(sid)) |existing| {
                    entry = existing;
                } else {
                    // Cookie present but session not found — create new
                    entry = createSession() orelse {
                        try ctx.next();
                        return;
                    };
                }
            } else {
                // No cookie — create new session
                entry = createSession() orelse {
                    try ctx.next();
                    return;
                };
            }

            // Load session data into context assigns
            for (entry.data.entries[0..entry.data.len]) |kv| {
                ctx.assigns.put(kv.key, kv.value);
            }

            // Store session ID in assigns for handlers
            ctx.assign("session_id", &entry.id);

            // Set the session cookie
            ctx.setCookie(config.cookie_name, &entry.id, .{
                .max_age = config.max_age,
                .path = config.path,
                .http_only = config.http_only,
                .secure = config.secure,
            });

            try ctx.next();

            // After handler: deep-copy assigns into session-owned storage
            entry.persistAssigns(&ctx.assigns);
        }
    };
    return &S.handle;
}

// ── Tests ──────────────────────────────────────────────────────────────

const Request = @import("../core/http/request.zig").Request;
const StatusCode = @import("../core/http/status.zig").StatusCode;
const Router = @import("../router/router.zig").Router;
const Response = @import("../core/http/response.zig").Response;

test "session middleware sets session cookie on new request" {
    const H = struct {
        fn handle(ctx: *Context) !void {
            const sid = ctx.getAssign("session_id") orelse "none";
            ctx.text(.ok, sid);
        }
    };
    const App = Router.define(.{
        .middleware = &.{session(.{})},
        .routes = &.{
            Router.get("/", H.handle),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req: Request = .{ .method = .GET, .path = "/" };
    defer req.deinit(alloc);

    var resp = try App.handler(alloc, &req);
    defer resp.deinit(alloc);

    try std.testing.expectEqual(StatusCode.ok, resp.status);
    // Should have a Set-Cookie header with session
    const cookie_header = resp.headers.get("Set-Cookie").?;
    try std.testing.expect(std.mem.startsWith(u8, cookie_header, "pidgn_session="));
    // Body should be the 32-char hex session ID
    try std.testing.expectEqual(@as(usize, 32), resp.body.?.len);
}

test "session middleware restores session data" {
    const H = struct {
        fn setName(ctx: *Context) !void {
            ctx.assign("user_name", "alice");
            ctx.text(.ok, "set");
        }
        fn getName(ctx: *Context) !void {
            const name = ctx.getAssign("user_name") orelse "unknown";
            ctx.text(.ok, name);
        }
    };
    const App = Router.define(.{
        .middleware = &.{session(.{ .cookie_name = "test_sess" })},
        .routes = &.{
            Router.post("/set", H.setName),
            Router.get("/get", H.getName),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // First request: set name
    var req1: Request = .{ .method = .POST, .path = "/set" };
    defer req1.deinit(alloc);
    var resp1 = try App.handler(alloc, &req1);
    defer resp1.deinit(alloc);
    try std.testing.expectEqualStrings("set", resp1.body.?);

    // Extract session ID from Set-Cookie header
    const cookie = resp1.headers.get("Set-Cookie").?;
    // Cookie format: test_sess=<32chars>; Path=/; ...
    const prefix = "test_sess=";
    try std.testing.expect(std.mem.startsWith(u8, cookie, prefix));
    const after_eq = cookie[prefix.len..];
    const semi = std.mem.indexOfScalar(u8, after_eq, ';') orelse after_eq.len;
    const sid = after_eq[0..semi];

    // Second request: get name with session cookie
    var req2: Request = .{ .method = .GET, .path = "/get" };
    // Build cookie header value
    var cookie_buf: [64]u8 = undefined;
    const cookie_val = std.fmt.bufPrint(&cookie_buf, "test_sess={s}", .{sid}) catch unreachable;
    try req2.headers.append(alloc, "Cookie", cookie_val);
    defer req2.deinit(alloc);
    var resp2 = try App.handler(alloc, &req2);
    defer resp2.deinit(alloc);

    try std.testing.expectEqualStrings("alice", resp2.body.?);
}
