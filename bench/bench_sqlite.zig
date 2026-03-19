const std = @import("std");
const zzz_db = @import("zzz_db");

const c = @cImport({
    @cInclude("time.h");
    @cInclude("stdlib.h");
});

// ── Schema ─────────────────────────────────────────────────────────────

const User = struct {
    id: i64,
    name: []const u8,
    email: []const u8,
    inserted_at: i64 = 0,
    updated_at: i64 = 0,

    pub const Meta = zzz_db.Schema.define(@This(), .{
        .table = "users",
        .primary_key = "id",
        .timestamps = true,
    });
};

// ── Helpers ────────────────────────────────────────────────────────────

fn timestamp() i64 {
    return c.time(null);
}

fn clockNs() i128 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i128, ts.tv_sec) * 1_000_000_000 + @as(i128, ts.tv_nsec);
}

fn elapsedMs(start: i128) f64 {
    const elapsed = clockNs() - start;
    return @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;
}

fn printResult(name: []const u8, count: usize, ms: f64) void {
    const ops_per_sec = if (ms > 0) @as(f64, @floatFromInt(count)) / (ms / 1000.0) else 0;
    std.debug.print("  {s:<40} {d:>8} ops  {d:>10.2} ms  ({d:>12.0} ops/sec)\n", .{ name, count, ms, ops_per_sec });
}

fn getEnvInt(name: [*:0]const u8, default: usize) usize {
    const val = c.getenv(name) orelse return default;
    const slice = std.mem.span(val);
    return std.fmt.parseInt(usize, slice, 10) catch default;
}

// ── Benchmarks ─────────────────────────────────────────────────────────

fn benchInsert(repo: *zzz_db.SqliteRepo, allocator: std.mem.Allocator, n: usize) !f64 {
    const start = clockNs();
    for (0..n) |i| {
        var name_buf: [32]u8 = undefined;
        const name_len = std.fmt.bufPrint(&name_buf, "user_{d}", .{i}) catch unreachable;

        var email_buf: [48]u8 = undefined;
        const email_len = std.fmt.bufPrint(&email_buf, "user_{d}@bench.test", .{i}) catch unreachable;

        var user = try repo.insert(User, .{
            .id = 0,
            .name = name_len,
            .email = email_len,
            .inserted_at = timestamp(),
            .updated_at = timestamp(),
        }, allocator);
        zzz_db.freeOne(User, &user, allocator);
    }
    return elapsedMs(start);
}

fn benchInsertBatch(pool: *zzz_db.SqlitePool, n: usize) !f64 {
    var pc = try pool.checkout();
    defer pc.release();

    try pc.conn.exec("BEGIN");
    const start = clockNs();
    for (0..n) |i| {
        var name_buf: [32]u8 = undefined;
        const name_len = std.fmt.bufPrint(&name_buf, "batch_{d}", .{i}) catch unreachable;

        var email_buf: [48]u8 = undefined;
        const email_len = std.fmt.bufPrint(&email_buf, "batch_{d}@bench.test", .{i}) catch unreachable;

        var stmt = try zzz_db.sqlite.ResultSet.query(
            &pc.conn.db,
            "INSERT INTO users (name, email, inserted_at, updated_at) VALUES (?, ?, ?, ?)",
            &.{ name_len, email_len, "0", "0" },
        );
        while (try stmt.next()) {}
        stmt.deinit();
    }
    try pc.conn.exec("COMMIT");
    return elapsedMs(start);
}

fn benchSelectAll(repo: *zzz_db.SqliteRepo, allocator: std.mem.Allocator, iterations: usize) !f64 {
    const q = zzz_db.Query(User).init().limit(100);
    const start = clockNs();
    for (0..iterations) |_| {
        const users = try repo.all(User, q, allocator);
        zzz_db.freeAll(User, users, allocator);
    }
    return elapsedMs(start);
}

