const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const tls_enabled = @import("tls_options").tls_enabled;
const tls = if (tls_enabled) @import("tls") else undefined;

const backend_mod = @import("backend.zig");
pub const SelectedBackend = backend_mod.SelectedBackend;
pub const backend_name = backend_mod.backend_name;

pub const request_handler = @import("request_handler.zig");

const Request = @import("http/request.zig").Request;
const Response = @import("http/response.zig").Response;

/// Handler function type: receives a request, returns a response.
pub const Handler = *const fn (Allocator, *const Request) anyerror!Response;

/// TLS configuration for HTTPS mode.
pub const TlsConfig = struct {
    cert_file: [:0]const u8,
    key_file: [:0]const u8,
};

/// Configuration for the HTTP server.
pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8888,
    max_body_size: usize = 1024 * 1024, // 1MB default
    max_header_size: usize = 16384, // 16KB default
    read_timeout_ms: u32 = 30_000, // 30s
    write_timeout_ms: u32 = 30_000, // 30s
    keepalive_timeout_ms: u32 = 65_000, // 65s
    worker_threads: u16 = 4, // 0 = single-threaded
    max_connections: u32 = 1024,
    max_requests_per_connection: u32 = 100,
    kernel_backlog: u31 = 128,
    drain_timeout_ms: u32 = 30_000, // 30s
    shutdown_hooks: [8]?*const fn () void = .{ null, null, null, null, null, null, null, null },
    tls: ?TlsConfig = null,
};

/// Global server reference for signal handling.
var global_server: ?*Server = null;

/// HTTP server using Zig 0.16's std.Io networking.
pub const Server = struct {
    config: Config,
    handler: Handler,
    allocator: Allocator,
    active_connections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    shutdown_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ssl_ctx: if (tls_enabled) ?*tls.c.SSL_CTX else void = if (tls_enabled) null else {},

    pub fn init(allocator: Allocator, config: Config, handler: Handler) Server {
        return .{
            .config = config,
            .handler = handler,
            .allocator = allocator,
        };
    }

    /// Start listening and serving requests via the selected backend.
    pub fn listen(self: *Server, io: Io) !void {
        self.installSignalHandlers();

        // Initialize TLS context if configured
        if (tls_enabled) {
            if (self.config.tls) |tls_config| {
                self.ssl_ctx = tls.SslContext.initSslContext(
                    tls_config.cert_file,
                    tls_config.key_file,
                ) catch |err| {
                    std.log.err("Failed to initialize TLS: {}", .{err});
                    return err;
                };
                std.log.info("TLS enabled (HTTPS mode)", .{});
            }
        }
        defer if (tls_enabled) {
            if (self.ssl_ctx) |ctx| tls.SslContext.deinitSslContext(ctx);
        };

        // Delegate to the selected backend
        try SelectedBackend.listen(self, io);
    }

    /// Handle a single connection: set up reader/writer (plain or TLS),
    /// then run the shared request handler loop.
    pub fn handleConnection(self: *Server, io: Io, stream: *Io.net.Stream) void {
        defer stream.close(io);

        // Set write timeout so sends don't block indefinitely.
        // Read timeouts are handled via poll() in the request handler
        // to avoid EAGAIN panics in std.Io on macOS.
        setSocketTimeouts(stream.socket.handle, self.config);

        if (tls_enabled) {
            if (self.ssl_ctx) |ctx| {
                // TLS path
                const ssl = tls.SslContext.sslAccept(ctx, stream.socket.handle) catch |err| {
                    std.log.debug("TLS handshake failed: {}", .{err});
                    return;
                };
                defer tls.SslContext.sslFree(ssl);

                var read_buf: [16384]u8 = undefined;
                var tls_reader = tls.TlsReader.init(ssl, &read_buf);
                var write_buf: [16384]u8 = undefined;
                var tls_writer = tls.TlsWriter.init(ssl, &write_buf);

                request_handler.handleRequests(
                    self.config,
                    self.handler,
                    self.allocator,
                    &tls_reader.interface,
                    &tls_writer.interface,
                    &self.shutdown_flag,
                    stream.socket.handle,
                );
                return;
            }
        }

        // Plain TCP path
        var read_buf: [16384]u8 = undefined;
        var reader: Io.net.Stream.Reader = .init(stream.*, io, &read_buf);
        var write_buf: [16384]u8 = undefined;
        var writer: Io.net.Stream.Writer = .init(stream.*, io, &write_buf);

        request_handler.handleRequests(
            self.config,
            self.handler,
            self.allocator,
            &reader.interface,
            &writer.interface,
            &self.shutdown_flag,
            stream.socket.handle,
        );
    }

    /// Set SO_SNDTIMEO on a socket fd.
    /// Note: SO_RCVTIMEO is intentionally not set — on macOS, read timeouts
    /// cause EAGAIN which panics in std.Io. Read timeouts are handled via
    /// poll() in the request handler instead.
    fn setSocketTimeouts(fd: std.posix.fd_t, config: Config) void {
        const send_tv = msToTimeval(config.write_timeout_ms);
        std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, &std.mem.toBytes(send_tv)) catch {};
    }

    fn msToTimeval(ms: u32) std.posix.timeval {
        return .{
            .sec = @intCast(ms / 1000),
            .usec = @intCast(@as(u64, ms % 1000) * 1000),
        };
    }

    /// Install signal handlers for graceful shutdown (SIGINT, SIGTERM).
    pub fn installSignalHandlers(self: *Server) void {
        global_server = self;
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = signalHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
        std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    }

    /// Perform a graceful shutdown: run hooks, close channels, drain connections.
    pub fn shutdown(self: *Server) void {
        // Run user shutdown hooks
        for (self.config.shutdown_hooks) |hook| {
            if (hook) |h| h();
        }
        // Drain active HTTP connections
        self.drainConnections();
    }

    /// Wait for active connections to drain (up to configured timeout).
    pub fn drainConnections(self: *Server) void {
        const timeout_ns: i128 = @as(i128, self.config.drain_timeout_ms) * std.time.ns_per_ms;
        const start = getMonotonicNs();

        while (self.active_connections.load(.acquire) > 0) {
            if (getMonotonicNs() - start >= timeout_ns) {
                const remaining = self.active_connections.load(.acquire);
                std.log.warn("Shutdown timeout: {d} connections still active", .{remaining});
                return;
            }
            // Sleep 50ms between polls
            std.Thread.yield() catch {};
        }
    }

    fn getMonotonicNs() i128 {
        if (native_os == .linux) {
            const linux = std.os.linux;
            var ts: linux.timespec = undefined;
            _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
            return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
        } else {
            const c = std.c;
            var ts: c.timespec = undefined;
            _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
            return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
        }
    }
};

fn signalHandler(_: std.posix.SIG) callconv(.c) void {
    if (global_server) |s| s.shutdown_flag.store(true, .release);
}
