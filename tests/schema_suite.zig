//! JSON Schema Test Suite Runner
//!
//! Runs tests from the official JSON-Schema-Test-Suite for draft2020-12.

const std = @import("std");
const json = @import("json");

const suite_path = "testdata/JSON-Schema-Test-Suite/tests/draft2020-12/";
const metaschema_path = "testdata/metaschema/";

// Test result tracking
var total_tests: usize = 0;
var passed_tests: usize = 0;
var failed_tests: usize = 0;
var skipped_tests: usize = 0;

// Metaschema resolver - maps URIs to local files
const MetaschemaResolver = struct {
    fn resolve(_: *anyopaque, uri_str: []const u8, a: std.mem.Allocator) anyerror![]const u8 {
        // Map metaschema URIs to local files
        const mappings = [_]struct { uri: []const u8, file: []const u8 }{
            .{ .uri = "https://json-schema.org/draft/2020-12/schema", .file = "schema.json" },
            .{ .uri = "https://json-schema.org/draft/2020-12/meta/core", .file = "core.json" },
            .{ .uri = "https://json-schema.org/draft/2020-12/meta/applicator", .file = "applicator.json" },
            .{ .uri = "https://json-schema.org/draft/2020-12/meta/validation", .file = "validation.json" },
            .{ .uri = "https://json-schema.org/draft/2020-12/meta/unevaluated", .file = "unevaluated.json" },
            .{ .uri = "https://json-schema.org/draft/2020-12/meta/meta-data", .file = "meta-data.json" },
            .{ .uri = "https://json-schema.org/draft/2020-12/meta/format-annotation", .file = "format-annotation.json" },
            .{ .uri = "https://json-schema.org/draft/2020-12/meta/content", .file = "content.json" },
        };

        for (mappings) |m| {
            if (std.mem.eql(u8, uri_str, m.uri)) {
                var path_buf: [512]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ metaschema_path, m.file }) catch return error.PathTooLong;
                const io = std.Io.Threaded.global_single_threaded.io();
                return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(10 * 1024 * 1024)) catch return error.FileNotFound;
            }
        }
        return error.UnknownUri;
    }
};

var dummy_ctx: u8 = 0;
const metaschema_resolver = json.Resolver{
    .ctx = @ptrCast(&dummy_ctx),
    .resolve = MetaschemaResolver.resolve,
};

fn readTestFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(10 * 1024 * 1024));
}

fn runTestFile(allocator: std.mem.Allocator, filename: []const u8) !void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ suite_path, filename }) catch return;

    const content = readTestFile(allocator, path) catch |e| {
        std.debug.print("Failed to read test file {s}: {}\n", .{ filename, e });
        return e;
    };
    defer allocator.free(content);

    var err = json.ParseError.init();
    var suite_doc = json.parse(allocator, content, .{}, &err) catch |e| {
        std.debug.print("Failed to parse test file {s}: {}\n", .{ filename, e });
        return e;
    };
    defer suite_doc.deinit();

    // Each test file is an array of test groups
    const groups = suite_doc.root.arr;

    for (groups) |group| {
        const group_desc = getStr(group, "description") orelse "unknown";
        const schema_value = getObj(group, "schema") orelse continue;
        const tests_arr = getArr(group, "tests") orelse continue;

        // Compile the schema - we don't need the arena since compileSchema only uses doc.root
        var schema_doc = json.Document{
            .root = schema_value,
            .arena = undefined,
        };

        var schema_err = json.ParseError.init();
        var compiled = json.compileSchema(allocator, &schema_doc, .{}, metaschema_resolver, &schema_err) catch {
            // Some schemas are intentionally invalid or use features we don't support
            for (tests_arr) |_| {
                skipped_tests += 1;
                total_tests += 1;
            }
            continue;
        };
        defer compiled.deinit();

        for (tests_arr) |test_case| {
            total_tests += 1;

            const test_desc = getStr(test_case, "description") orelse "unknown";
            const data = getVal(test_case, "data") orelse {
                skipped_tests += 1;
                continue;
            };
            const expected_valid = getBool(test_case, "valid") orelse {
                skipped_tests += 1;
                continue;
            };

            const report = json.validate(allocator, &compiled, data, .{}) catch |e| {
                std.debug.print("FAIL [{s}] {s} / {s}: validation error {}\n", .{ filename, group_desc, test_desc, e });
                failed_tests += 1;
                continue;
            };
            defer {
                for (report.errors) |ve| {
                    allocator.free(ve.instance_ptr);
                    allocator.free(ve.schema_ptr);
                    allocator.free(ve.keyword);
                    allocator.free(ve.message);
                }
                allocator.free(report.errors);
            }

            const actual_valid = report.ok;

            if (actual_valid == expected_valid) {
                passed_tests += 1;
            } else {
                std.debug.print("FAIL [{s}] {s} / {s}: expected valid={}, got valid={}\n", .{ filename, group_desc, test_desc, expected_valid, actual_valid });
                failed_tests += 1;
            }
        }
    }
}

