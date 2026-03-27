//! Testing utilities for pidgn applications.
//!
//! Provides an HTTP test client, cookie jar, multipart builder, and
//! WebSocket test channel for testing without a real TCP connection.

const std = @import("std");

pub const TestClient = @import("client.zig").TestClient;
pub const TestResponse = @import("response.zig").TestResponse;
pub const RequestBuilder = @import("request_builder.zig").RequestBuilder;
pub const CookieJar = @import("cookie_jar.zig").CookieJar;
pub const MultipartPart = @import("multipart.zig").MultipartPart;
pub const buildMultipartBody = @import("multipart.zig").buildMultipartBody;
pub const TestChannel = @import("ws_client.zig").TestChannel;

test {
    std.testing.refAllDecls(@This());
}
