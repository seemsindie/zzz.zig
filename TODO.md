# Zzz - Project TODO Tracker

## Quick Start

```bash
# Build the project
cd /Users/ivan/projects/zigweb_workspace/zzz
zig build

# Run the server
zig build run
# Server starts at http://127.0.0.1:5555

# Run all tests
zig build test

# Test with curl (in another terminal)
curl http://127.0.0.1:5555/              # HTML welcome page
curl http://127.0.0.1:5555/hello         # Plain text
curl http://127.0.0.1:5555/json          # JSON response
curl http://127.0.0.1:5555/users/42      # Path param extraction
curl http://127.0.0.1:5555/missing       # 404 Not Found
curl -X POST http://127.0.0.1:5555/hello # 405 Method Not Allowed
curl -I http://127.0.0.1:5555/hello      # HEAD (headers only, no body)

# Build optimized release
zig build -Doptimize=ReleaseFast

# Run with arguments
zig build run -- --some-arg
```

---

## Phase 1: Foundation (TCP Server + HTTP/1.1)

- [x] Initialize Zig project with build.zig / build.zig.zon
- [x] Git repository initialized
- [x] Project directory structure created
- [x] HTTP status codes enum with reason phrases (`src/core/http/status.zig`)
- [x] HTTP headers storage with case-insensitive lookup (`src/core/http/headers.zig`)
- [x] HTTP request type with method, path, query, body, version (`src/core/http/request.zig`)
- [x] HTTP method enum (GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS, CONNECT, TRACE)
- [x] Zero-copy HTTP/1.1 request parser (`src/core/http/parser.zig`)
- [x] HTTP response builder with .html(), .json(), .text(), .redirect(), .empty() (`src/core/http/response.zig`)
- [x] Response serialization to bytes
- [x] TCP server using Zig 0.16 std.Io networking (`src/core/server.zig`)
- [x] Accept loop with connection handling
- [x] Request body reading (Content-Length based)
- [x] Example app with 4 routes (`src/main.zig`)
- [x] All tests passing (10/10)
- [x] Chunked transfer encoding (request reading)
- [x] Chunked transfer encoding (response streaming)
- [x] Keep-alive connection reuse (currently closes after each response)
- [x] Configurable request size limits
- [x] Configurable read/write timeouts
- [x] Graceful shutdown (signal handling)
- [x] Multi-threaded accept (worker thread pool)
- [x] Connection backpressure / max connections limit
- [x] HTTP/1.0 compatibility mode
- [x] 100-continue handling

## Phase 1.5: TLS / HTTPS

- [x] OpenSSL integration via @cImport
- [x] SSL context creation and certificate loading
- [x] TLS handshake wrapping TCP streams
- [x] HTTPS server mode (listen on port 443 / custom)
- [ ] SNI (Server Name Indication) support
- [x] TLS 1.2 and 1.3 support
- [ ] Certificate auto-reload on file change
- [x] Self-signed cert generation for development

---

## Phase 2: Router & Middleware Pipeline

### Router
- [x] Route definition types (method + path + handler) (`src/router/router.zig` — `RouteDef`)
- [x] Comptime route compilation (pattern -> segments at compile time) (`src/router/route.zig`)
- [x] Path parameter extraction (`:id`, `:slug`) (`src/router/route.zig` — `matchSegments`)
- [x] Wildcard path matching (`*path`) (`src/router/route.zig` — `Segment.wildcard`)
- [x] HTTP method dispatch (GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS) (`src/router/router.zig`)
- [x] Route groups / scopes with shared middleware (`Router.scope()`)
- [x] RESTful resource helper (auto-generates index/show/create/update/delete)
- [x] Nested route scopes (via `Router.scope()` prefix concatenation)
- [x] Route naming for reverse URL generation
- [x] Comptime route validation (catch missing handlers at compile time)
- [x] 405 Method Not Allowed (path matches but wrong method, with `Allow` header)
- [x] OPTIONS route helper + CORS preflight handling (`Router.options()` + `cors.zig`)
- [x] HEAD auto-handling (GET without body)

### Middleware Pipeline
- [x] HandlerFn type (`*const fn (*Context) anyerror!void`) (`src/middleware/context.zig`)
- [x] Context struct (request + response + assigns + params + query) (`src/middleware/context.zig`)
- [x] Comptime middleware chain builder (`makePipelineEntry`/`makePipelineStep` in `router.zig`)
- [x] ctx.next() to call next middleware in chain
- [x] Assigns: fixed-size key-value store on context (like Phoenix conn.assigns)
- [x] Params: fixed-size key-value store for path params (zero-allocation)
- [x] Query string parsing into params

