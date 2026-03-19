const std = @import("std");
const WebSocket = @import("../websocket/connection.zig").WebSocket;
const PubSub = @import("pubsub.zig").PubSub;

fn spinLock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) {}
}

/// Per-connection channel state wrapping a `*WebSocket`.
/// Tracks joined topics (max 16).
pub const Socket = struct {
    ws: *WebSocket,
    active: bool = false,
    joined_topics: [max_joined]JoinedTopic = undefined,
    joined_count: usize = 0,
    /// Token bucket for rate limiting: current number of tokens.
    msg_tokens: u16 = 100,
    /// Timestamp of last token refill (monotonic nanoseconds).
    last_refill_ns: i128 = 0,

    const max_joined = 16;

    pub const JoinedTopic = struct {
        name: [128]u8 = undefined,
        name_len: usize = 0,

        pub fn nameSlice(self: *const JoinedTopic) []const u8 {
            return self.name[0..self.name_len];
        }
    };

    /// Check if this socket has joined a topic.
    pub fn isJoined(self: *const Socket, topic: []const u8) bool {
        for (self.joined_topics[0..self.joined_count]) |*jt| {
            if (jt.name_len == topic.len and std.mem.eql(u8, jt.nameSlice(), topic))
                return true;
        }
        return false;
    }

    /// Track a topic join. Returns true on success.
    pub fn trackJoin(self: *Socket, topic: []const u8) bool {
        if (self.isJoined(topic)) return true;
        if (self.joined_count >= max_joined) return false;
        if (topic.len > 128) return false;

        var jt = &self.joined_topics[self.joined_count];
        jt.name_len = topic.len;
        @memcpy(jt.name[0..topic.len], topic);
        self.joined_count += 1;
        return true;
    }

    /// Track a topic leave.
    pub fn trackLeave(self: *Socket, topic: []const u8) void {
        for (0..self.joined_count) |i| {
            if (self.joined_topics[i].name_len == topic.len and
                std.mem.eql(u8, self.joined_topics[i].nameSlice(), topic))
            {
                self.joined_count -= 1;
                if (i < self.joined_count) {
                    self.joined_topics[i] = self.joined_topics[self.joined_count];
                }
                return;
            }
        }
    }

    /// Try to consume one token from the rate-limit bucket.
    /// Returns true if the message is allowed, false if rate-limited.
    pub fn consumeToken(self: *Socket, refill_rate: u16, max_tokens: u16) bool {
        const now = getMonotonicNs();
        if (self.last_refill_ns == 0) {
            self.last_refill_ns = now;
            self.msg_tokens = max_tokens;
        }

        // Refill tokens based on elapsed time
        const elapsed_ns = now - self.last_refill_ns;
        if (elapsed_ns > 0) {
            const elapsed_s = @as(u64, @intCast(@divTrunc(elapsed_ns, std.time.ns_per_s)));
            const refill: u64 = elapsed_s * @as(u64, refill_rate);
            if (refill > 0) {
                const new_tokens = @min(@as(u64, self.msg_tokens) + refill, @as(u64, max_tokens));
                self.msg_tokens = @intCast(new_tokens);
                self.last_refill_ns = now;
            }
        }

        // Try to consume a token
        if (self.msg_tokens > 0) {
            self.msg_tokens -= 1;
            return true;
        }
        return false;
    }

    // ── Channel messaging ──────────────────────────────────────────────

    /// Push a message to this socket (sends JSON to the underlying WebSocket).
    pub fn push(self: *Socket, topic: []const u8, event: []const u8, payload_json: []const u8) void {
        var buf: [4096]u8 = undefined;
        const msg = formatMessage(&buf, topic, event, payload_json, null) orelse return;
        self.ws.send(msg);
    }

    /// Reply to a message (includes ref for client-side Promise resolution).
    pub fn reply(self: *Socket, topic: []const u8, ref: []const u8, status: []const u8, payload_json: []const u8) void {
        var buf: [4096]u8 = undefined;
        // Build reply payload: {"status":"ok","response":<payload>}
        var payload_buf: [4096]u8 = undefined;
        const reply_payload = std.fmt.bufPrint(&payload_buf,
            \\{{"status":"{s}","response":{s}}}
        , .{ status, payload_json }) catch return;

        const msg = formatMessage(&buf, topic, "phx_reply", reply_payload, ref) orelse return;
        self.ws.send(msg);
    }

    /// Broadcast a message to all subscribers of a topic.
    pub fn broadcast(self: *Socket, topic: []const u8, event: []const u8, payload_json: []const u8) void {
        _ = self;
        var buf: [4096]u8 = undefined;
        const msg = formatMessage(&buf, topic, event, payload_json, null) orelse return;
        PubSub.broadcast(topic, msg);
    }

    /// Send a formatted channel message to a specific WebSocket subscriber of a topic.
    pub fn pushTo(_: *Socket, topic: []const u8, event: []const u8, target: *WebSocket, payload_json: []const u8) void {
        var buf: [4096]u8 = undefined;
        const msg = formatMessage(&buf, topic, event, payload_json, null) orelse return;
        PubSub.sendTo(topic, msg, target);
    }

    /// Broadcast to all subscribers except this socket.
    pub fn broadcastFrom(self: *Socket, topic: []const u8, event: []const u8, payload_json: []const u8) void {
        var buf: [4096]u8 = undefined;
        const msg = formatMessage(&buf, topic, event, payload_json, null) orelse return;
        PubSub.broadcastFrom(topic, msg, self.ws);
    }

    // ── Delegate to underlying WebSocket ───────────────────────────────

    /// Get a path parameter by name.
    pub fn param(self: *const Socket, name: []const u8) ?[]const u8 {
        return self.ws.param(name);
    }

    /// Get an assign value by key.
    pub fn getAssign(self: *const Socket, key: []const u8) ?[]const u8 {
        return self.ws.getAssign(key);
    }

    // ── JSON formatting ────────────────────────────────────────────────

    fn formatMessage(buf: []u8, topic: []const u8, event: []const u8, payload_json: []const u8, ref: ?[]const u8) ?[]const u8 {
        if (ref) |r| {
            return std.fmt.bufPrint(buf,
                \\{{"topic":"{s}","event":"{s}","payload":{s},"ref":"{s}"}}
            , .{ topic, event, payload_json, r }) catch null;
        } else {
            return std.fmt.bufPrint(buf,
                \\{{"topic":"{s}","event":"{s}","payload":{s},"ref":null}}
            , .{ topic, event, payload_json }) catch null;
        }
    }
};

