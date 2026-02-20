# Contributing to zzz

Thanks for your interest in contributing! This guide covers the basics.

## Getting Started

1. Fork the repository
2. Clone your fork alongside the workspace dependencies:
   ```bash
   git clone https://github.com/YOUR_USERNAME/zzz.git
   cd zzz
   ```
3. Build and run tests:
   ```bash
   zig build
   zig build test
   ```

## Requirements

- Zig 0.16.0-dev.2535+b5bd49460 or later
- SQLite3 (for zzz_db tests)
- OpenSSL 3 (optional, for TLS features)

## Development Workflow

1. Create a feature branch from `main`
2. Make your changes
3. Ensure all tests pass: `zig build test`
4. Submit a pull request

## Code Style

- Follow the existing code patterns in the codebase
- Use `snake_case` for variables and functions
- Use `PascalCase` for types and comptime-known values
- Keep lines under 120 characters where practical
- Add tests for new functionality
- Use `std.log` for logging, not `std.debug.print`

## Commit Messages

- Use imperative mood ("Add feature" not "Added feature")
- Keep the first line under 72 characters
- Reference issues where relevant

## Testing

Every module has inline tests. Run the full test suite with:

```bash
cd zzz.zig && zig build test  # 281 tests
cd zzz_db && zig build test   # SQLite tests
cd zzz_jobs && zig build test # Job processing tests
```

## Pull Requests

- Keep PRs focused on a single change
- Include tests for new functionality
- Update documentation if needed
- Ensure CI passes

## Reporting Bugs

Open an issue with:
- Zig version (`zig version`)
- Operating system
- Steps to reproduce
- Expected vs actual behavior

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
