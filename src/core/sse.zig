const std = @import("std");
const Io = std.Io;

/// Server-Sent Events writer.
/// Wraps a raw writer to send SSE-formatted events.
pub const SseWriter = struct {
    writer_ctx: *anyopaque,
    write_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    flush_fn: *const fn (*anyopaque) anyerror!void,

    /// Send a data-only event.
    pub fn sendEvent(self: *SseWriter, data: []const u8) !void {
        try self.writeDataLines(data);
        try self.write_fn(self.writer_ctx, "\n");
        try self.flush_fn(self.writer_ctx);
    }

    /// Send a named event with data.
    pub fn sendNamedEvent(self: *SseWriter, event: []const u8, data: []const u8) !void {
        try self.write_fn(self.writer_ctx, "event: ");
        try self.write_fn(self.writer_ctx, event);
        try self.write_fn(self.writer_ctx, "\n");
        try self.writeDataLines(data);
        try self.write_fn(self.writer_ctx, "\n");
        try self.flush_fn(self.writer_ctx);
    }

    /// Send an event with id, event name, and data.
    pub fn sendWithId(self: *SseWriter, id: []const u8, event: []const u8, data: []const u8) !void {
        try self.write_fn(self.writer_ctx, "id: ");
        try self.write_fn(self.writer_ctx, id);
        try self.write_fn(self.writer_ctx, "\n");
        try self.write_fn(self.writer_ctx, "event: ");
        try self.write_fn(self.writer_ctx, event);
        try self.write_fn(self.writer_ctx, "\n");
        try self.writeDataLines(data);
        try self.write_fn(self.writer_ctx, "\n");
        try self.flush_fn(self.writer_ctx);
    }

    /// Send a keepalive comment (`: keepalive\n\n`).
    pub fn keepAlive(self: *SseWriter) !void {
        try self.write_fn(self.writer_ctx, ": keepalive\n\n");
        try self.flush_fn(self.writer_ctx);
    }

    /// Write data field(s), splitting on newlines.
    fn writeDataLines(self: *SseWriter, data: []const u8) !void {
        var start: usize = 0;
        for (data, 0..) |c, i| {
            if (c == '\n') {
                try self.write_fn(self.writer_ctx, "data: ");
                try self.write_fn(self.writer_ctx, data[start..i]);
                try self.write_fn(self.writer_ctx, "\n");
                start = i + 1;
            }
        }
        // Write remaining (or only) line
        try self.write_fn(self.writer_ctx, "data: ");
        try self.write_fn(self.writer_ctx, data[start..]);
        try self.write_fn(self.writer_ctx, "\n");
    }
};

/// Type-erased writer vtable generator (same pattern as WebSocket).
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

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

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

fn makeSseWriter(writer: *MockWriter) SseWriter {
    const VTable = WriterVTable(MockWriter);
    return .{
        .writer_ctx = @ptrCast(writer),
        .write_fn = &VTable.writeAll,
        .flush_fn = &VTable.flush,
    };
}

test "SseWriter sendEvent formats data correctly" {
    var w: MockWriter = .{};
    var sse = makeSseWriter(&w);

    try sse.sendEvent("hello");
    try testing.expectEqualStrings("data: hello\n\n", w.buf[0..w.pos]);
}

test "SseWriter sendNamedEvent includes event field" {
    var w: MockWriter = .{};
    var sse = makeSseWriter(&w);

    try sse.sendNamedEvent("message", "world");
    try testing.expectEqualStrings("event: message\ndata: world\n\n", w.buf[0..w.pos]);
}

test "SseWriter sendWithId includes all fields" {
    var w: MockWriter = .{};
    var sse = makeSseWriter(&w);

    try sse.sendWithId("1", "update", "data here");
    try testing.expectEqualStrings("id: 1\nevent: update\ndata: data here\n\n", w.buf[0..w.pos]);
}

test "SseWriter keepAlive sends comment" {
    var w: MockWriter = .{};
    var sse = makeSseWriter(&w);

    try sse.keepAlive();
    try testing.expectEqualStrings(": keepalive\n\n", w.buf[0..w.pos]);
}

test "SseWriter sendEvent handles multiline data" {
    var w: MockWriter = .{};
    var sse = makeSseWriter(&w);

    try sse.sendEvent("line1\nline2\nline3");
    try testing.expectEqualStrings("data: line1\ndata: line2\ndata: line3\n\n", w.buf[0..w.pos]);
}
