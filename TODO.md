# pidgn Framework — Release TODO

## Completed Phases

### Phase 1: Foundation (TCP + HTTP/1.1) — 24/24
- [x] TCP server with connection handling
- [x] HTTP/1.1 request parsing
- [x] HTTP/1.1 response building
- [x] Keep-alive connections
- [x] Chunked transfer encoding
- [x] Content-Length handling
- [x] All standard HTTP methods
- [x] Header parsing and building

### Phase 1.5: TLS — 6/8
- [x] Basic TLS/HTTPS support (TLS 1.2+)
- [x] Certificate and key loading
- [x] SSL handshake
- [x] TLS integration in server
- [x] OpenSSL vendored build (patched for Zig 0.16)
- [x] TLS config struct
- [ ] SNI (Server Name Indication) support
- [ ] Certificate auto-reload (hot-reload without restart)

### Phase 2: Router & Middleware — 45/45
- [x] Compile-time route resolution
- [x] Path parameters (`:id`)
- [x] Wildcards (`*path`)
- [x] HTTP method routing (GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS)
- [x] Router.resource for RESTful CRUD
- [x] Router.scope for grouped routes
- [x] Named routes with .named() and pathFor/buildPath
- [x] 20 built-in middleware:
  - [x] Logger
  - [x] Error handler
  - [x] CORS
  - [x] Body parser
  - [x] Static files
  - [x] Request ID
  - [x] Compress (gzip)
  - [x] Bearer auth
  - [x] Basic auth
  - [x] JWT auth
  - [x] Session
  - [x] CSRF
  - [x] Rate limiter
  - [x] Structured logger
  - [x] Metrics (Prometheus)
  - [x] Telemetry
  - [x] Health check
  - [x] htmx
  - [x] Channel middleware
  - [x] pidgn.js middleware

### Phase 3: Templates — 35/41
- [x] Comptime template compilation
- [x] Mustache-like syntax (`{{var}}`, `{{{raw}}}`)
- [x] Conditionals (`{{#if}}` / `{{else}}` / `{{/if}}`)
- [x] Loops (`{{#each}}`)
- [x] Scope blocks (`{{#with}}`)
- [x] Comments (`{{! comment}}`)
- [x] Raw blocks (`{{{{raw}}}}`)
- [x] HTML escaping (automatic)
- [x] Layouts with `{{{yield}}}`
- [x] Named yield blocks (`{{{yield_head}}}`, `{{{yield_scripts}}}`)
- [x] Partials (`{{> name}}`)
- [x] Partial arguments
- [x] Pipes (upper, lower, truncate, default, pluralize, format_date)
- [x] Dot notation for nested fields
- [x] Integer support in templates
- [x] Compile-time safety (missing fields = compile error)
- [x] SSR bridge (server-side rendering React via Bun subprocesses)
- [ ] Nested layouts (multi-level layout inheritance)
- [ ] Components with slots
- [ ] Template fragments / streaming
- [ ] Custom pipe registration API
- [ ] Template caching / precompilation cache
- [ ] Internationalized templates (i18n integration)
- [ ] Template debugging / source maps

### Phase 4: WebSocket & Channels — 33/34
- [x] WebSocket upgrade middleware
- [x] WebSocket connection handling (send, sendBinary, close)
- [x] Message types (text, binary, ping, pong, close)
- [x] Automatic ping/pong
- [x] Message fragmentation
- [x] Per-message deflate (compression)
- [x] Close handshake
- [x] Channel abstraction (ChannelDef)
- [x] Topic-based PubSub (64 topics, 256 subscribers)
- [x] Broadcast (all, excluding sender, direct)
- [x] Presence tracking (track, untrack, list, diff)
- [x] Join authorization
- [x] Wildcard topic patterns (`prefix:*`)
- [x] Wire protocol (JSON events)
- [x] pidgn.js JavaScript client (connect, channels, presence, auto-reconnect)
- [x] WebSocket test client
- [x] Channel rate limiting (token bucket, per-socket message throttling)
- [ ] Distributed PubSub (Redis adapter)
- [ ] Multi-node presence sync

