// SPDX-License-Identifier: Apache-2.0
// Example 10: JSON5 Extended Syntax
//
// This example demonstrates JSON5 parsing, which extends JSON with
// features like comments, trailing commas, unquoted keys, and more.
// JSON5 is useful for configuration files and human-written JSON.

const std = @import("std");
const json = @import("json");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var err = json.ParseError.init();

    // JSON5 options - enable JSON5 mode
    const json5_opts = json.ParseOptions{
        .json5 = true,
    };

    // =========================================================================
    // 1. Single-line comments
    // =========================================================================
    std.debug.print("=== 1. Single-line Comments ===\n", .{});

    const comment_json =
        \\{
        \\  // This is a comment
        \\  "name": "Alice", // inline comment
        \\  "age": 30
        \\}
    ;

    var comment_doc = try json.parse(allocator, comment_json, json5_opts, &err);
    defer comment_doc.deinit();

    std.debug.print("  Parsed with single-line comments: {} members\n", .{comment_doc.root.obj.len});

    // =========================================================================
    // 2. Multi-line comments
    // =========================================================================
    std.debug.print("\n=== 2. Multi-line Comments ===\n", .{});

    const multiline_json =
        \\{
        \\  /*
        \\   * This is a multi-line comment.
        \\   * It can span multiple lines.
        \\   */
        \\  "version": 1,
        \\  "enabled": true
        \\}
    ;

    var multi_doc = try json.parse(allocator, multiline_json, json5_opts, &err);
    defer multi_doc.deinit();

    std.debug.print("  Parsed with multi-line comments: {} members\n", .{multi_doc.root.obj.len});

    // =========================================================================
    // 3. Trailing commas
    // =========================================================================
    std.debug.print("\n=== 3. Trailing Commas ===\n", .{});

    const trailing_json =
        \\{
        \\  "items": [
        \\    "first",
        \\    "second",
        \\    "third",  // <-- trailing comma allowed
        \\  ],
        \\  "count": 3,  // <-- trailing comma allowed
        \\}
    ;

    var trailing_doc = try json.parse(allocator, trailing_json, json5_opts, &err);
    defer trailing_doc.deinit();

    for (trailing_doc.root.obj) |m| {
        if (std.mem.eql(u8, m.k, "items")) {
            std.debug.print("  Parsed array with trailing comma: {} elements\n", .{m.v.arr.len});
        }
    }

    // =========================================================================
    // 4. Unquoted keys
    // =========================================================================
    std.debug.print("\n=== 4. Unquoted Keys ===\n", .{});

    const unquoted_json =
        \\{
        \\  name: "Bob",
        \\  age: 25,
        \\  isActive: true,
        \\  $specialKey: "value",
        \\  _private: "data"
        \\}
    ;

    var unquoted_doc = try json.parse(allocator, unquoted_json, json5_opts, &err);
    defer unquoted_doc.deinit();

    std.debug.print("  Unquoted keys:\n", .{});
    for (unquoted_doc.root.obj) |m| {
        std.debug.print("    - {s}\n", .{m.k});
    }

    // =========================================================================
    // 5. Single-quoted strings
    // =========================================================================
    std.debug.print("\n=== 5. Single-quoted Strings ===\n", .{});

    const single_quote_json =
        \\{
        \\  name: 'Alice',
        \\  message: 'Hello, "World"!'
        \\}
    ;

    var single_doc = try json.parse(allocator, single_quote_json, json5_opts, &err);
    defer single_doc.deinit();

    for (single_doc.root.obj) |m| {
        if (std.mem.eql(u8, m.k, "message")) {
            std.debug.print("  Single-quoted string: {s}\n", .{m.v.str});
        }
    }

    // =========================================================================
    // 6. Hexadecimal numbers
    // =========================================================================
    std.debug.print("\n=== 6. Hexadecimal Numbers ===\n", .{});

    const hex_json =
        \\{
        \\  color: 0xFF5733,
        \\  mask: 0xFFFF,
        \\  negative: -0x10
        \\}
    ;

    var hex_doc = try json.parse(allocator, hex_json, json5_opts, &err);
    defer hex_doc.deinit();

    for (hex_doc.root.obj) |m| {
        std.debug.print("  {s}: {s}\n", .{ m.k, m.v.num.lexeme });
    }

    // =========================================================================
    // 7. Special number values
    // =========================================================================
    std.debug.print("\n=== 7. Special Number Values ===\n", .{});

    // The parser accepts `Infinity`, `-Infinity`, `NaN`, a leading `+`, and
    // leading/trailing decimal points. `-Infinity` is a first-class JSON5 number
    // (JSON5 §7 number grammar is `[+-]?(Infinity|NaN|...)`); the parser now
    // accepts it (GAP-0009), so it is demonstrated here.
    const special_json =
        \\{
        \\  infinity: Infinity,
        \\  negative_infinity: -Infinity,
        \\  not_a_number: NaN,
        \\  positive: +42,
        \\  leading_decimal: .5,
        \\  trailing_decimal: 5.
        \\}
    ;

    var special_doc = try json.parse(allocator, special_json, json5_opts, &err);
    defer special_doc.deinit();

    for (special_doc.root.obj) |m| {
        std.debug.print("  {s}: {s}\n", .{ m.k, m.v.num.lexeme });
    }

    // =========================================================================
    // 8. Complete JSON5 config file example
    // =========================================================================
    std.debug.print("\n=== 8. Complete Config File Example ===\n", .{});

    const config_json =
        \\{
        \\  // Application Configuration
        \\  appName: 'My Application',
        \\  version: '1.0.0',
        \\
        \\  /*
        \\   * Server settings
        \\   */
        \\  server: {
        \\    host: 'localhost',
        \\    port: 8080,
        \\    timeout: Infinity, // no timeout
        \\  },
        \\
        \\  // Feature flags
        \\  features: {
        \\    enableLogging: true,
        \\    maxConnections: 0xFF,  // 255 in hex
        \\    debugMode: false,
        \\  },
        \\
        \\  // List of allowed origins
        \\  allowedOrigins: [
        \\    'https://example.com',
        \\    'https://api.example.com',
        \\    'http://localhost:3000',  // for development
        \\  ],
        \\}
    ;

    var config_doc = try json.parse(allocator, config_json, json5_opts, &err);
    defer config_doc.deinit();

    std.debug.print("  Parsed complete JSON5 config:\n", .{});
    for (config_doc.root.obj) |m| {
        std.debug.print("    - {s}: ", .{m.k});
        switch (m.v) {
            .str => |s| std.debug.print("\"{s}\"\n", .{s}),
            .obj => std.debug.print("(object)\n", .{}),
            .arr => |a| std.debug.print("(array with {} items)\n", .{a.len}),
            .num => |n| std.debug.print("{s}\n", .{n.lexeme}),
            .bool => |b| std.debug.print("{}\n", .{b}),
            .null => std.debug.print("null\n", .{}),
        }
    }

    // =========================================================================
    // 9. Comparison: Strict JSON vs JSON5
    // =========================================================================
    std.debug.print("\n=== 9. Strict JSON vs JSON5 ===\n", .{});

    const strict_only =
        \\{"key": "value", "num": 42}
    ;

    // This works with both modes
    var strict_doc = try json.parse(allocator, strict_only, .{}, &err);
    defer strict_doc.deinit();
    std.debug.print("  Strict JSON parsed in strict mode: OK\n", .{});

    var strict_doc2 = try json.parse(allocator, strict_only, json5_opts, &err);
    defer strict_doc2.deinit();
    std.debug.print("  Strict JSON parsed in JSON5 mode: OK\n", .{});

    // This only works in JSON5 mode
    const json5_only =
        \\{key: 'value', num: +42,}
    ;

    const strict_result = json.parse(allocator, json5_only, .{}, &err);
    if (strict_result) |d| {
        var doc = d;
        doc.deinit();
        std.debug.print("  JSON5 syntax unexpectedly parsed in strict mode\n", .{});
    } else |_| {
        std.debug.print("  JSON5 syntax rejected in strict mode: expected\n", .{});
    }

    var json5_doc = try json.parse(allocator, json5_only, json5_opts, &err);
    defer json5_doc.deinit();
    std.debug.print("  JSON5 syntax parsed in JSON5 mode: OK\n", .{});

    std.debug.print("\nAll examples completed successfully!\n", .{});
}
