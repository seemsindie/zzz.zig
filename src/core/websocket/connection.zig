const std = @import("std");
const Allocator = std.mem.Allocator;
const frame_mod = @import("frame.zig");
const Frame = frame_mod.Frame;
const Opcode = frame_mod.Opcode;
const deflate_mod = @import("deflate.zig");
const Params = @import("../../middleware/context.zig").Params;
const Assigns = @import("../../middleware/context.zig").Assigns;

/// A WebSocket message (text or binary).
pub const Message = union(enum) {
    text: []const u8,
    binary: []const u8,
};

/// Callback-based handler for WebSocket events.
pub const Handler = struct {
    on_open: ?*const fn (*WebSocket) void = null,
    on_message: ?*const fn (*WebSocket, Message) void = null,
    on_close: ?*const fn (*WebSocket, u16, []const u8) void = null,
};

/// Spin-lock helper for std.atomic.Mutex (which only provides tryLock).
fn spinLock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) {}
}

/// User-facing WebSocket connection handle, passed to handler callbacks.
pub const WebSocket = struct {
    allocator: Allocator,
    closed: bool = false,
    deflate: bool = false,
    params: Params,
    query: Params,
    assigns: Assigns,

    // Type-erased writer via function pointers
    writer_ctx: *anyopaque,
    write_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    flush_fn: *const fn (*anyopaque) anyerror!void,

    /// Mutex protecting all writes — allows safe cross-thread broadcasts.
    write_mutex: std.atomic.Mutex = .unlocked,

    /// Send a text message.
    pub fn send(self: *WebSocket, data: []const u8) void {
        spinLock(&self.write_mutex);
        defer self.write_mutex.unlock();
        if (self.closed) return;
        self.writeFrame(.text, data) catch {
            self.closed = true;
        };
    }

    /// Send a binary message.
    pub fn sendBinary(self: *WebSocket, data: []const u8) void {
        spinLock(&self.write_mutex);
        defer self.write_mutex.unlock();
        if (self.closed) return;
        self.writeFrame(.binary, data) catch {
            self.closed = true;
        };
    }

    /// Initiate a close with code and reason.
    pub fn close(self: *WebSocket, code: u16, reason: []const u8) void {
        spinLock(&self.write_mutex);
        defer self.write_mutex.unlock();
        if (self.closed) return;
        self.closed = true;
        self.writeCloseFrame(code, reason) catch {};
    }

    /// Get a path parameter by name.
    pub fn param(self: *const WebSocket, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    /// Get a query parameter by name.
    pub fn queryParam(self: *const WebSocket, name: []const u8) ?[]const u8 {
        return self.query.get(name);
    }

    /// Get an assign value by key.
    pub fn getAssign(self: *const WebSocket, key: []const u8) ?[]const u8 {
        return self.assigns.get(key);
    }

    fn writeFrame(self: *WebSocket, opcode: Opcode, payload: []const u8) !void {
        // Compress data frames if deflate is negotiated
        const is_data = (opcode == .text or opcode == .binary);
        if (self.deflate and is_data and payload.len > 0) {
            const compressed = deflate_mod.compressPayload(self.allocator, payload) catch
                return error.CompressionFailed;
            defer self.allocator.free(compressed);
            try self.writeRawFrame(opcode, compressed, true);
        } else {
            try self.writeRawFrame(opcode, payload, false);
        }
    }

    fn writeRawFrame(self: *WebSocket, opcode: Opcode, payload: []const u8, rsv1: bool) !void {
        const byte0: u8 = 0x80 |
            (if (rsv1) @as(u8, 0x40) else @as(u8, 0x00)) |
            @as(u8, @intFromEnum(opcode));
        try self.write_fn(self.writer_ctx, &.{byte0});

        if (payload.len < 126) {
            try self.write_fn(self.writer_ctx, &.{@intCast(payload.len)});
        } else if (payload.len <= 0xFFFF) {
            try self.write_fn(self.writer_ctx, &.{126});
            var len_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &len_buf, @intCast(payload.len), .big);
            try self.write_fn(self.writer_ctx, &len_buf);
        } else {
            try self.write_fn(self.writer_ctx, &.{127});
            var len_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &len_buf, @intCast(payload.len), .big);
            try self.write_fn(self.writer_ctx, &len_buf);
        }

        if (payload.len > 0) {
            try self.write_fn(self.writer_ctx, payload);
        }

        try self.flush_fn(self.writer_ctx);
    }

    fn writeCloseFrame(self: *WebSocket, code: u16, reason: []const u8) !void {
        var buf: [125]u8 = undefined;
        std.mem.writeInt(u16, buf[0..2], code, .big);
        const reason_len = @min(reason.len, 123);
        @memcpy(buf[2..][0..reason_len], reason[0..reason_len]);
        try self.writeFrame(.close, buf[0 .. 2 + reason_len]);
    }
};

