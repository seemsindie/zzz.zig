const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const server_mod = @import("../server.zig");
const Server = server_mod.Server;
const Config = server_mod.Config;
const Handler = server_mod.Handler;
const request_handler = server_mod.request_handler;
const http_parser = @import("../http/parser.zig");
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const StatusCode = @import("../http/status.zig").StatusCode;
const ws_handshake = @import("../websocket/handshake.zig");
const ws_connection = @import("../websocket/connection.zig");

const hv = @cImport({
    @cInclude("hloop.h");
    @cInclude("hsocket.h");
    @cInclude("hssl.h");
});

/// Backend-specific configuration for the libhv event-loop backend.
pub const BackendConfig = struct {
    /// Number of event loops (future: multi-loop).
    event_loop_count: u8 = 1,
};

/// Writer that wraps an hio_t* for WebSocket output via hio_write.
pub const LibhvWriter = struct {
    io: *hv.hio_t,

    pub fn writeAll(self: *LibhvWriter, data: []const u8) !void {
        _ = hv.hio_write(self.io, data.ptr, @intCast(data.len));
    }

    pub fn flush(_: *LibhvWriter) !void {
        // hio_write sends immediately; no buffering
    }
};

/// Reader that reads from a pipe fd, providing blocking reads for WebSocket runLoop.
pub const PipeReader = struct {
    fd: std.posix.fd_t,

    pub fn takeByte(self: *PipeReader) !u8 {
        var buf_arr: [1]u8 = undefined;
        const n = std.posix.read(self.fd, &buf_arr) catch return error.EndOfStream;
        if (n == 0) return error.EndOfStream;
        return buf_arr[0];
    }

    pub fn readSliceAll(self: *PipeReader, buf: []u8) !void {
        var total: usize = 0;
        while (total < buf.len) {
            const n = std.posix.read(self.fd, buf[total..]) catch return error.EndOfStream;
            if (n == 0) return error.EndOfStream;
            total += n;
        }
    }
};

/// Per-connection state, stored as hio context.
const ConnState = struct {
    buf: std.ArrayList(u8),
    headers_complete: bool,
    header_end: usize,
    content_length: ?usize,
    is_chunked: bool,
    allocator: Allocator,
    handler: Handler,
    config: Config,
    // WebSocket state
    ws_mode: bool,
    ws_pipe_write_fd: ?std.posix.fd_t,
    ws_pipe_read_fd: ?std.posix.fd_t,
    ws_thread: ?std.Thread,

    fn init(allocator: Allocator, handler: Handler, config: Config) !*ConnState {
        const state = try allocator.create(ConnState);
        state.* = .{
            .buf = .empty,
            .headers_complete = false,
            .header_end = 0,
            .content_length = null,
            .is_chunked = false,
            .allocator = allocator,
            .handler = handler,
            .config = config,
            .ws_mode = false,
            .ws_pipe_write_fd = null,
            .ws_pipe_read_fd = null,
            .ws_thread = null,
        };
        return state;
    }

    fn deinit(self: *ConnState) void {
        const allocator = self.allocator;
        // Close pipe fds if still open
        if (self.ws_pipe_write_fd) |fd| std.posix.close(fd);
        if (self.ws_pipe_read_fd) |fd| std.posix.close(fd);
        // Join WS thread if it's still running
        if (self.ws_thread) |t| t.join();
        self.buf.deinit(allocator);
        allocator.destroy(self);
    }

    fn reset(self: *ConnState) void {
        self.buf.clearRetainingCapacity();
        self.headers_complete = false;
        self.header_end = 0;
        self.content_length = null;
        self.is_chunked = false;
    }
};

// Module-level state for callbacks (libhv C callbacks can't capture Zig closures)
var global_libhv_server: ?*Server = null;
var global_libhv_loop: ?*hv.hloop_t = null;

