const std = @import("std");
const Env = @import("env.zig").Env;

// ── Environment Enum ─────────────────────────────────────────────────

/// Build-time environment selector. Passed via `zig build -Denv=prod`.
pub const Environment = enum {
    dev,
    prod,
    staging,
    testing,

    pub fn fromString(s: []const u8) ?Environment {
        const map = std.StaticStringMap(Environment).initComptime(.{
            .{ "dev", .dev },
            .{ "development", .dev },
            .{ "prod", .prod },
            .{ "production", .prod },
            .{ "staging", .staging },
            .{ "test", .testing },
            .{ "testing", .testing },
        });
        return map.get(s);
    }

    pub fn toString(self: Environment) []const u8 {
        return switch (self) {
            .dev => "dev",
            .prod => "prod",
            .staging => "staging",
            .testing => "testing",
        };
    }
};

// ── DatabaseUrl ──────────────────────────────────────────────────────

/// Zero-allocation database URL parser.
///
/// Parses URLs in the following formats:
///   - `postgres://user:pass@host:port/dbname`
///   - `postgres://user@host/dbname`  (no password, default port)
///   - `sqlite:path/to/db.sqlite`
///   - `path/to/db.sqlite`  (bare filename, assumed SQLite)
///
/// All returned slices point into the original input string.
pub const DatabaseUrl = struct {
    scheme: Scheme,
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,
    host: ?[]const u8 = null,
    port: ?u16 = null,
    database: []const u8,

    pub const Scheme = enum { postgres, sqlite };

    pub const ParseError = error{InvalidUrl};

    /// Parse a database URL string into components.
    pub fn parse(url: []const u8) ParseError!DatabaseUrl {
        // postgres://...
        if (std.mem.startsWith(u8, url, "postgres://") or std.mem.startsWith(u8, url, "postgresql://")) {
            return parsePostgres(url);
        }

        // sqlite:path
        if (std.mem.startsWith(u8, url, "sqlite:")) {
            const path = url[7..];
            if (path.len == 0) return error.InvalidUrl;
            return .{ .scheme = .sqlite, .database = path };
        }

        // Bare filename — treat as SQLite
        if (url.len > 0) {
            return .{ .scheme = .sqlite, .database = url };
        }

        return error.InvalidUrl;
    }

    fn parsePostgres(url: []const u8) ParseError!DatabaseUrl {
        // Skip scheme
        const after_scheme = if (std.mem.startsWith(u8, url, "postgresql://"))
            url[13..]
        else
            url[11..];

        if (after_scheme.len == 0) return error.InvalidUrl;

        // Split on / to get authority and dbname
        const slash = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return error.InvalidUrl;
        const authority = after_scheme[0..slash];
        const dbname = after_scheme[slash + 1 ..];
        if (dbname.len == 0) return error.InvalidUrl;

        // Split authority into userinfo and hostinfo at @
        var user: ?[]const u8 = null;
        var password: ?[]const u8 = null;
        var hostinfo: []const u8 = authority;

        if (std.mem.indexOfScalar(u8, authority, '@')) |at| {
            const userinfo = authority[0..at];
            hostinfo = authority[at + 1 ..];

            // Split userinfo into user:password
            if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
                user = userinfo[0..colon];
                const pw = userinfo[colon + 1 ..];
                password = if (pw.len > 0) pw else null;
            } else {
                user = if (userinfo.len > 0) userinfo else null;
            }
        }

        // Split hostinfo into host:port
        var host: ?[]const u8 = null;
        var port: ?u16 = null;

        if (std.mem.indexOfScalar(u8, hostinfo, ':')) |colon| {
            host = if (colon > 0) hostinfo[0..colon] else null;
            const port_str = hostinfo[colon + 1 ..];
            port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidUrl;
        } else {
            host = if (hostinfo.len > 0) hostinfo else null;
        }

        return .{
            .scheme = .postgres,
            .user = user,
            .password = password,
            .host = host,
            .port = port,
            .database = dbname,
        };
    }

    /// Write a libpq-compatible connection string into `buf`.
    /// Returns a slice of the written portion, or null if the buffer is too small.
    pub fn toConninfo(self: DatabaseUrl, buf: []u8) ?[]const u8 {
        if (self.scheme != .postgres) return null;

        var pos: usize = 0;

        if (self.host) |h| {
            pos = appendStr(buf, pos, "host=") orelse return null;
            pos = appendStr(buf, pos, h) orelse return null;
            pos = appendStr(buf, pos, " ") orelse return null;
        }
        pos = appendStr(buf, pos, "dbname=") orelse return null;
        pos = appendStr(buf, pos, self.database) orelse return null;
        if (self.user) |u| {
            pos = appendStr(buf, pos, " user=") orelse return null;
            pos = appendStr(buf, pos, u) orelse return null;
        }
        if (self.password) |p| {
            pos = appendStr(buf, pos, " password=") orelse return null;
            pos = appendStr(buf, pos, p) orelse return null;
        }
        if (self.port) |prt| {
            pos = appendStr(buf, pos, " port=") orelse return null;
            var num_buf: [6]u8 = undefined;
            const num_str = formatU16(prt, &num_buf);
            pos = appendStr(buf, pos, num_str) orelse return null;
        }

        return buf[0..pos];
    }

    fn appendStr(buf: []u8, pos: usize, s: []const u8) ?usize {
        if (pos + s.len > buf.len) return null;
        @memcpy(buf[pos..][0..s.len], s);
        return pos + s.len;
    }

    fn formatU16(val: u16, buf: *[6]u8) []const u8 {
        var v = val;
        var i: usize = buf.len;
        if (v == 0) {
            i -= 1;
            buf[i] = '0';
            return buf[i..];
        }
        while (v > 0) {
            i -= 1;
            buf[i] = @intCast('0' + (v % 10));
            v /= 10;
        }
        return buf[i..];
    }
};

