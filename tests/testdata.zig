//! Edge Case Tests for JSON Parsing
//!
//! Tests parsing of valid and invalid JSON from the edge-testdata directory.

const std = @import("std");
const json = @import("json");

fn readTestFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(10 * 1024 * 1024));
}

// ============================================================
// Invalid JSON Tests
// ============================================================

test "invalid: missing-colon.json should fail to parse" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/invalid/missing-colon.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    const result = json.parse(allocator, content, .{}, &err);

    try std.testing.expectError(error.JsonParse, result);
}

test "invalid: unterminated.json should fail to parse" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/invalid/unterminated.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    const result = json.parse(allocator, content, .{}, &err);

    try std.testing.expectError(error.JsonParse, result);
}

test "invalid: binary-data.json should fail to parse" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/invalid/binary-data.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    const result = json.parse(allocator, content, .{}, &err);

    try std.testing.expectError(error.JsonParse, result);
}

// ============================================================
// Valid JSON Tests - Formatted
// ============================================================

test "valid: 64KB.json formatted" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/formatted/64KB.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, content, .{}, &err);
    defer doc.deinit();

    // Verify it's an array
    try std.testing.expect(doc.root == .arr);
    try std.testing.expect(doc.root.arr.len > 0);
}

test "valid: 128KB.json formatted" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/formatted/128KB.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, content, .{}, &err);
    defer doc.deinit();

    try std.testing.expect(doc.root == .arr);
}

test "valid: 256KB.json formatted" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/formatted/256KB.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, content, .{}, &err);
    defer doc.deinit();

    try std.testing.expect(doc.root == .arr);
}

test "valid: 512KB.json formatted" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/formatted/512KB.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, content, .{}, &err);
    defer doc.deinit();

    try std.testing.expect(doc.root == .arr);
}

test "valid: 1MB.json formatted" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/formatted/1MB.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, content, .{}, &err);
    defer doc.deinit();

    try std.testing.expect(doc.root == .arr);
}

// ============================================================
// Valid JSON Tests - Minified
// ============================================================

test "valid: 64KB-min.json minified" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/minified/64KB-min.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, content, .{}, &err);
    defer doc.deinit();

    try std.testing.expect(doc.root == .arr);
}

test "valid: 128KB-min.json minified" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/minified/128KB-min.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, content, .{}, &err);
    defer doc.deinit();

    try std.testing.expect(doc.root == .arr);
}

test "valid: 256KB-min.json minified" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/minified/256KB-min.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, content, .{}, &err);
    defer doc.deinit();

    try std.testing.expect(doc.root == .arr);
}

test "valid: 512KB-min.json minified" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/minified/512KB-min.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, content, .{}, &err);
    defer doc.deinit();

    try std.testing.expect(doc.root == .arr);
}

test "valid: 1MB-min.json minified" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/minified/1MB-min.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, content, .{}, &err);
    defer doc.deinit();

    try std.testing.expect(doc.root == .arr);
}

// ============================================================
// Round-trip Tests
// ============================================================

test "round-trip: parse and stringify 64KB" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/formatted/64KB.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, content, .{}, &err);
    defer doc.deinit();

    // Stringify
    const output = try json.stringify(allocator, doc.root);
    defer allocator.free(output);

    // Parse the stringified output
    var doc2 = try json.parse(allocator, output, .{}, &err);
    defer doc2.deinit();

    // Verify equality
    try std.testing.expect(doc.root.eql(doc2.root));
}

test "round-trip: parse and stringify 128KB" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/formatted/128KB.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, content, .{}, &err);
    defer doc.deinit();

    const output = try json.stringify(allocator, doc.root);
    defer allocator.free(output);

    var doc2 = try json.parse(allocator, output, .{}, &err);
    defer doc2.deinit();

    try std.testing.expect(doc.root.eql(doc2.root));
}

test "round-trip: parse and stringify 256KB" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/formatted/256KB.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, content, .{}, &err);
    defer doc.deinit();

    const output = try json.stringify(allocator, doc.root);
    defer allocator.free(output);

    var doc2 = try json.parse(allocator, output, .{}, &err);
    defer doc2.deinit();

    try std.testing.expect(doc.root.eql(doc2.root));
}