fn benchSelectOne(repo: *zzz_db.SqliteRepo, allocator: std.mem.Allocator, iterations: usize) !f64 {
    const start = clockNs();
    for (0..iterations) |_| {
        if (try repo.get(User, 1, allocator)) |*u| {
            var user = u.*;
            zzz_db.freeOne(User, &user, allocator);
        }
    }
    return elapsedMs(start);
}

fn benchSelectWhere(repo: *zzz_db.SqliteRepo, allocator: std.mem.Allocator, iterations: usize) !f64 {
    const q = zzz_db.Query(User).init().where("name", .eq, "user_50").limit(1);
    const start = clockNs();
    for (0..iterations) |_| {
        if (try repo.one(User, q, allocator)) |*u| {
            var user = u.*;
            zzz_db.freeOne(User, &user, allocator);
        }
    }
    return elapsedMs(start);
}

fn benchCount(repo: *zzz_db.SqliteRepo, allocator: std.mem.Allocator, iterations: usize) !f64 {
    const q = zzz_db.Query(User).init();
    const start = clockNs();
    for (0..iterations) |_| {
        _ = try repo.count(User, q, allocator);
    }
    return elapsedMs(start);
}

// ── Main ───────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const allocator = gpa_impl.allocator();

    const insert_n = getEnvInt("BENCH_INSERT_N", 1000);
    const select_n = getEnvInt("BENCH_SELECT_N", 1000);

    std.debug.print("\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("  SQLite Benchmark (zzz_db)\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("  Insert count: {d} | Select iterations: {d}\n", .{ insert_n, select_n });
    std.debug.print("───────────────────────────────────────────────────────────────\n", .{});

    var pool = try zzz_db.SqlitePool.init(.{
        .size = 1,
        .connection = .{
            .database = ":memory:",
            .enable_wal = true,
            .pragmas = &.{
                "PRAGMA journal_mode = WAL",
                "PRAGMA synchronous = OFF",
            },
        },
    });
    defer pool.deinit();

    // Create table + index
    {
        var pc = try pool.checkout();
        defer pc.release();
        try pc.conn.exec(
            "CREATE TABLE users (" ++
                "id INTEGER PRIMARY KEY AUTOINCREMENT, " ++
                "name TEXT NOT NULL, " ++
                "email TEXT NOT NULL, " ++
                "inserted_at BIGINT DEFAULT 0, " ++
                "updated_at BIGINT DEFAULT 0" ++
                ")",
        );
        try pc.conn.exec("CREATE INDEX idx_users_name ON users (name)");
    }

    var repo = zzz_db.SqliteRepo.init(&pool);

    // 1. Individual inserts via Repo
    const t1 = try benchInsert(&repo, allocator, insert_n);
    printResult("INSERT (individual, via Repo)", insert_n, t1);

    // 2. Batched inserts in a transaction
    {
        var pc = try pool.checkout();
        defer pc.release();
        try pc.conn.exec("DELETE FROM users");
    }

    const t2 = try benchInsertBatch(&pool, insert_n);
    printResult("INSERT (batched in transaction)", insert_n, t2);

    // Re-seed for SELECT benchmarks
    {
        var pc = try pool.checkout();
        defer pc.release();
        try pc.conn.exec("DELETE FROM users");
    }
    _ = try benchInsert(&repo, allocator, @min(insert_n, 500));

    // 3. SELECT all (LIMIT 100)
    const t3 = try benchSelectAll(&repo, allocator, select_n);
    printResult("SELECT all (LIMIT 100)", select_n, t3);

    // 4. SELECT by PK
    const t4 = try benchSelectOne(&repo, allocator, select_n);
    printResult("SELECT by PK (Repo.get)", select_n, t4);

    // 5. SELECT WHERE with index
    const t5 = try benchSelectWhere(&repo, allocator, select_n);
    printResult("SELECT WHERE name = ? (indexed)", select_n, t5);

    // 6. COUNT(*)
    const t6 = try benchCount(&repo, allocator, select_n);
    printResult("COUNT(*)", select_n, t6);

    std.debug.print("───────────────────────────────────────────────────────────────\n", .{});
    std.debug.print("  Done.\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════════\n\n", .{});
}
