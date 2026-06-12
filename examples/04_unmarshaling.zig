// SPDX-License-Identifier: Apache-2.0
// Example 04: JSON Unmarshaling
//
// This example demonstrates how to unmarshal JSON data directly into
// Zig types with full type safety and automatic memory management.

const std = @import("std");
const json = @import("json");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // =========================================================================
    // 1. Unmarshaling to a struct
    // =========================================================================
    std.debug.print("=== 1. Unmarshaling to a Struct ===\n", .{});

    const User = struct {
        name: []const u8,
        age: u32,
        active: bool,
    };

    const user_json =
        \\{"name": "Alice", "age": 30, "active": true}
    ;

    var user = try json.unmarshal(User, allocator, user_json);
    defer json.free(User, allocator, &user);

    std.debug.print("  Name: {s}\n", .{user.name});
    std.debug.print("  Age: {d}\n", .{user.age});
    std.debug.print("  Active: {}\n", .{user.active});

    // =========================================================================
    // 2. Unmarshaling with optional fields
    // =========================================================================
    std.debug.print("\n=== 2. Unmarshaling with Optional Fields ===\n", .{});

    const Profile = struct {
        username: []const u8,
        email: ?[]const u8, // Optional field
        bio: ?[]const u8, // Optional field
    };

    // JSON with some optional fields missing
    const profile_json =
        \\{"username": "alice123", "email": "alice@example.com"}
    ;

    var profile = try json.unmarshal(Profile, allocator, profile_json);
    defer json.free(Profile, allocator, &profile);

    std.debug.print("  Username: {s}\n", .{profile.username});
    if (profile.email) |email| {
        std.debug.print("  Email: {s}\n", .{email});
    }
    if (profile.bio) |bio| {
        std.debug.print("  Bio: {s}\n", .{bio});
    } else {
        std.debug.print("  Bio: (not provided)\n", .{});
    }

    // =========================================================================
    // 3. Unmarshaling arrays
    // =========================================================================
    std.debug.print("\n=== 3. Unmarshaling Arrays ===\n", .{});

    const numbers_json = "[1, 2, 3, 4, 5]";
    var numbers = try json.unmarshal([]u32, allocator, numbers_json);
    defer json.free([]u32, allocator, &numbers);

    std.debug.print("  Numbers: ", .{});
    for (numbers) |n| {
        std.debug.print("{d} ", .{n});
    }
    std.debug.print("\n", .{});

    // Array of structs
    const Point = struct { x: i32, y: i32 };
    const points_json =
        \\[{"x": 1, "y": 2}, {"x": 3, "y": 4}, {"x": 5, "y": 6}]
    ;

    var points = try json.unmarshal([]Point, allocator, points_json);
    defer json.free([]Point, allocator, &points);

    std.debug.print("  Points:\n", .{});
    for (points) |p| {
        std.debug.print("    ({d}, {d})\n", .{ p.x, p.y });
    }

    // =========================================================================
    // 4. Unmarshaling enums
    // =========================================================================
    std.debug.print("\n=== 4. Unmarshaling Enums ===\n", .{});

    const Status = enum {
        pending,
        approved,
        rejected,
    };

    const status_json = "\"approved\"";
    var status = try json.unmarshal(Status, allocator, status_json);
    _ = &status;

    std.debug.print("  Status: {}\n", .{status});

    // Struct with enum field
    const Task = struct {
        title: []const u8,
        status: Status,
    };

    const task_json =
        \\{"title": "Review PR", "status": "pending"}
    ;

    var task = try json.unmarshal(Task, allocator, task_json);
    defer json.free(Task, allocator, &task);

    std.debug.print("  Task: {s} ({})\n", .{ task.title, task.status });

    // =========================================================================
    // 5. Unmarshaling tagged unions
    // =========================================================================
    std.debug.print("\n=== 5. Unmarshaling Tagged Unions ===\n", .{});

    const Shape = union(enum) {
        circle: f32, // radius
        rectangle: struct { width: f32, height: f32 },
        point: void,
    };

    const circle_json =
        \\{"circle": 5.5}
    ;

    var shape = try json.unmarshal(Shape, allocator, circle_json);
    _ = &shape;

    switch (shape) {
        .circle => |radius| std.debug.print("  Circle with radius: {d}\n", .{radius}),
        .rectangle => |rect| std.debug.print("  Rectangle: {d}x{d}\n", .{ rect.width, rect.height }),
        .point => std.debug.print("  Point\n", .{}),
    }

    // =========================================================================
    // 6. Nested structures
    // =========================================================================
    std.debug.print("\n=== 6. Nested Structures ===\n", .{});

    const Address = struct {
        street: []const u8,
        city: []const u8,
        country: []const u8,
    };

    const Person = struct {
        name: []const u8,
        address: Address,
        tags: [][]const u8,
    };

    const person_json =
        \\{
        \\  "name": "Bob",
        \\  "address": {
        \\    "street": "123 Main St",
        \\    "city": "Boston",
        \\    "country": "USA"
        \\  },
        \\  "tags": ["developer", "zig"]
        \\}
    ;

    var person = try json.unmarshal(Person, allocator, person_json);
    defer json.free(Person, allocator, &person);

    std.debug.print("  Name: {s}\n", .{person.name});
    std.debug.print("  Address: {s}, {s}, {s}\n", .{
        person.address.street,
        person.address.city,
        person.address.country,
    });
    std.debug.print("  Tags: ", .{});
    for (person.tags) |tag| {
        std.debug.print("{s} ", .{tag});
    }
    std.debug.print("\n", .{});

    // =========================================================================
    // 7. Unmarshal with detailed error info
    // =========================================================================
    std.debug.print("\n=== 7. Unmarshal with Error Details ===\n", .{});

    const StrictUser = struct {
        id: u64,
        name: []const u8,
    };

    // Invalid JSON (wrong type for id)
    const bad_json =
        \\{"id": "not-a-number", "name": "Test"}
    ;

    const result = json.unmarshalWithInfo(StrictUser, allocator, bad_json);
    switch (result) {
        .ok => |u| {
            var mutable_u = u;
            defer json.free(StrictUser, allocator, &mutable_u);
            std.debug.print("  Unexpectedly succeeded\n", .{});
        },
        .err => |e| {
            std.debug.print("  Error at path: {s}\n", .{e.path});
            std.debug.print("  Error kind: {}\n", .{e.kind});
            std.debug.print("  Message: {s}\n", .{e.message});
            // Free the path if it was allocated
            if (e.path.len > 0) {
                allocator.free(e.path);
            }
        },
    }

    // =========================================================================
    // 8. Using fromValue for Value tree
    // =========================================================================
    std.debug.print("\n=== 8. Unmarshal from Parsed Value ===\n", .{});

    // First parse JSON into a Value tree
    var parse_err = json.ParseError.init();
    var doc = try json.parse(allocator, user_json, .{}, &parse_err);
    defer doc.deinit();

    // Then unmarshal from the Value tree
    var user2 = try json.fromValue(User, allocator, doc.root);
    defer json.free(User, allocator, &user2);

    std.debug.print("  From Value tree - Name: {s}, Age: {d}\n", .{
        user2.name,
        user2.age,
    });

    std.debug.print("\nAll examples completed successfully!\n", .{});
}
