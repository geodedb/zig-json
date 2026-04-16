// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_tp = b.option(bool, "thread-pool", "Enable thread-pool-based parallelism") orelse true;

    // Get thread_pool dependency if enabled
    const tp_mod: ?*std.Build.Module = if (enable_tp) blk: {
        const tp_dep = b.dependency("thread_pool", .{
            .target = target,
            .optimize = optimize,
        });
        break :blk tp_dep.module("thread_pool");
    } else null;

    // ============================================================
    // Dependencies
    // ============================================================

    const use_uri = b.option(bool, "uri", "Use internal uri dependency") orelse true;
    const uri_mod: ?*std.Build.Module = if (use_uri) blk: {
        const uri_dep = b.dependency("uri", .{
            .target = target,
            .optimize = optimize,
        });
        break :blk uri_dep.module("uri");
    } else null;

    // ============================================================
    // Parallel Module
    // ============================================================

    const parallel_mod: ?*std.Build.Module = if (enable_tp) blk: {
        break :blk b.addModule("parallel", .{
            .root_source_file = b.path("src/parallel.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        });
    } else null;
    if (parallel_mod) |pm| {
        if (tp_mod) |tm| pm.addImport("thread_pool", tm);
    }

    // ============================================================
    // Main JSON Module
    // ============================================================

    const json_mod = b.addModule("json", .{
        .root_source_file = b.path("src/json.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{},
    });
    if (uri_mod) |m| json_mod.addImport("uri", m);
    if (tp_mod) |tm| json_mod.addImport("thread_pool", tm);

    // ============================================================
    // Unit Tests
    // ============================================================

    const json_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/json.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (uri_mod) |m| json_tests.root_module.addImport("uri", m);
    if (tp_mod) |tm| json_tests.root_module.addImport("thread_pool", tm);

    const run_json_tests = b.addRunArtifact(json_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_json_tests.step);

    // ============================================================
    // Acceptance Tests
    // ============================================================

    const accept_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/accept.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "json", .module = json_mod },
            },
        }),
    });

    const run_accept_tests = b.addRunArtifact(accept_tests);

    const accept_step = b.step("test-accept", "Run acceptance tests");
    accept_step.dependOn(&run_accept_tests.step);

    // ============================================================
    // Edge Case Tests (testdata)
    // ============================================================

    const testdata_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/testdata.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "json", .module = json_mod },
            },
        }),
    });

    const run_testdata_tests = b.addRunArtifact(testdata_tests);

    const testdata_step = b.step("test-data", "Run edge case tests");
    testdata_step.dependOn(&run_testdata_tests.step);

    // ============================================================
    // JSON Schema Test Suite
    // ============================================================

    const schema_suite_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/schema_suite.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "json", .module = json_mod },
            },
        }),
    });

    const run_schema_suite_tests = b.addRunArtifact(schema_suite_tests);

    const schema_suite_step = b.step("test-schema", "Run JSON Schema test suite");
    schema_suite_step.dependOn(&run_schema_suite_tests.step);

    // ============================================================
    // All Tests
    // ============================================================

    const test_all_step = b.step("test-all", "Run all tests");
    test_all_step.dependOn(test_step);
    test_all_step.dependOn(accept_step);
    test_all_step.dependOn(testdata_step);
    test_all_step.dependOn(schema_suite_step);

    // ============================================================
    // Documentation
    // ============================================================

    const lib_docs = b.addObject(.{
        .name = "json",
        .root_module = json_mod,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib_docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);

    // ============================================================
    // Parallel Benchmark
    // ============================================================

    const parallel_bench_step = b.step("bench-parallel", "Run parallel operations benchmark");
    const parallel_bench_exe = b.addExecutable(.{
        .name = "parallel_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/parallel_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{},
        }),
    });
    const run_parallel_bench = b.addRunArtifact(parallel_bench_exe);
    parallel_bench_step.dependOn(&run_parallel_bench.step);

    // ============================================================
    // Format Check
    // ============================================================

    const fmt = b.addFmt(.{
        .paths = &.{
            "src",
            "tests",
            "build.zig",
        },
        .check = true,
    });

    const fmt_step = b.step("fmt-check", "Check formatting");
    fmt_step.dependOn(&fmt.step);
}
