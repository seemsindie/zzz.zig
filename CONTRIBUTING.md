# Contributing to pidgn

## Setup

pidgn lives inside a workspace with its sibling packages (`pidgn_db`, `pidgn_jobs`, `pidgn_mailer`, `pidgn_template`, `pidgn_example_app`, `pidgn_website`). Clone the whole workspace, not just this repo:

```bash
git clone https://github.com/pidgn-web/zigweb_workspace.git
cd zigweb_workspace
./setup          # clones all packages, pins correct commits
```

Dependencies (SQLite, OpenSSL, libpq) are vendored — no system libraries needed.

**Requirements:** Zig 0.16.0-dev.2535+b5bd49460 or later.

## Development

### Where things live

| What | Where |
|---|---|
| Core types (Server, Request, Response, Router) | `src/core/` |
| Middleware (compression, CORS, caching, etc.) | `src/middleware/` |
| Public API surface | `src/root.zig` (re-exports from core/middleware) |
| Tests | Inline, at the bottom of each module |

### Adding something new

- **New core type** -- add a file in `src/core/`, export it from `src/root.zig`.
- **New middleware** -- add a file in `src/middleware/`, export it from `src/root.zig`.
- Everything users import comes through `root.zig`. If it's not exported there, it doesn't exist to consumers.

## Code Patterns

These are pidgn-specific conventions. Follow them in new code.

### Fixed-size data structures

No heap allocations on hot paths. Use fixed-capacity buffers, ring buffers, and bounded queues. The allocator is for setup; the request loop should be allocation-free.

### Thread safety

Use `std.atomic.Mutex` with `spinLock()` — not `std.Thread.Mutex`. The spin lock is appropriate for the short critical sections in pidgn's I/O paths.

### Type-erased callbacks

Pass behavior through function pointers with an erased `*anyopaque` context. See the WebSocket and SSE handler patterns for examples.

### Comptime config structs

Middleware is configured via comptime structs (`ChannelConfig`, `CacheConfig`, etc.). The struct fields become comptime-known, so the compiler eliminates dead branches. New middleware should follow this pattern.

### Syscalls

Use `std.c` for syscalls, not `std.posix`. The `std.posix` namespace has macOS compatibility issues that `std.c` avoids.

## Testing

Every module has inline tests at the bottom of the file. Run them:

```bash
cd pidgn && zig build test   # ~281 tests
```

To run sibling package tests from the workspace root:

```bash
cd pidgn_db && zig build test    # SQLite tests
cd pidgn_jobs && zig build test  # Job processing tests
```

Write tests for all new functionality. Tests go in the same file as the code they test, inside a `test` block at the bottom.

## Code Style

- `snake_case` for variables and functions
- `PascalCase` for types and comptime-known values
- Lines under 120 characters where practical
- `std.log` for logging, never `std.debug.print`
- No unnecessary abstractions -- keep it direct
- Match the style of surrounding code

## Commit Messages

- Imperative mood: "Add feature" not "Added feature"
- First line under 72 characters
- Reference issues where relevant
- One logical change per commit

## After Your Change

Checklist before submitting:

- [ ] New public types are exported from `src/root.zig`
- [ ] Added usage example in `pidgn_example_app` if applicable
- [ ] Updated `README.md` and `CHANGELOG.md`
- [ ] All tests pass: `zig build test`
- [ ] Push, then propagate hashes to downstream packages with `zpush`

See the workspace-level `CONTRIBUTING.md` in `zigweb_workspace/` for the full cross-package lifecycle.

## Pull Requests

- Keep PRs focused on a single change
- Include tests for new functionality
- Ensure CI passes

## Reporting Bugs

Open an issue with:
- Zig version (`zig version`)
- Operating system
- Steps to reproduce
- Expected vs actual behavior

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
