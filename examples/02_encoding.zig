// SPDX-License-Identifier: Apache-2.0
// Example 02: JSON Encoding / Serialization
//
// This example demonstrates how to encode Zig types to JSON strings
// using the library's type-safe encoding with comptime reflection.

const std = @import("std");
const json = @import("json");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // =========================================================================
    // 1. Encoding primitive types
    // =========================================================================
    std.debug.print("=== 1. Encoding Primitive Types ===\n", .{});

    // Booleans
    const bool_json = try json.encode(allocator, true, .{});
    defer allocator.free(bool_json);
    std.debug.print("  bool: {s}\n", .{bool_json});

    // Integers
    const int_json = try json.encode(allocator, @as(i32, -42), .{});
    defer allocator.free(int_json);
    std.debug.print("  int: {s}\n", .{int_json});

    // Floats
    const float_json = try json.encode(allocator, @as(f64, 3.14159), .{});
    defer allocator.free(float_json);
    std.debug.print("  float: {s}\n", .{float_json});

    // Strings
    const str_json = try json.encode(allocator, "Hello, World!", .{});
    defer allocator.free(str_json);
    std.debug.print("  string: {s}\n", .{str_json});

    // Null and optionals
    const null_val: ?i32 = null;
    const null_json = try json.encode(allocator, null_val, .{});
    defer allocator.free(null_json);
    std.debug.print("  null: {s}\n", .{null_json});

    // =========================================================================
    // 2. Encoding structs
    // =========================================================================
    std.debug.print("\n=== 2. Encoding Structs ===\n", .{});

    const Point = struct {
        x: i32,
        y: i32,
    };

    const point = Point{ .x = 10, .y = 20 };
    const point_json = try json.encode(allocator, point, .{});
    defer allocator.free(point_json);
    std.debug.print("  Point: {s}\n", .{point_json});

    // Nested struct
    const Rectangle = struct {
        top_left: Point,
        bottom_right: Point,
        label: []const u8,
    };

    const rect = Rectangle{
        .top_left = .{ .x = 0, .y = 0 },
        .bottom_right = .{ .x = 100, .y = 50 },
        .label = "main area",
    };
    const rect_json = try json.encode(allocator, rect, .{});
    defer allocator.free(rect_json);
    std.debug.print("  Rectangle: {s}\n", .{rect_json});

    // =========================================================================
    // 3. Encoding arrays and slices
    // =========================================================================
    std.debug.print("\n=== 3. Encoding Arrays and Slices ===\n", .{});

    const numbers = [_]i32{ 1, 2, 3, 4, 5 };
    const arr_json = try json.encode(allocator, &numbers, .{});
    defer allocator.free(arr_json);
    std.debug.print("  Array: {s}\n", .{arr_json});

    // Tuples are also encoded as arrays
    const tuple = .{ "name", 42, true };
    const tuple_json = try json.encode(allocator, tuple, .{});
    defer allocator.free(tuple_json);
    std.debug.print("  Tuple: {s}\n", .{tuple_json});

    // =========================================================================
    // 4. Encoding enums and unions
    // =========================================================================
    std.debug.print("\n=== 4. Encoding Enums and Unions ===\n", .{});

    const Color = enum { red, green, blue };
    const color = Color.green;
    const enum_json = try json.encode(allocator, color, .{});
    defer allocator.free(enum_json);
    std.debug.print("  Enum: {s}\n", .{enum_json});

    // Tagged unions are encoded as {"tag": value}
    const Shape = union(enum) {
        circle: f32, // radius
        rectangle: struct { width: f32, height: f32 },
        point: void,
    };

    const circle = Shape{ .circle = 5.0 };
    const union_json = try json.encode(allocator, circle, .{});
    defer allocator.free(union_json);
    std.debug.print("  Union (circle): {s}\n", .{union_json});

    // =========================================================================
    // 5. Pretty printing with indentation
    // =========================================================================
    std.debug.print("\n=== 5. Pretty Printing ===\n", .{});

    const Config = struct {
        name: []const u8,
        version: u32,
        features: struct {
            enabled: bool,
            max_size: u64,
        },
    };

    const config = Config{
        .name = "my-app",
        .version = 1,
        .features = .{
            .enabled = true,
            .max_size = 1024,
        },
    };

    // Pretty print with 2-space indentation
    const pretty_json = try json.encode(allocator, config, .{ .indent = "  " });
    defer allocator.free(pretty_json);
    std.debug.print("  Pretty (2-space):\n{s}\n", .{pretty_json});

    // Pretty print with tabs
    const tab_json = try json.encode(allocator, config, .{ .indent = "\t" });
    defer allocator.free(tab_json);
    std.debug.print("\n  Pretty (tabs):\n{s}\n", .{tab_json});

    // =========================================================================
    // 6. Optional field handling
    // =========================================================================
    std.debug.print("\n=== 6. Optional Field Handling ===\n", .{});

    const User = struct {
        name: []const u8,
        email: ?[]const u8,
        age: ?u32,
    };

    const user = User{
        .name = "Alice",
        .email = "alice@example.com",
        .age = null, // This field is null
    };

    // By default, null optional fields are omitted
    const user_json1 = try json.encode(allocator, user, .{});
    defer allocator.free(user_json1);
    std.debug.print("  Without null fields: {s}\n", .{user_json1});

    // Include null fields explicitly
    const user_json2 = try json.encode(allocator, user, .{ .emit_null_optional_fields = true });
    defer allocator.free(user_json2);
    std.debug.print("  With null fields: {s}\n", .{user_json2});

    // =========================================================================
    // 7. Special encoding options
    // =========================================================================
    std.debug.print("\n=== 7. Special Encoding Options ===\n", .{});

    // Escape non-ASCII characters
    const unicode_str = "Hello, World!";
    const escaped = try json.encode(allocator, unicode_str, .{ .escape_non_ascii = true });
    defer allocator.free(escaped);
    std.debug.print("  Non-ASCII escaped: {s}\n", .{escaped});

    // Escape forward slashes (useful for HTML embedding)
    const url = "https://example.com/path";
    const slash_escaped = try json.encode(allocator, url, .{ .escape_slash = true });
    defer allocator.free(slash_escaped);
    std.debug.print("  Slash escaped: {s}\n", .{slash_escaped});

    // Deterministic output (sorted keys)
    const Unordered = struct { z: i32, a: i32, m: i32 };
    const unordered = Unordered{ .z = 3, .a = 1, .m = 2 };
    const sorted_json = try json.encode(allocator, unordered, .{ .deterministic = true });
    defer allocator.free(sorted_json);
    std.debug.print("  Sorted keys: {s}\n", .{sorted_json});

    // Stringify numbers as JSON strings (for large integers)
    const BigId = struct { id: u64 };
    const big_id = BigId{ .id = 9007199254740993 };
    const stringified = try json.encode(allocator, big_id, .{ .stringify_numbers = true });
    defer allocator.free(stringified);
    std.debug.print("  Stringified numbers: {s}\n", .{stringified});

    std.debug.print("\nAll examples completed successfully!\n", .{});
}
