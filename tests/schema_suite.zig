//! JSON Schema Test Suite Runner
//!
//! Runs tests from the official JSON-Schema-Test-Suite for draft2020-12.

const std = @import("std");
const json = @import("json");

const suite_path = "testdata/JSON-Schema-Test-Suite/tests/draft2020-12/";
const metaschema_path = "testdata/metaschema/";

// Test result tracking
const Tally = struct {
    total: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
};

/// Totals for the whole suite run, printed by the summary test.
var tally: Tally = .{};

/// SONNY-2426: the only groups allowed to skip. At the suite commit
/// scripts/fetch-json-schema-test-suite.sh pins (fe8c2f0), these five cases
/// are the ones whose schemas do not compile: their regexes use Unicode
/// property escapes (\p{...}), which the regex engine does not support. Any
/// other group whose schema fails to compile fails its file, so a compile
/// regression cannot pass as a wave of skips. Bumping the pin means
/// revisiting this list.
const known_skips = [_]struct { file: []const u8, group: []const u8 }{
    .{ .file = "pattern.json", .group = "pattern with Unicode property escape requires unicode mode" }, // 3 cases
    .{ .file = "patternProperties.json", .group = "patternProperties with Unicode property escape" }, // 2 cases
};

fn isKnownSkip(file: []const u8, group: []const u8) bool {
    for (known_skips) |known| {
        if (std.mem.eql(u8, known.file, file) and std.mem.eql(u8, known.group, group)) return true;
    }
    return false;
}

/// Print a runner message to `out`, or to stderr when `out` is null.
fn printTo(out: ?*std.Io.Writer, comptime fmt: []const u8, args: anytype) void {
    if (out) |w| {
        w.print(fmt, args) catch {};
    } else {
        std.debug.print(fmt, args);
    }
}

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
    const path = try std.fmt.bufPrint(&path_buf, "{s}{s}", .{ suite_path, filename });

    const content = readTestFile(allocator, path) catch |e| {
        // SONNY-2426: a missing file fails; it is not skipped. The suite is
        // fetched, not vendored (scripts/fetch-json-schema-test-suite.sh), and
        // build.zig refuses to run test-schema without it. Skipping here let
        // test-all pass with a vacuous "Total: 0".
        std.debug.print("Failed to read test file {s}: {}\n", .{ filename, e });
        return e;
    };
    defer allocator.free(content);

    return runSuiteText(allocator, &tally, null, filename, content);
}