### Phase 5: Database (pidgn_db) — 52/52
- [x] SQLite backend (vendored amalgamation)
- [x] PostgreSQL backend (libpq)
- [x] Schema definition (comptime structs)
- [x] Repository (CRUD: insert, get, one, all, update, delete)
- [x] Query builder (where, order, limit, join, group, having)
- [x] Changesets (casting, validation)
- [x] Migrations (up/down, DDL helpers, runner)
- [x] Transactions (begin/commit/rollback, savepoints, isolation levels)
- [x] Associations (has_many, has_one, belongs_to, many_to_many)
- [x] Connection pooling
- [x] Raw queries
- [x] Test sandbox (transaction-based isolation)
- [x] Factory for test data
- [x] Aggregate functions
- [x] DatabaseUrl parsing

### Phase 6: Background Jobs (pidgn_jobs) — 27/27
- [x] Job definition and enqueueing
- [x] Supervisor/worker architecture
- [x] Memory store
- [x] Database store (SQLite/PostgreSQL)
- [x] Queue priorities
- [x] Retry strategies (exponential, linear, constant, custom)
- [x] Max attempts / dead letter
- [x] Cron scheduling (5-field syntax)
- [x] Unique jobs (ignore_new, cancel_existing)
- [x] Job telemetry (7 event types)
- [x] Stuck job rescue
- [x] Queue pause/resume

### Phase 7: Swagger/OpenAPI — 24/24
- [x] OpenAPI spec generation from routes
- [x] ApiDoc annotations
- [x] JSON Schema from Zig types
- [x] Swagger UI middleware
- [x] Security schemes (Bearer, API Key, Basic)
- [x] Query/path parameter documentation
- [x] SpecConfig customization

### Phase 8: Testing & CLI — 26/26
- [x] HTTP test client (get, post, put, patch, delete)
- [x] Request builder (chainable API)
- [x] Response assertions (status, body, headers, JSON, cookies)
- [x] Cookie jar persistence
- [x] Redirect following
- [x] Multipart file upload testing
- [x] WebSocket test client (TestChannel)
- [x] Database test sandbox
- [x] CLI: `pidgn new` (project scaffolding)
- [x] CLI: `pidgn server` (dev server with file watching)
- [x] CLI: `pidgn gen controller/model/channel/mailer`
- [x] CLI: `pidgn migrate` (up/rollback/status)
- [x] CLI: `pidgn routes` (route listing)
- [x] CLI: `pidgn test`
- [x] CLI: `pidgn swagger`
- [x] CLI: `pidgn assets setup` (scaffold asset directory)
- [x] CLI: `pidgn assets build` (bundle, minify, fingerprint)

### Phase 9: Release Prep (v0.1.0) — 34/37
- [x] Documentation site (pidgn_docs — 69 pages, Astro/Starlight)
- [x] All doc pages filled with real content
- [x] CHANGELOG.md in pidgn.zig, pidgn_db, pidgn_jobs, pidgn_cli
- [x] LICENSE in all packages
- [x] GitHub Actions CI in all packages (ubuntu + macos matrix)
- [x] Release workflows (release.yml)
- [x] Homebrew tap (homebrew-pidgn)
- [x] CLI install script (curl | sh)
- [x] GitHub Releases with pre-built binaries
- [x] VSCode extension (pidgn_vscode — syntax highlighting for .pidgn templates)
- [x] Marketing website (pidgn_website — built with pidgn itself)
- [x] Example app (pidgn_example_app)
- [x] build.zig.zon with version 0.1.0 and fingerprint
- [x] README.md in all packages
- [x] .github/ISSUE_TEMPLATE and PULL_REQUEST_TEMPLATE
- [x] pidgn_mailer CHANGELOG.md
- [x] Zig package index — N/A (URL-based, build.zig.zon already configured)
- [ ] Getting Started video / screencast

### Phase 10: Config & Environment — 22/22
- [x] .env file loading
- [x] Multi-environment configs (dev/prod/staging)
- [x] Env precedence (system > .env.{env} > .env > comptime)
- [x] Typed accessors (get, getInt, getBool, require)
- [x] mergeWithEnv for config structs
- [x] configInit convenience
- [x] maskSensitive for logging
- [x] Docker scaffolding in `pidgn new`
- [x] -Denv build flag

