const std = @import("std");

fn linkOpenSsl(module: *std.Build.Module, openssl_dep: *std.Build.Dependency) void {
    module.linkLibrary(openssl_dep.artifact("ssl"));
    module.linkLibrary(openssl_dep.artifact("crypto"));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tls_enabled = b.option(bool, "tls", "Enable TLS/HTTPS support (requires OpenSSL)") orelse false;
    const backend = b.option([]const u8, "backend", "Server backend: \"pidgn\" (default) or \"libhv\"") orelse "pidgn";

    // Create a module for the TLS build option so server.zig can query it at comptime
    const tls_options = b.addOptions();
    tls_options.addOption(bool, "tls_enabled", tls_enabled);

    // Backend selection option
    const backend_options = b.addOptions();
    backend_options.addOption([]const u8, "backend", backend);

    const pidgn_template_dep = b.dependency("pidgn_template", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("pidgn", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Add pidgn_template module
    mod.addImport("pidgn_template", pidgn_template_dep.module("pidgn_template"));

    // Add TLS options module
    mod.addImport("tls_options", tls_options.createModule());

    // Add backend options module
    mod.addImport("backend_options", backend_options.createModule());

    // libc is needed unconditionally (sendFile, clock_gettime, etc.)
    mod.link_libc = true;

    // Add TLS module (always available, guarded by comptime check in server.zig)
    const tls_mod = b.createModule(.{
        .root_source_file = b.path("src/tls/tls.zig"),
        .target = target,
    });
    tls_mod.link_libc = true;
    mod.addImport("tls", tls_mod);

    const openssl_dep = if (tls_enabled)
        b.dependency("openssl", .{ .target = target, .optimize = optimize })
    else
        null;

    if (tls_enabled) {
        linkOpenSsl(mod, openssl_dep.?);
        mod.link_libc = true;

        linkOpenSsl(tls_mod, openssl_dep.?);
        tls_mod.link_libc = true;
    }

    // ── libhv C compilation (when backend=libhv) ────────────────────────
    if (std.mem.eql(u8, backend, "libhv")) {
        const libhv_c_flags: []const []const u8 = if (tls_enabled)
            (if (target.result.os.tag == .macos)
                &.{
                    "-DHV_WITHOUT_EVPP",
                    "-DHV_WITHOUT_HTTP",
                    "-DWITH_OPENSSL",
                    "-DHAVE_EVENTFD=0",
                    "-DHAVE_ENDIAN_H=0",
                    "-DHAVE_PTHREAD_SPIN_LOCK=0",
                    "-Wno-date-time",
                }
            else
                &.{
                    "-DHV_WITHOUT_EVPP",
                    "-DHV_WITHOUT_HTTP",
                    "-DWITH_OPENSSL",
                    "-Wno-date-time",
                })
        else if (target.result.os.tag == .macos)
            &.{
                "-DHV_WITHOUT_EVPP",
                "-DHV_WITHOUT_HTTP",
                "-DHV_WITHOUT_SSL",
                "-DHAVE_EVENTFD=0",
                "-DHAVE_ENDIAN_H=0",
                "-DHAVE_PTHREAD_SPIN_LOCK=0",
                "-Wno-date-time",
            }
        else
            &.{
                "-DHV_WITHOUT_EVPP",
                "-DHV_WITHOUT_HTTP",
                "-DHV_WITHOUT_SSL",
                "-Wno-date-time",
            };

        // SSL source: openssl.c when TLS enabled, nossl.c otherwise
        const ssl_source: []const u8 = if (tls_enabled)
            "vendor/libhv/ssl/openssl.c"
        else
            "vendor/libhv/ssl/nossl.c";

        mod.addCSourceFiles(.{
            .files = &.{
                "vendor/libhv/base/hbase.c",
                "vendor/libhv/base/hsocket.c",
                "vendor/libhv/base/hlog.c",
                "vendor/libhv/base/htime.c",
                "vendor/libhv/base/herr.c",
                "vendor/libhv/base/rbtree.c",
                "vendor/libhv/event/hloop.c",
                "vendor/libhv/event/hevent.c",
                "vendor/libhv/event/nio.c",
                "vendor/libhv/event/nlog.c",
                "vendor/libhv/event/overlapio.c",
                "vendor/libhv/event/unpack.c",
                "vendor/libhv/ssl/hssl.c",
                ssl_source,
            },
            .flags = libhv_c_flags,
        });

        // Platform-specific event source
        if (target.result.os.tag == .linux) {
            mod.addCSourceFiles(.{
                .files = &.{"vendor/libhv/event/epoll.c"},
                .flags = libhv_c_flags,
            });
        } else if (target.result.os.tag == .macos) {
            mod.addCSourceFiles(.{
                .files = &.{"vendor/libhv/event/kqueue.c"},
                .flags = libhv_c_flags,
            });
        }

        mod.addIncludePath(b.path("vendor/libhv"));
        mod.addIncludePath(b.path("vendor/libhv/base"));
        mod.addIncludePath(b.path("vendor/libhv/event"));
        mod.addIncludePath(b.path("vendor/libhv/ssl"));
        mod.link_libc = true;
    }

    const exe = b.addExecutable(.{
        .name = "pidgn",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pidgn", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // ── Shared pidgn_db module for benchmarks ────────────────────────────
    const db_options = b.addOptions();
    db_options.addOption(bool, "sqlite_enabled", true);
    db_options.addOption(bool, "postgres_enabled", false);

    const pidgn_db_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "../pidgn_db/src/root.zig" },
        .target = target,
    });
    pidgn_db_mod.addImport("db_options", db_options.createModule());
    pidgn_db_mod.addCSourceFiles(.{
        .files = &.{"../pidgn_db/vendor/sqlite3/sqlite3.c"},
        .flags = &.{"-DSQLITE_THREADSAFE=1"},
    });
    pidgn_db_mod.addIncludePath(.{ .cwd_relative = "../pidgn_db/vendor/sqlite3" });
    pidgn_db_mod.link_libc = true;

    // ── Benchmark server ────────────────────────────────────────────────
    const bench_exe = b.addExecutable(.{
        .name = "pidgn-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench_server.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "pidgn", .module = mod },
                .{ .name = "pidgn_db", .module = pidgn_db_mod },
            },
        }),
    });
    bench_exe.root_module.link_libc = true;
    const install_bench = b.addInstallArtifact(bench_exe, .{});
    const bench_step = b.step("bench", "Build benchmark server (ReleaseFast)");
    bench_step.dependOn(&install_bench.step);

    // ── SQLite benchmark (standalone) ───────────────────────────────────
    const bench_sqlite_exe = b.addExecutable(.{
        .name = "pidgn-bench-sqlite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench_sqlite.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "pidgn_db", .module = pidgn_db_mod },
            },
        }),
    });
    bench_sqlite_exe.root_module.link_libc = true;
    const install_bench_sqlite = b.addInstallArtifact(bench_sqlite_exe, .{});

    const bench_sqlite_step = b.step("bench-sqlite", "Build and run SQLite benchmark");
    const run_bench_sqlite = b.addRunArtifact(bench_sqlite_exe);
    bench_sqlite_step.dependOn(&run_bench_sqlite.step);

    // Also make `zig build bench` install the sqlite bench binary
    bench_step.dependOn(&install_bench_sqlite.step);

    // ── Parallel test execution ─────────────────────────────────────────
    // Split into independent test compilations so the build system can
    // compile and run them in parallel (via dependOn).
    const test_groups = .{
        .{ "test-core", "src/test_core.zig" },
        .{ "test-router", "src/test_router.zig" },
        .{ "test-middleware", "src/test_middleware.zig" },
        .{ "test-template", "src/test_template.zig" },
        .{ "test-swagger", "src/test_swagger.zig" },
        .{ "test-testing", "src/test_testing.zig" },
        .{ "test-env", "src/test_env.zig" },
        .{ "test-config", "src/test_config.zig" },
        .{ "test-backend", "src/test_backend.zig" },
    };

    const test_step = b.step("test", "Run all tests (parallel)");

    inline for (test_groups) |group| {
        const name = group[0];
        const root = group[1];

        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = target,
            }),
        });
        t.root_module.link_libc = true;

        // All tests transitively import template/engine.zig which re-exports from pidgn_template
        t.root_module.addImport("pidgn_template", pidgn_template_dep.module("pidgn_template"));

        // Backend tests need the same options modules as the main pidgn module
        if (comptime std.mem.eql(u8, name, "test-backend")) {
            t.root_module.addImport("tls_options", tls_options.createModule());
            t.root_module.addImport("backend_options", backend_options.createModule());
            t.root_module.addImport("tls", tls_mod);

            // When backend=libhv, add libhv include paths and C sources for test compilation
            if (std.mem.eql(u8, backend, "libhv")) {
                const test_libhv_c_flags: []const []const u8 = if (tls_enabled)
                    (if (target.result.os.tag == .macos)
                        &.{
                            "-DHV_WITHOUT_EVPP", "-DHV_WITHOUT_HTTP", "-DWITH_OPENSSL",
                            "-DHAVE_EVENTFD=0",  "-DHAVE_ENDIAN_H=0", "-DHAVE_PTHREAD_SPIN_LOCK=0",
                            "-Wno-date-time",
                        }
                    else
                        &.{ "-DHV_WITHOUT_EVPP", "-DHV_WITHOUT_HTTP", "-DWITH_OPENSSL", "-Wno-date-time" })
                else if (target.result.os.tag == .macos)
                    &.{
                        "-DHV_WITHOUT_EVPP", "-DHV_WITHOUT_HTTP", "-DHV_WITHOUT_SSL",
                        "-DHAVE_EVENTFD=0",  "-DHAVE_ENDIAN_H=0", "-DHAVE_PTHREAD_SPIN_LOCK=0",
                        "-Wno-date-time",
                    }
                else
                    &.{ "-DHV_WITHOUT_EVPP", "-DHV_WITHOUT_HTTP", "-DHV_WITHOUT_SSL", "-Wno-date-time" };

                const test_ssl_source: []const u8 = if (tls_enabled) "vendor/libhv/ssl/openssl.c" else "vendor/libhv/ssl/nossl.c";

                t.root_module.addCSourceFiles(.{
                    .files = &.{
                        "vendor/libhv/base/hbase.c",   "vendor/libhv/base/hsocket.c",
                        "vendor/libhv/base/hlog.c",    "vendor/libhv/base/htime.c",
                        "vendor/libhv/base/herr.c",    "vendor/libhv/base/rbtree.c",
                        "vendor/libhv/event/hloop.c",  "vendor/libhv/event/hevent.c",
                        "vendor/libhv/event/nio.c",    "vendor/libhv/event/nlog.c",
                        "vendor/libhv/event/overlapio.c", "vendor/libhv/event/unpack.c",
                        "vendor/libhv/ssl/hssl.c",     test_ssl_source,
                    },
                    .flags = test_libhv_c_flags,
                });
                if (target.result.os.tag == .linux) {
                    t.root_module.addCSourceFiles(.{
                        .files = &.{"vendor/libhv/event/epoll.c"},
                        .flags = test_libhv_c_flags,
                    });
                } else if (target.result.os.tag == .macos) {
                    t.root_module.addCSourceFiles(.{
                        .files = &.{"vendor/libhv/event/kqueue.c"},
                        .flags = test_libhv_c_flags,
                    });
                }
                t.root_module.addIncludePath(b.path("vendor/libhv"));
                t.root_module.addIncludePath(b.path("vendor/libhv/base"));
                t.root_module.addIncludePath(b.path("vendor/libhv/event"));
                t.root_module.addIncludePath(b.path("vendor/libhv/ssl"));
                if (tls_enabled) {
                    linkOpenSsl(t.root_module, openssl_dep.?);
                }
            }
        }

        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);

        const named_step = b.step(name, "Run " ++ name ++ " tests");
        named_step.dependOn(&run_t.step);
    }

    // exe_tests (main.zig — imports pidgn module)
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);
}
