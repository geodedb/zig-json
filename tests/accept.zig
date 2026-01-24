//! Acceptance Tests for zigjsonschema
//!
//! These tests verify the library meets the specification requirements.

const std = @import("std");
const json = @import("json");

// ============================================================
// T1: Parse + debugJson Round-trip
// ============================================================

test "T1: parse and debugJson round-trip" {
    const allocator = std.testing.allocator;

    const input =
        \\{"b":2,"a":[1,true,"\u00A9"]}
    ;

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    const output = try json.debugJson(allocator, doc.root);
    defer allocator.free(output);

    // Expected: sorted keys, non-ASCII escaped as \uXXXX
    // {"a":[1,true,"\u00A9"],"b":2}
    const expected = "{\"a\":[1,true,\"\\u00A9\"],\"b\":2}";
    try std.testing.expectEqualStrings(expected, output);
}

// ============================================================
// T2: Invalid Surrogate Detection
// ============================================================

test "T2: lone high surrogate error" {
    const allocator = std.testing.allocator;

    // High surrogate without low surrogate
    const input = "\"\\uD83D\"";

    var err = json.ParseError.init();
    const result = json.parse(allocator, input, .{}, &err);

    try std.testing.expectError(error.JsonParse, result);
    try std.testing.expectEqual(json.ErrorCode.InvalidSurrogate, err.code);
}

test "T2: lone low surrogate error" {
    const allocator = std.testing.allocator;

    // Low surrogate without high surrogate
    const input = "\"\\uDE00\"";

    var err = json.ParseError.init();
    const result = json.parse(allocator, input, .{}, &err);

    try std.testing.expectError(error.JsonParse, result);
    try std.testing.expectEqual(json.ErrorCode.InvalidSurrogate, err.code);
}

test "T2: valid surrogate pair" {
    const allocator = std.testing.allocator;

    // Valid surrogate pair for U+1F600 (grinning face)
    const input = "\"\\uD83D\\uDE00\"";

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    // Should decode to UTF-8 bytes for U+1F600
    try std.testing.expectEqualStrings("\xF0\x9F\x98\x80", doc.root.str);
}

// ============================================================
// T3: Schema Validation with Multiple Errors
// ============================================================

test "T3: schema validation with errors" {
    const allocator = std.testing.allocator;

    // Schema: requires name (string), age (integer >= 0), email (format: email)
    const schema_json =
        \\{
        \\  "type": "object",
        \\  "required": ["name", "age"],
        \\  "properties": {
        \\    "name": {"type": "string"},
        \\    "age": {"type": "integer", "minimum": 0},
        \\    "email": {"type": "string", "format": "email"}
        \\  }
        \\}
    ;

    // Instance: missing name, age is negative, email is invalid
    const instance_json =
        \\{
        \\  "age": -5,
        \\  "email": "not-an-email"
        \\}
    ;

    var err = json.ParseError.init();

    var schema_doc = try json.parse(allocator, schema_json, .{}, &err);
    defer schema_doc.deinit();

    var compiled = try json.compileSchema(allocator, &schema_doc, .{}, null, &err);
    defer compiled.deinit();

    var inst_doc = try json.parse(allocator, instance_json, .{}, &err);
    defer inst_doc.deinit();

    const report = try json.validate(allocator, &compiled, inst_doc.root, .{});
    defer {
        for (report.errors) |e| {
            allocator.free(e.instance_ptr);
            allocator.free(e.schema_ptr);
            allocator.free(e.keyword);
            allocator.free(e.message);
        }
        allocator.free(report.errors);
    }

    // Should have at least 3 errors: required (name), minimum (age), format (email)
    try std.testing.expect(!report.ok);
    try std.testing.expect(report.errors.len >= 3);

    // Verify errors are sorted by instance_ptr
    for (report.errors[0 .. report.errors.len - 1], report.errors[1..]) |a, b| {
        const cmp = std.mem.order(u8, a.instance_ptr, b.instance_ptr);
        try std.testing.expect(cmp != .gt);
    }
}

// ============================================================
// T4: $ref and Pattern Validation
// ============================================================

