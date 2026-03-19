# zzz.zig

A Phoenix-inspired, batteries-included web framework written in Zig.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16.0-orange.svg)](https://ziglang.org/)

A fast, memory-safe web framework with compile-time route resolution, a rich middleware stack, WebSocket channels, and template rendering. Designed for developers who want Rails/Phoenix-level productivity with Zig-level performance.

## Features

- **HTTP Server** with optional TLS/HTTPS (OpenSSL)
- **Compile-time Router** with path/query params, scoping, and RESTful resources
- **20 Built-in Middleware** -- logging, CORS, compression, auth, rate limiting, CSRF, sessions, body parsing, static files, error handling, and more
- **WebSocket** support with frame encoding/decoding and HTTP upgrade
- **Phoenix-style Channels** with topic-based pub/sub, presence tracking, and a zzz.js client library
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

## Quick Start

```zig
const std = @import("std");
const zzz = @import("zzz");

fn index(ctx: *zzz.Context) !void {
    ctx.text(.ok, "Hello from zzz!");
}

const App = zzz.Router.define(.{
    .middleware = &.{zzz.logger},
    .routes = &.{
        zzz.Router.get("/", index),
    },
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var server = zzz.Server.init(gpa.allocator(), .{
        .port = 4000,
    }, &App.handler);

    std.log.info("Listening on http://127.0.0.1:4000", .{});
    try server.listen(std.io.defaultIo());
}
```

## Installation

Add zzz as a dependency in your `build.zig.zon`:

```zon
.dependencies = .{
    .zzz = .{
        .url = "https://github.com/seemsindie/zzz.zig/archive/<commit>.tar.gz",
        .hash = "<hash>",
    },
},
```

Then in your `build.zig`:

```zig
const zzz_dep = b.dependency("zzz", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zzz", zzz_dep.module("zzz"));
```

## Middleware

```zig
const App = zzz.Router.define(.{
    .middleware = &.{
        zzz.errorHandler(.{ .show_details = true }),
        zzz.logger,
        zzz.gzipCompress(.{}),
        zzz.requestId(.{}),
        zzz.cors(.{ .allow_origins = &.{"*"} }),
        zzz.bodyParser(.{}),
        zzz.session(.{}),
        zzz.csrf(.{}),
        zzz.staticFiles(.{ .root = "public", .prefix = "/static" }),
    },
    .routes = &.{ ... },
});
```

## Routing

```zig
const routes = &.{
    zzz.Router.get("/", index),
    zzz.Router.post("/users", createUser),
    zzz.Router.get("/users/:id", getUser),

    // RESTful resource
    zzz.Router.resource("/posts", .{
        .index = listPosts,
        .show = showPost,
        .create = createPost,
        .update = updatePost,
        .delete_handler = deletePost,
    }),

    // Scoped routes with middleware
    zzz.Router.scope("/api", .{
        .middleware = &.{ zzz.bearerAuth(.{ .validate = &myValidator }) },
    }, &.{
        zzz.Router.get("/me", currentUser),
    }),
};
```

## WebSocket & Channels

```zig
// WebSocket echo server
zzz.Router.websocket("/ws/echo", .{
    .on_text = &echoText,
});

// Phoenix-style channels
zzz.Router.channel("/socket", .{
    .channels = &.{
        .{ .topic_pattern = "room:*", .join = &handleJoin, .handlers = &.{
            .{ .event = "new_msg", .handler = &handleMessage },
        }},
    },
});
```

## Server-Sent Events (SSE)

```zig
fn sseHandler(ctx: *zzz.Context) !void {
    ctx.respond(.ok, "text/event-stream", "");
    // SSE headers set automatically by sseMiddleware
}

// In routes:
zzz.Router.scope("/events", &.{zzz.sseMiddleware(.{})}, &.{
    zzz.Router.get("", sseHandler),
}),
```

## Caching

```zig
const App = zzz.Router.define(.{
    .middleware = &.{
        zzz.cacheMiddleware(.{
            .cacheable_prefixes = &.{"/api/"},
            .default_ttl_s = 300,
        }),
        // ...other middleware
    },
    .routes = routes,
});

// Or use the generic cache directly:
var cache: zzz.Cache([]const u8) = .{};
cache.put("key", "value", 60_000); // 60s TTL
const val = cache.get("key");
```

## OpenAPI / Swagger

```zig
zzz.Router.get("/users", listUsers).doc(.{
    .summary = "List users",
    .description = "Returns all users",
    .tags = &.{"Users"},
    .security = &.{"bearerAuth"},
});

// Generate spec
const spec = zzz.swagger.generateSpec(.{
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

Full documentation available at [docs.zzz.indielab.link](https://docs.zzz.indielab.link).

## Ecosystem

### Core

| Package | Description |
|---------|-------------|
| [zzz.zig](https://github.com/seemsindie/zzz.zig) | A performant web framework for Zig |
| [zzz_db](https://github.com/seemsindie/zzz_db) | Database layer for Zig — schemas, queries, migrations, and connection pooling |
| [zzz_jobs](https://github.com/seemsindie/zzz_jobs) | Reliable background jobs for Zig — queues, retries, scheduling, and priorities |
| [zzz_mailer](https://github.com/seemsindie/zzz_mailer) | Email delivery for Zig — templates, attachments, and multi-provider support |
| [zzz_template](https://github.com/seemsindie/zzz_template) | Compile-time template engine for Zig with type-safe bindings |

### Tooling

| Package | Description |
|---------|-------------|
| [zzz_cli](https://github.com/seemsindie/zzz_cli) | Command-line toolkit for the zzz web framework |
| [zzz_docs](https://github.com/seemsindie/zzz_docs) | Documentation for the zzz web framework |
| [zzz_vscode](https://github.com/seemsindie/zzz_vscode) | Visual Studio Code extension for zzz template syntax |
| [homebrew-zzz](https://github.com/seemsindie/homebrew-zzz) | Homebrew formulae for the zzz CLI |
| [zzz_example_app](https://github.com/seemsindie/zzz_example_app) | Reference application showcasing the zzz web framework |
| [zzzworkspace](https://github.com/seemsindie/zzzworkspace) | Development workspace and tooling for the zzz ecosystem |

## Requirements

- Zig 0.16.0-dev.2905+5d71e3051 or later
- libc (linked automatically)
- OpenSSL 3 (optional, for TLS)

## License

MIT License -- Copyright (c) 2026 Ivan Stamenkovic
