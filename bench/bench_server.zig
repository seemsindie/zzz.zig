const std = @import("std");
const pidgn = @import("pidgn");
const pidgn_db = @import("pidgn_db");

// ── Schema ──────────────────────────────────────────────────────────────

const User = struct {
    id: i64,
    name: []const u8,
    email: []const u8,
    inserted_at: i64 = 0,
    updated_at: i64 = 0,

    pub const Meta = pidgn_db.Schema.define(@This(), .{
        .table = "users",
        .primary_key = "id",
        .timestamps = true,
    });
};

// ── Module-level state ──────────────────────────────────────────────────

var pool: pidgn_db.SqlitePool = undefined;
var repo: pidgn_db.SqliteRepo = undefined;
var counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

// ── Router ──────────────────────────────────────────────────────────────

const App = pidgn.Router.define(.{
    .routes = &.{
        pidgn.Router.get("/plaintext", plaintextHandler),
        pidgn.Router.get("/json", jsonHandler),
        pidgn.Router.get("/users/:id", userHandler),
        pidgn.Router.get("/db", dbReadHandler),
        pidgn.Router.get("/db-insert", dbInsertHandler),
    },
});

// ── Handlers ────────────────────────────────────────────────────────────

fn plaintextHandler(ctx: *pidgn.Context) !void {
    ctx.text(.ok, "Hello, World!");
}

fn jsonHandler(ctx: *pidgn.Context) !void {
    ctx.json(.ok,
        \\{"message":"Hello, World!"}
    );
}

fn userHandler(ctx: *pidgn.Context) !void {
    const id = ctx.param("id") orelse "0";
    ctx.text(.ok, id);
}

fn dbReadHandler(ctx: *pidgn.Context) !void {
    const n = counter.fetchAdd(1, .monotonic);
    const id: i64 = @intCast((n % 500) + 1);

    if (try repo.get(User, id, ctx.allocator)) |*u| {
        var user = u.*;
        defer pidgn_db.freeOne(User, &user, ctx.allocator);

        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{{"id":{d},"name":"{s}","email":"{s}"}}
        , .{ user.id, user.name, user.email }) catch {
            ctx.text(.internal_server_error, "format error");
            return;
        };

        const owned = try ctx.allocator.dupe(u8, body);
        ctx.json(.ok, owned);
        ctx.response.body_owned = true;
    } else {
        ctx.json(.not_found,
            \\{"error":"not found"}
        );
    }
}

fn dbInsertHandler(ctx: *pidgn.Context) !void {
    const n = counter.fetchAdd(1, .monotonic);

    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "bench_{d}", .{n}) catch "bench";

    var email_buf: [48]u8 = undefined;
    const email = std.fmt.bufPrint(&email_buf, "bench_{d}@test", .{n}) catch "bench@test";

    var user = try repo.insert(User, .{
        .id = 0,
        .name = name,
        .email = email,
    }, ctx.allocator);
    defer pidgn_db.freeOne(User, &user, ctx.allocator);

    var buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&buf,
        \\{{"id":{d},"name":"{s}","email":"{s}"}}
    , .{ user.id, user.name, user.email }) catch {
        ctx.text(.internal_server_error, "format error");
        return;
    };

    const owned = try ctx.allocator.dupe(u8, body);
    ctx.json(.ok, owned);
    ctx.response.body_owned = true;
}

// ── Main ────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Initialize SQLite pool
    pool = try pidgn_db.SqlitePool.init(.{
        .size = 4,
        .connection = .{
            .database = "/tmp/pidgn-bench.db",
            .enable_wal = true,
            .pragmas = &.{
                "PRAGMA journal_mode = WAL",
                "PRAGMA synchronous = OFF",
            },
        },
    });

    // Create table + seed data
    {
        var pc = try pool.checkout();
        defer pc.release();
        pc.conn.exec("DROP TABLE IF EXISTS users") catch {};
        try pc.conn.exec(
            "CREATE TABLE IF NOT EXISTS users (" ++
                "id INTEGER PRIMARY KEY AUTOINCREMENT, " ++
                "name TEXT NOT NULL, " ++
                "email TEXT NOT NULL, " ++
                "inserted_at BIGINT DEFAULT 0, " ++
                "updated_at BIGINT DEFAULT 0" ++
                ")",
        );
        try pc.conn.exec("CREATE INDEX IF NOT EXISTS idx_users_name ON users (name)");
    }

    // Seed 500 users in a transaction
    {
        var pc = try pool.checkout();
        defer pc.release();
        try pc.conn.exec("BEGIN");
        for (0..500) |i| {
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "user_{d}", .{i}) catch unreachable;

            var email_buf: [48]u8 = undefined;
            const email = std.fmt.bufPrint(&email_buf, "user_{d}@bench.test", .{i}) catch unreachable;

            var stmt = try pidgn_db.sqlite.ResultSet.query(
                &pc.conn.db,
                "INSERT INTO users (name, email, inserted_at, updated_at) VALUES (?, ?, ?, ?)",
                &.{ name, email, "0", "0" },
            );
            while (try stmt.next()) {}
            stmt.deinit();
        }
        try pc.conn.exec("COMMIT");
    }

    repo = pidgn_db.SqliteRepo.init(&pool);

    std.debug.print("Benchmark server ready on http://127.0.0.1:3000\n", .{});
    std.debug.print("  Endpoints: /plaintext, /json, /users/:id, /db, /db-insert\n", .{});

    var server = pidgn.Server.init(allocator, .{
        .host = "127.0.0.1",
        .port = 3000,
        .keepalive_timeout_ms = 5_000, // shorter for benchmarks
        .read_timeout_ms = 5_000, // faster shutdown detection
    }, App.handler);

    try server.listen(io);
}