/// Type-erased writer vtable generator.
pub fn WriterVTable(comptime WriterType: type) type {
    return struct {
        pub fn writeAll(ctx: *anyopaque, data: []const u8) anyerror!void {
            const writer: *WriterType = @ptrCast(@alignCast(ctx));
            try writer.writeAll(data);
        }

        pub fn flush(ctx: *anyopaque) anyerror!void {
            const writer: *WriterType = @ptrCast(@alignCast(ctx));
            try writer.flush();
        }
    };
}

/// Type-erased reader vtable generator.
fn ReaderVTable(comptime ReaderType: type) type {
    return struct {
        fn takeByte(ctx: *anyopaque) anyerror!u8 {
            const reader: *ReaderType = @ptrCast(@alignCast(ctx));
            return reader.takeByte();
        }

        fn readSliceAll(ctx: *anyopaque, buf: []u8) anyerror!void {
            const reader: *ReaderType = @ptrCast(@alignCast(ctx));
            try reader.readSliceAll(buf);
        }
    };
}

/// Type-erased reader for frame reading.
const ErasedReader = struct {
    ctx: *anyopaque,
    take_byte_fn: *const fn (*anyopaque) anyerror!u8,
    read_slice_fn: *const fn (*anyopaque, []u8) anyerror!void,

    pub fn takeByte(self: *ErasedReader) !u8 {
        return self.take_byte_fn(self.ctx);
    }

    pub fn readSliceAll(self: *ErasedReader, buf: []u8) !void {
        try self.read_slice_fn(self.ctx, buf);
    }
};