// ── mergeWithEnv ─────────────────────────────────────────────────────

/// Merge a comptime-known config struct with runtime `.env` overrides.
///
/// For each field in `T`, looks up the corresponding env var
/// (field name converted from `snake_case` to `UPPER_SNAKE_CASE`).
/// If found, parses the value into the field's type. If not found,
/// the original value from `base` is kept.
///
/// Supported field types: `[]const u8`, `u16`, `u32`, `u64`, `i16`, `i32`, `i64`,
/// `bool`, and enums with a `fromString` method.
/// Nested structs are skipped.
pub fn mergeWithEnv(comptime T: type, base: T, env: *const Env) T {
    var result = base;
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields) |field| {
        const env_name = comptime snakeToCapsSnake(field.name);
        if (env.get(env_name)) |val| {
            @field(result, field.name) = parseField(field.type, val) orelse @field(base, field.name);
        }
    }
    return result;
}

fn parseField(comptime T: type, val: []const u8) ?T {
    const info = @typeInfo(T);

    // []const u8 — string passthrough
    if (T == []const u8) return val;

    // Integers
    if (info == .int or info == .comptime_int) {
        return std.fmt.parseInt(T, val, 10) catch null;
    }

    // Bool
    if (T == bool) {
        if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "yes"))
            return true;
        if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "no"))
            return false;
        return null;
    }

    // Enums with fromString
    if (info == .@"enum") {
        if (@hasDecl(T, "fromString")) {
            return T.fromString(val);
        }
        return std.meta.stringToEnum(T, val);
    }

    return null;
}

/// Comptime: convert `snake_case` field name to `UPPER_SNAKE_CASE` env var name.
fn snakeToCapsSnake(comptime name: []const u8) []const u8 {
    return comptime blk: {
        var buf: [name.len]u8 = undefined;
        for (name, 0..) |ch, i| {
            buf[i] = std.ascii.toUpper(ch);
        }
        const final = buf;
        break :blk &final;
    };
}

// ── configInit ───────────────────────────────────────────────────────

