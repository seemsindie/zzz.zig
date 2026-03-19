const std = @import("std");
const Context = @import("context.zig").Context;
const HandlerFn = @import("context.zig").HandlerFn;
const Params = @import("context.zig").Params;
const Assigns = @import("context.zig").Assigns;
const Response = @import("../core/http/response.zig").Response;
const WsConnection = @import("../core/websocket/connection.zig");
const WebSocket = WsConnection.WebSocket;
const WsMessage = WsConnection.Message;
const WsHandler = WsConnection.Handler;
const ChannelDef = @import("../core/channel/channel.zig").ChannelDef;
const JoinResult = @import("../core/channel/channel.zig").JoinResult;
const channel_match = @import("../core/channel/channel.zig");
const Socket = @import("../core/channel/socket.zig").Socket;
const SocketRegistry = @import("../core/channel/socket.zig").SocketRegistry;
const PubSub = @import("../core/channel/pubsub.zig").PubSub;
const Presence = @import("../core/channel/presence.zig").Presence;

/// Configuration for the channel middleware.
pub const ChannelConfig = struct {
    channels: []const ChannelDef,
    heartbeat_timeout_s: u32 = 60,
    /// Maximum burst of messages before rate limiting kicks in.
    rate_limit_msgs: u16 = 100,
    /// Token refill rate (messages per second).
    rate_limit_per_s: u16 = 10,
    /// What to do when rate limited.
    rate_limit_action: enum { drop, disconnect } = .drop,
};

/// Create a handler function that upgrades the connection and runs the channel wire protocol.
pub fn channelHandler(comptime config: ChannelConfig) HandlerFn {
    const S = struct {
        fn handle(ctx: *Context) anyerror!void {
            // Validate WebSocket upgrade request
            if (!ctx.request.isWebSocketUpgrade()) {
                ctx.respond(.bad_request, "text/plain; charset=utf-8", "400 Bad Request: Not a WebSocket upgrade request");
                return;
            }

            ctx.response.status = .switching_protocols;

            const ws_upgrade = ctx.allocator.create(Response.WebSocketUpgrade) catch {
                ctx.respond(.internal_server_error, "text/plain; charset=utf-8", "500 Internal Server Error");
                return;
            };
            ws_upgrade.* = .{
                .handler = .{
                    .on_open = &onOpen,
                    .on_message = &onMessage,
                    .on_close = &onClose,
                },
                .params = ctx.params,
                .query = ctx.query,
                .assigns = ctx.assigns,
            };

            ctx.response.ws_handler = ws_upgrade;
        }

        fn onOpen(ws: *WebSocket) void {
            _ = SocketRegistry.register(ws);
        }

        fn onMessage(ws: *WebSocket, msg: WsMessage) void {
            const text = switch (msg) {
                .text => |t| t,
                .binary => return, // channels use text frames only
            };

            // Parse channel message
            const parsed = parseChannelMessage(text) orelse return;

            const socket = SocketRegistry.find(ws) orelse return;

            // Rate limit check (skip for heartbeats)
            if (!std.mem.eql(u8, parsed.event, "heartbeat")) {
                if (!socket.consumeToken(config.rate_limit_per_s, config.rate_limit_msgs)) {
                    if (config.rate_limit_action == .disconnect) {
                        ws.close(1008, "rate limited");
                        return;
                    }
                    // Drop: send error event and skip processing
                    socket.reply(parsed.topic, parsed.ref, "error", "{\"reason\":\"rate_limited\"}");
                    return;
                }
            }

            // Route based on event
            if (std.mem.eql(u8, parsed.event, "heartbeat")) {
                socket.reply(parsed.topic, parsed.ref, "ok", "{}");
                return;
            }

            if (std.mem.eql(u8, parsed.event, "phx_join")) {
                handleJoin(socket, parsed.topic, parsed.payload, parsed.ref);
                return;
            }

            if (std.mem.eql(u8, parsed.event, "phx_leave")) {
                handleLeave(socket, parsed.topic, parsed.ref);
                return;
            }

            // Custom event — must be joined to the topic
            if (!socket.isJoined(parsed.topic)) return;

            // Route to matching channel handler
            inline for (config.channels) |ch| {
                if (channel_match.topicMatchesPattern(ch.topic_pattern, parsed.topic)) {
                    inline for (ch.handlers) |eh| {
                        if (std.mem.eql(u8, eh.event, parsed.event)) {
                            eh.handler(socket, parsed.topic, parsed.event, parsed.payload);
                            return;
                        }
                    }
                    return;
                }
            }
        }

        fn handleJoin(socket: *Socket, topic: []const u8, payload: []const u8, ref: []const u8) void {
            // Find matching channel definition
            inline for (config.channels) |ch| {
                if (channel_match.topicMatchesPattern(ch.topic_pattern, topic)) {
                    const result = ch.join(socket, topic, payload);
                    if (result == .ok) {
                        _ = socket.trackJoin(topic);
                        _ = PubSub.subscribe(topic, socket.ws);
                        socket.reply(topic, ref, "ok", "{}");
                    } else {
                        socket.reply(topic, ref, "error", "{\"reason\":\"join rejected\"}");
                    }
                    return;
                }
            }
            // No matching channel
            socket.reply(topic, ref, "error", "{\"reason\":\"no such channel\"}");
        }

        fn handleLeave(socket: *Socket, topic: []const u8, ref: []const u8) void {
            // Call leave callback if defined
            inline for (config.channels) |ch| {
                if (channel_match.topicMatchesPattern(ch.topic_pattern, topic)) {
                    if (ch.leave) |leave| {
                        leave(socket, topic);
                    }
                    break;
                }
            }

            socket.trackLeave(topic);
            PubSub.unsubscribe(topic, socket.ws);
            Presence.untrack(socket, topic);
            socket.reply(topic, ref, "ok", "{}");
        }

        fn onClose(ws: *WebSocket, _: u16, _: []const u8) void {
            const socket = SocketRegistry.find(ws) orelse return;

            // Call leave on all joined topics
            var i: usize = 0;
            while (i < socket.joined_count) {
                const topic = socket.joined_topics[i].nameSlice();
                inline for (config.channels) |ch| {
                    if (channel_match.topicMatchesPattern(ch.topic_pattern, topic)) {
                        if (ch.leave) |leave| {
                            leave(socket, topic);
                        }
                        break;
                    }
                }
                i += 1;
            }

            PubSub.unsubscribeAll(ws);
            Presence.untrackAll(socket);
            SocketRegistry.unregister(ws);
        }
    };
    return &S.handle;
}

