// SPDX-License-Identifier: Apache-2.0
// Example 07: JSONPath Query Language
//
// This example demonstrates how to use JSONPath to query JSON documents.
// JSONPath is like XPath for JSON - it allows you to extract specific
// values from complex JSON structures.

const std = @import("std");
const json = @import("json");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var err = json.ParseError.init();

    // Sample document for all examples
    const sample_json =
        \\{
        \\  "store": {
        \\    "name": "Book Store",
        \\    "books": [
        \\      {"title": "Zig Programming", "author": "Andrew Kelley", "price": 29.99},
        \\      {"title": "Systems Design", "author": "Jane Smith", "price": 39.99},
        \\      {"title": "Low-Level Hacking", "author": "Bob Jones", "price": 49.99}
        \\    ],
        \\    "electronics": [
        \\      {"name": "Laptop", "price": 999.99},
        \\      {"name": "Phone", "price": 699.99}
        \\    ]
        \\  }
        \\}
    ;

    var doc = try json.parse(allocator, sample_json, .{}, &err);
    defer doc.deinit();

    // =========================================================================
    // 1. Root element ($)
    // =========================================================================
    std.debug.print("=== 1. Root Element ($) ===\n", .{});

    var result1 = try json.jsonpath(allocator, doc.root, "$");
    defer result1.deinit();
    std.debug.print("  $ returns the entire document ({d} result)\n", .{result1.values.len});

    // =========================================================================
    // 2. Child access (.name or ['name'])
    // =========================================================================
    std.debug.print("\n=== 2. Child Access ===\n", .{});

    // Dot notation
    var result2 = try json.jsonpath(allocator, doc.root, "$.store.name");
    defer result2.deinit();
    if (result2.values.len > 0) {
        std.debug.print("  $.store.name = \"{s}\"\n", .{result2.values[0].str});
    }

    // Bracket notation (equivalent)
    var result3 = try json.jsonpath(allocator, doc.root, "$['store']['name']");
    defer result3.deinit();
    if (result3.values.len > 0) {
        std.debug.print("  $['store']['name'] = \"{s}\"\n", .{result3.values[0].str});
    }

    // =========================================================================
    // 3. Array indexing ([n])
    // =========================================================================
    std.debug.print("\n=== 3. Array Indexing ===\n", .{});

    // First book
    var result4 = try json.jsonpath(allocator, doc.root, "$.store.books[0]");
    defer result4.deinit();
    if (result4.values.len > 0) {
        const first_book = try json.stringify(allocator, result4.values[0]);
        defer allocator.free(first_book);
        std.debug.print("  $.store.books[0] = {s}\n", .{first_book});
    }

    // Last book (negative index)
    var result5 = try json.jsonpath(allocator, doc.root, "$.store.books[-1]");
    defer result5.deinit();
    if (result5.values.len > 0) {
        const last_book = try json.stringify(allocator, result5.values[0]);
        defer allocator.free(last_book);
        std.debug.print("  $.store.books[-1] = {s}\n", .{last_book});
    }

    // =========================================================================
    // 4. Wildcard (*)
    // =========================================================================
    std.debug.print("\n=== 4. Wildcard (*) ===\n", .{});

    // All book titles
    var result6 = try json.jsonpath(allocator, doc.root, "$.store.books[*].title");
    defer result6.deinit();
    std.debug.print("  $.store.books[*].title ({d} results):\n", .{result6.values.len});
    for (result6.values) |val| {
        std.debug.print("    - \"{s}\"\n", .{val.str});
    }

    // =========================================================================
    // 5. Array slice ([start:end] or [start:end:step])
    // =========================================================================
    std.debug.print("\n=== 5. Array Slice ===\n", .{});

    // First two books
    var result7 = try json.jsonpath(allocator, doc.root, "$.store.books[0:2]");
    defer result7.deinit();
    std.debug.print("  $.store.books[0:2] ({d} results)\n", .{result7.values.len});

    // Every other book
    var result8 = try json.jsonpath(allocator, doc.root, "$.store.books[::2]");
    defer result8.deinit();
    std.debug.print("  $.store.books[::2] ({d} results)\n", .{result8.values.len});

    // =========================================================================
    // 6. Recursive descent (..)
    // =========================================================================
    std.debug.print("\n=== 6. Recursive Descent ===\n", .{});

    // All prices anywhere in the document
    var result9 = try json.jsonpath(allocator, doc.root, "$..price");
    defer result9.deinit();
    std.debug.print("  $..price ({d} results):\n", .{result9.values.len});
    for (result9.values) |val| {
        std.debug.print("    - {s}\n", .{val.num.lexeme});
    }

    // All authors
    var result10 = try json.jsonpath(allocator, doc.root, "$..author");
    defer result10.deinit();
    std.debug.print("  $..author ({d} results):\n", .{result10.values.len});
    for (result10.values) |val| {
        std.debug.print("    - \"{s}\"\n", .{val.str});
    }

    // =========================================================================
    // 7. Filter expressions ([?(...)])
    // =========================================================================
    std.debug.print("\n=== 7. Filter Expressions ===\n", .{});

    // Books with price > 30
    var result11 = try json.jsonpath(allocator, doc.root, "$.store.books[?(@.price > 30)]");
    defer result11.deinit();
    std.debug.print("  Books with price > 30 ({d} results):\n", .{result11.values.len});
    for (result11.values) |val| {
        const book = try json.stringify(allocator, val);
        defer allocator.free(book);
        std.debug.print("    - {s}\n", .{book});
    }

    // Books by specific author
    var result12 = try json.jsonpath(allocator, doc.root, "$.store.books[?(@.author == 'Jane Smith')]");
    defer result12.deinit();
    std.debug.print("  Books by Jane Smith ({d} results):\n", .{result12.values.len});
    for (result12.values) |val| {
        for (val.obj) |m| {
            if (std.mem.eql(u8, m.k, "title")) {
                std.debug.print("    - \"{s}\"\n", .{m.v.str});
            }
        }
    }

    // =========================================================================
    // 8. Union (multiple indices/names)
    // =========================================================================
    std.debug.print("\n=== 8. Union Selector ===\n", .{});

    // First and last book
    var result13 = try json.jsonpath(allocator, doc.root, "$.store.books[0,-1]");
    defer result13.deinit();
    std.debug.print("  $.store.books[0,-1] ({d} results):\n", .{result13.values.len});
    for (result13.values) |val| {
        for (val.obj) |m| {
            if (std.mem.eql(u8, m.k, "title")) {
                std.debug.print("    - \"{s}\"\n", .{m.v.str});
            }
        }
    }

    // =========================================================================
    // 9. Practical examples
    // =========================================================================
    std.debug.print("\n=== 9. Practical Examples ===\n", .{});

    // API response-style document
    const api_json =
        \\{
        \\  "users": [
        \\    {"id": 1, "name": "Alice", "roles": ["admin", "user"], "active": true},
        \\    {"id": 2, "name": "Bob", "roles": ["user"], "active": true},
        \\    {"id": 3, "name": "Charlie", "roles": ["user"], "active": false}
        \\  ]
        \\}
    ;
    var api_doc = try json.parse(allocator, api_json, .{}, &err);
    defer api_doc.deinit();

    // Get all active users
    var active = try json.jsonpath(allocator, api_doc.root, "$.users[?(@.active == true)].name");
    defer active.deinit();
    std.debug.print("  Active users: ", .{});
    for (active.values, 0..) |val, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("{s}", .{val.str});
    }
    std.debug.print("\n", .{});

    // Get all user IDs
    var ids = try json.jsonpath(allocator, api_doc.root, "$.users[*].id");
    defer ids.deinit();
    std.debug.print("  User IDs: ", .{});
    for (ids.values, 0..) |val, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("{s}", .{val.num.lexeme});
    }
    std.debug.print("\n", .{});

    // List every role across all users (filters must test a field, e.g.
    // `@.active`, so we enumerate roles with a wildcard rather than a bare-`@`
    // equality filter, which the RFC 9535 evaluator rejects as a syntax error).
    var roles = try json.jsonpath(allocator, api_doc.root, "$.users[*].roles[*]");
    defer roles.deinit();
    var has_admin = false;
    for (roles.values) |val| {
        if (val == .str and std.mem.eql(u8, val.str, "admin")) has_admin = true;
    }
    std.debug.print("  Has admin users: {}\n", .{has_admin});

    std.debug.print("\nAll examples completed successfully!\n", .{});
}