/// Signal handler that stops the libhv event loop cleanly.
fn libhvSignalHandler(_: std.posix.SIG) callconv(.c) void {
    if (global_libhv_server) |s| s.shutdown_flag.store(true, .release);
    if (global_libhv_loop) |loop| _ = hv.hloop_stop(loop);
}

/// Main entry point for the libhv backend.
pub fn listen(server: *Server, io: Io) !void {
    _ = io;
    const config = server.config;

    global_libhv_server = server;

    const loop = hv.hloop_new(0) orelse return error.LoopCreateFailed;
    global_libhv_loop = loop;

    // Install signal handlers that call hloop_stop (avoids kevent EINTR)
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = libhvSignalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);

    const port: c_int = @intCast(config.port);
    // libhv needs a null-terminated host string
    var host_buf: [256]u8 = undefined;
    const host_len = @min(config.host.len, host_buf.len - 1);
    @memcpy(host_buf[0..host_len], config.host[0..host_len]);
    host_buf[host_len] = 0;
    const host_z: [*c]const u8 = &host_buf;

    const use_tls = config.tls != null;
    const listenio = if (use_tls)
        hv.hloop_create_ssl_server(loop, host_z, port, onAccept)
    else
        hv.hloop_create_tcp_server(loop, host_z, port, onAccept);
    if (listenio == null) {
        var loop_ptr: ?*hv.hloop_t = loop;
        hv.hloop_free(&loop_ptr);
        return error.ListenFailed;
    }

    // Configure TLS if enabled
    if (config.tls) |tls_config| {
        var ssl_opt: hv.hssl_ctx_opt_t = std.mem.zeroes(hv.hssl_ctx_opt_t);
        ssl_opt.crt_file = tls_config.cert_file.ptr;
        ssl_opt.key_file = tls_config.key_file.ptr;
        ssl_opt.endpoint = hv.HSSL_SERVER;
        if (hv.hio_new_ssl_ctx(listenio, &ssl_opt) != 0) {
            var loop_ptr: ?*hv.hloop_t = loop;
            hv.hloop_free(&loop_ptr);
            return error.SslContextFailed;
        }
    }

    const scheme = if (use_tls) "https" else "http";
    std.log.info("Zzz server listening on {s}://{s}:{d} (backend=libhv)", .{
        scheme,
        config.host,
        config.port,
    });

    // Run the event loop (blocks until hloop_stop)
    _ = hv.hloop_run(loop);

    server.drainConnections();
    std.log.info("Server stopped.", .{});
}

fn onAccept(io: ?*hv.hio_t) callconv(.c) void {
    const conn_io = io orelse return;
    const server = global_libhv_server orelse return;

    // Allocate per-connection state
    const state = ConnState.init(
        server.allocator,
        server.handler,
        server.config,
    ) catch return;

    hv.hio_set_context(conn_io, state);
    hv.hio_setcb_read(conn_io, onRead);
    hv.hio_setcb_close(conn_io, onClose);

    // Set timeouts
    hv.hio_set_keepalive_timeout(conn_io, @intCast(server.config.keepalive_timeout_ms));
    hv.hio_set_read_timeout(conn_io, @intCast(server.config.read_timeout_ms));

    // Start reading
    _ = hv.hio_read_start(conn_io);
}

