//! Test root for core module — HTTP, WebSocket, and Channel subsystems.
//! Compiled as an independent test binary for parallel execution.

const std = @import("std");

// HTTP
pub const parser = @import("core/http/parser.zig");
pub const headers = @import("core/http/headers.zig");
pub const request = @import("core/http/request.zig");
pub const response = @import("core/http/response.zig");
pub const status = @import("core/http/status.zig");

// WebSocket
pub const websocket = @import("core/websocket/websocket.zig");
pub const ws_connection = @import("core/websocket/connection.zig");
pub const ws_frame = @import("core/websocket/frame.zig");
pub const ws_handshake = @import("core/websocket/handshake.zig");

// Channel
pub const channel = @import("core/channel/channel.zig");
pub const pubsub = @import("core/channel/pubsub.zig");
pub const presence = @import("core/channel/presence.zig");
pub const socket = @import("core/channel/socket.zig");
pub const channel_mod = @import("core/channel/channel_mod.zig");

test {
    std.testing.refAllDecls(@This());
}