/// Fixed-size socket registry — tracks all active channel sockets.
pub const SocketRegistry = struct {
    const max_sockets = 1024;

    const RegistryEntry = struct {
        socket: Socket = undefined,
        active: bool = false,
    };

    var sockets: [max_sockets]RegistryEntry = blk: {
        @setEvalBranchQuota(10_000);
        var s: [max_sockets]RegistryEntry = undefined;
        for (&s) |*entry| {
            entry.* = .{};
        }
        break :blk s;
    };
    var mutex: std.atomic.Mutex = .unlocked;

    /// Register a WebSocket and return a pointer to its Socket.
    pub fn register(ws: *WebSocket) ?*Socket {
        spinLock(&mutex);
        defer mutex.unlock();

        for (&sockets) |*entry| {
            if (!entry.active) {
                entry.active = true;
                entry.socket = .{
                    .ws = ws,
                    .active = true,
                    .joined_count = 0,
                };
                return &entry.socket;
            }
        }
        return null;
    }

    /// Unregister a WebSocket's Socket.
    pub fn unregister(ws: *WebSocket) void {
        spinLock(&mutex);
        defer mutex.unlock();

        for (&sockets) |*entry| {
            if (entry.active and entry.socket.ws == ws) {
                entry.active = false;
                entry.socket.active = false;
                return;
            }
        }
    }

    /// Find the Socket for a given WebSocket.
    pub fn find(ws: *WebSocket) ?*Socket {
        spinLock(&mutex);
        defer mutex.unlock();

        for (&sockets) |*entry| {
            if (entry.active and entry.socket.ws == ws) {
                return &entry.socket;
            }
        }
        return null;
    }

    /// Close all active channel sockets (sends WebSocket close frame).
    /// Used during graceful shutdown.
    pub fn closeAll() void {
        spinLock(&mutex);
        defer mutex.unlock();
        for (&sockets) |*entry| {
            if (entry.active) {
                entry.socket.ws.close(1001, "server shutdown");
                entry.active = false;
                entry.socket.active = false;
            }
        }
    }

    /// Reset all state (for testing).
    pub fn reset() void {
        spinLock(&mutex);
        defer mutex.unlock();
        for (&sockets) |*entry| {
            entry.active = false;
        }
    }
};

