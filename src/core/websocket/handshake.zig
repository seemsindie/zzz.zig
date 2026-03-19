const std = @import("std");
const Allocator = std.mem.Allocator;
const Request = @import("../http/request.zig").Request;

/// The RFC 6455 magic GUID used for computing Sec-WebSocket-Accept.
const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Compute the Sec-WebSocket-Accept value from a Sec-WebSocket-Key.
/// Returns a base64-encoded 28-byte string.
pub fn computeAcceptKey(sec_websocket_key: []const u8) [28]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(sec_websocket_key);
    hasher.update(ws_guid);
    const digest = hasher.finalResult();

    var result: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&result, &digest);
    return result;
}

/// Validate that a request is a proper WebSocket upgrade request per RFC 6455 Section 4.2.
pub fn validateUpgradeRequest(request: *const Request) !void {
    // Must have Upgrade: websocket header
    const upgrade = request.header("Upgrade") orelse return error.MissingUpgradeHeader;
    if (!std.ascii.eqlIgnoreCase(upgrade, "websocket")) return error.InvalidUpgradeHeader;

    // Must have Connection header containing "upgrade"
    const connection = request.header("Connection") orelse return error.MissingConnectionHeader;
    if (!containsIgnoreCase(connection, "upgrade")) return error.InvalidConnectionHeader;

    // Must have Sec-WebSocket-Key
    const key = request.header("Sec-WebSocket-Key") orelse return error.MissingWebSocketKey;
    if (key.len == 0) return error.InvalidWebSocketKey;

    // Must have Sec-WebSocket-Version: 13
    const version = request.header("Sec-WebSocket-Version") orelse return error.MissingWebSocketVersion;
    if (!std.mem.eql(u8, version, "13")) return error.UnsupportedWebSocketVersion;
}

/// Result of building the upgrade response, includes negotiated extensions.
pub const UpgradeResult = struct {
    response_bytes: []u8,
    deflate: bool,
};

/// Build the raw HTTP/1.1 101 Switching Protocols response bytes.
/// Negotiates permessage-deflate if the client advertises it.
pub fn buildUpgradeResponse(allocator: Allocator, request: *const Request) !UpgradeResult {
    const key = request.header("Sec-WebSocket-Key") orelse return error.MissingWebSocketKey;
    const accept_key = computeAcceptKey(key);

    // Check for permessage-deflate extension
    const deflate = if (request.header("Sec-WebSocket-Extensions")) |ext|
        containsIgnoreCase(ext, "permessage-deflate")
    else
        false;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "HTTP/1.1 101 Switching Protocols\r\n");
    try buf.appendSlice(allocator, "Upgrade: websocket\r\n");
    try buf.appendSlice(allocator, "Connection: Upgrade\r\n");
    try buf.appendSlice(allocator, "Sec-WebSocket-Accept: ");
    try buf.appendSlice(allocator, &accept_key);
    try buf.appendSlice(allocator, "\r\n");
    if (deflate) {
        try buf.appendSlice(allocator, "Sec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover; client_no_context_takeover\r\n");
    }
    try buf.appendSlice(allocator, "Server: Zzz/0.1.0\r\n");
    try buf.appendSlice(allocator, "\r\n");

    return .{
        .response_bytes = try buf.toOwnedSlice(allocator),
        .deflate = deflate,
    };
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "computeAcceptKey matches RFC 6455 test vector" {
    // RFC 6455 Section 4.2.2 example:
    // Key: "dGhlIHNhbXBsZSBub25jZQ=="
    // Expected Accept: "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    const accept = computeAcceptKey(key);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
}

test "validateUpgradeRequest succeeds with valid headers" {
    var req: Request = .{ .method = .GET, .path = "/ws" };
    try req.headers.append(testing.allocator, "Upgrade", "websocket");
    try req.headers.append(testing.allocator, "Connection", "Upgrade");
    try req.headers.append(testing.allocator, "Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==");
    try req.headers.append(testing.allocator, "Sec-WebSocket-Version", "13");
    defer req.deinit(testing.allocator);

    try validateUpgradeRequest(&req);
}

test "validateUpgradeRequest fails without Upgrade header" {
    var req: Request = .{ .method = .GET, .path = "/ws" };
    try req.headers.append(testing.allocator, "Connection", "Upgrade");
    try req.headers.append(testing.allocator, "Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==");
    try req.headers.append(testing.allocator, "Sec-WebSocket-Version", "13");
    defer req.deinit(testing.allocator);

    try testing.expectError(error.MissingUpgradeHeader, validateUpgradeRequest(&req));
}

test "validateUpgradeRequest fails with wrong version" {
    var req: Request = .{ .method = .GET, .path = "/ws" };
    try req.headers.append(testing.allocator, "Upgrade", "websocket");
    try req.headers.append(testing.allocator, "Connection", "Upgrade");
    try req.headers.append(testing.allocator, "Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==");
    try req.headers.append(testing.allocator, "Sec-WebSocket-Version", "8");
    defer req.deinit(testing.allocator);

    try testing.expectError(error.UnsupportedWebSocketVersion, validateUpgradeRequest(&req));
}

test "validateUpgradeRequest fails without key" {
    var req: Request = .{ .method = .GET, .path = "/ws" };
    try req.headers.append(testing.allocator, "Upgrade", "websocket");
    try req.headers.append(testing.allocator, "Connection", "Upgrade");
    try req.headers.append(testing.allocator, "Sec-WebSocket-Version", "13");
    defer req.deinit(testing.allocator);

    try testing.expectError(error.MissingWebSocketKey, validateUpgradeRequest(&req));
}

test "buildUpgradeResponse produces valid HTTP response" {
    var req: Request = .{ .method = .GET, .path = "/ws" };
    try req.headers.append(testing.allocator, "Upgrade", "websocket");
    try req.headers.append(testing.allocator, "Connection", "Upgrade");
    try req.headers.append(testing.allocator, "Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==");
    try req.headers.append(testing.allocator, "Sec-WebSocket-Version", "13");
    defer req.deinit(testing.allocator);

    const result = try buildUpgradeResponse(testing.allocator, &req);
    defer testing.allocator.free(result.response_bytes);

    const response = result.response_bytes;
    try testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1 101 Switching Protocols\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, response, "Upgrade: websocket\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, response, "Connection: Upgrade\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, response, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, response, "\r\n\r\n"));
    try testing.expect(!result.deflate);
}

test "buildUpgradeResponse negotiates permessage-deflate" {
    var req: Request = .{ .method = .GET, .path = "/ws" };
    try req.headers.append(testing.allocator, "Upgrade", "websocket");
    try req.headers.append(testing.allocator, "Connection", "Upgrade");
    try req.headers.append(testing.allocator, "Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==");
    try req.headers.append(testing.allocator, "Sec-WebSocket-Version", "13");
    try req.headers.append(testing.allocator, "Sec-WebSocket-Extensions", "permessage-deflate; client_max_window_bits");
    defer req.deinit(testing.allocator);

    const result = try buildUpgradeResponse(testing.allocator, &req);
    defer testing.allocator.free(result.response_bytes);

    try testing.expect(result.deflate);
    try testing.expect(std.mem.indexOf(u8, result.response_bytes, "Sec-WebSocket-Extensions: permessage-deflate") != null);
    try testing.expect(std.mem.indexOf(u8, result.response_bytes, "server_no_context_takeover") != null);
    try testing.expect(std.mem.indexOf(u8, result.response_bytes, "client_no_context_takeover") != null);
}