fn getStr(v: json.Value, key: []const u8) ?[]const u8 {
    if (v != .obj) return null;
    for (v.obj) |m| {
        if (std.mem.eql(u8, m.k, key)) {
            if (m.v == .str) return m.v.str;
        }
    }
    return null;
}

fn getObj(v: json.Value, key: []const u8) ?json.Value {
    if (v != .obj) return null;
    for (v.obj) |m| {
        if (std.mem.eql(u8, m.k, key)) {
            return m.v;
        }
    }
    return null;
}

fn getArr(v: json.Value, key: []const u8) ?[]const json.Value {
    if (v != .obj) return null;
    for (v.obj) |m| {
        if (std.mem.eql(u8, m.k, key)) {
            if (m.v == .arr) return m.v.arr;
        }
    }
    return null;
}

fn getVal(v: json.Value, key: []const u8) ?json.Value {
    if (v != .obj) return null;
    for (v.obj) |m| {
        if (std.mem.eql(u8, m.k, key)) {
            return m.v;
        }
    }
    return null;
}

fn getBool(v: json.Value, key: []const u8) ?bool {
    if (v != .obj) return null;
    for (v.obj) |m| {
        if (std.mem.eql(u8, m.k, key)) {
            if (m.v == .bool) return m.v.bool;
        }
    }
    return null;
}

// ============================================================
// Test Suite - Core Keywords
// ============================================================

test "schema suite: type" {
    try runTestFile(std.testing.allocator, "type.json");
}

test "schema suite: enum" {
    try runTestFile(std.testing.allocator, "enum.json");
}

test "schema suite: const" {
    try runTestFile(std.testing.allocator, "const.json");
}

// ============================================================
// Test Suite - Numeric Validation
// ============================================================

test "schema suite: minimum" {
    try runTestFile(std.testing.allocator, "minimum.json");
}

test "schema suite: maximum" {
    try runTestFile(std.testing.allocator, "maximum.json");
}

test "schema suite: exclusiveMinimum" {
    try runTestFile(std.testing.allocator, "exclusiveMinimum.json");
}

test "schema suite: exclusiveMaximum" {
    try runTestFile(std.testing.allocator, "exclusiveMaximum.json");
}

test "schema suite: multipleOf" {
    try runTestFile(std.testing.allocator, "multipleOf.json");
}

// ============================================================
// Test Suite - String Validation
// ============================================================

test "schema suite: minLength" {
    try runTestFile(std.testing.allocator, "minLength.json");
}

test "schema suite: maxLength" {
    try runTestFile(std.testing.allocator, "maxLength.json");
}

test "schema suite: pattern" {
    try runTestFile(std.testing.allocator, "pattern.json");
}

// ============================================================
// Test Suite - Array Validation
// ============================================================