/// One-call convenience: load `.env`, merge with comptime config, return both.
///
/// Combines `Env.init` + `mergeWithEnv` into a single call so callers don't
/// need to import both modules separately.
///
/// ```zig
/// const result = try zzz.configInit(@TypeOf(app_config.config), app_config.config, allocator, .{});
/// defer result.env.deinit();
/// const config = result.config;
/// ```
pub fn configInit(comptime T: type, comptime base: T, allocator: std.mem.Allocator, env_options: Env.Options) !struct { config: T, env: Env } {
    var env = try Env.init(allocator, env_options);
    return .{ .config = mergeWithEnv(T, base, &env), .env = env };
}

// ── Tests ────────────────────────────────────────────────────────────

test "Environment.fromString valid values" {
    try std.testing.expectEqual(Environment.dev, Environment.fromString("dev").?);
    try std.testing.expectEqual(Environment.dev, Environment.fromString("development").?);
    try std.testing.expectEqual(Environment.prod, Environment.fromString("prod").?);
    try std.testing.expectEqual(Environment.prod, Environment.fromString("production").?);
    try std.testing.expectEqual(Environment.staging, Environment.fromString("staging").?);
    try std.testing.expectEqual(Environment.testing, Environment.fromString("test").?);
    try std.testing.expectEqual(Environment.testing, Environment.fromString("testing").?);
}

test "Environment.fromString invalid returns null" {
    try std.testing.expect(Environment.fromString("bogus") == null);
    try std.testing.expect(Environment.fromString("") == null);
}

test "Environment.toString roundtrip" {
    try std.testing.expectEqualStrings("dev", Environment.dev.toString());
    try std.testing.expectEqualStrings("prod", Environment.prod.toString());
    try std.testing.expectEqualStrings("staging", Environment.staging.toString());
    try std.testing.expectEqualStrings("testing", Environment.testing.toString());
}

test "DatabaseUrl parse postgres full URL" {
    const db = try DatabaseUrl.parse("postgres://alice:s3cret@db.example.com:5433/myapp");
    try std.testing.expectEqual(DatabaseUrl.Scheme.postgres, db.scheme);
    try std.testing.expectEqualStrings("alice", db.user.?);
    try std.testing.expectEqualStrings("s3cret", db.password.?);
    try std.testing.expectEqualStrings("db.example.com", db.host.?);
    try std.testing.expectEqual(@as(u16, 5433), db.port.?);
    try std.testing.expectEqualStrings("myapp", db.database);
}

test "DatabaseUrl parse postgres no password, default port" {
    const db = try DatabaseUrl.parse("postgres://deploy@localhost/prod_db");
    try std.testing.expectEqualStrings("deploy", db.user.?);
    try std.testing.expect(db.password == null);
    try std.testing.expectEqualStrings("localhost", db.host.?);
    try std.testing.expect(db.port == null);
    try std.testing.expectEqualStrings("prod_db", db.database);
}

test "DatabaseUrl parse postgresql:// scheme" {
    const db = try DatabaseUrl.parse("postgresql://user:pw@host:5432/db");
    try std.testing.expectEqual(DatabaseUrl.Scheme.postgres, db.scheme);
    try std.testing.expectEqualStrings("user", db.user.?);
    try std.testing.expectEqualStrings("host", db.host.?);
    try std.testing.expectEqual(@as(u16, 5432), db.port.?);
}

test "DatabaseUrl parse sqlite: prefix" {
    const db = try DatabaseUrl.parse("sqlite:data/app.db");
    try std.testing.expectEqual(DatabaseUrl.Scheme.sqlite, db.scheme);
    try std.testing.expectEqualStrings("data/app.db", db.database);
}

test "DatabaseUrl parse bare filename as sqlite" {
    const db = try DatabaseUrl.parse("my_app.db");
    try std.testing.expectEqual(DatabaseUrl.Scheme.sqlite, db.scheme);
    try std.testing.expectEqualStrings("my_app.db", db.database);
}

test "DatabaseUrl parse invalid empty" {
    try std.testing.expectError(error.InvalidUrl, DatabaseUrl.parse(""));
}

test "DatabaseUrl parse invalid postgres missing db" {
    try std.testing.expectError(error.InvalidUrl, DatabaseUrl.parse("postgres://user@host/"));
}

