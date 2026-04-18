const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;

fn spinLock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) {}
}

/// Generic in-memory cache with TTL support.
/// Fixed-size, thread-safe, open-addressing hash map.
pub fn Cache(comptime V: type) type {
    return struct {
        const Self = @This();
        const num_slots = 256;

        const Entry = struct {
            key_hash: u64 = 0,
            tag_hash: u64 = 0, // 0 = no tag
            value: V = undefined,
            expires_ns: i128 = 0,
            occupied: bool = false,
        };

        entries: [num_slots]Entry = [_]Entry{.{}} ** num_slots,
        mutex: std.atomic.Mutex = .unlocked,

        /// Look up a value by key. Returns null if missing or expired.
        pub fn get(self: *Self, key: []const u8) ?V {
            spinLock(&self.mutex);
            defer self.mutex.unlock();

            const hash = std.hash.Wyhash.hash(0, key);
            var idx = hash % num_slots;
            var probes: usize = 0;

            while (probes < num_slots) : ({
                idx = (idx + 1) % num_slots;
                probes += 1;
            }) {
                const entry = &self.entries[idx];
                if (!entry.occupied) return null;
                if (entry.key_hash == hash) {
                    // Check TTL
                    if (entry.expires_ns > 0 and getMonotonicNs() >= entry.expires_ns) {
                        entry.occupied = false;
                        return null;
                    }
                    return entry.value;
                }
            }
            return null;
        }

        /// Insert or update a value with a TTL in milliseconds.
        /// If ttl_ms is 0, the entry never expires.
        pub fn put(self: *Self, key: []const u8, value: V, ttl_ms: u32) void {
            self.putWithTag(key, value, ttl_ms, "");
        }

        /// Insert or update with an associated tag. Entries sharing a tag can be
        /// bulk-invalidated via `invalidateTag`. An empty tag is treated as "no tag".
        pub fn putWithTag(self: *Self, key: []const u8, value: V, ttl_ms: u32, tag: []const u8) void {
            spinLock(&self.mutex);
            defer self.mutex.unlock();

            const hash = std.hash.Wyhash.hash(0, key);
            const tag_hash: u64 = if (tag.len == 0) 0 else std.hash.Wyhash.hash(1, tag);
            const expires_ns: i128 = if (ttl_ms > 0)
                getMonotonicNs() + @as(i128, ttl_ms) * std.time.ns_per_ms
            else
                0;

            var idx = hash % num_slots;
            var probes: usize = 0;
            var first_empty: ?usize = null;

            while (probes < num_slots) : ({
                idx = (idx + 1) % num_slots;
                probes += 1;
            }) {
                const entry = &self.entries[idx];
                if (!entry.occupied) {
                    if (first_empty == null) first_empty = idx;
                    break;
                }
                if (entry.key_hash == hash) {
                    // Update existing
                    entry.value = value;
                    entry.expires_ns = expires_ns;
                    entry.tag_hash = tag_hash;
                    return;
                }
                // Check if this entry is expired, reuse its slot
                if (entry.expires_ns > 0 and getMonotonicNs() >= entry.expires_ns) {
                    entry.* = .{
                        .key_hash = hash,
                        .tag_hash = tag_hash,
                        .value = value,
                        .expires_ns = expires_ns,
                        .occupied = true,
                    };
                    return;
                }
                if (first_empty == null and !entry.occupied) first_empty = idx;
            }

            // Insert into first empty slot
            if (first_empty) |slot| {
                self.entries[slot] = .{
                    .key_hash = hash,
                    .tag_hash = tag_hash,
                    .value = value,
                    .expires_ns = expires_ns,
                    .occupied = true,
                };
            }
            // If full, silently drop (consistent with framework's fixed-size philosophy)
        }

        /// Delete a key from the cache.
        pub fn delete(self: *Self, key: []const u8) void {
            spinLock(&self.mutex);
            defer self.mutex.unlock();

            const hash = std.hash.Wyhash.hash(0, key);
            var idx = hash % num_slots;
            var probes: usize = 0;

            while (probes < num_slots) : ({
                idx = (idx + 1) % num_slots;
                probes += 1;
            }) {
                const entry = &self.entries[idx];
                if (!entry.occupied) return;
                if (entry.key_hash == hash) {
                    entry.occupied = false;
                    return;
                }
            }
        }

        /// Invalidate every entry tagged with `tag`. Returns the number cleared.
        pub fn invalidateTag(self: *Self, tag: []const u8) usize {
            if (tag.len == 0) return 0;
            spinLock(&self.mutex);
            defer self.mutex.unlock();
            const tag_hash = std.hash.Wyhash.hash(1, tag);
            var n: usize = 0;
            for (&self.entries) |*entry| {
                if (entry.occupied and entry.tag_hash == tag_hash) {
                    entry.occupied = false;
                    n += 1;
                }
            }
            return n;
        }

        /// Clear all entries.
        pub fn clear(self: *Self) void {
            spinLock(&self.mutex);
            defer self.mutex.unlock();
            self.entries = [_]Entry{.{}} ** num_slots;
        }

        /// Count the number of occupied (non-expired) entries.
        pub fn count(self: *Self) usize {
            spinLock(&self.mutex);
            defer self.mutex.unlock();
            var n: usize = 0;
            const now = getMonotonicNs();
            for (&self.entries) |*entry| {
                if (entry.occupied) {
                    if (entry.expires_ns > 0 and now >= entry.expires_ns) {
                        entry.occupied = false;
                    } else {
                        n += 1;
                    }
                }
            }
            return n;
        }
    };
}

