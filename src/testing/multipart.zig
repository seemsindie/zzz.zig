const std = @import("std");
const Allocator = std.mem.Allocator;

/// A single part in a multipart/form-data body.
pub const MultipartPart = struct {
    name: []const u8,
    value: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    data: ?[]const u8 = null,
};

/// Result of building a multipart body.
pub const MultipartBody = struct {
    body: []const u8,
    content_type: []const u8,
};

/// Build a multipart/form-data body from parts.
/// The caller owns the returned slices and must free them with the same allocator.
pub fn buildMultipartBody(allocator: Allocator, parts: []const MultipartPart) !MultipartBody {
    const boundary = "----PidgnTestBoundary7MA4YWxkTrZu0gW";
    const content_type = "multipart/form-data; boundary=" ++ boundary;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (parts) |part| {
        // Boundary
        try buf.appendSlice(allocator, "--");
        try buf.appendSlice(allocator, boundary);
        try buf.appendSlice(allocator, "\r\n");

        // Content-Disposition
        try buf.appendSlice(allocator, "Content-Disposition: form-data; name=\"");
        try buf.appendSlice(allocator, part.name);
        try buf.appendSlice(allocator, "\"");

        if (part.filename) |filename| {
            try buf.appendSlice(allocator, "; filename=\"");
            try buf.appendSlice(allocator, filename);
            try buf.appendSlice(allocator, "\"");
        }
        try buf.appendSlice(allocator, "\r\n");

        // Content-Type (for file parts)
        if (part.content_type) |ct| {
            try buf.appendSlice(allocator, "Content-Type: ");
            try buf.appendSlice(allocator, ct);
            try buf.appendSlice(allocator, "\r\n");
        }

        // Empty line before body
        try buf.appendSlice(allocator, "\r\n");

        // Body (data takes precedence over value)
        if (part.data) |data| {
            try buf.appendSlice(allocator, data);
        } else if (part.value) |value| {
            try buf.appendSlice(allocator, value);
        }

        try buf.appendSlice(allocator, "\r\n");
    }

    // Final boundary
    try buf.appendSlice(allocator, "--");
    try buf.appendSlice(allocator, boundary);
    try buf.appendSlice(allocator, "--\r\n");

    return .{
        .body = try buf.toOwnedSlice(allocator),
        .content_type = content_type,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

test "buildMultipartBody single text field" {
    const allocator = std.testing.allocator;
    const result = try buildMultipartBody(allocator, &.{
        .{ .name = "name", .value = "alice" },
    });
    defer allocator.free(result.body);

    try std.testing.expect(std.mem.indexOf(u8, result.body, "name=\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content_type, "multipart/form-data") != null);
}

test "buildMultipartBody file field" {
    const allocator = std.testing.allocator;
    const result = try buildMultipartBody(allocator, &.{
        .{ .name = "file", .filename = "photo.jpg", .content_type = "image/jpeg", .data = "FAKE_IMAGE_DATA" },
    });
    defer allocator.free(result.body);

    try std.testing.expect(std.mem.indexOf(u8, result.body, "filename=\"photo.jpg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "Content-Type: image/jpeg") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "FAKE_IMAGE_DATA") != null);
}

test "buildMultipartBody mixed fields" {
    const allocator = std.testing.allocator;
    const result = try buildMultipartBody(allocator, &.{
        .{ .name = "desc", .value = "a photo" },
        .{ .name = "file", .filename = "a.jpg", .content_type = "image/jpeg", .data = "FAKE" },
    });
    defer allocator.free(result.body);

    try std.testing.expect(std.mem.indexOf(u8, result.body, "name=\"desc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "a photo") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "filename=\"a.jpg\"") != null);
    // Ends with final boundary
    try std.testing.expect(std.mem.endsWith(u8, result.body, "----PidgnTestBoundary7MA4YWxkTrZu0gW--\r\n"));
}