### Built-in Middleware
- [x] Logger middleware (method, path, status, timing) (`src/middleware/logger.zig`)
- [x] Static file serving (directory, MIME detection, ETag, caching headers) (`src/middleware/static.zig`)
- [x] CORS middleware (configurable origins, methods, headers) (`src/middleware/cors.zig`)
- [x] Body parser: JSON (application/json)
- [x] Body parser: URL-encoded (application/x-www-form-urlencoded)
- [x] Body parser: Multipart form data (file uploads)
- [x] Body parser: text/* and binary fallback
- [x] Unified `ctx.param()` (path -> body -> query, Phoenix-style)
- [x] `ctx.pathParam()`, `ctx.formValue()`, `ctx.jsonBody()`, `ctx.rawBody()`, `ctx.file()`
- [x] `FormData` fixed-size key-value store (32 fields)
- [x] `FilePart` / `MultipartData` types for file uploads
- [x] `urlDecode()` percent-encoding decoder
- [x] CSRF protection (token generation/validation)
- [x] Session middleware (cookie-based, pluggable stores)
- [x] gzip/deflate response compression
- [x] Rate limiting (token bucket per IP/key)
- [x] Auth: Bearer token extraction
- [x] Auth: Basic auth
- [x] Auth: JWT verification
- [x] Global error handler middleware (catch panics, render error pages)

### Controller Helpers
- [x] json() response helper (`ctx.json()`)
- [x] html() response helper (`ctx.html()`)
- [x] text() response helper (`ctx.text()`)
- [x] respond() generic helper with content type (`ctx.respond()`)
- [x] redirect() helper on Context
- [x] send_file() for file downloads
- [x] set_cookie() / delete_cookie()

---

## Phase 3: Template Engine & View Layer

### Core Engine
- [x] Template file format (.zzz or .html.zzz extension)
- [x] Template lexer (tokenize template syntax)
- [x] Template AST parser
- [x] Comptime template compilation (templates -> Zig render functions)
- [x] Build.zig integration (compile templates during build)
- [x] Auto HTML escaping (XSS protection by default)
- [x] Triple-brace {{{ }}} for raw/unescaped output

### Template Syntax
- [x] Variable interpolation: `{{name}}`
- [x] Dot notation: `{{user.name}}`
- [x] Conditionals: `{{#if}}` / `{{else}}` / `{{/if}}`
- [x] Iteration: `{{#each items as |item|}}` / `{{/each}}`
- [x] With blocks: `{{#with user}}` / `{{/with}}`
- [x] Comments: `{{! this is a comment }}`
- [x] Raw blocks: `{{{{raw}}}}` (no processing)

### Layout System
- [x] Layout templates with `{{yield}}` blocks
- [ ] Nested layouts
- [x] Named yield blocks (header, footer, sidebar)
- [ ] Layout selection per controller/action

### Partials & Components
- [x] Partial inclusion: `{{> partials/header}}`
- [x] Partial with arguments: `{{> button type="primary"}}`
- [ ] Component blocks: `{{#component "card"}}...{{/component}}`
- [ ] Slot support for components

### Built-in Helpers (Pipe Syntax)
- [x] `{{created_at | format_date:"YYYY-MM-DD"}}` — pipe syntax with format_date
- [x] `{{title | truncate:20}}` — pipe syntax with truncate
- [x] `{{count | pluralize:"item":"items"}}` — pipe syntax with pluralize
- [x] `{{name | upper}}`, `{{name | lower}}` — case pipes
- [x] `{{name | default:"N/A"}}` — default pipe
- [x] Integer rendering: `{{count}}` with integer types
- [x] `App.urlFor(allocator, "user_path", &params)` — runtime URL generation from route names
- [x] Custom helper registration — built-in pipe system (truncate, upper, lower, default, pluralize)

### htmx Integration (Built-in)
- [x] htmx request detection (`ctx.isHtmx()` — checks `HX-Request` header)
- [x] htmx response headers helper (`ctx.htmxTrigger()`, `ctx.htmxPushUrl()`, `ctx.htmxRedirect()`, `ctx.htmxReswap()`, `ctx.htmxRetarget()`)
- [x] Partial rendering mode — render a template fragment instead of full page when htmx request detected
- [x] `ctx.htmxRedirect()` — uses `HX-Redirect` header instead of 301/302 for htmx requests
- [x] Configurable htmx.js serving (`htmx_cdn_version` config, `htmx_script` assign, `ctx.htmxScriptTag()`)
- [x] Out-of-band swap support (`ctx.htmxTriggerAfterSwap()`, `ctx.htmxTriggerAfterSettle()`)
- [x] htmx middleware — auto-detect htmx requests and set `ctx.assigns.is_htmx`
- [x] Template helpers for htmx attributes — htmx attributes are plain HTML (`hx-get="/path"`) which works directly in templates
- [x] Example: htmx-powered CRUD app (todo list with add/delete via htmx partials)

### React/Vue/Svelte SSR Bridge (Future)
- [ ] Shell out to Node/Deno/Bun for initial render
- [ ] Pass props as JSON, receive rendered HTML
- [ ] Hydration script injection
- [ ] Embedded QuickJS option for in-process JS
- [ ] SSR mode flag in router config (`.ssr = .{ .engine = .node, .entry = "src/App.tsx" }`)
- [ ] API-only mode for SPA backends (JSON routes + CORS, no templates)

---

## Phase 4: WebSocket & zzz.js Client Library

### WebSocket Protocol
- [x] RFC 6455 implementation (`src/core/websocket/frame.zig`)
- [x] HTTP -> WebSocket upgrade handshake (`src/core/websocket/handshake.zig`)
- [x] Frame encoding (text, binary, ping, pong, close) (`frame.zig`)
- [x] Frame decoding with masking/unmasking (`frame.zig`)
- [x] Fragmented message reassembly (`src/core/websocket/connection.zig`)
- [x] Per-message compression (permessage-deflate)
- [x] Ping/pong heartbeat keepalive (`connection.zig` — auto-pong)
- [x] Clean close handshake (`connection.zig`)
- [x] WebSocket URL routing (`Router.ws()`, `src/middleware/websocket.zig`)

### zzz.js Client Library
- [x] WebSocket connect with auto-reconnect and exponential backoff (`src/js/zzz.js`)
- [x] fetch() wrapper with auto CSRF token (`zzz.js`)
- [x] AJAX form submission helper (`zzz.js`)
- [x] zzz.js serving middleware at `/__zzz/zzz.js` (`src/middleware/zzz_js.zig`)
- [x] Example WebSocket echo demo page (`zzz_example_app/src/templates/ws_demo.html.zzz`)

### Server Integration
- [x] Response WebSocketUpgrade struct (`src/core/http/response.zig`)
- [x] Server processRequest WebSocket upgrade path (`src/core/server.zig`)
- [x] WebSocket module re-exports (`src/core/websocket/websocket.zig`)
- [x] Root module exports (WebSocket, WsMessage, WsConfig, zzzJs)

## Phase 4b: Channel System

### Channel System (Phoenix-style)
- [x] Channel definition (topic pattern + join/leave/handle_in)
- [x] Topic-based PubSub (in-process)
- [x] Channel join with authorization
- [x] Incoming message handlers (event name -> handler)
- [x] Broadcast to all subscribers of a topic
- [x] Push messages to specific socket
- [x] Channel reply messages
- [x] Channel leave / disconnect handling
- [x] Heartbeat monitoring per socket

### Presence
- [x] Presence tracking (who's in which topic)
- [x] Presence join/leave events
- [x] Presence list with metadata
- [x] Presence diff tracking (efficient updates)

### PubSub
- [x] In-process PubSub (single node)
- [x] Subscribe/unsubscribe to topics
- [x] Broadcast to topic
- [x] Direct message to specific subscriber
- [ ] Distributed PubSub (multi-node, future)

---

## Phase 5: Database Layer (zzz_db)

### Connection & Pooling
- [x] Initialize zzz_db as separate package in workspace
- [x] PostgreSQL adapter via libpq (@cImport)
- [x] SQLite adapter via sqlite3 (@cImport)
- [x] Connection pool (configurable size, checkout/checkin)
- [x] Connection health checks
- [x] Auto-reconnection on connection loss
- [x] Connection timeout handling

### Schema Definition
- [x] Comptime schema definition (struct -> table mapping)
- [x] Field types mapping (Zig types -> SQL types)
- [x] Primary key declaration
- [x] Timestamps (inserted_at, updated_at) auto-fields
- [x] has_many association
- [x] belongs_to association
- [x] has_one association
- [x] many_to_many association (join table)
- [x] Virtual/computed fields

### Query Builder
- [x] SELECT builder with field selection
- [x] WHERE clauses (=, !=, >, <, >=, <=, LIKE, IS NULL)
- [x] AND/OR composition
- [x] ORDER BY (asc/desc, multiple fields)
- [x] LIMIT / OFFSET
- [x] JOIN (inner, left, right, full)
- [x] GROUP BY / HAVING
- [x] COUNT, SUM, AVG, MIN, MAX aggregates
- [x] Subqueries (via whereRaw)
- [x] Raw SQL fragments
- [x] Query composition (via merge)
- [x] Preloading associations

### Repo Operations
- [x] Repo.all(query) -> []T
- [x] Repo.one(query) -> ?T
- [x] Repo.get(Schema, id) -> ?T
- [x] Repo.insert(changeset) -> T
- [x] Repo.update(changeset) -> T
- [x] Repo.delete(record) -> void
- [x] Repo.aggregate(query, :count/:sum/etc)
- [x] Repo.exists?(query) -> bool
- [x] Repo.transaction(fn) -> result
- [x] Repo.rawAll(T, sql, params) -> []T (raw SQL mapped to structs)
- [x] Repo.rawOne(T, sql, params) -> ?T (raw SQL, first row)
- [x] Repo.rawExec(sql, params) -> ExecResult (raw INSERT/UPDATE/DELETE)

### Changesets
- [x] Changeset creation from params
- [x] cast() - whitelist allowed fields
- [x] validate_required() - required fields
- [x] validate_format() - substring validation
- [x] validate_length() - min/max string length
- [x] validate_number() - min/max numeric range
- [x] validate_inclusion() - value in list
- [x] validate_exclusion() - value not in list
- [x] unique_constraint() - database unique check (deferred)
- [x] foreign_key_constraint() (deferred)
- [x] custom validators
- [x] Error messages (per field, per validation)
- [x] Changeset.valid() -> bool

### Migrations
- [x] Migration file format (up/down functions)
- [x] create_table with column definitions
- [x] alter_table (add/remove/rename columns)
- [x] drop_table
- [x] create_index / drop_index
- [x] add_foreign_key / remove_foreign_key
- [x] Migration runner (apply pending migrations)
- [x] Migration rollback (revert last N migrations)
- [x] Migration status tracking (schema_migrations table)
- [x] Migration file generator (manual convention: YYYYMMDDHHMMSS)

### Transactions
- [x] Begin/commit/rollback
- [x] Nested transactions (savepoints)
- [x] Transaction isolation levels

---

## Phase 6: Background Jobs (zzz_jobs)

### Core
- [x] Initialize zzz_jobs as separate package in workspace
- [x] Job definition type (name, args struct, options)
- [x] Job states: available -> executing -> completed / retryable / discarded
- [x] Job insertion (enqueue)
- [x] Scheduled jobs (run at specific time)
- [x] Job priority levels

### Queue System
- [x] In-memory queue (for dev/testing)
- [x] Database-backed queue (uses zzz_db, for production)
- [x] Named queues (e.g., "default", "mailers", "reports")
- [x] Configurable concurrency per queue
- [x] FIFO ordering within priority level
- [x] Queue pausing/resuming

### Worker Management
- [x] Worker thread pool
- [x] Configurable worker count per queue
- [x] Worker heartbeat monitoring
- [x] Graceful shutdown (finish current jobs, stop accepting new)
- [x] Worker crash recovery

### Retry & Error Handling
- [x] Configurable max attempts per job
- [x] Exponential backoff with jitter
- [x] Custom retry strategies
- [x] Dead letter queue (permanently failed jobs)
- [x] Error callbacks / telemetry hooks
- [x] Job timeout (kill long-running jobs)

### Scheduling (Cron)
- [x] Cron expression parser
- [x] Recurring job definitions
- [x] Cron job registration at startup
- [x] Timezone support (`matchesWithOffset`, `nextAfterWithOffset`, `initWithTimezone`)

### Unique Jobs
- [x] Unique constraints (prevent duplicate jobs)
- [x] Unique by: args, queue, worker, period
- [x] Replace strategy (cancel existing, ignore new)

### Telemetry
- [x] Job start/complete/fail events
- [x] Queue depth metrics
- [x] Worker utilization metrics
- [x] Job duration tracking

---

## Phase 7: Swagger / OpenAPI

### Schema Generation
- [x] Comptime Zig struct -> JSON Schema conversion (`src/swagger/schema.zig`)
- [x] Type mapping (i32->integer, []const u8->string, bool->boolean, etc.)
- [x] Optional type handling (?T -> nullable)
- [x] Array type handling ([]T -> array)
- [x] Nested struct handling (-> object)
- [x] Enum -> enum schema

### Route Documentation
- [x] Route annotation types (summary, description, tags) (`ApiDoc` on `RouteDef`)
- [x] Path parameter schemas (auto-extracted from `:param` patterns)
- [x] Query parameter schemas (`QueryParamDoc`)
- [x] Request body schemas (via `.doc(.{ .request_body = T })`)
- [x] Response schemas (via `.doc(.{ .response_body = T })`)
- [x] Auto-detection from handler function signatures (comptime)

### OpenAPI Spec Generation
- [x] OpenAPI 3.1.0 JSON output (`src/swagger/spec.zig`)
- [x] Info section (title, version, description)
- [x] Paths section (from router)
- [x] Components/schemas section (from Zig types)
- [x] Tags grouping
- [x] Security schemes (Bearer, Basic, API key)
- [x] Serve spec at configurable endpoint (`/api/docs/openapi.json`)

### Swagger UI
- [x] Swagger UI via CDN (`src/swagger/middleware.zig`)
- [x] Serve Swagger UI at /api/docs
- [x] Auto-configure with generated spec URL
- [x] Configurable path and CDN version

### Controller System
- [x] `Controller.define()` — first-class controller type with prefix, tag, middleware
- [x] Auto-prefix patterns, auto-tag swagger docs, shared middleware
- [x] Composable with `++` and `Router.scope()`
- [x] Example app refactored into 10 controller modules

---

## Phase 8: Testing Framework & CLI

### HTTP Test Client
- [x] TestClient that sends requests to router without network (`src/testing/client.zig`)
- [x] GET/POST/PUT/PATCH/DELETE helpers
- [x] Request header setting (default headers + per-request via RequestBuilder)
- [x] JSON body helper (`postJson`, `putJson`, `patchJson`)
- [x] Multipart body helper (file upload testing) (`src/testing/multipart.zig`)
- [x] Response status assertions (`expectOk`, `expectCreated`, `expectNotFound`, etc.)
- [x] Response header assertions (`expectHeader`, `expectHeaderContains`, `expectHeaderExists`)
- [x] Response body assertions (`expectBody`, `expectBodyContains`, `expectEmptyBody`)
- [x] JSON path assertions (`expectJson("field", "value")`, `expectJsonContains`)
- [x] Cookie assertions (`expectCookie`, `expectCookieValue`) + CookieJar (`src/testing/cookie_jar.zig`)
- [x] Redirect following (auto-follow 301/302/303/307/308 with configurable max)

### WebSocket Test Client
- [x] TestChannel for channel-level testing (`src/testing/ws_client.zig`)
- [x] Channel join/leave
- [x] Push messages
- [x] Expect reply (`expectPush`)
- [x] Broadcast assertions (`expectBroadcast`)

### Database Testing
- [x] Test transaction sandboxing (auto-rollback per test) (`zzz_db/src/testing.zig` — `TestSandbox`)
- [x] Parallel test execution support
- [x] Factory/fixture helpers for test data (`Factory`)
- [x] Database seeding (`seed`)

### CLI Tool (zzz_cli)
- [x] Initialize zzz_cli as separate package in workspace
- [x] `zzz new my_app` - scaffold a new project
- [x] `zzz server` - start development server with auto-reload
- [ ] `zzz server` - file watching with swatcher (watch src/ + templates/ + public/, rebuild on change)
- [x] `zzz routes` - list all registered routes
- [x] `zzz migrate` - run pending migrations
- [x] `zzz migrate rollback` - rollback last migration
- [x] `zzz migrate status` - show migration status
- [x] `zzz gen controller Name` - generate controller boilerplate
- [x] `zzz gen model Name field:type` - generate model + migration
- [x] `zzz gen channel Name` - generate channel boilerplate
- [x] `zzz swagger` - generate/export OpenAPI spec
- [x] `zzz test` - run tests with framework helpers
- [x] `zzz deps` - manage dependencies

---

## Cross-Cutting Concerns

### Performance
- [x] Benchmark suite (`zig build bench` + `bench/run_bench.sh` with wrk/hey)
- [ ] Compare against other Zig frameworks (http.zig, zap, jetzig)
- [ ] Memory usage profiling
- [ ] Connection pooling optimization
- [ ] Zero-allocation hot paths

### Build System — Vendored Dependencies
- [ ] Clone and build SQLite from source instead of linkSystemLibrary("sqlite3")
- [ ] Clone and build libpq from source instead of linkSystemLibrary("pq")
- [ ] Clone and build OpenSSL from source instead of linkSystemLibrary("ssl"/"crypto")
- [ ] Clone swatcher from source for zzz_cli file watching
- [ ] Remove all Homebrew/system include/library path hardcoding from build.zig files
- [ ] All deps self-contained — `zig build` works on a fresh machine with no system libraries

### Observability
- [x] Structured logging (configurable levels, JSON output)
- [x] Request ID generation and propagation
- [x] Telemetry hooks (request start/end, DB query, job execution)
- [x] Metrics collection (counters, histograms, gauges)
- [x] Health check endpoint

### Documentation
_(Moved to Phase 9: Release Preparation)_

### CI / Packaging
_(Moved to Phase 9: Release Preparation)_

---

## Phase 9: Release Preparation (v0.1.0)

### Version & Tagging
- [x] Bump zzz version from 0.0.0 to 0.1.0 in build.zig.zon
- [x] Align all package versions to 0.1.0 (zzz, zzz_db, zzz_jobs, zzz_cli)
- [x] Create git tags (v0.1.0) in all repositories
- [x] Create GitHub Releases with release notes for each repo
- [x] CHANGELOG.md for each package (initial release)

### README & Project Docs
- [x] README.md for zzz (features, quick start, code examples, badges)
- [x] README.md for zzz_db (setup, schema, queries, migrations)
- [x] README.md for zzz_jobs (job definition, queues, scheduling)
- [x] README.md for zzz_cli (installation, commands reference)
- [x] README.md for zzz_example_app (how to run, what it demonstrates)
- [x] CONTRIBUTING.md (code style, PR process, testing)
- [x] SECURITY.md (vulnerability reporting)
- [x] GitHub issue templates (bug report, feature request)
- [x] GitHub pull request template

### Documentation Site
- [ ] Choose doc engine (mdBook or zzz-powered)
- [ ] Getting started guide
- [ ] Installation guide
- [ ] Tutorial: building a REST API
- [ ] Tutorial: building a blog with templates
- [ ] Tutorial: real-time chat with channels
- [ ] API reference (auto-generated from doc comments)
- [ ] Middleware reference (all built-in middleware with config options)
- [ ] Database guide (schema, queries, migrations, associations)
- [ ] Background jobs guide
- [ ] Deployment guide
- [ ] Deploy docs site (GitHub Pages or similar)

### CLI Distribution
- [x] Shell installer script (`curl -fsSL https://zzz.seemsindie.com/install.sh | sh`)
- [x] GitHub Releases with prebuilt binaries (Linux x86_64, macOS arm64, macOS x86_64)
- [x] Release CI workflow (build binaries on tag push, attach to GitHub Release)
- [x] Homebrew tap repository (homebrew-zzz)
- [x] Homebrew formula for zzz CLI
- [x] Install instructions in CLI README

### CI / Packaging
- [x] GitHub Actions CI (build + test on Linux + macOS)
- [x] Release builds for common targets
- [ ] Package published to Zig package index
- [x] Docker image for deployment (zzz_cli + zzz_example_app Dockerfiles)
- [x] Example docker-compose with PostgreSQL
- [x] CI workflows for zzz_cli and zzz_example_app (build-only)

### Package Publishing
- [x] Convert local path dependencies to package references (zzz_jobs -> zzz_db)
- [x] Test `zig fetch` from GitHub URLs for each package
- [ ] Register packages with Zig package index (when available)

---

## Phase 10: Configuration & Environment

### .env Support
- [x] `.env` file parser (key=value, `#` comments, quoted values)
- [x] Load order: `.env` → `.env.{environment}` → real env vars (later overrides earlier)
- [x] `zzz.Env` module: `get(key)`, `getDefault(key, fallback)`, `require(key)` (error if missing)
- [x] Standalone module usable by all packages (zzz, zzz_db, zzz_jobs) — app loads env via `zzz.Env`, passes values downstream
- [x] `.env.example` template generation (documents all config vars)
- [x] Sensitive value masking in logs (DATABASE_URL, SECRET_KEY, etc.)

### Multi-Environment Configs (Phoenix-style)
- [x] `config/` directory convention with per-environment files
- [x] `config/config.zig` — shared defaults (app name, base settings)
- [x] `config/dev.zig` — dev overrides (debug logging, local DB, port 4000)
- [x] `config/prod.zig` — production settings (release mode, real DB URL, TLS)
- [x] `config/staging.zig` — staging overrides
- [x] `config/runtime.zig` — runtime overrides from env vars / `.env` files
- [x] Environment selected at build time: `zig build -Denv=prod`
- [x] Config struct: comptime-known base + runtime overlay from env
- [x] `zzz.configInit` convenience — combines Env.init + mergeWithEnv in one call
- [x] Database config from env (`DATABASE_URL` parsing into host/port/name/user/pass)

### Docker Support in `zzz new`
- [x] Generate `Dockerfile` — multi-stage build (Zig build stage → slim runtime)
- [x] Generate `docker-compose.yml` — app + PostgreSQL service (with `--db=postgres`)
- [x] Generate `.dockerignore` (zig-cache, zig-out, .env)
- [x] Generated `main.zig` reads host/port/DB config from env vars
- [x] `zzz new --docker=false` flag to skip Docker files
- [x] Health check endpoint wired into docker-compose

### `zzz new` Enhancements
- [x] Generate `config/` directory with dev/prod/staging configs (all three)
- [x] Generate `.env.example` with documented variables
- [x] Generate `.env` with development defaults
- [x] `zzz new --db=sqlite` / `--db=postgres` / `--db=none` — database preset
- [x] `zzz new --full` — scaffold with controllers, middleware, templates
- [x] `zzz new --api` — API-only mode (JSON routes, CORS, no templates)

---

## Phase 11: Server Backend Abstraction

### Backend Trait
- [x] Define `Backend` interface: listener, accept, reader/writer, event model
- [x] Extract shared request handling into `request_handler.zig`
- [x] Backend selection at build time: `zig build -Dbackend=zzz|libhv`
- [x] Shared `Handler` type that works across all backends
- [x] Comptime backend selection via `backend.zig`
- [x] Backend-specific config options (`BackendConfig` per backend)

### Native zzz Backend (default)
- [x] Refactor `server.zig` to delegate to selected backend
- [x] Thread pool with bounded queue (replaces thread-per-connection)
- [x] BoundedQueue using pthread mutex + condition variables
- [x] Back-pressure: accept blocks when queue is full
- [x] Zero behavior change for existing users

### io_uring Backend (Linux, future)
- [ ] io_uring submission/completion queue management
- [ ] Async accept, read, write, close operations
- [ ] Multi-shot accept for high connection rates
- [ ] Zero-copy send via `IORING_OP_SEND_ZC`
- [ ] Fixed buffer pool for reduced allocation
- [ ] Benchmark: target 500K+ req/sec plaintext

### kqueue Backend (macOS, future)
- [ ] kqueue event loop with kevent batching
- [ ] Non-blocking accept + read/write
- [ ] Edge-triggered mode for efficiency
- [ ] Timer events for connection timeouts

### epoll Backend (Linux fallback, future)
- [ ] epoll event loop with edge-triggered mode
- [ ] Non-blocking socket management
- [ ] Fallback for Linux kernels without io_uring (< 5.6)

### libhv Backend (Cross-platform)
- [x] libhv C library integration via `@cImport`
- [x] Vendored as git submodule (`vendor/libhv`)
- [x] Event loop wrapping (`hloop_t`)
- [x] TCP server with zzz HTTP parser in `on_read` callback
- [x] Incremental header/body parsing with per-connection state
- [x] Chunked transfer encoding support
- [x] Keep-alive connection reuse
- [x] WebSocket support via callback-driven I/O
- [x] TLS via libhv's built-in SSL support
- [x] Timer integration for scheduled tasks

---

## Phase 12: Application Features

### Caching Layer
- [ ] `zzz.Cache` module — in-memory key-value cache
- [ ] TTL (time-to-live) per entry with automatic expiration
- [ ] LRU eviction when max capacity reached
- [ ] Configurable max entries and max memory
- [ ] `cache.get(key)`, `cache.put(key, value, ttl)`, `cache.delete(key)`, `cache.clear()`
- [ ] Thread-safe (concurrent reads, mutex on writes)
- [ ] Cache middleware for HTTP responses (ETag + cache headers)
- [ ] Telemetry: hit rate, miss rate, eviction count
- [ ] Optional: cache adapter interface (in-memory, Redis, distributed)

### Mailer
- [x] `zzz.Mailer` module — email sending abstraction
- [x] SMTP client implementation (connect, AUTH, STARTTLS, send)
- [x] Adapter pattern: SMTP, SendGrid API, Mailgun API, test/log adapter
- [x] Email struct: to, cc, bcc, subject, text_body, html_body, attachments
- [x] Template rendering for email bodies (reuse zzz template engine)
- [x] Async delivery via zzz_jobs integration (enqueue email as background job)
- [x] `zzz gen mailer WelcomeEmail` — CLI generator for mailer boilerplate
- [x] Test adapter: capture sent emails in-memory for test assertions
- [x] Rate limiting / throttling per adapter

### Internationalization (i18n)
- [ ] Locale files (JSON): `locales/en.json`, `locales/es.json`, etc.
- [ ] `{{t "hello.welcome"}}` template helper for translations
- [ ] Nested key support: `{{t "errors.not_found"}}`
- [ ] Interpolation: `{{t "hello.name" name=user.name}}`
- [ ] Pluralization rules (one/few/many/other)
- [ ] Locale detection from `Accept-Language` header
- [ ] Locale override via session/cookie/query param
- [ ] `zzz.I18n.t(locale, key, params)` runtime API
- [ ] Missing translation fallback (default locale or key name)
- [ ] `zzz gen locale es` — CLI generator for new locale file

### Asset Pipeline
- [ ] Static asset fingerprinting (content hash in filename for cache busting)
- [ ] `{{asset_path "css/style.css"}}` → `/css/style-a1b2c3.css` template helper
- [ ] Digest manifest file (JSON mapping original → fingerprinted paths)
- [ ] CSS/JS minification (shell out to esbuild or lightningcss)
- [ ] `zig build assets` step for production asset compilation
- [ ] Source map support for development
- [ ] Auto-rebuild in dev mode (watch file changes, use swatcher)
- [ ] Bundle multiple files into one (basic concatenation)
- [ ] Configurable asset paths (input dir, output dir)

---

## Phase 13: Operations & Observability

### Telemetry Dashboard
- [ ] Built-in web UI served at `/__zzz/dashboard` (opt-in middleware)
- [ ] Request rate graph (requests/sec over time)
- [ ] Latency histograms (p50, p95, p99)
- [ ] Error rate and recent errors
- [ ] Active WebSocket connections and channel subscriptions
- [ ] Job queue depth and worker utilization (from zzz_jobs telemetry)
- [ ] DB pool status: active/idle/waiting connections (from zzz_db)
- [ ] Cache hit/miss rates (from cache telemetry)
- [ ] System info: memory usage, uptime, Zig version
- [ ] Auth-protected (configurable credentials or bearer token)

### Release System
- [ ] `zzz release` CLI command — build production artifact
- [ ] Optimized binary build (ReleaseFast or ReleaseSafe, configurable)
- [ ] Bundle static assets + templates into binary or tarball
- [ ] Generate systemd unit file (`zzz release --systemd`)
- [ ] Generate supervisord config
- [ ] Cross-compilation: `zzz release --target=x86_64-linux`
- [ ] Self-contained tarball output with start script
- [ ] Version stamping (embed git SHA + build time in binary)
- [ ] `zzz release --docker` — build Docker image directly

### Deployment Targets
- [ ] `zzz deploy fly` — Fly.io deployment (generate fly.toml, Dockerfile)
- [ ] `zzz deploy railway` — Railway deployment config
- [ ] `zzz deploy render` — Render blueprint generation
- [ ] Generic `Procfile` generation for Heroku-like platforms
- [ ] Deployment guide per platform in docs

---

## Phase 14: Distributed Systems

### Node Discovery & Clustering
- [ ] Node name/identity system (e.g., `zzz@host1:9000`)
- [ ] Config-based node list (static cluster membership)
- [ ] TCP mesh networking between nodes (custom binary protocol)
- [ ] Node health monitoring (heartbeat + failure detection)
- [ ] Automatic reconnection on node failure
- [ ] `zzz.Cluster.nodes()` — list connected nodes
- [ ] `zzz.Cluster.self()` — current node identity

### Distributed PubSub
- [ ] PubSub adapter interface (in-process, distributed, Redis)
- [ ] TCP-based PubSub relay (broadcast messages across nodes in mesh)
- [ ] Redis PubSub adapter (for deployments without direct node connectivity)
- [ ] Topic subscription syncing across nodes
- [ ] Message deduplication (prevent broadcast storms)
- [ ] Channel messages automatically distributed (transparent to app code)

### Distributed Presence
- [ ] CRDT-based presence tracking across nodes (Phoenix-style)
- [ ] Presence data replicated via PubSub
- [ ] Conflict resolution for concurrent joins/leaves
- [ ] `Presence.list(topic)` returns presence from all nodes
- [ ] Presence diff events propagated across cluster

### Distributed Cache
- [ ] Consistent hashing for cache key distribution across nodes
- [ ] Cache replication (configurable replication factor)
- [ ] Cache invalidation broadcast
- [ ] Fallback to local cache on network partition
- [ ] `zzz.Cache.init(.{ .mode = .distributed })` opt-in

---

## Phase 15: LiveView (Server-Rendered Real-Time UI)

### Core Runtime
- [ ] LiveView module type: `mount/2`, `render/1`, `handle_event/3`, `handle_info/2`
- [ ] Server-side state management per connected client
- [ ] Initial HTTP render → WebSocket upgrade → diff-based updates
- [ ] DOM diffing: compute minimal diff between old and new rendered HTML
- [ ] Binary diff protocol over WebSocket (compressed patches)
- [ ] Automatic reconnection with state recovery

### Template Integration
- [ ] LiveView-aware templates (re-render on state change)
- [ ] `lv-click`, `lv-submit`, `lv-change` — client-side event bindings
- [ ] `lv-value-*` — form field bindings (live form validation)
- [ ] Dynamic class/attribute bindings based on server state

### Client Library (zzz-live.js)
- [ ] Lightweight JS client (~5KB) for WebSocket connection + DOM patching
- [ ] Event capturing and serialization (clicks, form submissions, key events)
- [ ] Morphdom-style DOM patching (or custom minimal patcher)
- [ ] Loading states / optimistic UI indicators
- [ ] Auto-served at `/__zzz/live.js`

### Features
- [ ] Live form validation (validate on every keystroke, server-side)
- [ ] Live navigation (pushState + server-rendered page transitions)
- [ ] Live file uploads with progress
- [ ] Presence integration (show who's viewing a page in real-time)
- [ ] `zzz gen live Dashboard` — CLI generator for LiveView modules

---

## Summary

| Phase | Status | Items Done | Items Remaining |
|-------|--------|------------|-----------------|
| 1. Foundation | **Complete** | 24 | 0 |
| 1.5 TLS | In Progress | 6 | 2 |
| 2. Router & Middleware | **Complete** | 45 | 0 |
| 3. Templates & Views | In Progress | 34 | 8 |
| 4. WebSocket & zzz.js | **Complete** | 17 | 1 |
| 4b. Channels | **Complete** | 15 | 2 |
| 5. Database (zzz_db) | **Complete** | 52 | 0 |
| 6. Jobs (zzz_jobs) | **Complete** | 27 | 0 |
| 7. Swagger & Controllers | **Complete** | 24 | 0 |
| 8. Testing & CLI | **Complete** | 24 | 0 |
| 9. Release Prep (v0.1.0) | In Progress | 25 | 12 |
| 10. Config & Environment | **Complete** | 22 | 0 |
| 11. Backend Abstraction | In Progress | 21 | 13 |
| 12. App Features | Not Started | 0 | 37 |
| 13. Operations | Not Started | 0 | 22 |
| 14. Distributed | Not Started | 0 | 19 |
| 15. LiveView | Not Started | 0 | 17 |
| Cross-Cutting | In Progress | 7 | 4 |
| **Total** | | **342** | **138** |
