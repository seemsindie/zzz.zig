const std = @import("std");
const Allocator = std.mem.Allocator;

extern "c" fn system(command: [*:0]const u8) c_int;

/// Configuration for the SSR pool.
pub const SsrConfig = struct {
    /// Path to the SSR worker script (e.g., "assets/ssr-worker.js").
    worker_script: []const u8 = "assets/ssr-worker.js",
    /// Number of worker processes.
    pool_size: u8 = 4,
    /// Timeout in milliseconds for a render call.
    timeout_ms: u32 = 5000,
};

/// A pool of SSR worker subprocesses.
pub const SsrPool = struct {
    workers: [max_workers]Worker = undefined,
    active_count: u8 = 0,
    config: SsrConfig,
    allocator: Allocator,
    next_worker: u8 = 0,
    mutex: std.atomic.Mutex = .unlocked,

    const max_workers = 8;

    const Worker = struct {
        alive: bool = false,
        busy: bool = false,
        // We store the command to restart workers
        script_path: []const u8 = "",
    };

    /// Initialize the SSR pool. Does not start workers immediately —
    /// workers are started lazily on first render call.
    pub fn init(allocator: Allocator, config: SsrConfig) SsrPool {
        return .{
            .config = config,
            .allocator = allocator,
            .active_count = 0,
        };
    }

    /// Render a component with the given props JSON.
    /// Returns the rendered HTML string (caller owns the memory).
    ///
    /// This uses a synchronous subprocess approach: spawns `bun run <script>`,
    /// writes the render request to stdin, reads HTML from stdout.
    /// Each render call is isolated (no persistent workers), which is simpler
    /// and more robust at the cost of per-request process overhead.
    pub fn render(self: *SsrPool, component: []const u8, props_json: []const u8) ![]const u8 {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        // Build the JSON request: {"component":"Name","props":{...}}
        var req_buf: [4096]u8 = undefined;
        const request = std.fmt.bufPrint(&req_buf,
            \\{{"component":"{s}","props":{s}}}
        , .{ component, props_json }) catch return error.RequestTooLarge;

        // Build a one-shot script that requires the component and renders it
        var script_buf: [8192]u8 = undefined;
        const script = std.fmt.bufPrint(&script_buf,
            \\const {{ renderToString }} = require("react-dom/server");
            \\const {{ createElement }} = require("react");
            \\const input = {s};
            \\const Component = require("./{s}/components/" + input.component + ".jsx").default;
            \\const html = renderToString(createElement(Component, input.props));
            \\process.stdout.write(html);
        , .{ request, self.config.worker_script[0..std.mem.lastIndexOf(u8, self.config.worker_script, "/") orelse 0] }) catch return error.ScriptTooLarge;

        // Spawn bun to execute the script
        _ = script;

        // For the initial implementation, use a simpler approach:
        // Write request to a temp file and have bun evaluate it
        return self.renderViaProcess(request);
    }

    fn renderViaProcess(self: *SsrPool, request: []const u8) ![]const u8 {
        // Build inline script for Bun
        var script_buf: [8192]u8 = undefined;
        const script_path_dir = if (std.mem.lastIndexOf(u8, self.config.worker_script, "/")) |idx|
            self.config.worker_script[0..idx]
        else
            ".";

        const script = std.fmt.bufPrint(&script_buf,
            \\try {{
            \\  const {{ renderToString }} = require("react-dom/server");
            \\  const {{ createElement }} = require("react");
            \\  const input = {s};
            \\  const mod = require("./{s}/components/" + input.component + ".jsx");
            \\  const Component = mod.default || mod;
            \\  const html = renderToString(createElement(Component, input.props));
            \\  process.stdout.write(html);
            \\}} catch(e) {{
            \\  process.stdout.write("<div>SSR Error: " + e.message + "</div>");
            \\  process.exit(1);
            \\}}
        , .{ request, script_path_dir }) catch return error.ScriptTooLarge;

        // Use system() to run bun and capture output
        // For proper implementation, we'd use child process with pipes
        // For now, write to temp file and read back
        const tmp_script = "/tmp/pidgn-ssr-render.js";
        const tmp_output = "/tmp/pidgn-ssr-output.html";

        // Write script
        writeTmpFile(tmp_script, script);

        // Run: bun run /tmp/pidgn-ssr-render.js > /tmp/pidgn-ssr-output.html
        var cmd_buf: [512]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "bun run {s} > {s} 2>/dev/null", .{ tmp_script, tmp_output }) catch return error.CommandTooLong;

        var cmd_z: [512]u8 = undefined;
        @memcpy(cmd_z[0..cmd.len], cmd);
        cmd_z[cmd.len] = 0;

        const ret = system(@ptrCast(cmd_z[0..cmd.len :0]));
        _ = ret;

        // Read output
        return self.readTmpOutput(tmp_output);
    }

    fn readTmpOutput(self: *SsrPool, path: []const u8) ![]const u8 {
        const c = std.c;
        var path_buf: [256]u8 = undefined;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        const fd = c.open(@ptrCast(path_buf[0..path.len :0]), .{}, @as(c.mode_t, 0));
        if (fd < 0) return error.FileNotFound;
        defer _ = c.close(fd);

        // Read up to 64KB
        const buf = try self.allocator.alloc(u8, 65536);
        errdefer self.allocator.free(buf);

        var total: usize = 0;
        while (total < buf.len) {
            const n = c.read(fd, buf[total..].ptr, buf.len - total);
            if (n <= 0) break;
            total += @intCast(n);
        }

        if (total == 0) {
            self.allocator.free(buf);
            return error.EmptyResponse;
        }

        // Shrink to actual size
        if (total < buf.len) {
            const result = self.allocator.realloc(buf, total) catch buf;
            return result[0..total];
        }
        return buf[0..total];
    }

    fn writeTmpFile(path: []const u8, content: []const u8) void {
        const c = std.c;
        var path_buf: [256]u8 = undefined;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        const fd = c.open(@ptrCast(path_buf[0..path.len :0]), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o644));
        if (fd < 0) return;
        defer _ = c.close(fd);

        var written: usize = 0;
        while (written < content.len) {
            const n = c.write(fd, content[written..].ptr, content.len - written);
            if (n <= 0) break;
            written += @intCast(n);
        }
    }

    /// Clean up the pool (no-op for now since we use one-shot processes).
    pub fn deinit(self: *SsrPool) void {
        _ = self;
    }
};