/// Parsed channel message fields.
pub const ChannelMessage = struct {
    topic: []const u8,
    event: []const u8,
    payload: []const u8,
    ref: []const u8,
};

/// Parse a channel wire-format JSON message.
/// Expected format: {"topic":"...","event":"...","payload":{...},"ref":"..."}
pub fn parseChannelMessage(text: []const u8) ?ChannelMessage {
    const topic = extractJsonString(text, "topic") orelse return null;
    const event = extractJsonString(text, "event") orelse return null;
    const payload = extractJsonPayload(text) orelse "{}";
    const ref = extractJsonString(text, "ref") orelse "0";

    return .{
        .topic = topic,
        .event = event,
        .payload = payload,
        .ref = ref,
    };
}

/// Extract a string value from JSON by key. Simple pattern matching for "key":"value".
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Look for "key":"
    var i: usize = 0;
    while (i + key.len + 4 < json.len) : (i += 1) {
        if (json[i] == '"' and
            i + 1 + key.len + 2 < json.len and
            std.mem.eql(u8, json[i + 1 ..][0..key.len], key) and
            json[i + 1 + key.len] == '"' and
            json[i + 1 + key.len + 1] == ':')
        {
            const after_colon = i + 1 + key.len + 2;
            // Skip whitespace
            var j = after_colon;
            while (j < json.len and json[j] == ' ') : (j += 1) {}

            if (j >= json.len) return null;

            // Check for null
            if (j + 4 <= json.len and std.mem.eql(u8, json[j..][0..4], "null")) {
                return null;
            }

            if (json[j] != '"') return null;
            j += 1;
            const start = j;
            while (j < json.len and json[j] != '"') : (j += 1) {
                if (json[j] == '\\') j += 1; // skip escaped chars
            }
            if (j >= json.len) return null;
            return json[start..j];
        }
    }
    return null;
}

/// Extract the "payload" field as a raw JSON substring (including braces).
fn extractJsonPayload(json: []const u8) ?[]const u8 {
    // Look for "payload":
    const needle = "\"payload\":";
    const idx = std.mem.indexOf(u8, json, needle) orelse return null;
    var pos = idx + needle.len;

    // Skip whitespace
    while (pos < json.len and json[pos] == ' ') : (pos += 1) {}

    if (pos >= json.len) return null;

    // Check for null
    if (pos + 4 <= json.len and std.mem.eql(u8, json[pos..][0..4], "null")) {
        return "{}";
    }

    if (json[pos] == '{') {
        // Find matching closing brace (handle nesting)
        var depth: usize = 0;
        var in_string = false;
        var i = pos;
        while (i < json.len) : (i += 1) {
            if (in_string) {
                if (json[i] == '\\') {
                    i += 1;
                } else if (json[i] == '"') {
                    in_string = false;
                }
            } else {
                if (json[i] == '"') {
                    in_string = true;
                } else if (json[i] == '{') {
                    depth += 1;
                } else if (json[i] == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        return json[pos .. i + 1];
                    }
                }
            }
        }
    } else if (json[pos] == '"') {
        // String payload — return as-is with quotes
        var i = pos + 1;
        while (i < json.len) : (i += 1) {
            if (json[i] == '\\') {
                i += 1;
            } else if (json[i] == '"') {
                return json[pos .. i + 1];
            }
        }
    }

    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Request = @import("../core/http/request.zig").Request;
