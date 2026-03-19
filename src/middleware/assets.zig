const std = @import("std");
const Context = @import("context.zig").Context;
const HandlerFn = @import("context.zig").HandlerFn;

/// Configuration for the asset middleware.
pub const AssetConfig = struct {
    /// Path to the asset manifest JSON file.
    manifest_path: []const u8 = "public/assets/assets-manifest.json",
    /// URL prefix for assets (e.g., "/static/assets").
    prefix: []const u8 = "/static/assets",
};

/// Fixed-size asset manifest (up to 64 entries).
pub const AssetManifest = struct {
    const max_entries = 64;

    const Entry = struct {
        key: [128]u8 = undefined,
        key_len: u8 = 0,
        value: [128]u8 = undefined,
        value_len: u8 = 0,
        occupied: bool = false,
    };

    entries: [max_entries]Entry = [_]Entry{.{}} ** max_entries,
    prefix: []const u8 = "/static/assets",
    loaded: bool = false,

    /// Look up a fingerprinted asset path.
    /// Given "app.js", returns "/static/assets/app-abc123.js" or falls back
    /// to "/static/assets/app.js" if not found in manifest.
    pub fn resolve(self: *const AssetManifest, name: []const u8) []const u8 {
        if (name.len > 128) return name;
        for (&self.entries) |*entry| {
            if (entry.occupied and entry.key_len == name.len and
                std.mem.eql(u8, entry.key[0..entry.key_len], name))
            {
                return entry.value[0..entry.value_len];
            }
        }
        // Not found — return the name as-is (caller can prepend prefix)
        return name;
    }

    /// Load manifest from a JSON file on disk.
    /// Expected format: {"app.js": "app-abc123.js", "app.css": "app-abc123.css"}
    pub fn load(self: *AssetManifest, path: []const u8, prefix: []const u8) void {
        self.prefix = prefix;

        const c = std.c;
        var path_buf: [256]u8 = undefined;
        if (path.len >= path_buf.len) return;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        const fd = c.open(@ptrCast(path_buf[0..path.len :0]), .{}, @as(c.mode_t, 0));
        if (fd < 0) return;
        defer _ = c.close(fd);

        var buf: [4096]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            const n = c.read(fd, buf[total..].ptr, buf.len - total);
            if (n <= 0) break;
            total += @intCast(n);
        }
        if (total == 0) return;

        self.parseManifest(buf[0..total], prefix);
        self.loaded = true;
    }

    fn parseManifest(self: *AssetManifest, json: []const u8, prefix: []const u8) void {
        // Simple JSON parser for flat {"key": "value"} objects
        var idx: usize = 0;
        var entry_idx: usize = 0;

        while (idx < json.len and entry_idx < max_entries) {
            // Find next key (after a quote)
            const key_start = std.mem.indexOfPos(u8, json, idx, "\"") orelse break;
            const key_end = std.mem.indexOfPos(u8, json, key_start + 1, "\"") orelse break;
            const key = json[key_start + 1 .. key_end];

            // Find value (after colon and quote)
            const colon = std.mem.indexOfPos(u8, json, key_end + 1, ":") orelse break;
            const val_start = std.mem.indexOfPos(u8, json, colon + 1, "\"") orelse break;
            const val_end = std.mem.indexOfPos(u8, json, val_start + 1, "\"") orelse break;
            const val = json[val_start + 1 .. val_end];

            if (key.len <= 128 and prefix.len + 1 + val.len <= 128) {
                var entry = &self.entries[entry_idx];
                @memcpy(entry.key[0..key.len], key);
                entry.key_len = @intCast(key.len);

                // Build full path: prefix/value
                @memcpy(entry.value[0..prefix.len], prefix);
                entry.value[prefix.len] = '/';
                @memcpy(entry.value[prefix.len + 1 ..][0..val.len], val);
                entry.value_len = @intCast(prefix.len + 1 + val.len);

                entry.occupied = true;
                entry_idx += 1;
            }

            idx = val_end + 1;
        }
    }
};

/// Global asset manifest instance.
var manifest: AssetManifest = .{};

/// Get the global asset manifest.
pub fn getManifest() *AssetManifest {
    return &manifest;
}

/// Resolve an asset name to its fingerprinted URL path.
/// Example: assetPath("app.js") → "/static/assets/app-2b3e914a.js"
pub fn assetPath(name: []const u8) []const u8 {
    return manifest.resolve(name);
}

/// Middleware that loads the asset manifest on first request.
/// Place this in the middleware stack to enable `assetPath()`.
pub fn assets(comptime config: AssetConfig) HandlerFn {
    const S = struct {
        fn handle(ctx: *Context) anyerror!void {
            if (!manifest.loaded) {
                manifest.load(config.manifest_path, config.prefix);
            }
            try ctx.next();
        }
    };
    return &S.handle;
}
