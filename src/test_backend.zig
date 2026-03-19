//! Test root for backend module — BoundedQueue, backend selection, request handler.
//! Compiled as an independent test binary for parallel execution.

const std = @import("std");
const testing = std.testing;

// Re-export for refAllDecls
pub const zzz_backend = @import("core/backends/zzz.zig");

fn sleepMs(ms: u32) void {
    const ts: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast(@as(u64, ms % 1000) * 1_000_000),
    };
    _ = std.c.nanosleep(&ts, null);
}

// ── BoundedQueue tests ──────────────────────────────────────────────

const IntQueue = zzz_backend.BoundedQueue(u32);

test "BoundedQueue: basic push and pop" {
    var q = try IntQueue.init(testing.allocator, 4);
    defer q.deinit(testing.allocator);

    try testing.expect(q.push(1));
    try testing.expect(q.push(2));
    try testing.expect(q.push(3));

    try testing.expectEqual(@as(u32, 1), q.pop().?);
    try testing.expectEqual(@as(u32, 2), q.pop().?);
    try testing.expectEqual(@as(u32, 3), q.pop().?);
}

test "BoundedQueue: wraps around correctly" {
    var q = try IntQueue.init(testing.allocator, 3);
    defer q.deinit(testing.allocator);

    // Fill and drain to advance head/tail
    try testing.expect(q.push(10));
    try testing.expect(q.push(20));
    try testing.expectEqual(@as(u32, 10), q.pop().?);
    try testing.expectEqual(@as(u32, 20), q.pop().?);

    // Now push past the end to force wrap
    try testing.expect(q.push(30));
    try testing.expect(q.push(40));
    try testing.expect(q.push(50));

    try testing.expectEqual(@as(u32, 30), q.pop().?);
    try testing.expectEqual(@as(u32, 40), q.pop().?);
    try testing.expectEqual(@as(u32, 50), q.pop().?);
}

test "BoundedQueue: shutdown wakes pop waiters" {
    var q = try IntQueue.init(testing.allocator, 4);
    defer q.deinit(testing.allocator);

    // Spawn a thread that will block on pop (empty queue)
    const PopThread = struct {
        fn run(queue: *IntQueue) void {
            // Should return null after shutdown
            const val = queue.pop();
            std.debug.assert(val == null);
        }
    };

    const t = try std.Thread.spawn(.{}, PopThread.run, .{&q});

    // Give the thread time to start and block
    sleepMs(20);

    // Signal shutdown
    q.shutdown();

    // Thread should exit cleanly
    t.join();
}

test "BoundedQueue: shutdown wakes push waiters" {
    var q = try IntQueue.init(testing.allocator, 1);
    defer q.deinit(testing.allocator);

    // Fill the queue
    try testing.expect(q.push(42));

    // Spawn a thread that will block on push (full queue)
    const PushThread = struct {
        fn run(queue: *IntQueue) void {
            // Should return false after shutdown
            const ok = queue.push(99);
            std.debug.assert(!ok);
        }
    };

    const t = try std.Thread.spawn(.{}, PushThread.run, .{&q});

    // Give the thread time to start and block
    sleepMs(20);

    // Signal shutdown
    q.shutdown();

    // Thread should exit cleanly
    t.join();
}

