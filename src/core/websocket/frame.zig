const std = @import("std");
const Allocator = std.mem.Allocator;

/// WebSocket frame opcodes per RFC 6455.
pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

/// A decoded WebSocket frame.
pub const Frame = struct {
    fin: bool,
    rsv1: bool = false,
    opcode: Opcode,
    payload: []const u8,
    close_code: ?u16 = null,
};

/// XOR mask/unmask a payload in place. Mask and unmask are the same operation.
pub fn applyMask(payload: []u8, mask: [4]u8) void {
    for (payload, 0..) |*byte, i| {
        byte.* ^= mask[i % 4];
    }
}

/// Read a single WebSocket frame from a reader. Caller owns the returned payload slice.
pub fn readFrame(allocator: Allocator, reader: anytype) !Frame {
    // Read first two header bytes
    const byte0 = try reader.takeByte();
    const byte1 = try reader.takeByte();

    const fin = (byte0 & 0x80) != 0;
    const rsv1 = (byte0 & 0x40) != 0;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(byte0 & 0x0F)));
    const masked = (byte1 & 0x80) != 0;
    const len7: u7 = @truncate(byte1 & 0x7F);

    // Decode payload length
    var payload_len: u64 = len7;
    if (len7 == 126) {
        var len_buf: [2]u8 = undefined;
        try reader.readSliceAll(&len_buf);
        payload_len = std.mem.readInt(u16, &len_buf, .big);
    } else if (len7 == 127) {
        var len_buf: [8]u8 = undefined;
        try reader.readSliceAll(&len_buf);
        payload_len = std.mem.readInt(u64, &len_buf, .big);
    }

    // Sanity check: limit frame size to 16MB
    if (payload_len > 16 * 1024 * 1024) return error.FrameTooLarge;

    // Read mask key if present
    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        try reader.readSliceAll(&mask);
    }

    // Read payload
    const len: usize = @intCast(payload_len);
    const payload = try allocator.alloc(u8, len);
    errdefer allocator.free(payload);

    if (len > 0) {
        try reader.readSliceAll(payload);
        if (masked) {
            applyMask(payload, mask);
        }
    }

    // Parse close code if this is a close frame
    var close_code: ?u16 = null;
    if (opcode == .close and len >= 2) {
        close_code = std.mem.readInt(u16, payload[0..2], .big);
    }

    return .{
        .fin = fin,
        .rsv1 = rsv1,
        .opcode = opcode,
        .payload = payload,
        .close_code = close_code,
    };
}

/// Write an unmasked server frame to a writer.
pub fn writeFrame(writer: anytype, opcode: Opcode, payload: []const u8, fin: bool) !void {
    // First byte: FIN + opcode
    const byte0: u8 = (if (fin) @as(u8, 0x80) else @as(u8, 0x00)) | @as(u8, @intFromEnum(opcode));
    try writer.writeAll(&.{byte0});

    // Second byte: length (server frames are unmasked)
    if (payload.len < 126) {
        try writer.writeAll(&.{@intCast(payload.len)});
    } else if (payload.len <= 0xFFFF) {
        try writer.writeAll(&.{126});
        var len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_buf, @intCast(payload.len), .big);
        try writer.writeAll(&len_buf);
    } else {
        try writer.writeAll(&.{127});
        var len_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_buf, @intCast(payload.len), .big);
        try writer.writeAll(&len_buf);
    }

    // Payload
    if (payload.len > 0) {
        try writer.writeAll(payload);
    }

    try writer.flush();
}

/// Write an unmasked server frame with RSV1 control (for permessage-deflate).
pub fn writeFrameEx(writer: anytype, opcode: Opcode, payload: []const u8, fin: bool, rsv1: bool) !void {
    // First byte: FIN + RSV1 + opcode
    const byte0: u8 = (if (fin) @as(u8, 0x80) else @as(u8, 0x00)) |
        (if (rsv1) @as(u8, 0x40) else @as(u8, 0x00)) |
        @as(u8, @intFromEnum(opcode));
    try writer.writeAll(&.{byte0});

    // Second byte: length (server frames are unmasked)
    if (payload.len < 126) {
        try writer.writeAll(&.{@intCast(payload.len)});
    } else if (payload.len <= 0xFFFF) {
        try writer.writeAll(&.{126});
        var len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_buf, @intCast(payload.len), .big);
        try writer.writeAll(&len_buf);
    } else {
        try writer.writeAll(&.{127});
        var len_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_buf, @intCast(payload.len), .big);
        try writer.writeAll(&len_buf);
    }

    // Payload
    if (payload.len > 0) {
        try writer.writeAll(payload);
    }

    try writer.flush();
}