fn getMonotonicNs() i128 {
    if (native_os == .linux) {
        const linux = std.os.linux;
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
        return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    } else {
        const c = std.c;
        var ts: c.timespec = undefined;
        _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
        return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "Cache put and get" {
    var cache: Cache(u32) = .{};
    cache.put("key1", 42, 0);
    try testing.expectEqual(@as(u32, 42), cache.get("key1").?);
}

test "Cache get returns null for missing key" {
    var cache: Cache(u32) = .{};
    try testing.expect(cache.get("missing") == null);
}

test "Cache delete removes entry" {
    var cache: Cache(u32) = .{};
    cache.put("key1", 42, 0);
    cache.delete("key1");
    try testing.expect(cache.get("key1") == null);
}

test "Cache put overwrites existing key" {
    var cache: Cache(u32) = .{};
    cache.put("key1", 42, 0);
    cache.put("key1", 100, 0);
    try testing.expectEqual(@as(u32, 100), cache.get("key1").?);
}

test "Cache clear removes all entries" {
    var cache: Cache(u32) = .{};
    cache.put("a", 1, 0);
    cache.put("b", 2, 0);
    cache.clear();
    try testing.expect(cache.get("a") == null);
    try testing.expect(cache.get("b") == null);
}

test "Cache count returns occupied entries" {
    var cache: Cache(u32) = .{};
    try testing.expectEqual(@as(usize, 0), cache.count());
    cache.put("a", 1, 0);
    cache.put("b", 2, 0);
    try testing.expectEqual(@as(usize, 2), cache.count());
    cache.delete("a");
    try testing.expectEqual(@as(usize, 1), cache.count());
}

test "Cache with slice value type" {
    var cache: Cache([]const u8) = .{};
    cache.put("greeting", "hello world", 0);
    try testing.expectEqualStrings("hello world", cache.get("greeting").?);
}

test "Cache invalidateTag clears entries with matching tag" {
    var cache: Cache(u32) = .{};
    cache.putWithTag("u:1:name", 1, 0, "user:1");
    cache.putWithTag("u:1:email", 2, 0, "user:1");
    cache.putWithTag("u:2:name", 3, 0, "user:2");
    cache.put("untagged", 9, 0);

    try testing.expectEqual(@as(usize, 2), cache.invalidateTag("user:1"));
    try testing.expect(cache.get("u:1:name") == null);
    try testing.expect(cache.get("u:1:email") == null);
    try testing.expectEqual(@as(u32, 3), cache.get("u:2:name").?);
    try testing.expectEqual(@as(u32, 9), cache.get("untagged").?);
}

test "Cache invalidateTag ignores empty tag" {
    var cache: Cache(u32) = .{};
    cache.put("x", 1, 0);
    try testing.expectEqual(@as(usize, 0), cache.invalidateTag(""));
    try testing.expectEqual(@as(u32, 1), cache.get("x").?);
}