fn onRead(io: ?*hv.hio_t, buf: ?*anyopaque, readbytes: c_int) callconv(.c) void {
    const conn_io = io orelse return;
    const data_ptr: [*]const u8 = @ptrCast(buf orelse return);
    if (readbytes <= 0) return;
    const nbytes: usize = @intCast(readbytes);

    const state: *ConnState = @ptrCast(@alignCast(hv.hio_context(conn_io) orelse return));

    // WebSocket mode: forward raw bytes to pipe for runLoop thread
    if (state.ws_mode) {
        if (state.ws_pipe_write_fd) |fd| {
            var written: usize = 0;
            while (written < nbytes) {
                const result = std.c.write(fd, data_ptr + written, nbytes - written);
                if (result <= 0) break;
                written += @intCast(result);
            }
        }
        return;
    }

    // Append received bytes
    state.buf.appendSlice(state.allocator, data_ptr[0..nbytes]) catch {
        _ = hv.hio_close(conn_io);
        return;
    };

    // If headers not yet complete, scan for \r\n\r\n
    if (!state.headers_complete) {
        const data = state.buf.items;
        if (data.len >= 4) {
            // Scan from a reasonable starting position
            const start = if (data.len > nbytes + 3) data.len - nbytes - 3 else 0;
            for (start..data.len - 3) |i| {
                if (data[i] == '\r' and data[i + 1] == '\n' and
                    data[i + 2] == '\r' and data[i + 3] == '\n')
                {
                    state.headers_complete = true;
                    state.header_end = i + 4;

                    // Parse headers to determine body requirements
                    const parse_result = http_parser.parse(state.allocator, data[0..state.header_end]) catch {
                        sendErrorResponse(conn_io, state, .bad_request);
                        return;
                    };
                    var req = parse_result.request;

                    // Determine content length
                    if (req.isChunked()) {
                        state.is_chunked = true;
                    } else if (req.contentLength()) |cl| {
                        state.content_length = cl;
                    }

                    req.deinit(state.allocator);
                    break;
                }
            }
        }

        if (!state.headers_complete) {
            // Check header size limit
            if (state.buf.items.len > state.config.max_header_size) {
                sendErrorResponse(conn_io, state, .bad_request);
            }
            return;
        }
    }

    // Headers complete — check if we have the full body
    if (state.is_chunked) {
        // For chunked encoding, look for the terminating 0\r\n\r\n
        const data = state.buf.items;
        if (data.len >= 5) {
            const end = data[data.len - 5 ..];
            if (std.mem.eql(u8, end, "0\r\n\r\n")) {
                processFullRequest(conn_io, state);
                return;
            }
        }
        // Otherwise, keep accumulating
        return;
    }

    const body_expected = state.content_length orelse 0;
    const body_received = state.buf.items.len - state.header_end;

    if (body_received >= body_expected) {
        processFullRequest(conn_io, state);
    }
    // Otherwise, keep accumulating
}

fn processFullRequest(conn_io: *hv.hio_t, state: *ConnState) void {
    const data = state.buf.items;

    // Parse the full request
    const parse_result = http_parser.parse(state.allocator, data[0..state.header_end]) catch {
        sendErrorResponse(conn_io, state, .bad_request);
        return;
    };
    var req = parse_result.request;
    defer req.deinit(state.allocator);

    // Attach body if present
    if (state.header_end < data.len) {
        if (state.is_chunked) {
            // Decode chunked body
            const chunked_data = data[state.header_end..];
            const decoded = decodeChunkedBody(state.allocator, chunked_data) catch {
                sendErrorResponse(conn_io, state, .bad_request);
                return;
            };
            if (decoded) |body| {
                defer state.allocator.free(body);
                req.body = body;
                handleAndRespond(conn_io, state, &req);
            } else {
                handleAndRespond(conn_io, state, &req);
            }
        } else {
            const body_end = state.header_end + (state.content_length orelse 0);
            if (body_end <= data.len) {
                req.body = data[state.header_end..body_end];
            }
            handleAndRespond(conn_io, state, &req);
        }
    } else {
        handleAndRespond(conn_io, state, &req);
    }
}