/// Write a close frame with a status code and optional reason.
pub fn writeCloseFrame(writer: anytype, code: u16, reason: []const u8) !void {
    var buf: [125]u8 = undefined; // Max control frame payload is 125 bytes
    std.mem.writeInt(u16, buf[0..2], code, .big);
    const reason_len = @min(reason.len, 123);
    @memcpy(buf[2..][0..reason_len], reason[0..reason_len]);
    try writeFrame(writer, .close, buf[0 .. 2 + reason_len], true);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// A mock reader backed by a fixed buffer.
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

/// A mock writer that captures output.
const MockWriter = struct {
    buf: [4096]u8 = undefined,
    pos: usize = 0,

    pub fn writeAll(self: *MockWriter, data: []const u8) !void {
        if (self.pos + data.len > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    pub fn flush(_: *MockWriter) !void {}

    pub fn written(self: *const MockWriter) []const u8 {
        return self.buf[0..self.pos];
    }
};

test "applyMask round-trip" {
    const mask = [_]u8{ 0x37, 0xfa, 0x21, 0x3d };
    var data = [_]u8{ 'H', 'e', 'l', 'l', 'o' };
    const original = [_]u8{ 'H', 'e', 'l', 'l', 'o' };

    applyMask(&data, mask);
    // After masking, data should be different
    try testing.expect(!std.mem.eql(u8, &data, &original));

    // Masking again should restore original
    applyMask(&data, mask);
    try testing.expectEqualSlices(u8, &original, &data);
}

test "writeFrame and readFrame round-trip: text" {
    var writer: MockWriter = .{};
    try writeFrame(&writer, .text, "Hello", true);

    var reader: MockReader = .{ .data = writer.written() };
    const frame = try readFrame(testing.allocator, &reader);
    defer testing.allocator.free(@constCast(frame.payload));

    try testing.expect(frame.fin);
    try testing.expectEqual(Opcode.text, frame.opcode);
    try testing.expectEqualStrings("Hello", frame.payload);
    try testing.expect(frame.close_code == null);
}

test "writeFrame and readFrame round-trip: binary" {
    var writer: MockWriter = .{};
    const data = &[_]u8{ 0x00, 0xFF, 0x42, 0x99 };
    try writeFrame(&writer, .binary, data, true);

    var reader: MockReader = .{ .data = writer.written() };
    const frame = try readFrame(testing.allocator, &reader);
    defer testing.allocator.free(@constCast(frame.payload));

    try testing.expect(frame.fin);
    try testing.expectEqual(Opcode.binary, frame.opcode);
    try testing.expectEqualSlices(u8, data, frame.payload);
}

test "writeFrame and readFrame round-trip: empty payload" {
    var writer: MockWriter = .{};
    try writeFrame(&writer, .text, "", true);

    var reader: MockReader = .{ .data = writer.written() };
    const frame = try readFrame(testing.allocator, &reader);
    defer testing.allocator.free(@constCast(frame.payload));

    try testing.expect(frame.fin);
    try testing.expectEqual(Opcode.text, frame.opcode);
    try testing.expectEqualStrings("", frame.payload);
}

test "writeFrame and readFrame: extended 16-bit length" {
    var writer: MockWriter = .{};
    const data = "x" ** 200; // > 125 bytes, uses 16-bit length
    try writeFrame(&writer, .text, data, true);

    var reader: MockReader = .{ .data = writer.written() };
    const frame = try readFrame(testing.allocator, &reader);
    defer testing.allocator.free(@constCast(frame.payload));

    try testing.expect(frame.fin);
    try testing.expectEqual(@as(usize, 200), frame.payload.len);
}

test "readFrame with masked payload" {
    // Build a masked frame manually: text "Hi" with mask [1,2,3,4]
    const mask = [_]u8{ 1, 2, 3, 4 };
    var masked_payload = [_]u8{ 'H' ^ 1, 'i' ^ 2 };
    var frame_bytes: [8]u8 = undefined;
    frame_bytes[0] = 0x81; // FIN + text
    frame_bytes[1] = 0x82; // masked + length 2
    frame_bytes[2] = mask[0];
    frame_bytes[3] = mask[1];
    frame_bytes[4] = mask[2];
    frame_bytes[5] = mask[3];
    frame_bytes[6] = masked_payload[0];
    frame_bytes[7] = masked_payload[1];

    var reader: MockReader = .{ .data = &frame_bytes };
    const frame = try readFrame(testing.allocator, &reader);
    defer testing.allocator.free(@constCast(frame.payload));

    try testing.expectEqualStrings("Hi", frame.payload);
    try testing.expect(frame.fin);
    try testing.expectEqual(Opcode.text, frame.opcode);
}

test "writeCloseFrame" {
    var writer: MockWriter = .{};
    try writeCloseFrame(&writer, 1000, "normal");

    var reader: MockReader = .{ .data = writer.written() };
    const frame = try readFrame(testing.allocator, &reader);
    defer testing.allocator.free(@constCast(frame.payload));

    try testing.expectEqual(Opcode.close, frame.opcode);
    try testing.expect(frame.fin);
    try testing.expectEqual(@as(u16, 1000), frame.close_code.?);
    // Payload after the 2-byte code is the reason
    try testing.expectEqualStrings("normal", frame.payload[2..]);
}

test "ping frame round-trip" {
    var writer: MockWriter = .{};
    try writeFrame(&writer, .ping, "ping!", true);

    var reader: MockReader = .{ .data = writer.written() };
    const frame = try readFrame(testing.allocator, &reader);
    defer testing.allocator.free(@constCast(frame.payload));

    try testing.expectEqual(Opcode.ping, frame.opcode);
    try testing.expectEqualStrings("ping!", frame.payload);
}

test "writeFrameEx with RSV1 and readFrame round-trip" {
    var writer: MockWriter = .{};
    try writeFrameEx(&writer, .text, "compressed", true, true);

    var reader: MockReader = .{ .data = writer.written() };
    const frame = try readFrame(testing.allocator, &reader);
    defer testing.allocator.free(@constCast(frame.payload));

    try testing.expect(frame.fin);
    try testing.expect(frame.rsv1);
    try testing.expectEqual(Opcode.text, frame.opcode);
    try testing.expectEqualStrings("compressed", frame.payload);
}

test "writeFrameEx without RSV1" {
    var writer: MockWriter = .{};
    try writeFrameEx(&writer, .text, "plain", true, false);

    var reader: MockReader = .{ .data = writer.written() };
    const frame = try readFrame(testing.allocator, &reader);
    defer testing.allocator.free(@constCast(frame.payload));

    try testing.expect(frame.fin);
    try testing.expect(!frame.rsv1);
    try testing.expectEqualStrings("plain", frame.payload);
}

test "readFrame RSV1 is false for normal writeFrame" {
    var writer: MockWriter = .{};
    try writeFrame(&writer, .text, "Hello", true);

    var reader: MockReader = .{ .data = writer.written() };
    const frame = try readFrame(testing.allocator, &reader);
    defer testing.allocator.free(@constCast(frame.payload));

    try testing.expect(!frame.rsv1);
}

test "non-FIN frame" {
    var writer: MockWriter = .{};
    try writeFrame(&writer, .text, "part1", false);

    var reader: MockReader = .{ .data = writer.written() };
    const frame = try readFrame(testing.allocator, &reader);
    defer testing.allocator.free(@constCast(frame.payload));

    try testing.expect(!frame.fin);
    try testing.expectEqual(Opcode.text, frame.opcode);
    try testing.expectEqualStrings("part1", frame.payload);
}