fn getMonotonicNs() i128 {
    const builtin = @import("builtin");
    const native_os = builtin.os.tag;
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
const Params = @import("../../middleware/context.zig").Params;
const Assigns = @import("../../middleware/context.zig").Assigns;
const frame_mod = @import("../websocket/frame.zig");
const Opcode = frame_mod.Opcode;

const MockWriter = struct {
    buf: [4096]u8 = undefined,
    pos: usize = 0,

    pub fn writeAll(self: *MockWriter, data: []const u8) !void {
        if (self.pos + data.len > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    pub fn flush(_: *MockWriter) !void {}
};

const MockReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn takeByte(self: *MockReader) !u8 {
        if (self.pos >= self.data.len) return error.EndOfStream;
        const byte = self.data[self.pos];
        self.pos += 1;
        return byte;
    }

    pub fn readSliceAll(self: *MockReader, buf: []u8) !void {
        if (self.pos + buf.len > self.data.len) return error.EndOfStream;
        @memcpy(buf, self.data[self.pos..][0..buf.len]);
        self.pos += buf.len;
    }
};

const WriterVTable = @import("../websocket/connection.zig").WriterVTable;

fn makeTestWs(writer: *MockWriter) WebSocket {
    const VTable = WriterVTable(MockWriter);
    return .{
        .allocator = testing.allocator,
        .closed = false,
        .params = .{},
        .query = .{},
        .assigns = .{},
        .writer_ctx = @ptrCast(writer),
        .write_fn = &VTable.writeAll,
        .flush_fn = &VTable.flush,
    };
}

test "Socket trackJoin and isJoined" {
    var w: MockWriter = .{};
    var ws = makeTestWs(&w);
    var sock: Socket = .{ .ws = &ws, .active = true };

    try testing.expect(!sock.isJoined("room:lobby"));
    try testing.expect(sock.trackJoin("room:lobby"));
    try testing.expect(sock.isJoined("room:lobby"));
    try testing.expectEqual(@as(usize, 1), sock.joined_count);
}

test "Socket trackLeave" {
    var w: MockWriter = .{};
    var ws = makeTestWs(&w);
    var sock: Socket = .{ .ws = &ws, .active = true };

    _ = sock.trackJoin("room:lobby");
    try testing.expect(sock.isJoined("room:lobby"));

    sock.trackLeave("room:lobby");
    try testing.expect(!sock.isJoined("room:lobby"));
    try testing.expectEqual(@as(usize, 0), sock.joined_count);
}

test "Socket push formats JSON correctly" {
    var w: MockWriter = .{};
    var ws = makeTestWs(&w);
    var sock: Socket = .{ .ws = &ws, .active = true };

    sock.push("room:lobby", "new_msg", "{\"body\":\"hello\"}");

    // Read back the frame
    var reader: MockReader = .{ .data = w.buf[0..w.pos] };
    const frame = try frame_mod.readFrame(testing.allocator, &reader);
    defer testing.allocator.free(@constCast(frame.payload));

    try testing.expectEqual(Opcode.text, frame.opcode);
    // Verify it's valid JSON with the expected fields
    try testing.expect(std.mem.indexOf(u8, frame.payload, "\"topic\":\"room:lobby\"") != null);
    try testing.expect(std.mem.indexOf(u8, frame.payload, "\"event\":\"new_msg\"") != null);
    try testing.expect(std.mem.indexOf(u8, frame.payload, "\"payload\":{\"body\":\"hello\"}") != null);
    try testing.expect(std.mem.indexOf(u8, frame.payload, "\"ref\":null") != null);
}

test "Socket pushTo sends formatted JSON to specific target" {
    PubSub.reset();
    var w1: MockWriter = .{};
    var w2: MockWriter = .{};
    var ws1 = makeTestWs(&w1);
    var ws2 = makeTestWs(&w2);
    var sock: Socket = .{ .ws = &ws1, .active = true };

    _ = PubSub.subscribe("room:lobby", &ws1);
    _ = PubSub.subscribe("room:lobby", &ws2);

    sock.pushTo("room:lobby", "whisper", &ws2, "{\"body\":\"secret\"}");

    // ws1 should NOT have received
    try testing.expectEqual(@as(usize, 0), w1.pos);
    // ws2 should have received a formatted JSON message
    try testing.expect(w2.pos > 0);

    var reader: MockReader = .{ .data = w2.buf[0..w2.pos] };
    const frame = try frame_mod.readFrame(testing.allocator, &reader);
    defer testing.allocator.free(@constCast(frame.payload));

    try testing.expectEqual(Opcode.text, frame.opcode);
    try testing.expect(std.mem.indexOf(u8, frame.payload, "\"topic\":\"room:lobby\"") != null);
    try testing.expect(std.mem.indexOf(u8, frame.payload, "\"event\":\"whisper\"") != null);
    try testing.expect(std.mem.indexOf(u8, frame.payload, "\"payload\":{\"body\":\"secret\"}") != null);
}

test "Socket reply formats JSON with ref" {
    var w: MockWriter = .{};
    var ws = makeTestWs(&w);
    var sock: Socket = .{ .ws = &ws, .active = true };

    sock.reply("room:lobby", "1", "ok", "{}");

    var reader: MockReader = .{ .data = w.buf[0..w.pos] };
    const frame = try frame_mod.readFrame(testing.allocator, &reader);
    defer testing.allocator.free(@constCast(frame.payload));

    try testing.expect(std.mem.indexOf(u8, frame.payload, "\"event\":\"phx_reply\"") != null);
    try testing.expect(std.mem.indexOf(u8, frame.payload, "\"ref\":\"1\"") != null);
    try testing.expect(std.mem.indexOf(u8, frame.payload, "\"status\":\"ok\"") != null);
}

test "SocketRegistry register and find" {
    SocketRegistry.reset();
    var w: MockWriter = .{};
    var ws = makeTestWs(&w);

    const sock = SocketRegistry.register(&ws);
    try testing.expect(sock != null);
    try testing.expect(sock.?.active);

    const found = SocketRegistry.find(&ws);
    try testing.expect(found != null);
    try testing.expect(found.? == sock.?);
}

test "SocketRegistry unregister" {
    SocketRegistry.reset();
    var w: MockWriter = .{};
    var ws = makeTestWs(&w);

    _ = SocketRegistry.register(&ws);
    SocketRegistry.unregister(&ws);

    const found = SocketRegistry.find(&ws);
    try testing.expect(found == null);
}
