//! File storage abstraction with a local-disk backend.
//!
//! The `Storage` struct is a runtime-dispatched trait so handlers can accept a
//! single storage value regardless of backend. A `LocalStorage` backend is
//! included here; remote backends (S3, GCS) can be implemented by filling in
//! the same vtable and are out of scope for this module.
//!
//! Paths are rooted at `LocalStorage.root` and traversal (`..`) is rejected
//! so a handler receiving user-controlled keys cannot escape the root.
//!
//! I/O uses POSIX directly, matching the pattern used elsewhere in the
//! framework (e.g. `Context.sendFile`) and avoiding the std.Io churn.
const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const c = std.c;
const Allocator = std.mem.Allocator;

pub const StorageError = error{
    InvalidKey,
    NotFound,
    IoError,
    TooLarge,
    OutOfMemory,
};

pub const Storage = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put: *const fn (ctx: *anyopaque, key: []const u8, data: []const u8) StorageError!void,
        get: *const fn (ctx: *anyopaque, allocator: Allocator, key: []const u8) StorageError![]u8,
        delete: *const fn (ctx: *anyopaque, key: []const u8) StorageError!void,
        exists: *const fn (ctx: *anyopaque, key: []const u8) bool,
        url: *const fn (ctx: *anyopaque, allocator: Allocator, key: []const u8) StorageError![]u8,
    };

    pub fn put(self: Storage, key: []const u8, data: []const u8) StorageError!void {
        return self.vtable.put(self.ctx, key, data);
    }
    pub fn get(self: Storage, allocator: Allocator, key: []const u8) StorageError![]u8 {
        return self.vtable.get(self.ctx, allocator, key);
    }
    pub fn delete(self: Storage, key: []const u8) StorageError!void {
        return self.vtable.delete(self.ctx, key);
    }
    pub fn exists(self: Storage, key: []const u8) bool {
        return self.vtable.exists(self.ctx, key);
    }
    pub fn url(self: Storage, allocator: Allocator, key: []const u8) StorageError![]u8 {
        return self.vtable.url(self.ctx, allocator, key);
    }
};

// ── Local disk backend ─────────────────────────────────────────────────

pub const LocalStorage = struct {
    root: []const u8,
    /// Optional URL prefix returned by `url()`. Useful when a reverse proxy
    /// exposes `root` at a public path like `/uploads/`.
    url_prefix: []const u8 = "",

    const vtable = Storage.VTable{
        .put = &putImpl,
        .get = &getImpl,
        .delete = &deleteImpl,
        .exists = &existsImpl,
        .url = &urlImpl,
    };

    pub fn storage(self: *LocalStorage) Storage {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    fn cast(ctx: *anyopaque) *LocalStorage {
        return @ptrCast(@alignCast(ctx));
    }

    fn putImpl(ctx: *anyopaque, key: []const u8, data: []const u8) StorageError!void {
        const s = cast(ctx);
        if (!isSafeKey(key)) return StorageError.InvalidKey;

        // Ensure the root exists, then any intermediate directories.
        mkdirP(s.root) catch return StorageError.IoError;

        var buf: [1024]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ s.root, key }) catch return StorageError.InvalidKey;

        if (std.mem.lastIndexOfScalar(u8, full, '/')) |slash| {
            if (slash > s.root.len) {
                mkdirP(full[0..slash]) catch return StorageError.IoError;
            }
        }

        const path_z = allocZ(std.heap.page_allocator, full) catch return StorageError.OutOfMemory;
        defer std.heap.page_allocator.free(path_z);

        const fd = c.open(path_z.ptr, .{ .CREAT = true, .TRUNC = true, .ACCMODE = .WRONLY }, @as(c.mode_t, 0o644));
        if (fd < 0) return StorageError.IoError;
        defer _ = c.close(fd);

        var written: usize = 0;
        while (written < data.len) {
            const n = c.write(fd, data[written..].ptr, data.len - written);
            if (n <= 0) return StorageError.IoError;
            written += @intCast(n);
        }
    }

    fn getImpl(ctx: *anyopaque, allocator: Allocator, key: []const u8) StorageError![]u8 {
        const s = cast(ctx);
        if (!isSafeKey(key)) return StorageError.InvalidKey;

        var buf: [1024]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ s.root, key }) catch return StorageError.InvalidKey;

        const path_z = allocZ(std.heap.page_allocator, full) catch return StorageError.OutOfMemory;
        defer std.heap.page_allocator.free(path_z);

        const fd = c.open(path_z.ptr, .{}, @as(c.mode_t, 0));
        if (fd < 0) {
            // Assume missing file. errno would distinguish but we don't need to.
            return StorageError.NotFound;
        }
        defer _ = c.close(fd);

        const size = fileSize(fd) orelse return StorageError.IoError;
        if (size > 100 * 1024 * 1024) return StorageError.TooLarge;

        const out = allocator.alloc(u8, size) catch return StorageError.OutOfMemory;
        var total: usize = 0;
        while (total < size) {
            const n = c.read(fd, out[total..].ptr, out.len - total);
            if (n <= 0) {
                allocator.free(out);
                return StorageError.IoError;
            }
            total += @intCast(n);
        }
        return out;
    }

    fn deleteImpl(ctx: *anyopaque, key: []const u8) StorageError!void {
        const s = cast(ctx);
        if (!isSafeKey(key)) return StorageError.InvalidKey;
        var buf: [1024]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ s.root, key }) catch return StorageError.InvalidKey;
        const path_z = allocZ(std.heap.page_allocator, full) catch return StorageError.OutOfMemory;
        defer std.heap.page_allocator.free(path_z);
        _ = c.unlink(path_z.ptr); // idempotent — ignore errors
    }

    fn existsImpl(ctx: *anyopaque, key: []const u8) bool {
        const s = cast(ctx);
        if (!isSafeKey(key)) return false;
        var buf: [1024]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ s.root, key }) catch return false;
        const path_z = allocZ(std.heap.page_allocator, full) catch return false;
        defer std.heap.page_allocator.free(path_z);
        return c.access(path_z.ptr, 0) == 0;
    }

    fn urlImpl(ctx: *anyopaque, allocator: Allocator, key: []const u8) StorageError![]u8 {
        const s = cast(ctx);
        if (!isSafeKey(key)) return StorageError.InvalidKey;
        const prefix = if (s.url_prefix.len == 0) s.root else s.url_prefix;
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, key }) catch StorageError.OutOfMemory;
    }
};

