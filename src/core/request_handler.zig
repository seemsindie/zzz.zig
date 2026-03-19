const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const http_parser = @import("http/parser.zig");
const Request = @import("http/request.zig").Request;
const Response = @import("http/response.zig").Response;
const StatusCode = @import("http/status.zig").StatusCode;
const ws_handshake = @import("websocket/handshake.zig");
const ws_connection = @import("websocket/connection.zig");

const server_mod = @import("server.zig");
const Handler = server_mod.Handler;
const Config = server_mod.Config;

/// Poll a socket for readability with a timeout (milliseconds).
/// Returns true if data is available, false on timeout or error.
fn pollReadable(fd: std.posix.fd_t, timeout_ms: i32) bool {
    var pfds = [1]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const n = std.posix.poll(&pfds, timeout_ms) catch return false;
    return n > 0;
}

/// Handle the HTTP request/response loop over a reader/writer pair.
/// Works identically for both plain TCP and TLS connections, and is
/// backend-agnostic — any backend can call this with an Io.Reader/Io.Writer.
pub fn handleRequests(
    config: Config,
    handler: Handler,
    allocator: Allocator,
    reader: *Io.Reader,
    writer: *Io.Writer,
    shutdown_flag: *const std.atomic.Value(bool),
    socket_fd: std.posix.fd_t,
) void {
    var requests_served: u32 = 0;

    while (requests_served < config.max_requests_per_connection) {
        if (shutdown_flag.load(.acquire)) break;

        // Poll for readability before reading — this replaces SO_RCVTIMEO
        // which causes EAGAIN panics in std.Io on macOS.
        const timeout_ms: i32 = if (requests_served == 0)
            @intCast(config.read_timeout_ms)
        else
            @intCast(config.keepalive_timeout_ms);
        if (!pollReadable(socket_fd, timeout_ms)) return;

        // Read request header byte by byte, looking for \r\n\r\n
        var req_buf: [16384]u8 = undefined;
        var total_read: usize = 0;

        while (total_read < req_buf.len) {
            const byte = reader.takeByte() catch return;
            req_buf[total_read] = byte;
            total_read += 1;

            // Check if we have complete headers (\r\n\r\n)
            if (total_read >= 4 and
                req_buf[total_read - 4] == '\r' and
                req_buf[total_read - 3] == '\n' and
                req_buf[total_read - 2] == '\r' and
                req_buf[total_read - 1] == '\n')
            {
                break;
            }
        }

        // Client closed connection
        if (total_read == 0) return;

        // Parse request
        const parse_result = http_parser.parse(allocator, req_buf[0..total_read]) catch |err| {
            std.log.debug("parse error: {}", .{err});
            sendError(writer, .bad_request);
            return;
        };
        var req = parse_result.request;
        defer req.deinit(allocator);

        // Handle 100-continue
        if (req.header("Expect")) |expect| {
            if (std.ascii.eqlIgnoreCase(expect, "100-continue")) {
                writer.writeAll("HTTP/1.1 100 Continue\r\n\r\n") catch {};
                writer.flush() catch {};
            }
        }

        // Read body
        var should_continue = true;
        if (req.isChunked() and req.contentLength() == null) {
            // Chunked transfer encoding
            const body_data = readChunkedBody(config, reader, allocator) catch {
                sendError(writer, .bad_request);
                return;
            };
            if (body_data) |data| {
                defer allocator.free(data);
                req.body = data;

                // Call handler and send response
                should_continue = processRequest(config, handler, allocator, reader, writer, &req, requests_served);
            } else {
                should_continue = processRequest(config, handler, allocator, reader, writer, &req, requests_served);
            }
        } else if (req.contentLength()) |content_len| {
            if (content_len > config.max_body_size) {
                sendError(writer, .payload_too_large);
                return;
            }
            if (content_len > 0) {
                const body_buf = allocator.alloc(u8, content_len) catch {
                    sendError(writer, .payload_too_large);
                    return;
                };
                defer allocator.free(body_buf);

                // Some body bytes may already be in req_buf after headers
                const already_read = total_read - parse_result.bytes_consumed;
                if (already_read > 0) {
                    const copy_len = @min(already_read, content_len);
                    @memcpy(body_buf[0..copy_len], req_buf[parse_result.bytes_consumed .. parse_result.bytes_consumed + copy_len]);
                }

                // Read remaining body bytes from stream
                const body_so_far = @min(already_read, content_len);
                if (body_so_far < content_len) {
                    reader.readSliceAll(body_buf[body_so_far..content_len]) catch return;
                }
                req.body = body_buf;

                should_continue = processRequest(config, handler, allocator, reader, writer, &req, requests_served);
            } else {
                should_continue = processRequest(config, handler, allocator, reader, writer, &req, requests_served);
            }
        } else {
            should_continue = processRequest(config, handler, allocator, reader, writer, &req, requests_served);
        }

        // If processRequest returned false (e.g., WebSocket upgrade), exit the loop
        if (!should_continue) return;

        requests_served += 1;

        // Check if we should keep the connection alive
        const keep_alive = req.keepAlive() and
            (requests_served < config.max_requests_per_connection);
        if (!keep_alive) break;
    }
}

