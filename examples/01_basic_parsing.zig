// SPDX-License-Identifier: Apache-2.0
// Example 01: Basic JSON Parsing
//
// This example demonstrates how to parse JSON strings into Zig data structures
// using the json library's RFC 8259 compliant parser.

const std = @import("std");
const json = @import("json");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // =========================================================================
    // 1. Parse a simple JSON object
    // =========================================================================
    std.debug.print("=== 1. Parsing a Simple Object ===\n", .{});

    const simple_json =
        \\{"name": "Alice", "age": 30, "active": true}
    ;

    // Create an error structure to capture parse errors
    var err = json.ParseError.init();

    // Parse the JSON string
    var doc = try json.parse(allocator, simple_json, .{}, &err);
    defer doc.deinit(); // Always clean up the document

    // Access object members
    for (doc.root.obj) |member| {
        std.debug.print("  Key: {s}, ", .{member.k});
        switch (member.v) {
            .str => |s| std.debug.print("Value (string): {s}\n", .{s}),
            .num => |n| std.debug.print("Value (number): {s}\n", .{n.lexeme}),
            .bool => |b| std.debug.print("Value (bool): {}\n", .{b}),
            else => std.debug.print("Value (other type)\n", .{}),
        }
    }

    // =========================================================================
    // 2. Parse a JSON array
    // =========================================================================
    std.debug.print("\n=== 2. Parsing an Array ===\n", .{});

    const array_json =
        \\[1, 2, 3, "four", true, null]
    ;

    var arr_doc = try json.parse(allocator, array_json, .{}, &err);
    defer arr_doc.deinit();

    std.debug.print("  Array has {} elements:\n", .{arr_doc.root.arr.len});
    for (arr_doc.root.arr, 0..) |item, i| {
        std.debug.print("    [{d}]: ", .{i});
        switch (item) {
            .null => std.debug.print("null\n", .{}),
            .bool => |b| std.debug.print("{}\n", .{b}),
            .num => |n| std.debug.print("{s}\n", .{n.lexeme}),
            .str => |s| std.debug.print("\"{s}\"\n", .{s}),
            else => std.debug.print("(complex value)\n", .{}),
        }
    }

    // =========================================================================
    // 3. Parse nested JSON structures
    // =========================================================================
    std.debug.print("\n=== 3. Parsing Nested Structures ===\n", .{});

    const nested_json =
        \\{
        \\  "user": {
        \\    "profile": {
        \\      "name": "Bob",
        \\      "email": "bob@example.com"
        \\    },
        \\    "tags": ["developer", "zig", "json"]
        \\  }
        \\}
    ;

    var nested_doc = try json.parse(allocator, nested_json, .{}, &err);
    defer nested_doc.deinit();

    // Navigate to nested values manually
    const root_obj = nested_doc.root.obj;
    for (root_obj) |m| {
        if (std.mem.eql(u8, m.k, "user")) {
            std.debug.print("  Found 'user' object\n", .{});
            for (m.v.obj) |user_m| {
                if (std.mem.eql(u8, user_m.k, "profile")) {
                    std.debug.print("    Found 'profile' with fields:\n", .{});
                    for (user_m.v.obj) |profile_m| {
                        std.debug.print("      {s}: {s}\n", .{ profile_m.k, profile_m.v.str });
                    }
                } else if (std.mem.eql(u8, user_m.k, "tags")) {
                    std.debug.print("    Found 'tags' array:\n", .{});
                    for (user_m.v.arr) |tag| {
                        std.debug.print("      - {s}\n", .{tag.str});
                    }
                }
            }
        }
    }

    // =========================================================================
    // 4. Using parse options
    // =========================================================================
    std.debug.print("\n=== 4. Parse Options ===\n", .{});

    // Parse with custom limits
    const opts = json.ParseOptions{
        .max_bytes = 1024 * 1024, // 1MB limit
        .max_depth = 64, // Maximum nesting depth
        .max_nodes = 10000, // Maximum number of JSON nodes
        .allow_bom = true, // Allow UTF-8 BOM
        .unique_keys = true, // Reject duplicate keys
    };

    var opts_doc = try json.parse(allocator, simple_json, opts, &err);
    defer opts_doc.deinit();
    std.debug.print("  Parsed with custom options successfully\n", .{});

    // =========================================================================
    // 5. Handling parse errors
    // =========================================================================
    std.debug.print("\n=== 5. Handling Parse Errors ===\n", .{});

    const invalid_json = "{ invalid json }";
    var parse_err = json.ParseError.init();

    const result = json.parse(allocator, invalid_json, .{}, &parse_err);
    if (result) |valid_doc| {
        var invalid_doc = valid_doc;
        invalid_doc.deinit();
        std.debug.print("  Unexpectedly parsed invalid JSON\n", .{});
    } else |_| {
        std.debug.print("  Parse error at line {d}, column {d}\n", .{
            parse_err.line,
            parse_err.col,
        });
        std.debug.print("  Error code: {}\n", .{parse_err.code});
    }

    // =========================================================================
    // 6. Comparing JSON values
    // =========================================================================
    std.debug.print("\n=== 6. Comparing JSON Values ===\n", .{});

    const json_a =
        \\{"x": 10, "y": 20}
    ;
    const json_b =
        \\{"y": 20, "x": 10}
    ;

    var doc_a = try json.parse(allocator, json_a, .{}, &err);
    defer doc_a.deinit();

    var doc_b = try json.parse(allocator, json_b, .{}, &err);
    defer doc_b.deinit();

    // Values are compared semantically (order doesn't matter for objects)
    if (doc_a.root.eql(doc_b.root)) {
        std.debug.print("  The two JSON objects are equal (order-independent)\n", .{});
    } else {
        std.debug.print("  The two JSON objects are different\n", .{});
    }

    std.debug.print("\nAll examples completed successfully!\n", .{});
}