fn handleAndRespond(conn_io: *hv.hio_t, state: *ConnState, req: *Request) void {
    var resp = state.handler(state.allocator, req) catch |err| {
        std.log.err("handler error: {}", .{err});
        sendErrorResponse(conn_io, state, .internal_server_error);
        return;
    };
    defer resp.deinit(state.allocator);

    // Check for WebSocket upgrade
    if (resp.status == .switching_protocols) {
        if (resp.ws_handler) |ws_upgrade| {
            // Build and send the 101 handshake response
            const upgrade_result = ws_handshake.buildUpgradeResponse(state.allocator, req) catch {
                sendErrorResponse(conn_io, state, .internal_server_error);
                return;
            };
            defer state.allocator.free(upgrade_result.response_bytes);

            _ = hv.hio_write(conn_io, upgrade_result.response_bytes.ptr, @intCast(upgrade_result.response_bytes.len));

            // Create a pipe for the WS bridge
            var pipe_fds: [2]std.posix.fd_t = undefined;
            if (std.c.pipe(&pipe_fds) != 0) {
                _ = hv.hio_close(conn_io);
                return;
            }
            state.ws_pipe_read_fd = pipe_fds[0];
            state.ws_pipe_write_fd = pipe_fds[1];
            state.ws_mode = true;

            // Disable keepalive/read timeouts — WS connections are long-lived
            hv.hio_set_keepalive_timeout(conn_io, 0);
            hv.hio_set_read_timeout(conn_io, 0);

            // Set up WebSocket ping heartbeat (every 30s)
            hv.hio_set_heartbeat(conn_io, 30000, wsPingCallback);

            // Capture data needed by the WS thread
            const ws_handler_copy = ws_upgrade.handler;
            const ws_params_copy = ws_upgrade.params;
            const ws_query_copy = ws_upgrade.query;
            const ws_assigns_copy = ws_upgrade.assigns;
            const ws_deflate = upgrade_result.deflate;
            const allocator = state.allocator;
            const read_fd = pipe_fds[0];

            // Spawn a thread to run the WebSocket frame loop
            state.ws_thread = std.Thread.spawn(.{}, wsThreadFn, .{
                allocator,
                conn_io,
                read_fd,
                ws_handler_copy,
                ws_params_copy,
                ws_query_copy,
                ws_assigns_copy,
                ws_deflate,
                state,
            }) catch {
                state.ws_mode = false;
                std.posix.close(pipe_fds[0]);
                std.posix.close(pipe_fds[1]);
                state.ws_pipe_read_fd = null;
                state.ws_pipe_write_fd = null;
                _ = hv.hio_close(conn_io);
                return;
            };

            // Free the WebSocketUpgrade struct allocated in wsHandler middleware
            state.allocator.destroy(ws_upgrade);

            return; // Connection taken over by WebSocket
        }
    }

    // Set response version to match request
    resp.version = req.version;

    // Set Connection header
    const keep_alive = req.keepAlive();
    resp.headers.set(state.allocator, "Connection", if (keep_alive) "keep-alive" else "close") catch {};

    // Serialize and send
    const bytes = resp.serialize(std.heap.page_allocator) catch {
        sendErrorResponse(conn_io, state, .internal_server_error);
        return;
    };
    defer std.heap.page_allocator.free(bytes);

    _ = hv.hio_write(conn_io, bytes.ptr, @intCast(bytes.len));

    if (keep_alive) {
        // Reset state for next request on the same connection
        state.reset();
    } else {
        _ = hv.hio_close(conn_io);
    }
}

/// Thread function that runs the WebSocket frame loop using pipe-based I/O.
fn wsThreadFn(
    allocator: Allocator,
    conn_io: *hv.hio_t,
    read_fd: std.posix.fd_t,
    ws_handler: ws_connection.Handler,
    ws_params: @import("../../middleware/context.zig").Params,
    ws_query: @import("../../middleware/context.zig").Params,
    ws_assigns: @import("../../middleware/context.zig").Assigns,
    ws_deflate: bool,
    state: *ConnState,
) void {
    var pipe_reader: PipeReader = .{ .fd = read_fd };
    var libhv_writer: LibhvWriter = .{ .io = conn_io };

    ws_connection.runLoop(
        allocator,
        &pipe_reader,
        &libhv_writer,
        ws_handler,
        ws_params,
        ws_query,
        ws_assigns,
        ws_deflate,
    );

    // runLoop returned — WS connection is done
    state.ws_mode = false;

    // Close the read end of the pipe (write end closed by onClose or here)
    std.posix.close(read_fd);
    state.ws_pipe_read_fd = null;

    // Close the connection from the event loop side
    _ = hv.hio_close(conn_io);
}

