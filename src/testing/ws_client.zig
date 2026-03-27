const std = @import("std");
const Allocator = std.mem.Allocator;
const ChannelDef = @import("../core/channel/channel.zig").ChannelDef;
const JoinResult = @import("../core/channel/channel.zig").JoinResult;
const channel_match = @import("../core/channel/channel.zig");
const Socket = @import("../core/channel/socket.zig").Socket;
const WebSocket = @import("../core/websocket/connection.zig").WebSocket;
const WriterVTable = @import("../core/websocket/connection.zig").WriterVTable;
const frame_mod = @import("../core/websocket/frame.zig");

/// Test client for WebSocket channels. Works at the channel protocol layer
/// rather than raw WebSocket frames — creates a mock Socket and drives
/// channel handlers directly.
///
/// Example:
/// ```
/// var ch = pidgn.testing.TestChannel(&channel_defs).init(std.testing.allocator);
/// defer ch.deinit();
/// ch.setup();
/// const result = ch.join("room:lobby", "{}");
/// try std.testing.expect(result == .ok);
/// ch.push("room:lobby", "new_msg", "{\"body\":\"hi\"}");
/// const msg = ch.expectPush("reply_event");
/// ```
pub fn TestChannel(comptime channel_defs: []const ChannelDef) type {
    return struct {
        const Self = @This();

        pub const SentMessage = struct {
            topic: [128]u8 = undefined,
            topic_len: usize = 0,
            event: [64]u8 = undefined,
            event_len: usize = 0,
            payload: [2048]u8 = undefined,
            payload_len: usize = 0,

            pub fn topicSlice(self: *const SentMessage) []const u8 {
                return self.topic[0..self.topic_len];
            }

            pub fn eventSlice(self: *const SentMessage) []const u8 {
                return self.event[0..self.event_len];
            }

            pub fn payloadSlice(self: *const SentMessage) []const u8 {
                return self.payload[0..self.payload_len];
            }
        };

        const MockWriter = struct {
            buf: [8192]u8 = undefined,
            pos: usize = 0,

            pub fn writeAll(self: *MockWriter, data: []const u8) !void {
                if (self.pos + data.len > self.buf.len) return error.NoSpaceLeft;
                @memcpy(self.buf[self.pos..][0..data.len], data);
                self.pos += data.len;
            }

            pub fn flush(_: *MockWriter) !void {}
        };

        mock_writer: MockWriter,
        ws: WebSocket,
        socket: Socket,
        sent_messages: [64]SentMessage,
        sent_count: usize,
        ready: bool,

        pub fn init(allocator: Allocator) Self {
            return .{
                .mock_writer = .{},
                .ws = .{
                    .allocator = allocator,
                    .closed = false,
                    .params = .{},
                    .query = .{},
                    .assigns = .{},
                    .writer_ctx = undefined,
                    .write_fn = undefined,
                    .flush_fn = undefined,
                },
                .socket = .{
                    .ws = undefined,
                    .active = true,
                },
                .sent_messages = undefined,
                .sent_count = 0,
                .ready = false,
            };
        }

        /// Must be called after init to fix internal pointers.
        /// Separate from init because Zig moves values on return.
        pub fn setup(self: *Self) void {
            const VTable = WriterVTable(MockWriter);
            self.ws.writer_ctx = @ptrCast(&self.mock_writer);
            self.ws.write_fn = &VTable.writeAll;
            self.ws.flush_fn = &VTable.flush;
            self.socket.ws = &self.ws;
            self.ready = true;
        }

        pub fn deinit(_: *Self) void {}

        /// Join a topic with a payload. Returns the join result.
        pub fn join(self: *Self, topic: []const u8, payload: []const u8) JoinResult {
            if (!self.ready) self.setup();
            inline for (channel_defs) |ch| {
                if (channel_match.topicMatchesPattern(ch.topic_pattern, topic)) {
                    const result = ch.join(&self.socket, topic, payload);
                    if (result == .ok) {
                        _ = self.socket.trackJoin(topic);
                    }
                    return result;
                }
            }
            return .@"error";
        }

        /// Leave a topic.
        pub fn leave(self: *Self, topic: []const u8) void {
            if (!self.ready) self.setup();
            inline for (channel_defs) |ch| {
                if (channel_match.topicMatchesPattern(ch.topic_pattern, topic)) {
                    if (ch.leave) |leave_fn| {
                        leave_fn(&self.socket, topic);
                    }
                    break;
                }
            }
            self.socket.trackLeave(topic);
        }

        /// Push a custom event to a topic. The event is routed to the matching
        /// channel handler, which may call `socket.push()` or `socket.reply()`.
        /// After calling this, use `expectPush` or `readSentMessages` to check responses.
        pub fn push(self: *Self, topic: []const u8, event: []const u8, payload: []const u8) void {
            if (!self.ready) self.setup();
            if (!self.socket.isJoined(topic)) return;

            // Clear write buffer to capture new messages
            self.mock_writer.pos = 0;

            inline for (channel_defs) |ch| {
                if (channel_match.topicMatchesPattern(ch.topic_pattern, topic)) {
                    inline for (ch.handlers) |eh| {
                        if (std.mem.eql(u8, eh.event, event)) {
                            eh.handler(&self.socket, topic, event, payload);
                            self.captureSentMessages();
                            return;
                        }
                    }
                    return;
                }
            }
        }

        /// Check if a message was sent with the given event.
        /// Returns the payload if found, null otherwise.
        pub fn expectPush(self: *const Self, event: []const u8) ?[]const u8 {
            for (self.sent_messages[0..self.sent_count]) |*msg| {
                if (std.mem.eql(u8, msg.eventSlice(), event)) {
                    return msg.payloadSlice();
                }
            }
            return null;
        }

        /// Check if a message was broadcast to the given topic with the given event.
        /// Returns the payload if found, null otherwise.
        pub fn expectBroadcast(self: *const Self, topic: []const u8, event: []const u8) ?[]const u8 {
            for (self.sent_messages[0..self.sent_count]) |*msg| {
                if (std.mem.eql(u8, msg.topicSlice(), topic) and
                    std.mem.eql(u8, msg.eventSlice(), event))
                {
                    return msg.payloadSlice();
                }
            }
            return null;
        }

        /// Clear sent messages.
        pub fn resetMessages(self: *Self) void {
            self.sent_count = 0;
            self.mock_writer.pos = 0;
        }

        /// Reset everything (topics, messages).
        pub fn reset(self: *Self) void {
            self.sent_count = 0;
            self.mock_writer.pos = 0;
            self.socket.joined_count = 0;
        }

        /// Parse WebSocket frames from the mock writer buffer into sent_messages.
        fn captureSentMessages(self: *Self) void {
            if (self.mock_writer.pos == 0) return;

            const data = self.mock_writer.buf[0..self.mock_writer.pos];

            // Each WebSocket frame in the buffer is a channel message.
            // Parse frames sequentially.
            var pos: usize = 0;
            while (pos < data.len and self.sent_count < 64) {
                // Read frame header (server frames are unmasked)
                if (pos + 2 > data.len) break;
                const byte1 = data[pos + 1];
                const base_len = byte1 & 0x7F;
                pos += 2;

                var payload_len: usize = 0;
                if (base_len <= 125) {
                    payload_len = base_len;
                } else if (base_len == 126) {
                    if (pos + 2 > data.len) break;
                    payload_len = @as(usize, data[pos]) << 8 | @as(usize, data[pos + 1]);
                    pos += 2;
                } else {
                    // 64-bit length - unlikely in tests
                    break;
                }

                if (pos + payload_len > data.len) break;
                const payload = data[pos .. pos + payload_len];
                pos += payload_len;

                // Parse the JSON channel message
                const channel_mod = @import("../middleware/channel.zig");
                if (channel_mod.parseChannelMessage(payload)) |parsed| {
                    var msg = &self.sent_messages[self.sent_count];
                    const t_len = @min(parsed.topic.len, msg.topic.len);
                    @memcpy(msg.topic[0..t_len], parsed.topic[0..t_len]);
                    msg.topic_len = t_len;

                    const e_len = @min(parsed.event.len, msg.event.len);
                    @memcpy(msg.event[0..e_len], parsed.event[0..e_len]);
                    msg.event_len = e_len;

                    const p_len = @min(parsed.payload.len, msg.payload.len);
                    @memcpy(msg.payload[0..p_len], parsed.payload[0..p_len]);
                    msg.payload_len = p_len;

                    self.sent_count += 1;
                }
            }
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const test_channels: []const ChannelDef = &.{
    .{
        .topic_pattern = "room:*",
        .join = &struct {
            fn handle(_: *Socket, _: []const u8, _: []const u8) JoinResult {
                return .ok;
            }
        }.handle,
        .handlers = &.{
            .{
                .event = "new_msg",
                .handler = &struct {
                    fn handle(socket: *Socket, topic: []const u8, _: []const u8, payload: []const u8) void {
                        // Echo back
                        socket.push(topic, "msg_received", payload);
                    }
                }.handle,
            },
        },
    },
    .{
        .topic_pattern = "restricted",
        .join = &struct {
            fn handle(_: *Socket, _: []const u8, _: []const u8) JoinResult {
                return .@"error";
            }
        }.handle,
    },
};

test "TestChannel join success" {
    var ch = TestChannel(test_channels).init(testing.allocator);
    defer ch.deinit();
    ch.setup();

    const result = ch.join("room:lobby", "{}");
    try testing.expect(result == .ok);
    try testing.expect(ch.socket.isJoined("room:lobby"));
}

test "TestChannel join failure" {
    var ch = TestChannel(test_channels).init(testing.allocator);
    defer ch.deinit();
    ch.setup();

    const result = ch.join("restricted", "{}");
    try testing.expect(result == .@"error");
    try testing.expect(!ch.socket.isJoined("restricted"));
}

test "TestChannel join unknown topic" {
    var ch = TestChannel(test_channels).init(testing.allocator);
    defer ch.deinit();
    ch.setup();

    const result = ch.join("unknown:topic", "{}");
    try testing.expect(result == .@"error");
}

test "TestChannel leave" {
    var ch = TestChannel(test_channels).init(testing.allocator);
    defer ch.deinit();
    ch.setup();

    _ = ch.join("room:lobby", "{}");
    ch.leave("room:lobby");
    try testing.expect(!ch.socket.isJoined("room:lobby"));
}

test "TestChannel push and expectPush" {
    var ch = TestChannel(test_channels).init(testing.allocator);
    defer ch.deinit();
    ch.setup();

    _ = ch.join("room:lobby", "{}");
    ch.push("room:lobby", "new_msg", "{\"body\":\"hello\"}");

    // The handler echoes back as "msg_received"
    const payload = ch.expectPush("msg_received");
    try testing.expect(payload != null);
    try testing.expect(std.mem.indexOf(u8, payload.?, "hello") != null);
}

test "TestChannel push without join is ignored" {
    var ch = TestChannel(test_channels).init(testing.allocator);
    defer ch.deinit();
    ch.setup();

    // Don't join, just push
    ch.push("room:lobby", "new_msg", "{}");
    try testing.expect(ch.expectPush("msg_received") == null);
}

test "TestChannel reset" {
    var ch = TestChannel(test_channels).init(testing.allocator);
    defer ch.deinit();
    ch.setup();

    _ = ch.join("room:lobby", "{}");
    ch.push("room:lobby", "new_msg", "{\"body\":\"hi\"}");
    ch.reset();

    try testing.expect(!ch.socket.isJoined("room:lobby"));
    try testing.expectEqual(@as(usize, 0), ch.sent_count);
}