test "round-trip: parse and stringify 512KB" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/formatted/512KB.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, content, .{}, &err);
    defer doc.deinit();

    const output = try json.stringify(allocator, doc.root);
    defer allocator.free(output);

    var doc2 = try json.parse(allocator, output, .{}, &err);
    defer doc2.deinit();

    try std.testing.expect(doc.root.eql(doc2.root));
}

test "round-trip: parse and stringify 1MB" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/formatted/1MB.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, content, .{}, &err);
    defer doc.deinit();

    const output = try json.stringify(allocator, doc.root);
    defer allocator.free(output);

    var doc2 = try json.parse(allocator, output, .{}, &err);
    defer doc2.deinit();

    try std.testing.expect(doc.root.eql(doc2.root));
}

// ============================================================
// Round-trip with encode() function
// ============================================================

test "round-trip: parse and encode 64KB" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/formatted/64KB.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, content, .{}, &err);
    defer doc.deinit();

    // Use encode() instead of stringify()
    const output = try json.encode(allocator, doc.root, .{});
    defer allocator.free(output);

    var doc2 = try json.parse(allocator, output, .{}, &err);
    defer doc2.deinit();

    try std.testing.expect(doc.root.eql(doc2.root));
}

test "round-trip: parse and encode 128KB" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/formatted/128KB.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, content, .{}, &err);
    defer doc.deinit();

    const output = try json.encode(allocator, doc.root, .{});
    defer allocator.free(output);

    var doc2 = try json.parse(allocator, output, .{}, &err);
    defer doc2.deinit();

    try std.testing.expect(doc.root.eql(doc2.root));
}

test "round-trip: minified 64KB" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/minified/64KB-min.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, content, .{}, &err);
    defer doc.deinit();

    const output = try json.encode(allocator, doc.root, .{});
    defer allocator.free(output);

    var doc2 = try json.parse(allocator, output, .{}, &err);
    defer doc2.deinit();

    try std.testing.expect(doc.root.eql(doc2.root));
}

test "round-trip: minified 128KB" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/minified/128KB-min.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, content, .{}, &err);
    defer doc.deinit();

    const output = try json.encode(allocator, doc.root, .{});
    defer allocator.free(output);

    var doc2 = try json.parse(allocator, output, .{}, &err);
    defer doc2.deinit();

    try std.testing.expect(doc.root.eql(doc2.root));
}

test "round-trip: minified 256KB" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/minified/256KB-min.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, content, .{}, &err);
    defer doc.deinit();

    const output = try json.encode(allocator, doc.root, .{});
    defer allocator.free(output);

    var doc2 = try json.parse(allocator, output, .{}, &err);
    defer doc2.deinit();

    try std.testing.expect(doc.root.eql(doc2.root));
}

test "round-trip: minified 512KB" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/minified/512KB-min.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, content, .{}, &err);
    defer doc.deinit();

    const output = try json.encode(allocator, doc.root, .{});
    defer allocator.free(output);

    var doc2 = try json.parse(allocator, output, .{}, &err);
    defer doc2.deinit();

    try std.testing.expect(doc.root.eql(doc2.root));
}

test "round-trip: minified 1MB" {
    const allocator = std.testing.allocator;

    const content = try readTestFile(allocator, "testdata/edge-testdata/minified/1MB-min.json");
    defer allocator.free(content);

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, content, .{}, &err);
    defer doc.deinit();

    const output = try json.encode(allocator, doc.root, .{});
    defer allocator.free(output);

    var doc2 = try json.parse(allocator, output, .{}, &err);
    defer doc2.deinit();

    try std.testing.expect(doc.root.eql(doc2.root));
}

// ============================================================
// Round-trip Edge Cases
// ============================================================

test "round-trip: unicode strings" {
    const allocator = std.testing.allocator;

    // Use JSON escape sequences for unicode characters
    const input = "[\"hello\",\"world\",\"\\u00A9\",\"\\uD83D\\uDE00\",\"\\u4E2D\\u6587\"]";

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    const output = try json.encode(allocator, doc.root, .{});
    defer allocator.free(output);

    var doc2 = try json.parse(allocator, output, .{}, &err);
    defer doc2.deinit();

    try std.testing.expect(doc.root.eql(doc2.root));
}

