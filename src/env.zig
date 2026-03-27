const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

/// Environment variable loader with .env file support.
///
/// Parses `.env` files, reads system env vars, provides typed accessors.
/// Precedence (highest to lowest):
///   1. System env vars (C getenv)
///   2. `.env.{environment}` entries
///   3. `.env` entries (base)
pub const Env = struct {
    allocator: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    use_system_env: bool = true,

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    pub const Options = struct {
        /// Path to the base .env file. Set to null to skip file loading.
        path: ?[]const u8 = ".env",
        /// Environment name (e.g. "dev", "prod"). Loads `.env.{environment}` overlay.
        environment: ?[]const u8 = null,
        /// Whether to override loaded entries from system environment variables.
        system_env: bool = true,
    };

    pub const Error = error{MissingRequiredVar};

    /// Initialize the Env, loading .env files and optionally overriding from system env.
    pub fn init(allocator: Allocator, options: Options) !Env {
        var self = Env{
            .allocator = allocator,
        };

        // Load base .env file
        if (options.path) |path| {
            self.loadFile(path);

            // Load environment-specific overlay
            if (options.environment) |env_name| {
                // Build path like ".env.dev"
                const overlay_path = std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, env_name }) catch null;
                if (overlay_path) |op| {
                    defer allocator.free(op);
                    self.loadFile(op);
                }
            }
        }

        // Override from system env
        self.use_system_env = options.system_env;
        if (options.system_env) {
            self.overrideFromSystemEnv();
        }

        return self;
    }

    /// Free all owned key/value strings and the entries list.
    pub fn deinit(self: *Env) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        self.entries.deinit(self.allocator);
    }

    /// Get the value for a key, or null if not found.
    /// Checks loaded entries first, then falls back to system environment
    /// variables (if system_env was enabled at init).
    pub fn get(self: *const Env, key: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return entry.value;
            }
        }
        // Fallback: check system env for keys not in .env file
        if (self.use_system_env) {
            const key_z = self.allocator.allocSentinel(u8, key.len, 0) catch return null;
            defer self.allocator.free(key_z);
            @memcpy(key_z, key);
            const sys_val: ?[*:0]const u8 = std.c.getenv(key_z.ptr);
            if (sys_val) |val_ptr| {
                return std.mem.span(val_ptr);
            }
        }
        return null;
    }

    /// Get the value for a key, or return the default if not found.
    pub fn getDefault(self: *const Env, key: []const u8, default: []const u8) []const u8 {
        return self.get(key) orelse default;
    }

    /// Get the value for a key, or return an error if missing.
    pub fn require(self: *const Env, key: []const u8) Error![]const u8 {
        return self.get(key) orelse error.MissingRequiredVar;
    }

    /// Get an integer value for a key, or return the default if missing or unparseable.
    pub fn getInt(self: *const Env, comptime T: type, key: []const u8, default: T) T {
        const val = self.get(key) orelse return default;
        return std.fmt.parseInt(T, val, 10) catch default;
    }

    /// Get a boolean value for a key, or return the default if missing.
    /// Recognizes: true/True/TRUE/1/yes/Yes/YES as true,
    ///             false/False/FALSE/0/no/No/NO as false.
    pub fn getBool(self: *const Env, key: []const u8, default: bool) bool {
        const val = self.get(key) orelse return default;
        if (std.mem.eql(u8, val, "true") or
            std.mem.eql(u8, val, "True") or
            std.mem.eql(u8, val, "TRUE") or
            std.mem.eql(u8, val, "1") or
            std.mem.eql(u8, val, "yes") or
            std.mem.eql(u8, val, "Yes") or
            std.mem.eql(u8, val, "YES"))
        {
            return true;
        }
        if (std.mem.eql(u8, val, "false") or
            std.mem.eql(u8, val, "False") or
            std.mem.eql(u8, val, "FALSE") or
            std.mem.eql(u8, val, "0") or
            std.mem.eql(u8, val, "no") or
            std.mem.eql(u8, val, "No") or
            std.mem.eql(u8, val, "NO"))
        {
            return false;
        }
        return default;
    }

    /// Returns `"***"` if `key` looks sensitive, otherwise returns `value` unchanged.
    /// A key is considered sensitive if it contains (case-insensitive) any of:
    /// SECRET, PASSWORD, TOKEN, KEY, DATABASE_URL, PRIVATE.
    pub fn maskSensitive(_: *const Env, key: []const u8, value: []const u8) []const u8 {
        const sensitive = [_][]const u8{
            "SECRET",
            "PASSWORD",
            "TOKEN",
            "KEY",
            "DATABASE_URL",
            "PRIVATE",
        };
        for (sensitive) |pattern| {
            if (containsIgnoreCase(key, pattern)) return "***";
        }
        return value;
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len > haystack.len) return false;
        const end = haystack.len - needle.len + 1;
        for (0..end) |i| {
            var match = true;
            for (0..needle.len) |j| {
                if (std.ascii.toUpper(haystack[i + j]) != std.ascii.toUpper(needle[j])) {
                    match = false;
                    break;
                }
            }
            if (match) return true;
        }
        return false;
    }

    // ── Internal ──────────────────────────────────────────────────────────

    /// Load and parse a .env file. Missing file is silently skipped.
    fn loadFile(self: *Env, path: []const u8) void {
        const content = readFileContents(self.allocator, path) orelse return;
        defer self.allocator.free(content);
        self.parseContent(content);
    }

    /// Read entire file contents, capped at 1MB.
    fn readFileContents(allocator: Allocator, path: []const u8) ?[]u8 {
        const path_z = allocator.allocSentinel(u8, path.len, 0) catch return null;
        defer allocator.free(path_z);
        @memcpy(path_z, path);

        const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY });
        if (fd < 0) return null;
        defer _ = std.c.close(fd);

        const max_size = 1024 * 1024;
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(allocator);

        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = std.c.read(fd, &chunk, chunk.len);
            if (n <= 0) break;
            if (list.items.len + @as(usize, @intCast(n)) > max_size) {
                return null;
            }
            list.appendSlice(allocator, chunk[0..@intCast(n)]) catch return null;
        }

        if (list.items.len == 0) {
            return null;
        }

        return list.toOwnedSlice(allocator) catch null;
    }

    /// Parse .env file content and add entries.
    pub fn parseContent(self: *Env, content: []const u8) void {
        var rest = content;
        while (rest.len > 0) {
            // Find end of line
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            var line = if (nl) |pos| rest[0..pos] else rest;
            rest = if (nl) |pos| rest[pos + 1 ..] else &.{};

            // Strip \r for CRLF
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }

            // Trim leading/trailing whitespace
            line = std.mem.trim(u8, line, " \t");

            // Skip empty lines and comments
            if (line.len == 0) continue;
            if (line[0] == '#') continue;

            // Strip "export " prefix
            if (std.mem.startsWith(u8, line, "export ")) {
                line = line[7..];
                line = std.mem.trimStart(u8, line, " \t");
            }

            // Find = separator
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;

            const raw_key = std.mem.trim(u8, line[0..eq], " \t");
            if (raw_key.len == 0) continue;

            var raw_value = if (eq + 1 < line.len) line[eq + 1 ..] else "";
            raw_value = std.mem.trimStart(u8, raw_value, " \t");

            // Parse value (handle quotes, inline comments)
            const value = parseValue(raw_value);

            // Dupe key and value
            const key_owned = self.allocator.dupe(u8, raw_key) catch continue;
            const val_owned = self.allocator.dupe(u8, value) catch {
                self.allocator.free(key_owned);
                continue;
            };

            // Check for duplicate keys — last wins
            var replaced = false;
            for (self.entries.items) |*entry| {
                if (std.mem.eql(u8, entry.key, raw_key)) {
                    self.allocator.free(entry.key);
                    self.allocator.free(entry.value);
                    entry.key = key_owned;
                    entry.value = val_owned;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) {
                self.entries.append(self.allocator, .{
                    .key = key_owned,
                    .value = val_owned,
                }) catch {
                    self.allocator.free(key_owned);
                    self.allocator.free(val_owned);
                };
            }
        }
    }

    /// Parse a raw value, handling quotes and inline comments.
    fn parseValue(raw: []const u8) []const u8 {
        if (raw.len == 0) return "";

        // Double-quoted: strip quotes, preserve content (including # chars)
        if (raw.len >= 2 and raw[0] == '"') {
            if (std.mem.indexOfScalarPos(u8, raw, 1, '"')) |close| {
                return raw[1..close];
            }
            // No closing quote — treat as unquoted
        }

        // Single-quoted: strip quotes, preserve content literally
        if (raw.len >= 2 and raw[0] == '\'') {
            if (std.mem.indexOfScalarPos(u8, raw, 1, '\'')) |close| {
                return raw[1..close];
            }
        }

        // Unquoted: strip trailing inline comment ( #)
        var value = raw;
        if (std.mem.indexOf(u8, value, " #")) |comment_start| {
            value = value[0..comment_start];
        }
        value = std.mem.trimEnd(u8, value, " \t");
        return value;
    }

    /// Override entries from system environment variables.
    fn overrideFromSystemEnv(self: *Env) void {
        for (self.entries.items) |*entry| {
            const key_z = self.allocator.allocSentinel(u8, entry.key.len, 0) catch continue;
            defer self.allocator.free(key_z);
            @memcpy(key_z, entry.key);

            const sys_val: ?[*:0]const u8 = std.c.getenv(key_z.ptr);
            if (sys_val) |val_ptr| {
                const val_owned = self.allocator.dupe(u8, std.mem.span(val_ptr)) catch continue;
                self.allocator.free(entry.value);
                entry.value = val_owned;
            }
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

test "basic KEY=value parsing" {
    const allocator = std.testing.allocator;
    var env = Env{ .allocator = allocator };
    defer env.deinit();
    env.parseContent("FOO=bar\nBAZ=qux");
    try std.testing.expectEqualStrings("bar", env.get("FOO").?);
    try std.testing.expectEqualStrings("qux", env.get("BAZ").?);
}

test "comments and empty lines skipped" {
    const allocator = std.testing.allocator;
    var env = Env{ .allocator = allocator };
    defer env.deinit();
    env.parseContent("# comment\n\nFOO=bar\n# another comment\n");
    try std.testing.expectEqualStrings("bar", env.get("FOO").?);
    try std.testing.expect(env.entries.items.len == 1);
}

test "double-quoted values" {
    const allocator = std.testing.allocator;
    var env = Env{ .allocator = allocator };
    defer env.deinit();
    env.parseContent("MSG=\"hello world\"");
    try std.testing.expectEqualStrings("hello world", env.get("MSG").?);
}

test "single-quoted values" {
    const allocator = std.testing.allocator;
    var env = Env{ .allocator = allocator };
    defer env.deinit();
    env.parseContent("MSG='hello world'");
    try std.testing.expectEqualStrings("hello world", env.get("MSG").?);
}

test "export prefix stripped" {
    const allocator = std.testing.allocator;
    var env = Env{ .allocator = allocator };
    defer env.deinit();
    env.parseContent("export FOO=bar");
    try std.testing.expectEqualStrings("bar", env.get("FOO").?);
}

test "empty value" {
    const allocator = std.testing.allocator;
    var env = Env{ .allocator = allocator };
    defer env.deinit();
    env.parseContent("EMPTY=");
    try std.testing.expectEqualStrings("", env.get("EMPTY").?);
}

test "duplicate keys last wins" {
    const allocator = std.testing.allocator;
    var env = Env{ .allocator = allocator };
    defer env.deinit();
    env.parseContent("KEY=first\nKEY=second");
    try std.testing.expectEqualStrings("second", env.get("KEY").?);
    try std.testing.expect(env.entries.items.len == 1);
}

test "inline comments stripped for unquoted" {
    const allocator = std.testing.allocator;
    var env = Env{ .allocator = allocator };
    defer env.deinit();
    env.parseContent("PORT=8080 # web port");
    try std.testing.expectEqualStrings("8080", env.get("PORT").?);
}

test "inline comments preserved inside quotes" {
    const allocator = std.testing.allocator;
    var env = Env{ .allocator = allocator };
    defer env.deinit();
    env.parseContent("MSG=\"hello # world\"");
    try std.testing.expectEqualStrings("hello # world", env.get("MSG").?);
}

test "CRLF line endings" {
    const allocator = std.testing.allocator;
    var env = Env{ .allocator = allocator };
    defer env.deinit();
    env.parseContent("FOO=bar\r\nBAZ=qux\r\n");
    try std.testing.expectEqualStrings("bar", env.get("FOO").?);
    try std.testing.expectEqualStrings("qux", env.get("BAZ").?);
}

test "whitespace around =" {
    const allocator = std.testing.allocator;
    var env = Env{ .allocator = allocator };
    defer env.deinit();
    env.parseContent("  KEY  =  value  ");
    try std.testing.expectEqualStrings("value", env.get("KEY").?);
}

test "getDefault fallback" {
    const allocator = std.testing.allocator;
    var env = Env{ .allocator = allocator };
    defer env.deinit();
    env.parseContent("HOST=localhost");
    try std.testing.expectEqualStrings("localhost", env.getDefault("HOST", "0.0.0.0"));
    try std.testing.expectEqualStrings("0.0.0.0", env.getDefault("MISSING", "0.0.0.0"));
}

test "require error for missing key" {
    const allocator = std.testing.allocator;
    var env = Env{ .allocator = allocator };
    defer env.deinit();
    env.parseContent("KEY=val");
    try std.testing.expectEqualStrings("val", try env.require("KEY"));
    try std.testing.expectError(error.MissingRequiredVar, env.require("NOPE"));
}

test "getInt parsing and fallback" {
    const allocator = std.testing.allocator;
    var env = Env{ .allocator = allocator };
    defer env.deinit();
    env.parseContent("PORT=3000\nBAD=abc");
    try std.testing.expectEqual(@as(u16, 3000), env.getInt(u16, "PORT", 8080));
    try std.testing.expectEqual(@as(u16, 8080), env.getInt(u16, "BAD", 8080));
    try std.testing.expectEqual(@as(u16, 8080), env.getInt(u16, "MISSING", 8080));
}

test "getBool all variants" {
    const allocator = std.testing.allocator;
    var env = Env{ .allocator = allocator };
    defer env.deinit();
    env.parseContent(
        \\A=true
        \\B=True
        \\C=TRUE
        \\D=1
        \\E=yes
        \\F=Yes
        \\G=YES
        \\H=false
        \\I=False
        \\J=FALSE
        \\K=0
        \\L=no
        \\M=No
        \\N=NO
        \\O=maybe
    );
    try std.testing.expect(env.getBool("A", false) == true);
    try std.testing.expect(env.getBool("B", false) == true);
    try std.testing.expect(env.getBool("C", false) == true);
    try std.testing.expect(env.getBool("D", false) == true);
    try std.testing.expect(env.getBool("E", false) == true);
    try std.testing.expect(env.getBool("F", false) == true);
    try std.testing.expect(env.getBool("G", false) == true);
    try std.testing.expect(env.getBool("H", true) == false);
    try std.testing.expect(env.getBool("I", true) == false);
    try std.testing.expect(env.getBool("J", true) == false);
    try std.testing.expect(env.getBool("K", true) == false);
    try std.testing.expect(env.getBool("L", true) == false);
    try std.testing.expect(env.getBool("M", true) == false);
    try std.testing.expect(env.getBool("N", true) == false);
    // Unrecognized value returns default
    try std.testing.expect(env.getBool("O", true) == true);
    try std.testing.expect(env.getBool("O", false) == false);
    // Missing key returns default
    try std.testing.expect(env.getBool("MISSING", true) == true);
}

test "lines without = skipped" {
    const allocator = std.testing.allocator;
    var env = Env{ .allocator = allocator };
    defer env.deinit();
    env.parseContent("NOEQ\nGOOD=val");
    try std.testing.expect(env.get("NOEQ") == null);
    try std.testing.expectEqualStrings("val", env.get("GOOD").?);
}

test "init with path null loads nothing" {
    const allocator = std.testing.allocator;
    var env = try Env.init(allocator, .{ .path = null });
    defer env.deinit();
    try std.testing.expect(env.entries.items.len == 0);
}

test "init with missing file is not an error" {
    const allocator = std.testing.allocator;
    var env = try Env.init(allocator, .{ .path = "/tmp/pidgn_nonexistent_env_file_test", .system_env = false });
    defer env.deinit();
    try std.testing.expect(env.entries.items.len == 0);
}

test "maskSensitive masks sensitive keys" {
    const allocator = std.testing.allocator;
    var env = Env{ .allocator = allocator };
    defer env.deinit();
    try std.testing.expectEqualStrings("***", env.maskSensitive("SECRET_KEY_BASE", "abc123"));
    try std.testing.expectEqualStrings("***", env.maskSensitive("DB_PASSWORD", "hunter2"));
    try std.testing.expectEqualStrings("***", env.maskSensitive("API_TOKEN", "tok_xxx"));
    try std.testing.expectEqualStrings("***", env.maskSensitive("ENCRYPTION_KEY", "k3y"));
    try std.testing.expectEqualStrings("***", env.maskSensitive("DATABASE_URL", "postgres://..."));
    try std.testing.expectEqualStrings("***", env.maskSensitive("PRIVATE_KEY_PATH", "/etc/ssl/key.pem"));
}

test "maskSensitive case insensitive" {
    const allocator = std.testing.allocator;
    var env = Env{ .allocator = allocator };
    defer env.deinit();
    try std.testing.expectEqualStrings("***", env.maskSensitive("secret_key", "val"));
    try std.testing.expectEqualStrings("***", env.maskSensitive("My_Password", "val"));
    try std.testing.expectEqualStrings("***", env.maskSensitive("auth_token", "val"));
}

test "maskSensitive passes through non-sensitive keys" {
    const allocator = std.testing.allocator;
    var env = Env{ .allocator = allocator };
    defer env.deinit();
    try std.testing.expectEqualStrings("127.0.0.1", env.maskSensitive("HOST", "127.0.0.1"));
    try std.testing.expectEqualStrings("9000", env.maskSensitive("PORT", "9000"));
    try std.testing.expectEqualStrings("debug", env.maskSensitive("LOG_LEVEL", "debug"));
}
