const std = @import("std");
const pidgn = @import("pidgn");

const App = pidgn.Router.define(.{
    .middleware = &.{pidgn.logger},
    .routes = &.{
        pidgn.Router.get("/", indexHandler),
        pidgn.Router.get("/hello", helloHandler),
        pidgn.Router.get("/json", jsonHandler),
        pidgn.Router.get("/users/:id", userHandler),
    },
});

fn indexHandler(ctx: *pidgn.Context) !void {
    ctx.html(.ok,
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>Pidgn</title></head>
        \\<body>
        \\  <h1>Welcome to Pidgn</h1>
        \\  <p>The Zig web framework that never sleeps.</p>
        \\  <ul>
        \\    <li><a href="/hello">Hello</a></li>
        \\    <li><a href="/json">JSON Example</a></li>
        \\    <li><a href="/users/42">User 42</a></li>
        \\  </ul>
        \\</body>
        \\</html>
    );
}

fn helloHandler(ctx: *pidgn.Context) !void {
    ctx.text(.ok, "Hello from Pidgn!");
}

fn jsonHandler(ctx: *pidgn.Context) !void {
    ctx.json(.ok,
        \\{"framework": "pidgn", "version": "0.1.0", "status": "awake"}
    );
}

fn userHandler(ctx: *pidgn.Context) !void {
    const id = ctx.param("id") orelse "unknown";
    ctx.text(.ok, id);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var server = pidgn.Server.init(allocator, .{
        .host = "127.0.0.1",
        .port = 5555,
    }, App.handler);

    try server.listen(io);
}
