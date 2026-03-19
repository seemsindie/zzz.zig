const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

/// Trailing sync marker stripped after compression / appended before decompression (RFC 7692).
const deflate_tail = [_]u8{ 0x00, 0x00, 0xFF, 0xFF };

/// Empty final stored block (BFINAL=1, BTYPE=00, LEN=0, NLEN=0xFFFF).
/// Appended after the sync marker to properly terminate the DEFLATE stream
/// so the decompressor sees a final block and stops cleanly.
const deflate_final = [_]u8{ 0x01, 0x00, 0x00, 0xFF, 0xFF };

/// Compress a WebSocket payload using raw DEFLATE (permessage-deflate, RFC 7692).
/// Strips the trailing 0x00 0x00 0xFF 0xFF sync marker per the spec.
/// Caller owns the returned slice.
pub fn compressPayload(allocator: Allocator, payload: []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = try .initCapacity(allocator, if (payload.len > 16) payload.len else 64);
    errdefer aw.deinit();

    var window_buf: [flate.max_window_len]u8 = undefined;
    var compressor = try flate.Compress.init(&aw.writer, &window_buf, .raw, .default);

    try compressor.writer.writeAll(payload);
    try compressor.writer.flush();

    var result = try aw.toOwnedSlice();

    // Strip trailing sync marker if present
    if (result.len >= 4 and std.mem.eql(u8, result[result.len - 4 ..], &deflate_tail)) {
        result = allocator.realloc(result, result.len - 4) catch result;
    }
    return result;
}

/// Decompress a permessage-deflate payload by appending the sync marker and running raw DEFLATE decompression.
/// Caller owns the returned slice.
pub fn decompressPayload(allocator: Allocator, compressed: []const u8) ![]u8 {
    if (compressed.len == 0) return try allocator.alloc(u8, 0);

    // Append sync marker + final empty block to terminate the DEFLATE stream
    const with_tail = try allocator.alloc(u8, compressed.len + deflate_tail.len + deflate_final.len);
    defer allocator.free(with_tail);
    @memcpy(with_tail[0..compressed.len], compressed);
    @memcpy(with_tail[compressed.len..][0..deflate_tail.len], &deflate_tail);
    @memcpy(with_tail[compressed.len + deflate_tail.len ..], &deflate_final);

    // Decompress
    var reader: Io.Reader = .fixed(with_tail);
    var window_buf: [flate.max_window_len]u8 = undefined;
    var decompressor = flate.Decompress.init(&reader, .raw, &window_buf);

    return try decompressor.reader.allocRemaining(allocator, .unlimited);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "compressPayload and decompressPayload round-trip" {
    const original = "Hello, World! This is a test of permessage-deflate compression.";
    const compressed = try compressPayload(testing.allocator, original);
    defer testing.allocator.free(compressed);

    // Compressed should be different from original
    try testing.expect(!std.mem.eql(u8, compressed, original));

    const decompressed = try decompressPayload(testing.allocator, compressed);
    defer testing.allocator.free(decompressed);

    try testing.expectEqualStrings(original, decompressed);
}

test "compressPayload strips trailing sync marker" {
    const data = "test data for deflate";
    const compressed = try compressPayload(testing.allocator, data);
    defer testing.allocator.free(compressed);

    // Should NOT end with the sync marker
    if (compressed.len >= 4) {
        try testing.expect(!std.mem.eql(u8, compressed[compressed.len - 4 ..], &deflate_tail));
    }
}

test "compressPayload and decompressPayload with empty payload" {
    const compressed = try compressPayload(testing.allocator, "");
    defer testing.allocator.free(compressed);

    const decompressed = try decompressPayload(testing.allocator, compressed);
    defer testing.allocator.free(decompressed);

    try testing.expectEqualStrings("", decompressed);
}

test "compressPayload and decompressPayload with large payload" {
    const original = "abcdefghijklmnopqrstuvwxyz " ** 100;
    const compressed = try compressPayload(testing.allocator, original);
    defer testing.allocator.free(compressed);

    // Compression should actually reduce size for repetitive data
    try testing.expect(compressed.len < original.len);

    const decompressed = try decompressPayload(testing.allocator, compressed);
    defer testing.allocator.free(decompressed);

    try testing.expectEqualStrings(original, decompressed);
}
