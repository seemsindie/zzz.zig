const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const c = std.c;

const server_mod = @import("../server.zig");
const Server = server_mod.Server;
const Config = server_mod.Config;

/// Backend-specific configuration for the native zzz backend.
pub const BackendConfig = struct {
    /// Number of worker threads. 0 = auto-detect CPU count.
    pool_size: u16 = 0,
    /// Bounded queue capacity for pending connections.
    queue_capacity: u32 = 1024,
};

/// Thread-safe bounded queue for passing connections from acceptor to workers.
/// Uses POSIX pthread mutex + condition variables for efficient blocking.
pub fn BoundedQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,
        head: usize,
        tail: usize,
        count: usize,
        capacity: usize,
        mutex: c.pthread_mutex_t,
        not_empty: c.pthread_cond_t,
        not_full: c.pthread_cond_t,
        closed: bool,

        pub fn init(allocator: Allocator, capacity: usize) !Self {
            const items = try allocator.alloc(T, capacity);
            return .{
                .items = items,
                .head = 0,
                .tail = 0,
                .count = 0,
                .capacity = capacity,
                .mutex = c.PTHREAD_MUTEX_INITIALIZER,
                .not_empty = c.PTHREAD_COND_INITIALIZER,
                .not_full = c.PTHREAD_COND_INITIALIZER,
                .closed = false,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            _ = c.pthread_cond_destroy(&self.not_full);
            _ = c.pthread_cond_destroy(&self.not_empty);
            _ = c.pthread_mutex_destroy(&self.mutex);
            allocator.free(self.items);
        }

        /// Push an item onto the queue. Blocks if full. Returns false if shutdown.
        pub fn push(self: *Self, item: T) bool {
            _ = c.pthread_mutex_lock(&self.mutex);
            defer _ = c.pthread_mutex_unlock(&self.mutex);

            while (self.count == self.capacity and !self.closed) {
                _ = c.pthread_cond_wait(&self.not_full, &self.mutex);
            }
            if (self.closed) return false;

            self.items[self.tail] = item;
            self.tail = (self.tail + 1) % self.capacity;
            self.count += 1;
            _ = c.pthread_cond_signal(&self.not_empty);
            return true;
        }

        /// Pop an item from the queue. Blocks if empty. Returns null if shutdown.
        pub fn pop(self: *Self) ?T {
            _ = c.pthread_mutex_lock(&self.mutex);
            defer _ = c.pthread_mutex_unlock(&self.mutex);

            while (self.count == 0 and !self.closed) {
                _ = c.pthread_cond_wait(&self.not_empty, &self.mutex);
            }
            if (self.count == 0) return null;

            const item = self.items[self.head];
            self.head = (self.head + 1) % self.capacity;
            self.count -= 1;
            _ = c.pthread_cond_signal(&self.not_full);
            return item;
        }

        /// Signal all waiters to wake up for shutdown.
        pub fn shutdown(self: *Self) void {
            _ = c.pthread_mutex_lock(&self.mutex);
            self.closed = true;
            _ = c.pthread_cond_broadcast(&self.not_empty);
            _ = c.pthread_cond_broadcast(&self.not_full);
            _ = c.pthread_mutex_unlock(&self.mutex);
        }
    };
}

const Connection = struct {
    stream: Io.net.Stream,
    io: Io,
};

const ConnectionQueue = BoundedQueue(Connection);

/// Main entry point for the native zzz backend.
/// Uses a bounded queue and a fixed thread pool to serve connections.
pub fn listen(server: *Server, io: Io) !void {
    const config = server.config;

    // Determine pool size
    const pool_size: u16 = if (config.worker_threads == 0) 1 else config.worker_threads;

    const address = try Io.net.IpAddress.parseIp4(config.host, config.port);

    var tcp_server = try address.listen(io, .{
        .reuse_address = true,
        .kernel_backlog = config.kernel_backlog,
    });
    defer tcp_server.deinit(io);

    const scheme = "http";
    std.log.info("Zzz server listening on {s}://{s}:{d} (backend=zzz, workers={d})", .{
        scheme,
        config.host,
        config.port,
        pool_size,
    });

    // Create bounded queue
    var queue = try ConnectionQueue.init(server.allocator, config.max_connections);
    defer queue.deinit(server.allocator);

    // Spawn worker threads
    var workers = try server.allocator.alloc(std.Thread, pool_size);
    defer server.allocator.free(workers);

    for (0..pool_size) |i| {
        workers[i] = try std.Thread.spawn(.{}, workerThread, .{ server, &queue });
    }

    // Accept loop
    while (!server.shutdown_flag.load(.acquire)) {
        var stream = tcp_server.accept(io) catch |err| {
            if (server.shutdown_flag.load(.acquire)) break;
            std.log.warn("accept error: {}", .{err});
            continue;
        };

        // Push onto queue; if queue is full, this blocks (back-pressure)
        if (!queue.push(.{ .stream = stream, .io = io })) {
            // Queue was shut down
            stream.close(io);
            break;
        }
    }

    // Graceful shutdown
    std.log.info("Shutting down, signaling workers...", .{});
    queue.shutdown();

    for (workers) |w| {
        w.join();
    }

    server.drainConnections();
    std.log.info("Server stopped.", .{});
}

fn workerThread(server: *Server, queue: *ConnectionQueue) void {
    while (true) {
        const conn = queue.pop() orelse break; // null = shutdown

        _ = server.active_connections.fetchAdd(1, .release);
        defer _ = server.active_connections.fetchSub(1, .release);

        var stream = conn.stream;
        server.handleConnection(conn.io, &stream);
    }
}