test "T4: ref and pattern validation" {
    const allocator = std.testing.allocator;

    // Schema with $defs and $ref
    const schema_json =
        \\{
        \\  "$defs": {
        \\    "positiveInt": {
        \\      "type": "integer",
        \\      "minimum": 1
        \\    }
        \\  },
        \\  "type": "object",
        \\  "properties": {
        \\    "count": {"$ref": "#/$defs/positiveInt"},
        \\    "code": {"type": "string", "pattern": "^[A-Z]{3}$"}
        \\  }
        \\}
    ;

    var err = json.ParseError.init();

    var schema_doc = try json.parse(allocator, schema_json, .{}, &err);
    defer schema_doc.deinit();

    var compiled = try json.compileSchema(allocator, &schema_doc, .{}, null, &err);
    defer compiled.deinit();

    // Valid instance
    const valid_json = "{\"count\":5,\"code\":\"ABC\"}";
    var valid_doc = try json.parse(allocator, valid_json, .{}, &err);
    defer valid_doc.deinit();

    const valid_report = try json.validate(allocator, &compiled, valid_doc.root, .{});
    defer allocator.free(valid_report.errors);
    try std.testing.expect(valid_report.ok);

    // Invalid instance: count is 0 (below minimum), code doesn't match pattern
    const invalid_json = "{\"count\":0,\"code\":\"ab\"}";
    var invalid_doc = try json.parse(allocator, invalid_json, .{}, &err);
    defer invalid_doc.deinit();

    const invalid_report = try json.validate(allocator, &compiled, invalid_doc.root, .{});
    defer {
        for (invalid_report.errors) |e| {
            allocator.free(e.instance_ptr);
            allocator.free(e.schema_ptr);
            allocator.free(e.keyword);
            allocator.free(e.message);
        }
        allocator.free(invalid_report.errors);
    }

    try std.testing.expect(!invalid_report.ok);
    try std.testing.expect(invalid_report.errors.len >= 2);
}

// ============================================================
// Additional Acceptance Tests
// ============================================================

test "strict RFC 8259: reject trailing commas" {
    const allocator = std.testing.allocator;
    var err = json.ParseError.init();

    // Array with trailing comma
    const arr_result = json.parse(allocator, "[1,2,]", .{}, &err);
    try std.testing.expectError(error.JsonParse, arr_result);

    // Object with trailing comma
    const obj_result = json.parse(allocator, "{\"a\":1,}", .{}, &err);
    try std.testing.expectError(error.JsonParse, obj_result);
}

test "strict RFC 8259: reject leading zeros" {
    const allocator = std.testing.allocator;
    var err = json.ParseError.init();

    const result = json.parse(allocator, "007", .{}, &err);
    try std.testing.expectError(error.JsonParse, result);
    try std.testing.expectEqual(json.ErrorCode.InvalidNumber, err.code);
}

test "strict RFC 8259: reject unescaped control chars" {
    const allocator = std.testing.allocator;
    var err = json.ParseError.init();

    // Tab character in string (must be escaped as \t)
    const result = json.parse(allocator, "\"a\tb\"", .{}, &err);
    try std.testing.expectError(error.JsonParse, result);
    try std.testing.expectEqual(json.ErrorCode.InvalidString, err.code);
}

test "BOM handling" {
    const allocator = std.testing.allocator;
    var err = json.ParseError.init();

    // UTF-8 BOM followed by null
    var doc = try json.parse(allocator, "\xEF\xBB\xBFnull", .{}, &err);
    defer doc.deinit();

    try std.testing.expect(doc.root == .null);
}

test "duplicate key rejection" {
    const allocator = std.testing.allocator;
    var err = json.ParseError.init();

    const result = json.parse(allocator, "{\"a\":1,\"a\":2}", .{ .unique_keys = true }, &err);
    try std.testing.expectError(error.JsonParse, result);
    try std.testing.expectEqual(json.ErrorCode.DuplicateKey, err.code);
}

test "number: decimal precision preserved" {
    const allocator = std.testing.allocator;
    var err = json.ParseError.init();

    // Parse a decimal number
    var doc = try json.parse(allocator, "123.456", .{}, &err);
    defer doc.deinit();

    // The lexeme should be preserved exactly
    try std.testing.expectEqualStrings("123.456", doc.root.num.lexeme);

    // Stringify should output the same lexeme
    const output = try json.stringify(allocator, doc.root);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("123.456", output);
}

test "number: integer detection" {
    const allocator = std.testing.allocator;
    var err = json.ParseError.init();

    // Integer
    var int_doc = try json.parse(allocator, "42", .{}, &err);
    defer int_doc.deinit();
    try std.testing.expect(int_doc.root.num.isInteger());

    // Float that's actually an integer
    var whole_doc = try json.parse(allocator, "5.0", .{}, &err);
    defer whole_doc.deinit();
    try std.testing.expect(whole_doc.root.num.isInteger());

    // Float with fractional part
    var float_doc = try json.parse(allocator, "3.14", .{}, &err);
    defer float_doc.deinit();
    try std.testing.expect(!float_doc.root.num.isInteger());
}

test "value equality" {
    const allocator = std.testing.allocator;
    var err = json.ParseError.init();

    var doc1 = try json.parse(allocator, "{\"a\":1,\"b\":2}", .{}, &err);
    defer doc1.deinit();

    var doc2 = try json.parse(allocator, "{\"b\":2,\"a\":1}", .{ .unique_keys = false }, &err);
    defer doc2.deinit();

    // Objects with same content (different order) should be equal
    try std.testing.expect(doc1.root.eql(doc2.root));
}