test "DatabaseUrl toConninfo" {
    const db = try DatabaseUrl.parse("postgres://alice:s3cret@db.host:5433/myapp");
    var buf: [256]u8 = undefined;
    const conninfo = db.toConninfo(&buf).?;
    try std.testing.expectEqualStrings("host=db.host dbname=myapp user=alice password=s3cret port=5433", conninfo);
}

test "DatabaseUrl toConninfo minimal" {
    const db = try DatabaseUrl.parse("postgres://user@localhost/testdb");
    var buf: [256]u8 = undefined;
    const conninfo = db.toConninfo(&buf).?;
    try std.testing.expectEqualStrings("host=localhost dbname=testdb user=user", conninfo);
}

test "DatabaseUrl toConninfo returns null for sqlite" {
    const db = try DatabaseUrl.parse("sqlite:test.db");
    var buf: [64]u8 = undefined;
    try std.testing.expect(db.toConninfo(&buf) == null);
}

test "snakeToCapsSnake conversion" {
    try std.testing.expectEqualStrings("HOST", snakeToCapsSnake("host"));
    try std.testing.expectEqualStrings("SECRET_KEY_BASE", snakeToCapsSnake("secret_key_base"));
    try std.testing.expectEqualStrings("DATABASE_URL", snakeToCapsSnake("database_url"));
    try std.testing.expectEqualStrings("PORT", snakeToCapsSnake("port"));
}

test "mergeWithEnv overrides matching fields" {
    const allocator = std.testing.allocator;
    var env = Env{ .allocator = allocator };
    defer env.deinit();
    env.parseContent("PORT=7777\nHOST=0.0.0.0\nSHOW_ERRORS=true");

    const TestConfig = struct {
        host: []const u8,
        port: u16,
        show_errors: bool,
        untouched: []const u8,
    };

    const base = TestConfig{
        .host = "127.0.0.1",
        .port = 9000,
        .show_errors = false,
        .untouched = "original",
    };

    const merged = mergeWithEnv(TestConfig, base, &env);
    try std.testing.expectEqualStrings("0.0.0.0", merged.host);
    try std.testing.expectEqual(@as(u16, 7777), merged.port);
    try std.testing.expect(merged.show_errors == true);
    try std.testing.expectEqualStrings("original", merged.untouched);
}

test "mergeWithEnv leaves fields unchanged when no env var" {
    const allocator = std.testing.allocator;
    var env = Env{ .allocator = allocator };
    defer env.deinit();
    // Empty env — no overrides
    env.parseContent("");

    const Cfg = struct {
        port: u16,
        host: []const u8,
    };
    const base = Cfg{ .port = 4000, .host = "localhost" };
    const merged = mergeWithEnv(Cfg, base, &env);
    try std.testing.expectEqual(@as(u16, 4000), merged.port);
    try std.testing.expectEqualStrings("localhost", merged.host);
}

test "configInit combines env loading and merge" {
    const allocator = std.testing.allocator;

    const Cfg = struct {
        host: []const u8,
        port: u16,
    };
    const base = Cfg{ .host = "127.0.0.1", .port = 4000 };

    // Use path=null so no file I/O, system_env=false so no getenv
    var result = try configInit(Cfg, base, allocator, .{ .path = null, .system_env = false });
    defer result.env.deinit();

    // With no env vars, config should equal base
    try std.testing.expectEqualStrings("127.0.0.1", result.config.host);
    try std.testing.expectEqual(@as(u16, 4000), result.config.port);
}

test "mergeWithEnv with enum field" {
    const allocator = std.testing.allocator;
    var env = Env{ .allocator = allocator };
    defer env.deinit();
    env.parseContent("LOG_LEVEL=warn");

    const LogLevel = enum { debug, info, warn, err };
    const Cfg = struct {
        log_level: LogLevel,
    };
    const base = Cfg{ .log_level = .debug };
    const merged = mergeWithEnv(Cfg, base, &env);
    try std.testing.expectEqual(LogLevel.warn, merged.log_level);
}
