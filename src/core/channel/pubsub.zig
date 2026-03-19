const std = @import("std");
const WebSocket = @import("../websocket/connection.zig").WebSocket;

fn spinLock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) {}
}

/// Thread-safe topic-based PubSub registry.
/// Fixed-size arrays (max 64 topics, 256 subscribers per topic), mutex-protected.
pub const PubSub = struct {
    const max_topics = 64;
    const max_subscribers = 256;

    const TopicEntry = struct {
        name: [128]u8 = undefined,
        name_len: usize = 0,
        subscribers: [max_subscribers]*WebSocket = undefined,
        sub_count: usize = 0,
        active: bool = false,

        fn nameSlice(self: *const TopicEntry) []const u8 {
            return self.name[0..self.name_len];
        }
    };

    var topics: [max_topics]TopicEntry = blk: {
        var t: [max_topics]TopicEntry = undefined;
        for (&t) |*entry| {
            entry.* = .{};
        }
        break :blk t;
    };
    var topic_count: usize = 0;
    var mutex: std.atomic.Mutex = .unlocked;

    fn findTopic(topic: []const u8) ?*TopicEntry {
        for (topics[0..topic_count]) |*entry| {
            if (entry.active and entry.name_len == topic.len and
                std.mem.eql(u8, entry.nameSlice(), topic))
            {
                return entry;
            }
        }
        return null;
    }

    fn findOrCreateTopic(topic: []const u8) ?*TopicEntry {
        if (findTopic(topic)) |entry| return entry;

        if (topic.len > 128) return null;
        if (topic_count >= max_topics) return null;

        const entry = &topics[topic_count];
        entry.active = true;
        entry.name_len = topic.len;
        @memcpy(entry.name[0..topic.len], topic);
        entry.sub_count = 0;
        topic_count += 1;
        return entry;
    }

    /// Subscribe a WebSocket to a topic. Returns true on success.
    pub fn subscribe(topic: []const u8, ws: *WebSocket) bool {
        spinLock(&mutex);
        defer mutex.unlock();

        const entry = findOrCreateTopic(topic) orelse return false;

        // Check if already subscribed
        for (entry.subscribers[0..entry.sub_count]) |sub| {
            if (sub == ws) return true;
        }

        if (entry.sub_count >= max_subscribers) return false;
        entry.subscribers[entry.sub_count] = ws;
        entry.sub_count += 1;
        return true;
    }

    /// Unsubscribe a WebSocket from a topic.
    pub fn unsubscribe(topic: []const u8, ws: *WebSocket) void {
        spinLock(&mutex);
        defer mutex.unlock();

        const entry = findTopic(topic) orelse return;

        for (0..entry.sub_count) |i| {
            if (entry.subscribers[i] == ws) {
                // Swap-remove
                entry.sub_count -= 1;
                if (i < entry.sub_count) {
                    entry.subscribers[i] = entry.subscribers[entry.sub_count];
                }
                return;
            }
        }
    }

    /// Unsubscribe a WebSocket from all topics (call on disconnect).
    pub fn unsubscribeAll(ws: *WebSocket) void {
        spinLock(&mutex);
        defer mutex.unlock();

        for (topics[0..topic_count]) |*entry| {
            if (!entry.active) continue;
            var i: usize = 0;
            while (i < entry.sub_count) {
                if (entry.subscribers[i] == ws) {
                    entry.sub_count -= 1;
                    if (i < entry.sub_count) {
                        entry.subscribers[i] = entry.subscribers[entry.sub_count];
                    }
                } else {
                    i += 1;
                }
            }
        }
    }

    /// Broadcast a message to all subscribers of a topic.
    pub fn broadcast(topic: []const u8, message: []const u8) void {
        // Snapshot subscriber list while holding mutex
        var snapshot: [max_subscribers]*WebSocket = undefined;
        var count: usize = 0;

        {
            spinLock(&mutex);
            defer mutex.unlock();

            const entry = findTopic(topic) orelse return;
            count = entry.sub_count;
            for (0..count) |i| {
                snapshot[i] = entry.subscribers[i];
            }
        }

        // Send outside mutex — each ws.send() uses its own write_mutex
        for (snapshot[0..count]) |ws| {
            ws.send(message);
        }
    }

    /// Send a message to a specific subscriber of a topic.
    /// Verifies the target is actually subscribed before sending.
    pub fn sendTo(topic: []const u8, message: []const u8, target: *WebSocket) void {
        var found = false;
        {
            spinLock(&mutex);
            defer mutex.unlock();
            const entry = findTopic(topic) orelse return;
            for (entry.subscribers[0..entry.sub_count]) |ws| {
                if (ws == target) {
                    found = true;
                    break;
                }
            }
        }
        if (found) target.send(message);
    }

    /// Broadcast a message to all subscribers except the sender.
    pub fn broadcastFrom(topic: []const u8, message: []const u8, sender: *WebSocket) void {
        var snapshot: [max_subscribers]*WebSocket = undefined;
        var count: usize = 0;

        {
            spinLock(&mutex);
            defer mutex.unlock();

            const entry = findTopic(topic) orelse return;
            for (0..entry.sub_count) |i| {
                if (entry.subscribers[i] != sender) {
                    snapshot[count] = entry.subscribers[i];
                    count += 1;
                }
            }
        }

        for (snapshot[0..count]) |ws| {
            ws.send(message);
        }
    }

    /// Get the number of subscribers for a topic.
    pub fn subscriberCount(topic: []const u8) usize {
        spinLock(&mutex);
        defer mutex.unlock();

        const entry = findTopic(topic) orelse return 0;
        return entry.sub_count;
    }

    /// Reset all state (for testing).
    pub fn reset() void {
        spinLock(&mutex);
        defer mutex.unlock();
        for (&topics) |*entry| {
            entry.active = false;
            entry.sub_count = 0;
            entry.name_len = 0;
        }
        topic_count = 0;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Params = @import("../../middleware/context.zig").Params;
const Assigns = @import("../../middleware/context.zig").Assigns;

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

test "PubSub subscribe and broadcast" {
    PubSub.reset();
    var w1: MockWriter = .{};
    var w2: MockWriter = .{};
    var ws1 = makeTestWs(&w1);
    var ws2 = makeTestWs(&w2);

    try testing.expect(PubSub.subscribe("room:lobby", &ws1));
    try testing.expect(PubSub.subscribe("room:lobby", &ws2));
    try testing.expectEqual(@as(usize, 2), PubSub.subscriberCount("room:lobby"));

    PubSub.broadcast("room:lobby", "hello");
    // Both should have received data
    try testing.expect(w1.pos > 0);
    try testing.expect(w2.pos > 0);
}

test "PubSub broadcastFrom excludes sender" {
    PubSub.reset();
    var w1: MockWriter = .{};
    var w2: MockWriter = .{};
    var ws1 = makeTestWs(&w1);
    var ws2 = makeTestWs(&w2);

    _ = PubSub.subscribe("chat", &ws1);
    _ = PubSub.subscribe("chat", &ws2);

    PubSub.broadcastFrom("chat", "msg", &ws1);
    // ws1 (sender) should NOT have received
    try testing.expectEqual(@as(usize, 0), w1.pos);
    // ws2 should have received
    try testing.expect(w2.pos > 0);
}

test "PubSub unsubscribe" {
    PubSub.reset();
    var w1: MockWriter = .{};
    var ws1 = makeTestWs(&w1);

    _ = PubSub.subscribe("topic", &ws1);
    try testing.expectEqual(@as(usize, 1), PubSub.subscriberCount("topic"));

    PubSub.unsubscribe("topic", &ws1);
    try testing.expectEqual(@as(usize, 0), PubSub.subscriberCount("topic"));
}

test "PubSub unsubscribeAll" {
    PubSub.reset();
    var w1: MockWriter = .{};
    var ws1 = makeTestWs(&w1);

    _ = PubSub.subscribe("topic1", &ws1);
    _ = PubSub.subscribe("topic2", &ws1);
    try testing.expectEqual(@as(usize, 1), PubSub.subscriberCount("topic1"));
    try testing.expectEqual(@as(usize, 1), PubSub.subscriberCount("topic2"));

    PubSub.unsubscribeAll(&ws1);
    try testing.expectEqual(@as(usize, 0), PubSub.subscriberCount("topic1"));
    try testing.expectEqual(@as(usize, 0), PubSub.subscriberCount("topic2"));
}

test "PubSub sendTo sends only to target" {
    PubSub.reset();
    var w1: MockWriter = .{};
    var w2: MockWriter = .{};
    var ws1 = makeTestWs(&w1);
    var ws2 = makeTestWs(&w2);

    _ = PubSub.subscribe("room", &ws1);
    _ = PubSub.subscribe("room", &ws2);

    PubSub.sendTo("room", "direct", &ws2);
    // ws1 should NOT have received
    try testing.expectEqual(@as(usize, 0), w1.pos);
    // ws2 should have received
    try testing.expect(w2.pos > 0);
}

test "PubSub sendTo to non-subscriber does nothing" {
    PubSub.reset();
    var w1: MockWriter = .{};
    var w2: MockWriter = .{};
    var ws1 = makeTestWs(&w1);
    var ws2 = makeTestWs(&w2);

    _ = PubSub.subscribe("room", &ws1);
    // ws2 is NOT subscribed

    PubSub.sendTo("room", "direct", &ws2);
    try testing.expectEqual(@as(usize, 0), w1.pos);
    try testing.expectEqual(@as(usize, 0), w2.pos);
}

test "PubSub duplicate subscribe is idempotent" {
    PubSub.reset();
    var w1: MockWriter = .{};
    var ws1 = makeTestWs(&w1);

    _ = PubSub.subscribe("topic", &ws1);
    _ = PubSub.subscribe("topic", &ws1);
    try testing.expectEqual(@as(usize, 1), PubSub.subscriberCount("topic"));
}