const StatusCode = @import("../core/http/status.zig").StatusCode;

test "channelHandler returns 400 for non-upgrade request" {
    const handler = comptime channelHandler(.{
        .channels = &.{},
    });

    var req: Request = .{ .method = .GET, .path = "/socket" };
    defer req.deinit(testing.allocator);

    var ctx: Context = .{
        .request = &req,
        .response = .{},
        .params = .{},
        .query = .{},
        .assigns = .{},
        .allocator = testing.allocator,
        .next_handler = null,
    };
    defer ctx.response.deinit(testing.allocator);

    try handler(&ctx);
    try testing.expectEqual(StatusCode.bad_request, ctx.response.status);
}

test "channelHandler sets 101 on upgrade request" {
    const handler = comptime channelHandler(.{
        .channels = &.{},
    });

    var req: Request = .{ .method = .GET, .path = "/socket" };
    try req.headers.append(testing.allocator, "Upgrade", "websocket");
    try req.headers.append(testing.allocator, "Connection", "Upgrade");
    try req.headers.append(testing.allocator, "Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==");
    try req.headers.append(testing.allocator, "Sec-WebSocket-Version", "13");
    defer req.deinit(testing.allocator);

    var ctx: Context = .{
        .request = &req,
        .response = .{},
        .params = .{},
        .query = .{},
        .assigns = .{},
        .allocator = testing.allocator,
        .next_handler = null,
    };
    defer {
        if (ctx.response.ws_handler) |ws| {
            testing.allocator.destroy(ws);
        }
        ctx.response.deinit(testing.allocator);
    }

    try handler(&ctx);
    try testing.expectEqual(StatusCode.switching_protocols, ctx.response.status);
    try testing.expect(ctx.response.ws_handler != null);
}

test "parseChannelMessage extracts fields" {
    const msg =
        \\{"topic":"room:lobby","event":"new_msg","payload":{"body":"hello"},"ref":"1"}
    ;
    const parsed = parseChannelMessage(msg);
    try testing.expect(parsed != null);
    try testing.expectEqualStrings("room:lobby", parsed.?.topic);
    try testing.expectEqualStrings("new_msg", parsed.?.event);
    try testing.expectEqualStrings("{\"body\":\"hello\"}", parsed.?.payload);
    try testing.expectEqualStrings("1", parsed.?.ref);
}

test "parseChannelMessage handles null ref" {
    const msg =
        \\{"topic":"room:lobby","event":"heartbeat","payload":{},"ref":null}
    ;
    const parsed = parseChannelMessage(msg);
    try testing.expect(parsed != null);
    try testing.expectEqualStrings("room:lobby", parsed.?.topic);
    try testing.expectEqualStrings("heartbeat", parsed.?.event);
    try testing.expectEqualStrings("{}", parsed.?.payload);
    // ref returns "0" as default when null
    try testing.expectEqualStrings("0", parsed.?.ref);
}

test "parseChannelMessage with empty payload" {
    const msg =
        \\{"topic":"notifications","event":"phx_join","payload":{},"ref":"2"}
    ;
    const parsed = parseChannelMessage(msg);
    try testing.expect(parsed != null);
    try testing.expectEqualStrings("notifications", parsed.?.topic);
    try testing.expectEqualStrings("phx_join", parsed.?.event);
    try testing.expectEqualStrings("{}", parsed.?.payload);
}

const WriterVTable = @import("../core/websocket/connection.zig").WriterVTable;

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

test "Socket consumeToken rate limiting" {
    var w: MockWriter = .{};
    var ws = makeTestWs(&w);
    var sock: Socket = .{ .ws = &ws, .active = true };

    // First 100 tokens should succeed (default bucket)
    var consumed: u32 = 0;
    for (0..100) |_| {
        if (sock.consumeToken(10, 100)) consumed += 1;
    }
    try testing.expectEqual(@as(u32, 100), consumed);

    // 101st should fail (bucket empty)
    try testing.expect(!sock.consumeToken(10, 100));
}