### Phase 11: Backend Abstraction — 23/33
- [x] Backend trait/interface abstraction (backend.zig)
- [x] pidgn native backend (thread pool + bounded queue, POSIX mutexes)
- [x] libhv backend (event-loop, epoll/kqueue/IOCP via libhv)
- [x] Compile-time backend selection (-Dbackend=)
- [x] Server.Config with backend-specific options
- [x] TLS integration in both backends
- [x] WebSocket support in both backends
- [x] Graceful shutdown with drain timeout (signal handlers, shutdown hooks, connection draining)
- [x] Backend benchmarking harness (bench/ — wrk/hey, plaintext/JSON/DB/SQLite benchmarks)
- [ ] io_uring backend (Linux 5.1+)
- [ ] epoll backend (Linux, standalone without libhv)
- [ ] kqueue backend (macOS/BSD, standalone without libhv)
- [ ] IOCP backend (Windows)
- [ ] Async I/O with Zig's std.Io
- [ ] Connection pooling at backend level
- [ ] Hot restart (zero-downtime deploys)
- [ ] Unix domain socket support
- [ ] HTTP/2 support
- [ ] HTTP/3 / QUIC support
- [ ] Backend-specific tuning documentation

### Phase 12: App Features — 10/33
- [x] Caching layer (in-memory with TTL)
- [x] Cache middleware (response caching with `X-Cache` headers)
- [x] Asset pipeline (CSS/JS bundling via Bun)
- [x] Asset fingerprinting / cache busting (FNV-1a hash, manifest JSON)
- [x] Asset precompilation (`pidgn assets build`)
- [x] Server-Sent Events (SSE) with SseWriter
- [x] ETag generation middleware (static files ETag support)
- [x] Conditional GET (304 responses via If-None-Match)
- [x] Live reload (WebSocket-based, CSS hot-swap)
- [x] File upload handling (multipart via bodyParser)
- [ ] Cache invalidation strategies (beyond manual)
- [ ] i18n / localization framework
- [ ] Locale detection middleware
- [ ] Translation file format and loading
- [ ] Pluralization rules
- [ ] Flash messages
- [ ] File storage abstraction (local, S3)
- [ ] Pagination helpers
- [ ] Form builder helpers
- [ ] Input sanitization
- [ ] Content Security Policy middleware
- [ ] HSTS middleware
- [ ] Cookie encryption
- [ ] Signed cookies
- [ ] Action logging / audit trail
- [ ] Request throttling (more advanced than rate limit)
- [ ] IP allowlist / blocklist
- [ ] Geo-IP middleware
- [ ] User agent parsing
- [ ] Accept-Language negotiation
- [ ] Range requests (partial content / video streaming)
- [ ] GraphQL support
- [ ] gRPC support

---

## Not Started — Future Phases

### Phase 13: Operations — 0/22
- [ ] Telemetry dashboard (web UI for metrics)
- [ ] `pidgn release` CLI command (build + package)
- [ ] Deploy targets (fly.io, Railway, Docker registry)
- [ ] Health check dashboard
- [ ] Log aggregation integration
- [ ] Error tracking integration (Sentry-like)
- [ ] APM (Application Performance Monitoring)
- [ ] Structured log shipping
- [ ] Alerting rules
- [ ] Database migration CI/CD integration
- [ ] Canary deploy support
- [ ] Blue-green deploy support
- [ ] Rolling restart orchestration
- [ ] Resource limits / memory monitoring
- [ ] Connection pool monitoring
- [ ] Slow query logging
- [ ] Request tracing (distributed traces)
- [ ] Dependency health checks
- [ ] Runbook automation
- [ ] Backup/restore utilities
- [ ] Data seeding for staging
- [ ] Load testing harness

### Phase 14: Distributed — 0/19
- [ ] Node discovery / clustering
- [ ] Distributed PubSub (Redis, NATS, or custom)
- [ ] Distributed presence
- [ ] Distributed cache
- [ ] Distributed sessions (Redis-backed)
- [ ] Distributed rate limiting
- [ ] Distributed job queue (multi-node workers)
- [ ] Leader election
- [ ] Consistent hashing
- [ ] Sticky sessions / session affinity
- [ ] Service mesh integration
- [ ] Cross-node RPC
- [ ] Distributed tracing propagation
- [ ] Cluster-aware health checks
- [ ] Node draining for deploys
- [ ] Split-brain detection
- [ ] Quorum-based operations
- [ ] Distributed locks
- [ ] Event sourcing primitives

