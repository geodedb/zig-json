// SPDX-License-Identifier: Apache-2.0
// Example 03: JSON Schema Validation
//
// This example demonstrates how to validate JSON data against JSON Schema
// using the library's draft 2020-12 compliant validator.

const std = @import("std");
const json = @import("json");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var err = json.ParseError.init();

    // =========================================================================
    // 1. Basic type validation
    // =========================================================================
    std.debug.print("=== 1. Basic Type Validation ===\n", .{});

    const type_schema =
        \\{
        \\  "type": "string"
        \\}
    ;

    var type_schema_doc = try json.parse(allocator, type_schema, .{}, &err);
    defer type_schema_doc.deinit();

    var compiled_type = try json.compileSchema(allocator, &type_schema_doc, .{}, null, &err);
    defer compiled_type.deinit();

    // Valid string
    var valid_str = try json.parse(allocator, "\"hello world\"", .{}, &err);
    defer valid_str.deinit();

    var result1 = try json.validate(allocator, &compiled_type, valid_str.root, .{});
    defer result1.deinit(allocator);
    std.debug.print("  \"hello world\" is valid string: {}\n", .{result1.ok});

    // Invalid (number instead of string)
    var invalid_num = try json.parse(allocator, "42", .{}, &err);
    defer invalid_num.deinit();

    var result2 = try json.validate(allocator, &compiled_type, invalid_num.root, .{});
    defer result2.deinit(allocator);
    std.debug.print("  42 is valid string: {} (expected false)\n", .{result2.ok});

    // =========================================================================
    // 2. Object schema with required fields
    // =========================================================================
    std.debug.print("\n=== 2. Object Schema with Required Fields ===\n", .{});

    const user_schema =
        \\{
        \\  "type": "object",
        \\  "required": ["name", "email"],
        \\  "properties": {
        \\    "name": {"type": "string", "minLength": 1},
        \\    "email": {"type": "string", "format": "email"},
        \\    "age": {"type": "integer", "minimum": 0, "maximum": 150}
        \\  },
        \\  "additionalProperties": false
        \\}
    ;

    var user_schema_doc = try json.parse(allocator, user_schema, .{}, &err);
    defer user_schema_doc.deinit();

    var compiled_user = try json.compileSchema(allocator, &user_schema_doc, .{}, null, &err);
    defer compiled_user.deinit();

    // Valid user
    const valid_user_json =
        \\{"name": "Alice", "email": "alice@example.com", "age": 30}
    ;
    var valid_user = try json.parse(allocator, valid_user_json, .{}, &err);
    defer valid_user.deinit();

    var result3 = try json.validate(allocator, &compiled_user, valid_user.root, .{});
    defer result3.deinit(allocator);
    std.debug.print("  Valid user: {}\n", .{result3.ok});

    // Invalid user (missing required field)
    const missing_email_json =
        \\{"name": "Bob"}
    ;
    var missing_email = try json.parse(allocator, missing_email_json, .{}, &err);
    defer missing_email.deinit();

    var result4 = try json.validate(allocator, &compiled_user, missing_email.root, .{});
    defer result4.deinit(allocator);
    std.debug.print("  Missing email is valid: {} (expected false)\n", .{result4.ok});
    if (result4.errors.len > 0) {
        std.debug.print("    Error: {s}\n", .{result4.errors[0].message});
    }

    // =========================================================================
    // 3. Numeric constraints
    // =========================================================================
    std.debug.print("\n=== 3. Numeric Constraints ===\n", .{});

    const number_schema =
        \\{
        \\  "type": "number",
        \\  "minimum": 0,
        \\  "maximum": 100,
        \\  "multipleOf": 5
        \\}
    ;

    var num_schema_doc = try json.parse(allocator, number_schema, .{}, &err);
    defer num_schema_doc.deinit();

    var compiled_num = try json.compileSchema(allocator, &num_schema_doc, .{}, null, &err);
    defer compiled_num.deinit();

    // Valid: 50 is between 0-100 and multiple of 5
    var valid_num = try json.parse(allocator, "50", .{}, &err);
    defer valid_num.deinit();

    var result5 = try json.validate(allocator, &compiled_num, valid_num.root, .{});
    defer result5.deinit(allocator);
    std.debug.print("  50 is valid: {}\n", .{result5.ok});

    // Invalid: 52 is not a multiple of 5
    var invalid_mult = try json.parse(allocator, "52", .{}, &err);
    defer invalid_mult.deinit();

    var result6 = try json.validate(allocator, &compiled_num, invalid_mult.root, .{});
    defer result6.deinit(allocator);
    std.debug.print("  52 is valid: {} (expected false)\n", .{result6.ok});

    // =========================================================================
    // 4. Array validation
    // =========================================================================
    std.debug.print("\n=== 4. Array Validation ===\n", .{});

    const array_schema =
        \\{
        \\  "type": "array",
        \\  "items": {"type": "string"},
        \\  "minItems": 1,
        \\  "maxItems": 5,
        \\  "uniqueItems": true
        \\}
    ;

    var arr_schema_doc = try json.parse(allocator, array_schema, .{}, &err);
    defer arr_schema_doc.deinit();

    var compiled_arr = try json.compileSchema(allocator, &arr_schema_doc, .{}, null, &err);
    defer compiled_arr.deinit();

    // Valid array
    var valid_arr = try json.parse(allocator, "[\"a\", \"b\", \"c\"]", .{}, &err);
    defer valid_arr.deinit();

    var result7 = try json.validate(allocator, &compiled_arr, valid_arr.root, .{});
    defer result7.deinit(allocator);
    std.debug.print("  [\"a\", \"b\", \"c\"] is valid: {}\n", .{result7.ok});

    // Invalid: has duplicates
    var dup_arr = try json.parse(allocator, "[\"a\", \"a\", \"b\"]", .{}, &err);
    defer dup_arr.deinit();

    var result8 = try json.validate(allocator, &compiled_arr, dup_arr.root, .{});
    defer result8.deinit(allocator);
    std.debug.print("  [\"a\", \"a\", \"b\"] (duplicates) is valid: {} (expected false)\n", .{result8.ok});

    // =========================================================================
    // 5. Conditional validation with if/then/else
    // =========================================================================
    std.debug.print("\n=== 5. Conditional Validation (if/then/else) ===\n", .{});

    const conditional_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "type": {"type": "string"},
        \\    "value": {}
        \\  },
        \\  "if": {
        \\    "properties": {"type": {"const": "number"}}
        \\  },
        \\  "then": {
        \\    "properties": {"value": {"type": "number"}}
        \\  },
        \\  "else": {
        \\    "properties": {"value": {"type": "string"}}
        \\  }
        \\}
    ;

    var cond_schema_doc = try json.parse(allocator, conditional_schema, .{}, &err);
    defer cond_schema_doc.deinit();

    var compiled_cond = try json.compileSchema(allocator, &cond_schema_doc, .{}, null, &err);
    defer compiled_cond.deinit();

    // Valid: type is "number" so value should be a number
    const num_type_json =
        \\{"type": "number", "value": 42}
    ;
    var num_type_doc = try json.parse(allocator, num_type_json, .{}, &err);
    defer num_type_doc.deinit();

    var result9 = try json.validate(allocator, &compiled_cond, num_type_doc.root, .{});
    defer result9.deinit(allocator);
    std.debug.print("  type=number with value=42: {}\n", .{result9.ok});

    // Valid: type is "text" so value should be a string
    const str_type_json =
        \\{"type": "text", "value": "hello"}
    ;
    var str_type_doc = try json.parse(allocator, str_type_json, .{}, &err);
    defer str_type_doc.deinit();

    var result10 = try json.validate(allocator, &compiled_cond, str_type_doc.root, .{});
    defer result10.deinit(allocator);
    std.debug.print("  type=text with value=\"hello\": {}\n", .{result10.ok});

    // =========================================================================
    // 6. Using $ref for schema composition
    // =========================================================================
    std.debug.print("\n=== 6. Schema Composition with $ref ===\n", .{});

    const ref_schema =
        \\{
        \\  "$defs": {
        \\    "address": {
        \\      "type": "object",
        \\      "properties": {
        \\        "street": {"type": "string"},
        \\        "city": {"type": "string"}
        \\      },
        \\      "required": ["street", "city"]
        \\    }
        \\  },
        \\  "type": "object",
        \\  "properties": {
        \\    "name": {"type": "string"},
        \\    "home": {"$ref": "#/$defs/address"},
        \\    "work": {"$ref": "#/$defs/address"}
        \\  }
        \\}
    ;

    var ref_schema_doc = try json.parse(allocator, ref_schema, .{}, &err);
    defer ref_schema_doc.deinit();

    var compiled_ref = try json.compileSchema(allocator, &ref_schema_doc, .{}, null, &err);
    defer compiled_ref.deinit();

    const valid_refs_json =
        \\{
        \\  "name": "Alice",
        \\  "home": {"street": "123 Main St", "city": "Boston"},
        \\  "work": {"street": "456 Office Blvd", "city": "Cambridge"}
        \\}
    ;
    var valid_refs_doc = try json.parse(allocator, valid_refs_json, .{}, &err);
    defer valid_refs_doc.deinit();

    var result11 = try json.validate(allocator, &compiled_ref, valid_refs_doc.root, .{});
    defer result11.deinit(allocator);
    std.debug.print("  Document with referenced addresses: {}\n", .{result11.ok});

    // =========================================================================
    // 7. Displaying validation errors
    // =========================================================================
    std.debug.print("\n=== 7. Displaying Validation Errors ===\n", .{});

    const strict_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "id": {"type": "integer", "minimum": 1},
        \\    "name": {"type": "string", "minLength": 2}
        \\  },
        \\  "required": ["id", "name"]
        \\}
    ;

    var strict_schema_doc = try json.parse(allocator, strict_schema, .{}, &err);
    defer strict_schema_doc.deinit();

    var compiled_strict = try json.compileSchema(allocator, &strict_schema_doc, .{}, null, &err);
    defer compiled_strict.deinit();

    // Multiple errors: missing name, id too small
    const bad_json =
        \\{"id": 0}
    ;
    var bad_doc = try json.parse(allocator, bad_json, .{}, &err);
    defer bad_doc.deinit();

    var result12 = try json.validate(allocator, &compiled_strict, bad_doc.root, .{});
    defer result12.deinit(allocator);

    std.debug.print("  Validation result: {}\n", .{result12.ok});
    std.debug.print("  Number of errors: {d}\n", .{result12.errors.len});
    for (result12.errors) |e| {
        std.debug.print("    - [{s}] {s}: {s}\n", .{ e.instance_ptr, e.keyword, e.message });
    }

    std.debug.print("\nAll examples completed successfully!\n", .{});
}
