// SPDX-License-Identifier: Apache-2.0
// Build file for JSON library examples

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get the json module from the parent project
    const json_dep = b.dependency("json", .{
        .target = target,
        .optimize = optimize,
    });
    const json_mod = json_dep.module("json");

    // List of all examples
    const examples = [_]struct {
        name: []const u8,
        source: []const u8,
        description: []const u8,
    }{
        .{
            .name = "01_basic_parsing",
            .source = "01_basic_parsing.zig",
            .description = "Basic JSON parsing examples",
        },
        .{
            .name = "02_encoding",
            .source = "02_encoding.zig",
            .description = "JSON encoding/serialization examples",
        },
        .{
            .name = "03_schema_validation",
            .source = "03_schema_validation.zig",
            .description = "JSON Schema validation examples",
        },
        .{
            .name = "04_unmarshaling",
            .source = "04_unmarshaling.zig",
            .description = "JSON to Zig type unmarshaling examples",
        },
        .{
            .name = "05_field_tags",
            .source = "05_field_tags.zig",
            .description = "Struct field tag configuration examples",
        },
        .{
            .name = "06_json_patch",
            .source = "06_json_patch.zig",
            .description = "RFC 6902 JSON Patch examples",
        },
        .{
            .name = "07_jsonpath",
            .source = "07_jsonpath.zig",
            .description = "JSONPath query language examples",
        },
        .{
            .name = "08_streaming",
            .source = "08_streaming.zig",
            .description = "Streaming tokenizer and encoder examples",
        },
        .{
            .name = "09_custom_marshaler",
            .source = "09_custom_marshaler.zig",
            .description = "Custom jsonMarshal/jsonUnmarshal examples",
        },
        .{
            .name = "10_json5",
            .source = "10_json5.zig",
            .description = "JSON5 extended syntax examples",
        },
    };

    // Create build steps for each example
    const run_all_step = b.step("run-all", "Run all examples");

    inline for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.source),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "json", .module = json_mod },
                },
            }),
        });

        // Install artifact
        b.installArtifact(exe);

        // Create run step
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());

        // Create named step for this example
        const run_step = b.step(
            "run-" ++ example.name[0..2], // e.g., "run-01"
            example.description,
        );
        run_step.dependOn(&run_cmd.step);

        // Add to run-all
        run_all_step.dependOn(&run_cmd.step);
    }
}