/// Run every case in one suite file's JSON text, adding the results to `t` and
/// reporting failing cases to `out` (stderr when null).
///
/// SONNY-2426: any failing case, including a validation error, fails the file
/// with error.SchemaSuiteCaseFailed once every case has run and been reported,
/// so the test-schema step exits non-zero. Only a group listed in known_skips
/// may skip; any other schema that fails to compile, and any malformed group or
/// case, counts as failed and is reported.
fn runSuiteText(allocator: std.mem.Allocator, t: *Tally, out: ?*std.Io.Writer, filename: []const u8, content: []const u8) !void {
    var err = json.ParseError.init();
    var suite_doc = json.parse(allocator, content, .{}, &err) catch |e| {
        printTo(out, "Failed to parse test file {s}: {}\n", .{ filename, e });
        return e;
    };
    defer suite_doc.deinit();

    // Each test file is an array of test groups
    if (suite_doc.root != .arr) {
        printTo(out, "Test file {s} is not an array of test groups\n", .{filename});
        return error.InvalidSuiteFile;
    }
    const groups = suite_doc.root.arr;
    const failed_before = t.failed;

    for (groups) |group| {
        const group_desc = getStr(group, "description") orelse "unknown";
        const schema_value = getObj(group, "schema");
        const tests_arr = getArr(group, "tests");
        if (schema_value == null or tests_arr == null) {
            printTo(out, "FAIL [{s}] {s}: malformed group (no \"schema\" or \"tests\")\n", .{ filename, group_desc });
            t.total += 1;
            t.failed += 1;
            continue;
        }
        const cases = tests_arr.?;

        // Compile the schema - we don't need the arena since compileSchema only uses doc.root
        var schema_doc = json.Document{
            .root = schema_value.?,
            .arena = undefined,
        };

        var schema_err = json.ParseError.init();
        var compiled = json.compileSchema(allocator, &schema_doc, .{}, metaschema_resolver, &schema_err) catch |e| {
            t.total += cases.len;
            if (isKnownSkip(filename, group_desc)) {
                t.skipped += cases.len;
            } else {
                printTo(out, "FAIL [{s}] {s}: schema did not compile ({s}) and is not a known skip\n", .{ filename, group_desc, @errorName(e) });
                t.failed += cases.len;
            }
            continue;
        };
        defer compiled.deinit();

        for (cases) |test_case| {
            t.total += 1;

            const test_desc = getStr(test_case, "description") orelse "unknown";
            const data = getVal(test_case, "data") orelse {
                printTo(out, "FAIL [{s}] {s} / {s}: malformed case (no \"data\")\n", .{ filename, group_desc, test_desc });
                t.failed += 1;
                continue;
            };
            const expected_valid = getBool(test_case, "valid") orelse {
                printTo(out, "FAIL [{s}] {s} / {s}: malformed case (no \"valid\")\n", .{ filename, group_desc, test_desc });
                t.failed += 1;
                continue;
            };

            const report = json.validate(allocator, &compiled, data, .{}) catch |e| {
                printTo(out, "FAIL [{s}] {s} / {s}: validation error {}\n", .{ filename, group_desc, test_desc, e });
                t.failed += 1;
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
                t.passed += 1;
            } else {
                printTo(out, "FAIL [{s}] {s} / {s}: expected valid={}, got valid={}\n", .{ filename, group_desc, test_desc, expected_valid, actual_valid });
                t.failed += 1;
            }
        }
    }

    if (t.failed > failed_before) return error.SchemaSuiteCaseFailed;
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
// Runner self-test
// ============================================================

// SONNY-2426: the runner's own pass/fail logic. A failing case used to be
// counted and printed but never failed anything, so `zig build test-schema`
// (and test-all) exited 0 with "Failed: 1" in the summary. These run on
// in-memory suite files, so they need no fetched fixtures, keep their own
// tally, and report into a buffer (a passing run stays silent).
test "schema suite runner: a failing case fails the file" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();

    // One case passes and one has a flipped expectation: the file fails, and
    // the failing case is reported.
    const flipped =
        \\[{"description": "integers", "schema": {"type": "integer"}, "tests": [
        \\  {"description": "1 is an integer", "data": 1, "valid": true},
        \\  {"description": "flipped", "data": 1, "valid": false}]}]
    ;
    var t: Tally = .{};
    try std.testing.expectError(error.SchemaSuiteCaseFailed, runSuiteText(a, &t, &out.writer, "self-test.json", flipped));
    try std.testing.expectEqual(Tally{ .total = 2, .passed = 1, .failed = 1 }, t);
    try std.testing.expectEqualStrings(
        "FAIL [self-test.json] integers / flipped: expected valid=false, got valid=true\n",
        out.written(),
    );

    // A file that is not an array of groups is an error, not a silent pass.
    out.clearRetainingCapacity();
    t = .{};
    try std.testing.expectError(error.InvalidSuiteFile, runSuiteText(a, &t, &out.writer, "self-test.json", "{}"));
    try std.testing.expectEqual(Tally{}, t);
}