test "round-trip: nested objects and arrays" {
    const allocator = std.testing.allocator;

    const input =
        \\{"a":{"b":{"c":[1,2,{"d":[3,4,5]}]}},"e":[{"f":1},{"g":2}]}
    ;

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    const output = try json.encode(allocator, doc.root, .{});
    defer allocator.free(output);

    var doc2 = try json.parse(allocator, output, .{}, &err);
    defer doc2.deinit();

    try std.testing.expect(doc.root.eql(doc2.root));
}

test "round-trip: all value types" {
    const allocator = std.testing.allocator;

    const input =
        \\{"null":null,"bool_true":true,"bool_false":false,"int":42,"neg_int":-123,"float":3.14159,"exp":1.5e10,"string":"hello\nworld","array":[1,2,3],"object":{"key":"value"}}
    ;

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    const output = try json.encode(allocator, doc.root, .{});
    defer allocator.free(output);

    var doc2 = try json.parse(allocator, output, .{}, &err);
    defer doc2.deinit();

    try std.testing.expect(doc.root.eql(doc2.root));
}

test "round-trip: escape sequences" {
    const allocator = std.testing.allocator;

    const input = "[\"\\\"quoted\\\"\",\"back\\\\slash\",\"new\\nline\",\"tab\\there\",\"return\\rhere\"]";

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    const output = try json.encode(allocator, doc.root, .{});
    defer allocator.free(output);

    var doc2 = try json.parse(allocator, output, .{}, &err);
    defer doc2.deinit();

    try std.testing.expect(doc.root.eql(doc2.root));
}

test "round-trip: empty containers" {
    const allocator = std.testing.allocator;

    const input = "{\"empty_array\":[],\"empty_object\":{}}";

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    const output = try json.encode(allocator, doc.root, .{});
    defer allocator.free(output);

    var doc2 = try json.parse(allocator, output, .{}, &err);
    defer doc2.deinit();

    try std.testing.expect(doc.root.eql(doc2.root));
}

test "round-trip: number precision" {
    const allocator = std.testing.allocator;

    const input = "[0,1,-1,123456789012345678901234567890,0.1,0.123456789,1e100,1.5e-10]";

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    const output = try json.encode(allocator, doc.root, .{});
    defer allocator.free(output);

    var doc2 = try json.parse(allocator, output, .{}, &err);
    defer doc2.deinit();

    try std.testing.expect(doc.root.eql(doc2.root));
}

test "round-trip: pretty print preserves values" {
    const allocator = std.testing.allocator;

    const input = "{\"a\":1,\"b\":[2,3],\"c\":{\"d\":4}}";

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    // Encode with pretty printing
    const output = try json.encode(allocator, doc.root, json.encode_mod.pretty_2);
    defer allocator.free(output);

    // Verify output contains newlines (is pretty-printed)
    try std.testing.expect(std.mem.indexOf(u8, output, "\n") != null);

    var doc2 = try json.parse(allocator, output, .{}, &err);
    defer doc2.deinit();

    try std.testing.expect(doc.root.eql(doc2.root));
}

test "round-trip: deeply nested structure" {
    const allocator = std.testing.allocator;

    // Create a deeply nested structure
    const input = "[[[[[[[[[[1]]]]]]]]]]";

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    const output = try json.encode(allocator, doc.root, .{});
    defer allocator.free(output);

    var doc2 = try json.parse(allocator, output, .{}, &err);
    defer doc2.deinit();

    try std.testing.expect(doc.root.eql(doc2.root));
}

test "round-trip: stringify vs encode equivalence" {
    const allocator = std.testing.allocator;

    const input = "{\"key\":\"value\",\"num\":42,\"arr\":[1,2,3]}";

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    const stringify_output = try json.stringify(allocator, doc.root);
    defer allocator.free(stringify_output);

    const encode_output = try json.encode(allocator, doc.root, .{});
    defer allocator.free(encode_output);

    // Both should produce the same minified output
    try std.testing.expectEqualStrings(stringify_output, encode_output);
}