test "BoundedQueue: multi-producer multi-consumer" {
    const num_items: u32 = 100;
    const num_producers: usize = 4;
    const num_consumers: usize = 4;
    const items_per_producer: u32 = num_items / num_producers;

    var q = try IntQueue.init(testing.allocator, 16);
    defer q.deinit(testing.allocator);

    var sum = std.atomic.Value(u64).init(0);

    const Producer = struct {
        fn run(queue: *IntQueue, start: u32) void {
            for (0..items_per_producer) |i| {
                if (!queue.push(start + @as(u32, @intCast(i)))) break;
            }
        }
    };

    const Consumer = struct {
        fn run(queue: *IntQueue, total: *std.atomic.Value(u64)) void {
            while (true) {
                const val = queue.pop() orelse break;
                _ = total.fetchAdd(@intCast(val), .monotonic);
            }
        }
    };

    // Start consumers
    var consumers: [num_consumers]std.Thread = undefined;
    for (0..num_consumers) |i| {
        consumers[i] = try std.Thread.spawn(.{}, Consumer.run, .{ &q, &sum });
    }

    // Start producers
    var producers: [num_producers]std.Thread = undefined;
    for (0..num_producers) |i| {
        producers[i] = try std.Thread.spawn(.{}, Producer.run, .{
            &q,
            @as(u32, @intCast(i)) * items_per_producer,
        });
    }

    // Wait for producers to finish
    for (&producers) |*p| p.join();

    // Give consumers time to drain, then shutdown
    sleepMs(50);
    q.shutdown();

    // Wait for consumers
    for (&consumers) |*cc| cc.join();

    // Verify all items were consumed (sum of 0..99 = 4950)
    const expected_sum: u64 = @as(u64, num_items - 1) * num_items / 2;
    try testing.expectEqual(expected_sum, sum.load(.monotonic));
}

// ── Backend selection tests ─────────────────────────────────────────

test "backend module: BackendConfig exists" {
    const BC = zzz_backend.BackendConfig;
    const config: BC = .{};
    try testing.expectEqual(@as(u16, 0), config.pool_size);
    try testing.expectEqual(@as(u32, 1024), config.queue_capacity);
}

// ── libhv backend type verification (comptime) ─────────────────────
// These tests only compile when backend=libhv (requires libhv C headers).

const backend_options = @import("backend_options");
const is_libhv = std.mem.eql(u8, backend_options.backend, "libhv");

const libhv_backend = if (is_libhv) @import("core/backends/libhv.zig") else struct {};

test "libhv backend: BackendConfig type exists" {
    if (!is_libhv) return error.SkipZigTest;
    const BC = libhv_backend.BackendConfig;
    const config: BC = .{};
    try testing.expectEqual(@as(u8, 1), config.event_loop_count);
}

test "libhv backend: Timer type exists" {
    if (!is_libhv) return error.SkipZigTest;
    try testing.expect(@sizeOf(libhv_backend.Timer) > 0);
}

test "libhv backend: timer functions are declared" {
    if (!is_libhv) return error.SkipZigTest;
    try testing.expect(@TypeOf(libhv_backend.addTimer) != void);
    try testing.expect(@TypeOf(libhv_backend.removeTimer) != void);
    try testing.expect(@TypeOf(libhv_backend.resetTimer) != void);
}

test "libhv backend: LibhvWriter type exists" {
    if (!is_libhv) return error.SkipZigTest;
    try testing.expect(@sizeOf(libhv_backend.LibhvWriter) > 0);
}

test "libhv backend: PipeReader type exists" {
    if (!is_libhv) return error.SkipZigTest;
    try testing.expect(@sizeOf(libhv_backend.PipeReader) > 0);
}

test "libhv backend: TLS config types exist" {
    // This test works regardless of backend — TlsConfig is always available
    const server_mod = @import("core/server.zig");
    const TlsCfg = server_mod.TlsConfig;
    try testing.expect(@sizeOf(TlsCfg) > 0);
    const cfg: server_mod.Config = .{};
    try testing.expect(cfg.tls == null);
}

// ── Request handler extraction tests ────────────────────────────────

const request_handler_mod = @import("core/request_handler.zig");

test "request handler: exported functions are accessible" {
    // Verify the functions are accessible at comptime (type-check only)
    try testing.expect(@TypeOf(request_handler_mod.sendError) != void);
    try testing.expect(@TypeOf(request_handler_mod.sendResponseWriter) != void);
    try testing.expect(@TypeOf(request_handler_mod.handleRequests) != void);
}

test {
    std.testing.refAllDecls(@This());
}