fn isSafeKey(key: []const u8) bool {
    if (key.len == 0) return false;
    if (key[0] == '/') return false;
    var iter = std.mem.splitScalar(u8, key, '/');
    while (iter.next()) |seg| {
        if (seg.len == 0) return false;
        if (std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

fn allocZ(allocator: Allocator, s: []const u8) ![:0]u8 {
    return allocator.dupeZ(u8, s);
}

/// Create `path` plus any missing parent directories.
fn mkdirP(path: []const u8) !void {
    var buf: [1024:0]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    // Walk the path creating each prefix in turn.
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            const save = buf[i];
            buf[i] = 0;
            _ = c.mkdir(@ptrCast(&buf), @as(c.mode_t, 0o755));
            buf[i] = save;
        }
    }
}

fn fileSize(fd: c_int) ?usize {
    if (native_os == .linux) {
        var statx_buf = std.mem.zeroes(std.os.linux.Statx);
        if (std.os.linux.errno(std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .SIZE = true }, &statx_buf)) != .SUCCESS) return null;
        if (!statx_buf.mask.SIZE) return null;
        return @intCast(statx_buf.size);
    } else {
        var stat_buf: c.Stat = undefined;
        if (c.fstat(fd, &stat_buf) != 0) return null;
        return @intCast(stat_buf.size);
    }
}

fn rmrf(path: []const u8) void {
    // Best-effort recursive delete for tests.
    var path_buf: [1024:0]u8 = undefined;
    if (path.len >= path_buf.len) return;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&path_buf));
    _ = c.rmdir(@ptrCast(&path_buf));
}

// ── Tests ──────────────────────────────────────────────────────────────

test "isSafeKey blocks traversal and absolute paths" {
    try std.testing.expect(isSafeKey("foo.txt"));
    try std.testing.expect(isSafeKey("dir/sub/file.txt"));
    try std.testing.expect(!isSafeKey(""));
    try std.testing.expect(!isSafeKey("/etc/passwd"));
    try std.testing.expect(!isSafeKey("../../etc/passwd"));
    try std.testing.expect(!isSafeKey("a/..//b"));
}

fn tmpRoot() []const u8 {
    return "/tmp/pidgn_storage_test_xy9";
}

fn cleanTmp() void {
    // Delete files and the root dir — good enough since our tests only create
    // one file at a time.
    rmrf("/tmp/pidgn_storage_test_xy9/docs/hello.txt");
    rmrf("/tmp/pidgn_storage_test_xy9/docs");
    rmrf("/tmp/pidgn_storage_test_xy9");
}

test "LocalStorage put/get/delete round-trip" {
    cleanTmp();
    defer cleanTmp();

    var local: LocalStorage = .{ .root = tmpRoot() };
    const s = local.storage();

    try s.put("docs/hello.txt", "hello world");
    try std.testing.expect(s.exists("docs/hello.txt"));

    const got = try s.get(std.testing.allocator, "docs/hello.txt");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hello world", got);

    try s.delete("docs/hello.txt");
    try std.testing.expect(!s.exists("docs/hello.txt"));
}

test "LocalStorage get on missing returns NotFound" {
    cleanTmp();
    defer cleanTmp();

    var local: LocalStorage = .{ .root = tmpRoot() };
    const s = local.storage();
    try std.testing.expectError(StorageError.NotFound, s.get(std.testing.allocator, "does-not-exist"));
}

test "LocalStorage rejects unsafe keys" {
    var local: LocalStorage = .{ .root = tmpRoot() };
    const s = local.storage();
    try std.testing.expectError(StorageError.InvalidKey, s.put("../evil", "x"));
    try std.testing.expect(!s.exists("/etc/passwd"));
}

test "LocalStorage url uses prefix when set" {
    var local: LocalStorage = .{ .root = "/tmp/foo", .url_prefix = "/uploads" };
    const s = local.storage();
    const u = try s.url(std.testing.allocator, "pic.png");
    defer std.testing.allocator.free(u);
    try std.testing.expectEqualStrings("/uploads/pic.png", u);
}