/// Process a parsed request: call handler, set keep-alive headers, send response.
/// Returns `true` to continue keep-alive loop, `false` to break (e.g. WebSocket upgrade).
fn processRequest(
    config: Config,
    handler: Handler,
    allocator: Allocator,
    reader: *Io.Reader,
    writer: *Io.Writer,
    req: *Request,
    requests_served: u32,
) bool {
    var resp = handler(allocator, req) catch |err| {
        std.log.err("handler error: {}", .{err});
        sendError(writer, .internal_server_error);
        return true;
    };
    defer resp.deinit(allocator);

    // Check for WebSocket upgrade
    if (resp.status == .switching_protocols) {
        if (resp.ws_handler) |ws_upgrade| {
            // Build and send the 101 handshake response
            const upgrade_result = ws_handshake.buildUpgradeResponse(allocator, req) catch {
                sendError(writer, .internal_server_error);
                return false;
            };
            defer allocator.free(upgrade_result.response_bytes);

            writer.writeAll(upgrade_result.response_bytes) catch return false;
            writer.flush() catch return false;

            // Enter the WebSocket frame loop (blocks until WS closes)
            ws_connection.runLoop(
                allocator,
                reader,
                writer,
                ws_upgrade.handler,
                ws_upgrade.params,
                ws_upgrade.query,
                ws_upgrade.assigns,
                upgrade_result.deflate,
            );

            // Free the WebSocketUpgrade allocated in wsHandler middleware
            allocator.destroy(ws_upgrade);

            return false; // Connection taken over, exit HTTP loop
        }
    }

    // Check for SSE takeover — Content-Type: text/event-stream
    if (resp.headers.get("Content-Type")) |ct| {
        if (std.mem.eql(u8, ct, "text/event-stream")) {
            // Send the SSE headers as an HTTP response with no body
            resp.version = req.version;
            resp.chunked = false;
            // Remove Content-Length for streaming
            sendResponseWriter(writer, &resp);
            // SSE connection established — handler was responsible for
            // setting up its event loop via assigns or returning.
            // For now, the handler returns and the connection closes.
            return false; // Connection taken over
        }
    }

    // Set response version to match request
    resp.version = req.version;

    // Set Connection header based on keep-alive status
    const keep_alive = req.keepAlive() and
        (requests_served + 1 < config.max_requests_per_connection);
    resp.headers.set(allocator, "Connection", if (keep_alive) "keep-alive" else "close") catch {};

    sendResponseWriter(writer, &resp);
    return true;
}

/// Read a chunked request body, accumulating chunks until the terminating 0-length chunk.
fn readChunkedBody(config: Config, reader: *Io.Reader, allocator: Allocator) !?[]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);

    while (true) {
        // Read chunk size line (hex digits followed by \r\n)
        var line_buf: [64]u8 = undefined;
        var line_len: usize = 0;

        while (line_len < line_buf.len) {
            const byte = try reader.takeByte();
            if (byte == '\r') {
                // Expect \n next
                const lf = try reader.takeByte();
                if (lf != '\n') return error.InvalidChunkedEncoding;
                break;
            }
            line_buf[line_len] = byte;
            line_len += 1;
        }

        if (line_len == 0) return error.InvalidChunkedEncoding;

        // Strip optional chunk extensions (after semicolon)
        var size_str = line_buf[0..line_len];
        if (std.mem.indexOf(u8, size_str, ";")) |semi| {
            size_str = line_buf[0..semi];
        }

        const chunk_size = std.fmt.parseInt(usize, size_str, 16) catch
            return error.InvalidChunkedEncoding;

        // Chunk size 0 = end of body
        if (chunk_size == 0) {
            // Read trailing \r\n after the last chunk
            _ = reader.takeByte() catch {};
            _ = reader.takeByte() catch {};
            break;
        }

        // Enforce max body size
        if (body.items.len + chunk_size > config.max_body_size) {
            return error.PayloadTooLarge;
        }

        // Read chunk data
        const start = body.items.len;
        try body.resize(allocator, start + chunk_size);
        reader.readSliceAll(body.items[start..]) catch
            return error.InvalidChunkedEncoding;

        // Read trailing \r\n after chunk data
        const cr = reader.takeByte() catch return error.InvalidChunkedEncoding;
        const lf = reader.takeByte() catch return error.InvalidChunkedEncoding;
        if (cr != '\r' or lf != '\n') return error.InvalidChunkedEncoding;
    }

    if (body.items.len == 0) return null;
    return try body.toOwnedSlice(allocator);
}

/// Serialize and send a response.
pub fn sendResponseWriter(writer: *Io.Writer, resp: *const Response) void {
    const bytes = resp.serialize(std.heap.page_allocator) catch return;
    defer std.heap.page_allocator.free(bytes);

    writer.writeAll(bytes) catch return;
    writer.flush() catch return;
}

/// Send a simple error response with just status code.
pub fn sendError(writer: *Io.Writer, status: StatusCode) void {
    var resp = Response.empty(status);
    sendResponseWriter(writer, &resp);
}
