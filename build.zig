// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_spice = b.option(bool, "spice", "Enable spice-based parallelism") orelse true;

    // Build options module
    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_spice", enable_spice);

    // Get spice dependency if enabled
    const spice_mod: ?*std.Build.Module = if (enable_spice) blk: {
        const spice_dep = b.dependency("spice", .{
            .target = target,
            .optimize = optimize,
        });
        break :blk spice_dep.module("spice");
    } else null;

    // ============================================================
    // Dependencies
    // ============================================================

    const uri_dep = b.dependency("uri", .{
        .target = target,
        .optimize = optimize,
    });
    const uri_mod = uri_dep.module("uri");

    // ============================================================
    // Parallel Module
    // ============================================================

    const parallel_mod = b.addModule("parallel", .{
        .root_source_file = b.path("src/parallel.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });
    if (spice_mod) |sm| {
        parallel_mod.addImport("spice", sm);
    }

    // ============================================================
    // Main JSON Module
    // ============================================================

    const json_mod = b.addModule("json", .{
        .root_source_file = b.path("src/json.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "uri", .module = uri_mod },
            .{ .name = "parallel", .module = parallel_mod },
        },
    });

    // ============================================================
    // Unit Tests
    // ============================================================

    const json_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/json.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "uri", .module = uri_mod },
            },
        }),
    });

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
            .imports = &.{
                .{ .name = "parallel", .module = parallel_mod },
            },
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