// SONNY-2426: skips are pinned. Every group whose schema failed to compile
// used to count as skipped, without limit, so a compile regression passed in
// silence: with minContains broken, the suite reported Skipped 38 (from 5),
// Passed 821 (from 854), 14/14 steps, exit 0. Only the groups listed in
// known_skips may skip. Any other schema that fails to compile, and any
// malformed group or case, fails the file and is reported.
test "schema suite runner: only the pinned skips may skip" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();

    // A schema that fails to compile (an invalid regex) in a group that is not
    // a known skip fails the file; its cases count as failed.
    const unexpected =
        \\[{"description": "invalid regex", "schema": {"pattern": "("}, "tests": [
        \\  {"description": "a", "data": "a", "valid": true},
        \\  {"description": "b", "data": "b", "valid": true}]},
        \\ {"description": "integers", "schema": {"type": "integer"}, "tests": [
        \\  {"description": "1 is an integer", "data": 1, "valid": true}]}]
    ;
    var t: Tally = .{};
    try std.testing.expectError(error.SchemaSuiteCaseFailed, runSuiteText(a, &t, &out.writer, "self-test.json", unexpected));
    try std.testing.expectEqual(Tally{ .total = 3, .passed = 1, .failed = 2 }, t);
    try std.testing.expectEqualStrings(
        "FAIL [self-test.json] invalid regex: schema did not compile (JsonParse) and is not a known skip\n",
        out.written(),
    );

    // The same failure under a pinned file and group description is a known
    // skip: counted as skipped, not failed, and silent.
    const pinned =
        \\[{"description": "pattern with Unicode property escape requires unicode mode",
        \\  "schema": {"pattern": "("}, "tests": [
        \\  {"description": "a", "data": "a", "valid": true}]}]
    ;
    out.clearRetainingCapacity();
    t = .{};
    try runSuiteText(a, &t, &out.writer, "pattern.json", pinned);
    try std.testing.expectEqual(Tally{ .total = 1, .skipped = 1 }, t);
    try std.testing.expectEqualStrings("", out.written());

    // Malformed groups and cases cannot drop out quietly either.
    const malformed =
        \\[{"description": "no tests", "schema": {"type": "integer"}},
        \\ {"description": "integers", "schema": {"type": "integer"}, "tests": [
        \\  {"description": "no expectation", "data": 1},
        \\  {"description": "no data", "valid": true}]}]
    ;
    out.clearRetainingCapacity();
    t = .{};
    try std.testing.expectError(error.SchemaSuiteCaseFailed, runSuiteText(a, &t, &out.writer, "self-test.json", malformed));
    try std.testing.expectEqual(Tally{ .total = 3, .failed = 3 }, t);
    try std.testing.expectEqualStrings(
        "FAIL [self-test.json] no tests: malformed group (no \"schema\" or \"tests\")\n" ++
            "FAIL [self-test.json] integers / no expectation: malformed case (no \"valid\")\n" ++
            "FAIL [self-test.json] integers / no data: malformed case (no \"data\")\n",
        out.written(),
    );
}

// ============================================================
// Summary (runs last)
// ============================================================

/// SONNY-2426: JSON_SCHEMA_SUITE_VERBOSE=1 prints the summary even when every
/// case passes.
fn verboseRequested() bool {
    const value = std.testing.environ.getAlloc(std.testing.allocator, "JSON_SCHEMA_SUITE_VERBOSE") catch return false;
    defer std.testing.allocator.free(value);
    return std.mem.eql(u8, value, "1");
}

// SONNY-2426: a passing run prints nothing. Zig's build runner shows any test
// stderr under a "failed command:" label even when the step succeeds, so an
// unconditional summary made every clean run look like a failure. The summary
// prints when a case failed (each failure has already printed its FAIL line)
// or when JSON_SCHEMA_SUITE_VERBOSE=1 asks for it.
test "schema suite: summary" {
    if (tally.failed == 0 and !verboseRequested()) return;

    std.debug.print("\n========================================\n", .{});
    std.debug.print("JSON Schema Test Suite Results:\n", .{});
    std.debug.print("  Total:   {}\n", .{tally.total});
    std.debug.print("  Passed:  {}\n", .{tally.passed});
    std.debug.print("  Failed:  {}\n", .{tally.failed});
    std.debug.print("  Skipped: {}\n", .{tally.skipped});
    std.debug.print("========================================\n", .{});

    // Allow some failures for unsupported features
    // but fail if pass rate drops below 80%
    if (tally.total > 0) {
        const pass_rate = @as(f64, @floatFromInt(tally.passed)) / @as(f64, @floatFromInt(tally.total - tally.skipped));
        std.debug.print("  Pass rate: {d:.1}%\n", .{pass_rate * 100});
    }
}