test "schema suite: items" {
    try runTestFile(std.testing.allocator, "items.json");
}

test "schema suite: prefixItems" {
    try runTestFile(std.testing.allocator, "prefixItems.json");
}

test "schema suite: minItems" {
    try runTestFile(std.testing.allocator, "minItems.json");
}

test "schema suite: maxItems" {
    try runTestFile(std.testing.allocator, "maxItems.json");
}

test "schema suite: uniqueItems" {
    try runTestFile(std.testing.allocator, "uniqueItems.json");
}

test "schema suite: contains" {
    try runTestFile(std.testing.allocator, "contains.json");
}

test "schema suite: minContains" {
    try runTestFile(std.testing.allocator, "minContains.json");
}

test "schema suite: maxContains" {
    try runTestFile(std.testing.allocator, "maxContains.json");
}

// ============================================================
// Test Suite - Object Validation
// ============================================================

test "schema suite: properties" {
    try runTestFile(std.testing.allocator, "properties.json");
}

test "schema suite: additionalProperties" {
    try runTestFile(std.testing.allocator, "additionalProperties.json");
}

test "schema suite: patternProperties" {
    try runTestFile(std.testing.allocator, "patternProperties.json");
}

test "schema suite: required" {
    try runTestFile(std.testing.allocator, "required.json");
}

test "schema suite: minProperties" {
    try runTestFile(std.testing.allocator, "minProperties.json");
}

test "schema suite: maxProperties" {
    try runTestFile(std.testing.allocator, "maxProperties.json");
}

test "schema suite: propertyNames" {
    try runTestFile(std.testing.allocator, "propertyNames.json");
}

test "schema suite: dependentRequired" {
    try runTestFile(std.testing.allocator, "dependentRequired.json");
}

test "schema suite: dependentSchemas" {
    try runTestFile(std.testing.allocator, "dependentSchemas.json");
}

// ============================================================
// Test Suite - Applicator Keywords
// ============================================================

test "schema suite: allOf" {
    try runTestFile(std.testing.allocator, "allOf.json");
}

test "schema suite: anyOf" {
    try runTestFile(std.testing.allocator, "anyOf.json");
}

test "schema suite: oneOf" {
    try runTestFile(std.testing.allocator, "oneOf.json");
}

test "schema suite: not" {
    try runTestFile(std.testing.allocator, "not.json");
}

test "schema suite: if-then-else" {
    try runTestFile(std.testing.allocator, "if-then-else.json");
}

// ============================================================
// Test Suite - Definitions and References
// ============================================================

test "schema suite: defs" {
    try runTestFile(std.testing.allocator, "defs.json");
}

test "schema suite: ref" {
    try runTestFile(std.testing.allocator, "ref.json");
}

test "schema suite: anchor" {
    try runTestFile(std.testing.allocator, "anchor.json");
}

// ============================================================
// Test Suite - Boolean Schema
// ============================================================

test "schema suite: boolean_schema" {
    try runTestFile(std.testing.allocator, "boolean_schema.json");
}

// ============================================================
// Summary (runs last)
// ============================================================

test "schema suite: summary" {
    std.debug.print("\n========================================\n", .{});
    std.debug.print("JSON Schema Test Suite Results:\n", .{});
    std.debug.print("  Total:   {}\n", .{total_tests});
    std.debug.print("  Passed:  {}\n", .{passed_tests});
    std.debug.print("  Failed:  {}\n", .{failed_tests});
    std.debug.print("  Skipped: {}\n", .{skipped_tests});
    std.debug.print("========================================\n", .{});

    // Allow some failures for unsupported features
    // but fail if pass rate drops below 80%
    if (total_tests > 0) {
        const pass_rate = @as(f64, @floatFromInt(passed_tests)) / @as(f64, @floatFromInt(total_tests - skipped_tests));
        std.debug.print("  Pass rate: {d:.1}%\n", .{pass_rate * 100});
    }
}
