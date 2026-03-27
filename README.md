# pidgn

A Phoenix-inspired, batteries-included web framework written in Zig.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16.0-orange.svg)](https://ziglang.org/)

A fast, memory-safe web framework with compile-time route resolution, a rich middleware stack, WebSocket channels, and template rendering. Designed for developers who want Rails/Phoenix-level productivity with Zig-level performance.

## Features

- **HTTP Server** with optional TLS/HTTPS (OpenSSL)
- **Compile-time Router** with path/query params, scoping, and RESTful resources
- **20 Built-in Middleware** -- logging, CORS, compression, auth, rate limiting, CSRF, sessions, body parsing, static files, error handling, and more
- **WebSocket** support with frame encoding/decoding and HTTP upgrade
- **Phoenix-style Channels** with topic-based pub/sub, presence tracking, and a pidgn.js client library
- **Template Engine** with layouts, partials, and XSS-safe HTML escaping
- **OpenAPI/Swagger** spec generation from route annotations with Swagger UI
- **Observability** -- structured logging, request IDs, metrics (Prometheus), telemetry hooks, health checks
- **Authentication** -- Bearer, Basic, and JWT (HS256) middleware
- **htmx Integration** with request detection and response helpers
- **Testing Utilities** -- HTTP test client, WebSocket helpers, assertions
- **High-performance I/O** -- native thread pool with platform-optimized backends via libhv
- **In-Memory Cache** with TTL, response cache middleware, and `X-Cache` headers
- **Server-Sent Events (SSE)** with `SseWriter` for real-time streaming
- **Graceful Shutdown** with configurable drain timeout and shutdown hooks
- **Channel Rate Limiting** via token bucket (per-socket message throttling)
- **SSR Bridge** for server-side rendering React components via Bun subprocesses
- **Live Reload** with CSS hot-swap and automatic browser refresh via WebSocket
- **Asset Pipeline** with Bun bundling, minification, fingerprinting, and manifest-based cache busting

## Quick Start

```zig
const std = @import("std");
const pidgn = @import("pidgn");

fn index(ctx: *pidgn.Context) !void {
    ctx.text(.ok, "Hello from pidgn!");
}

const App = pidgn.Router.define(.{
    .middleware = &.{pidgn.logger},
    .routes = &.{
        pidgn.Router.get("/", index),
    },
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var server = pidgn.Server.init(gpa.allocator(), .{
        .port = 4000,
    }, &App.handler);

    std.log.info("Listening on http://127.0.0.1:4000", .{});
    try server.listen(std.io.defaultIo());
}
```

## Installation

Add pidgn as a dependency in your `build.zig.zon`:

```zon
.dependencies = .{
    .pidgn = .{
        .url = "https://github.com/seemsindie/pidgn/archive/<commit>.tar.gz",
        .hash = "<hash>",
    },
},
```

Then in your `build.zig`:

```zig
const pidgn_dep = b.dependency("pidgn", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("pidgn", pidgn_dep.module("pidgn"));
```

## Middleware

```zig
const App = pidgn.Router.define(.{
    .middleware = &.{
        pidgn.errorHandler(.{ .show_details = true }),
        pidgn.logger,
        pidgn.gzipCompress(.{}),
        pidgn.requestId(.{}),
        pidgn.cors(.{ .allow_origins = &.{"*"} }),
        pidgn.bodyParser(.{}),
        pidgn.session(.{}),
        pidgn.csrf(.{}),
        pidgn.staticFiles(.{ .root = "public", .prefix = "/static" }),
    },
    .routes = &.{ ... },
});
```

## Routing

```zig
const routes = &.{
    pidgn.Router.get("/", index),
    pidgn.Router.post("/users", createUser),
    pidgn.Router.get("/users/:id", getUser),

    // RESTful resource
    pidgn.Router.resource("/posts", .{
        .index = listPosts,
        .show = showPost,
        .create = createPost,
        .update = updatePost,
        .delete_handler = deletePost,
    }),

    // Scoped routes with middleware
    pidgn.Router.scope("/api", .{
        .middleware = &.{ pidgn.bearerAuth(.{ .validate = &myValidator }) },
    }, &.{
        pidgn.Router.get("/me", currentUser),
    }),
};
```

## WebSocket & Channels

```zig
// WebSocket echo server
pidgn.Router.websocket("/ws/echo", .{
    .on_text = &echoText,
});

// Phoenix-style channels
pidgn.Router.channel("/socket", .{
    .channels = &.{
        .{ .topic_pattern = "room:*", .join = &handleJoin, .handlers = &.{
            .{ .event = "new_msg", .handler = &handleMessage },
        }},
    },
});
```

## Server-Sent Events (SSE)

```zig
fn sseHandler(ctx: *pidgn.Context) !void {
    ctx.respond(.ok, "text/event-stream", "");
    // SSE headers set automatically by sseMiddleware
}

// In routes:
pidgn.Router.scope("/events", &.{pidgn.sseMiddleware(.{})}, &.{
    pidgn.Router.get("", sseHandler),
}),
```

## Caching

```zig
const App = pidgn.Router.define(.{
    .middleware = &.{
        pidgn.cacheMiddleware(.{
            .cacheable_prefixes = &.{"/api/"},
            .default_ttl_s = 300,
        }),
        // ...other middleware
    },
    .routes = routes,
});

// Or use the generic cache directly:
var cache: pidgn.Cache([]const u8) = .{};
cache.put("key", "value", 60_000); // 60s TTL
const val = cache.get("key");
```

## OpenAPI / Swagger

```zig
pidgn.Router.get("/users", listUsers).doc(.{
    .summary = "List users",
    .description = "Returns all users",
    .tags = &.{"Users"},
    .security = &.{"bearerAuth"},
});

// Generate spec
const spec = pidgn.swagger.generateSpec(.{
    .title = "My API",
    .version = "1.0.0",
    .security_schemes = &.{
        .{ .name = "bearerAuth", .type = .http, .scheme = "bearer" },
    },
}, routes);
```

## Building

```bash
zig build        # Build
zig build test   # Run tests (281 tests)
zig build run    # Run the server

# With TLS
zig build -Dtls=true
```

## Documentation

Full documentation available at [docs.pidgn.indielab.link](https://docs.pidgn.indielab.link).

## Ecosystem

### Core

| Package | Description |
|---------|-------------|
| [pidgn](https://github.com/seemsindie/pidgn) | A performant web framework for Zig |
| [pidgn_db](https://github.com/seemsindie/pidgn_db) | Database layer for Zig — schemas, queries, migrations, and connection pooling |
| [pidgn_jobs](https://github.com/seemsindie/pidgn_jobs) | Reliable background jobs for Zig — queues, retries, scheduling, and priorities |
| [pidgn_mailer](https://github.com/seemsindie/pidgn_mailer) | Email delivery for Zig — templates, attachments, and multi-provider support |
| [pidgn_template](https://github.com/seemsindie/pidgn_template) | Compile-time template engine for Zig with type-safe bindings |

### Tooling

| Package | Description |
|---------|-------------|
| [pidgn_cli](https://github.com/seemsindie/pidgn_cli) | Command-line toolkit for the pidgn web framework |
| [pidgn_docs](https://github.com/seemsindie/pidgn_docs) | Documentation for the pidgn web framework |
| [pidgn_vscode](https://github.com/seemsindie/pidgn_vscode) | Visual Studio Code extension for pidgn template syntax |
| [homebrew-pidgn](https://github.com/seemsindie/homebrew-pidgn) | Homebrew formulae for the pidgn CLI |
| [pidgn_example_app](https://github.com/seemsindie/pidgn_example_app) | Reference application showcasing the pidgn web framework |
| [pidgnworkspace](https://github.com/seemsindie/pidgnworkspace) | Development workspace and tooling for the pidgn ecosystem |

## Requirements

- Zig 0.16.0-dev.2905+5d71e3051 or later
- libc (linked automatically)
- OpenSSL 3 (optional, for TLS)

## License

MIT License -- Copyright (c) 2026 Ivan Stamenkovic