### Phase 15: LiveView — 0/17
- [ ] Server-rendered real-time UI
- [ ] LiveView mount / render lifecycle
- [ ] DOM diffing (server-side)
- [ ] Minimal WebSocket wire protocol for patches
- [ ] Event handling (phx-click, phx-submit, etc.)
- [ ] Form bindings with validation
- [ ] Live navigation (pushState without full reload)
- [ ] LiveView JavaScript client
- [ ] LiveView test helpers
- [ ] Uploads in LiveView
- [ ] Live components (nested)
- [ ] Slots in live components
- [ ] JS hooks for custom client behavior
- [ ] LiveView flash messages
- [ ] LiveView sessions / auth
- [ ] LiveView rate limiting
- [ ] LiveView presence integration

---

## Summary

| Phase | Done | Total | Status |
|-------|------|-------|--------|
| 1. Foundation | 24 | 24 | Done |
| 1.5 TLS | 6 | 8 | 75% |
| 2. Router & Middleware | 45 | 45 | Done |
| 3. Templates | 35 | 41 | 85% |
| 4. WebSocket & Channels | 33 | 34 | 97% |
| 5. Database | 52 | 52 | Done |
| 6. Background Jobs | 27 | 27 | Done |
| 7. Swagger/OpenAPI | 24 | 24 | Done |
| 8. Testing & CLI | 26 | 26 | Done |
| 9. Release Prep | 34 | 37 | 92% |
| 10. Config & Environment | 22 | 22 | Done |
| 11. Backend Abstraction | 23 | 33 | 70% |
| 12. App Features | 10 | 33 | 30% |
| 13. Operations | 0 | 22 | Not started |
| 14. Distributed | 0 | 19 | Not started |
| 15. LiveView | 0 | 17 | Not started |
| **Total** | **361** | **467** | **77%** |

### v0.1.0 Blockers (must-have)
1. ~~Documentation site~~ — Done
2. ~~Vendored build~~ — Done
3. ~~pidgn_mailer CHANGELOG.md~~ — Done
4. ~~Zig package index~~ — N/A (Zig uses URL-based deps, build.zig.zon already configured)

### v0.1.0 Nice-to-have
- [ ] SNI support
- [ ] Getting Started video
- [x] Performance benchmarks (bench/ — wrk/hey harness with plaintext, JSON, routing, DB benchmarks)

---

## Infrastructure & Tooling

### Build & Deploy — 4/7
- [x] libpq fork with Zig/clang compatibility patches (seemsindie/libpq)
- [x] zstd fork with correct sub-dependency hash (seemsindie/zstd)
- [x] Dockerfile: Debian glibc builder + runtime (pidgn_website)
- [x] Coolify auto-deploy from main branch
- [ ] CI: cross-repo integration tests (push to dep triggers downstream build)
- [ ] Monorepo migration (single repo with Zig workspace or path deps)
- [ ] pg.zig migration (replace libpq C dep with pure-Zig PostgreSQL driver)

### Workspace Tooling — 4/6
- [x] zhash — auto-fix Zig package hash mismatches
- [x] zpush — chain dependency updates across repos
- [x] setup — clone all repos, verify Zig, show status
- [x] zrelease — bump version across all packages, tag, push
- [ ] zdeps — visualize/check dependency freshness across workspace
- [ ] CI for workspace repo (lint scripts, validate repo list)

### Known Issues / Tech Debt
- libpq requires `-Wno-incompatible-pointer-types-discards-qualifiers` and `-fno-sanitize=undefined` for Zig's clang
- `@cImport` of libpq headers needs `@cUndef("_FORTIFY_SOURCE")` on glibc targets
- openssl-zig is on a detached HEAD (patched fork of kassane/openssl-zig zig-pkg branch)
- pidgn_jobs and pidgn_example_app still point to older pidgn_db commits (pre-libpq fork)
- pidgn_mailer tests fail at runtime (SMTP connection) — pre-existing, not build-related
- Version strings inconsistent across packages: build.zig.zon, src/root.zig, CHANGELOG.md often diverge — use `zrelease` to keep in sync