fn sendErrorResponse(conn_io: *hv.hio_t, state: *ConnState, status: StatusCode) void {
    var resp = Response.empty(status);
    const bytes = resp.serialize(std.heap.page_allocator) catch {
        _ = hv.hio_close(conn_io);
        return;
    };
    defer std.heap.page_allocator.free(bytes);

    _ = hv.hio_write(conn_io, bytes.ptr, @intCast(bytes.len));
    _ = hv.hio_close(conn_io);
    state.reset();
}

fn onClose(io: ?*hv.hio_t) callconv(.c) void {
    const conn_io = io orelse return;
    const state: *ConnState = @ptrCast(@alignCast(hv.hio_context(conn_io) orelse return));

    // If in WS mode, close the pipe write fd to trigger EOF in the reader thread
    if (state.ws_mode) {
        if (state.ws_pipe_write_fd) |fd| {
            std.posix.close(fd);
            state.ws_pipe_write_fd = null;
        }
        // Join the WS thread before freeing state
        if (state.ws_thread) |t| {
            t.join();
            state.ws_thread = null;
        }
    }

    state.deinit();
}

/// Decode a chunked transfer-encoded body from raw bytes.
fn decodeChunkedBody(allocator: Allocator, data: []const u8) !?[]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);

    var pos: usize = 0;
    while (pos < data.len) {
        // Find chunk size line ending (\r\n)
        const line_end = std.mem.indexOf(u8, data[pos..], "\r\n") orelse
            return error.InvalidChunkedEncoding;
        const size_str = data[pos .. pos + line_end];

        // Strip chunk extensions
        var clean_size = size_str;
        if (std.mem.indexOf(u8, clean_size, ";")) |semi| {
            clean_size = size_str[0..semi];
        }

        const chunk_size = std.fmt.parseInt(usize, clean_size, 16) catch
            return error.InvalidChunkedEncoding;

        pos += line_end + 2; // skip past \r\n

        if (chunk_size == 0) break; // terminal chunk

        if (pos + chunk_size > data.len) return error.InvalidChunkedEncoding;
        try body.appendSlice(allocator, data[pos .. pos + chunk_size]);
        pos += chunk_size + 2; // skip data + \r\n
    }

    if (body.items.len == 0) return null;
    return try body.toOwnedSlice(allocator);
}

// ── Timer API ────────────────────────────────────────────────────────

/// Timer handle wrapping libhv's htimer_t.
pub const Timer = struct {
    inner: *hv.htimer_t,
};

/// Timer callback type.
pub const TimerCallback = *const fn (?*hv.htimer_t) callconv(.c) void;

/// Add a one-shot or repeating timer.
/// `timeout_ms`: interval in milliseconds.
/// `repeat`: number of repetitions (0 = infinite).
pub fn addTimer(timeout_ms: u32, repeat: u32, callback: TimerCallback) ?Timer {
    const loop = global_libhv_loop orelse return null;
    const inner = hv.htimer_add(loop, callback, timeout_ms, repeat) orelse return null;
    return .{ .inner = inner };
}

/// Remove a timer.
pub fn removeTimer(timer: Timer) void {
    hv.htimer_del(timer.inner);
}

/// Reset a timer with a new timeout. Pass 0 to reuse the original timeout.
pub fn resetTimer(timer: Timer, timeout_ms: u32) void {
    hv.htimer_reset(timer.inner, timeout_ms);
}

// ── WebSocket heartbeat ──────────────────────────────────────────────

/// Sends a WebSocket ping frame via hio_write (used as hio_set_heartbeat callback).
fn wsPingCallback(io: ?*hv.hio_t) callconv(.c) void {
    const conn_io = io orelse return;
    // WebSocket ping frame: FIN + opcode 0x9, payload length 0
    const ping_frame = [_]u8{ 0x89, 0x00 };
    _ = hv.hio_write(conn_io, &ping_frame, 2);
}