/// Run the WebSocket frame loop. Blocks until the connection is closed.
/// reader and writer should be pointer types with takeByte/readSliceAll and writeAll/flush.
/// If `deflate` is true, incoming RSV1 frames are decompressed and outgoing data frames are compressed.
pub fn runLoop(
    allocator: Allocator,
    reader: anytype,
    writer: anytype,
    handler: Handler,
    params: Params,
    query: Params,
    assigns: Assigns,
    deflate: bool,
) void {
    const ReaderPtrType = std.meta.Child(@TypeOf(reader));
    const WriterPtrType = std.meta.Child(@TypeOf(writer));
    const RVTable = ReaderVTable(ReaderPtrType);
    const WVTable = WriterVTable(WriterPtrType);

    var ws: WebSocket = .{
        .allocator = allocator,
        .closed = false,
        .deflate = deflate,
        .params = params,
        .query = query,
        .assigns = assigns,
        .writer_ctx = @ptrCast(@alignCast(writer)),
        .write_fn = &WVTable.writeAll,
        .flush_fn = &WVTable.flush,
    };

    // on_open callback
    if (handler.on_open) |on_open| {
        on_open(&ws);
    }

    // Type-erased reader for frame reading
    var erased_reader: ErasedReader = .{
        .ctx = @ptrCast(@alignCast(reader)),
        .take_byte_fn = &RVTable.takeByte,
        .read_slice_fn = &RVTable.readSliceAll,
    };

    // Fragment accumulation
    var fragment_buf: std.ArrayList(u8) = .empty;
    defer fragment_buf.deinit(allocator);
    var fragment_opcode: Opcode = .text;

    // Frame loop
    while (!ws.closed) {
        const frame = frame_mod.readFrame(allocator, &erased_reader) catch {
            // Read error — abnormal close
            if (!ws.closed) {
                if (handler.on_close) |on_close| {
                    on_close(&ws, 1006, "");
                }
                ws.closed = true;
            }
            break;
        };
        defer allocator.free(@constCast(frame.payload));

        switch (frame.opcode) {
            .ping => {
                // Auto-pong with same payload
                spinLock(&ws.write_mutex);
                defer ws.write_mutex.unlock();
                ws.writeFrame(.pong, frame.payload) catch {
                    ws.closed = true;
                    break;
                };
            },
            .pong => {
                // Pong received — heartbeat acknowledged
            },
            .close => {
                const code = frame.close_code orelse 1005;
                const reason = if (frame.payload.len > 2) frame.payload[2..] else "";

                // Echo the close frame, then notify handler
                if (!ws.closed) {
                    spinLock(&ws.write_mutex);
                    ws.closed = true;
                    ws.writeCloseFrame(code, reason) catch {};
                    ws.write_mutex.unlock();
                    if (handler.on_close) |on_close| {
                        on_close(&ws, code, reason);
                    }
                }
                break;
            },
            .text, .binary => {
                if (frame.fin) {
                    if (fragment_buf.items.len > 0) {
                        // New non-continuation message while fragmenting — reset
                        fragment_buf.clearRetainingCapacity();
                    }

                    // Decompress if RSV1 is set and deflate was negotiated
                    var decompressed: ?[]u8 = null;
                    defer if (decompressed) |d| allocator.free(d);

                    const payload = if (frame.rsv1 and deflate) blk: {
                        decompressed = deflate_mod.decompressPayload(allocator, frame.payload) catch {
                            ws.close(1007, "decompression failed");
                            break :blk frame.payload;
                        };
                        break :blk decompressed.?;
                    } else frame.payload;

                    const msg: Message = if (frame.opcode == .text)
                        .{ .text = payload }
                    else
                        .{ .binary = payload };
                    if (handler.on_message) |on_message| {
                        on_message(&ws, msg);
                    }
                } else {
                    // Start of fragmented message
                    fragment_opcode = frame.opcode;
                    fragment_buf.clearRetainingCapacity();
                    fragment_buf.appendSlice(allocator, frame.payload) catch {
                        ws.close(1011, "internal error");
                        break;
                    };
                }
            },
            .continuation => {
                fragment_buf.appendSlice(allocator, frame.payload) catch {
                    ws.close(1011, "internal error");
                    break;
                };

                if (frame.fin) {
                    // Fragmented message complete
                    const assembled = fragment_buf.items;
                    const msg: Message = if (fragment_opcode == .text)
                        .{ .text = assembled }
                    else
                        .{ .binary = assembled };
                    if (handler.on_message) |on_message| {
                        on_message(&ws, msg);
                    }
                    fragment_buf.clearRetainingCapacity();
                }
            },
            _ => {
                // Unknown opcode — close with protocol error
                ws.close(1002, "unsupported opcode");
                break;
            },
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Mock reader for connection tests.
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

/// Mock writer for connection tests.
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

test "WebSocket send writes text frame" {
    var writer: MockWriter = .{};
    const VTable = WriterVTable(MockWriter);

    var ws: WebSocket = .{
        .allocator = testing.allocator,
        .closed = false,
        .params = .{},
        .query = .{},
        .assigns = .{},
        .writer_ctx = @ptrCast(&writer),
        .write_fn = &VTable.writeAll,
        .flush_fn = &VTable.flush,
    };

    ws.send("Hello");

    // Read back the frame from the writer buffer
    var reader: MockReader = .{ .data = writer.buf[0..writer.pos] };
    const frame = try frame_mod.readFrame(testing.allocator, &reader);
    defer testing.allocator.free(@constCast(frame.payload));

    try testing.expectEqual(Opcode.text, frame.opcode);
    try testing.expectEqualStrings("Hello", frame.payload);
    try testing.expect(frame.fin);
}

test "WebSocket sendBinary writes binary frame" {
    var writer: MockWriter = .{};
    const VTable = WriterVTable(MockWriter);

    var ws: WebSocket = .{
        .allocator = testing.allocator,
        .closed = false,
        .params = .{},
        .query = .{},
        .assigns = .{},
        .writer_ctx = @ptrCast(&writer),
        .write_fn = &VTable.writeAll,
        .flush_fn = &VTable.flush,
    };

    ws.sendBinary(&.{ 0x00, 0xFF });

    var reader: MockReader = .{ .data = writer.buf[0..writer.pos] };
    const frame = try frame_mod.readFrame(testing.allocator, &reader);
    defer testing.allocator.free(@constCast(frame.payload));

    try testing.expectEqual(Opcode.binary, frame.opcode);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0xFF }, frame.payload);
}

test "WebSocket close sends close frame and sets closed" {
    var writer: MockWriter = .{};
    const VTable = WriterVTable(MockWriter);

    var ws: WebSocket = .{
        .allocator = testing.allocator,
        .closed = false,
        .params = .{},
        .query = .{},
        .assigns = .{},
        .writer_ctx = @ptrCast(&writer),
        .write_fn = &VTable.writeAll,
        .flush_fn = &VTable.flush,
    };

    ws.close(1000, "goodbye");
    try testing.expect(ws.closed);

    var reader: MockReader = .{ .data = writer.buf[0..writer.pos] };
    const frame = try frame_mod.readFrame(testing.allocator, &reader);
    defer testing.allocator.free(@constCast(frame.payload));

    try testing.expectEqual(Opcode.close, frame.opcode);
    try testing.expectEqual(@as(u16, 1000), frame.close_code.?);
}

test "WebSocket param and queryParam" {
    var writer: MockWriter = .{};
    const VTable = WriterVTable(MockWriter);

    var p: Params = .{};
    p.put("room", "lobby");
    var q: Params = .{};
    q.put("token", "abc");

    const ws: WebSocket = .{
        .allocator = testing.allocator,
        .closed = false,
        .params = p,
        .query = q,
        .assigns = .{},
        .writer_ctx = @ptrCast(&writer),
        .write_fn = &VTable.writeAll,
        .flush_fn = &VTable.flush,
    };

    try testing.expectEqualStrings("lobby", ws.param("room").?);
    try testing.expectEqualStrings("abc", ws.queryParam("token").?);
    try testing.expect(ws.param("missing") == null);
}

test "runLoop calls on_open and on_close on read error" {
    var writer: MockWriter = .{};
    var reader: MockReader = .{ .data = "" }; // Empty → immediate read error

    var opened = false;
    var closed = false;
    var close_code: u16 = 0;

    const Callbacks = struct {
        var cb_opened: *bool = undefined;
        var cb_closed: *bool = undefined;
        var cb_close_code: *u16 = undefined;

        fn onOpen(_: *WebSocket) void {
            cb_opened.* = true;
        }
        fn onClose(_: *WebSocket, code: u16, _: []const u8) void {
            cb_closed.* = true;
            cb_close_code.* = code;
        }
    };
    Callbacks.cb_opened = &opened;
    Callbacks.cb_closed = &closed;
    Callbacks.cb_close_code = &close_code;

    runLoop(
        testing.allocator,
        &reader,
        &writer,
        .{
            .on_open = &Callbacks.onOpen,
            .on_close = &Callbacks.onClose,
        },
        .{},
        .{},
        .{},
        false,
    );

    try testing.expect(opened);
    try testing.expect(closed);
    try testing.expectEqual(@as(u16, 1006), close_code);
}
