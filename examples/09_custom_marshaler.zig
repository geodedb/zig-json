// SPDX-License-Identifier: Apache-2.0
// Example 09: Custom Marshaler Interface
//
// This example demonstrates how to implement custom jsonMarshal and
// jsonUnmarshal methods for types that need special serialization logic.

const std = @import("std");
const json = @import("json");

// ============================================================================
// Example 1: Point encoded as [x, y] array instead of {"x": ..., "y": ...}
// ============================================================================

const Point = struct {
    x: f64,
    y: f64,

    /// Custom marshaler: encode as [x, y] array
    pub fn jsonMarshal(self: @This(), allocator: std.mem.Allocator) !json.Value {
        var arr = try allocator.alloc(json.Value, 2);
        arr[0] = try json.toValue(allocator, self.x, .{});
        arr[1] = try json.toValue(allocator, self.y, .{});
        return .{ .arr = arr };
    }

    /// Custom unmarshaler: decode from [x, y] array
    pub fn jsonUnmarshal(allocator: std.mem.Allocator, value: json.Value) !Point {
        _ = allocator;
        if (value != .arr or value.arr.len != 2) {
            return error.InvalidFormat;
        }
        return .{
            .x = try valueToFloat(value.arr[0]),
            .y = try valueToFloat(value.arr[1]),
        };
    }

    fn valueToFloat(v: json.Value) !f64 {
        if (v != .num) return error.InvalidFormat;
        return std.fmt.parseFloat(f64, v.num.lexeme) catch return error.InvalidFormat;
    }
};

// ============================================================================
// Example 2: DateTime that formats as ISO 8601 string
// ============================================================================

const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,

    /// Custom marshaler: encode as ISO 8601 string
    pub fn jsonMarshal(self: @This(), allocator: std.mem.Allocator) !json.Value {
        const formatted = try std.fmt.allocPrint(
            allocator,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
            .{ self.year, self.month, self.day, self.hour, self.minute, self.second },
        );
        return .{ .str = formatted };
    }

    /// Custom unmarshaler: parse ISO 8601 string
    pub fn jsonUnmarshal(allocator: std.mem.Allocator, value: json.Value) !DateTime {
        _ = allocator;
        if (value != .str) return error.InvalidFormat;

        const s = value.str;
        if (s.len < 19) return error.InvalidFormat;

        return .{
            .year = std.fmt.parseInt(u16, s[0..4], 10) catch return error.InvalidFormat,
            .month = std.fmt.parseInt(u8, s[5..7], 10) catch return error.InvalidFormat,
            .day = std.fmt.parseInt(u8, s[8..10], 10) catch return error.InvalidFormat,
            .hour = std.fmt.parseInt(u8, s[11..13], 10) catch return error.InvalidFormat,
            .minute = std.fmt.parseInt(u8, s[14..16], 10) catch return error.InvalidFormat,
            .second = std.fmt.parseInt(u8, s[17..19], 10) catch return error.InvalidFormat,
        };
    }
};

// ============================================================================
// Example 3: Enum with custom string values
// ============================================================================

const Priority = enum {
    low,
    medium,
    high,
    critical,

    const string_map = std.StaticStringMap(@This()).initComptime(.{
        .{ "LOW", .low },
        .{ "MEDIUM", .medium },
        .{ "HIGH", .high },
        .{ "CRITICAL", .critical },
    });

    /// Custom marshaler: uppercase strings
    pub fn jsonMarshal(self: @This(), allocator: std.mem.Allocator) !json.Value {
        const str = switch (self) {
            .low => "LOW",
            .medium => "MEDIUM",
            .high => "HIGH",
            .critical => "CRITICAL",
        };
        return .{ .str = try allocator.dupe(u8, str) };
    }

    /// Custom unmarshaler: parse uppercase strings
    pub fn jsonUnmarshal(allocator: std.mem.Allocator, value: json.Value) !Priority {
        _ = allocator;
        if (value != .str) return error.InvalidFormat;
        return string_map.get(value.str) orelse return error.InvalidFormat;
    }
};

// ============================================================================
// Example 4: Wrapper type that adds metadata
// ============================================================================

fn Timestamped(comptime T: type) type {
    return struct {
        data: T,
        timestamp: i64,

        const Self = @This();

        /// Custom marshaler: wrap data with timestamp
        pub fn jsonMarshal(self: Self, allocator: std.mem.Allocator) !json.Value {
            var members = try allocator.alloc(json.Member, 2);

            // Add data field
            members[0].k = try allocator.dupe(u8, "data");
            members[0].v = try json.toValue(allocator, self.data, .{ .allocator = allocator });

            // Add timestamp field
            members[1].k = try allocator.dupe(u8, "timestamp");
            members[1].v = try json.toValue(allocator, self.timestamp, .{});

            return .{ .obj = members };
        }

        /// Custom unmarshaler: extract data and timestamp
        pub fn jsonUnmarshal(allocator: std.mem.Allocator, value: json.Value) !Self {
            if (value != .obj) return error.InvalidFormat;

            var data: ?T = null;
            var timestamp: ?i64 = null;

            for (value.obj) |m| {
                if (std.mem.eql(u8, m.k, "data")) {
                    data = try json.fromValue(T, allocator, m.v);
                } else if (std.mem.eql(u8, m.k, "timestamp")) {
                    if (m.v != .num) return error.InvalidFormat;
                    timestamp = std.fmt.parseInt(i64, m.v.num.lexeme, 10) catch return error.InvalidFormat;
                }
            }

            return .{
                .data = data orelse return error.InvalidFormat,
                .timestamp = timestamp orelse return error.InvalidFormat,
            };
        }
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // =========================================================================
    // 1. Point as array
    // =========================================================================
    std.debug.print("=== 1. Point as Array ===\n", .{});

    const point = Point{ .x = 10.5, .y = 20.3 };

    // Encode with custom marshaler
    const point_json = try json.encode(allocator, point, .{ .allocator = allocator });
    defer allocator.free(point_json);
    std.debug.print("  Encoded Point: {s}\n", .{point_json});
    // Output: [10.5,20.3]

    // Unmarshal back
    var err = json.ParseError.init();
    var point_doc = try json.parse(allocator, point_json, .{}, &err);
    defer point_doc.deinit();

    const decoded_point = try Point.jsonUnmarshal(allocator, point_doc.root);
    std.debug.print("  Decoded Point: ({d}, {d})\n", .{ decoded_point.x, decoded_point.y });

    // =========================================================================
    // 2. DateTime as ISO string
    // =========================================================================
    std.debug.print("\n=== 2. DateTime as ISO 8601 String ===\n", .{});

    const dt = DateTime{
        .year = 2024,
        .month = 3,
        .day = 15,
        .hour = 14,
        .minute = 30,
        .second = 0,
    };

    const dt_json = try json.encode(allocator, dt, .{ .allocator = allocator });
    defer allocator.free(dt_json);
    std.debug.print("  Encoded DateTime: {s}\n", .{dt_json});
    // Output: "2024-03-15T14:30:00Z"

    // =========================================================================
    // 3. Custom enum strings
    // =========================================================================
    std.debug.print("\n=== 3. Custom Enum Strings ===\n", .{});

    const priority = Priority.critical;

    const priority_json = try json.encode(allocator, priority, .{ .allocator = allocator });
    defer allocator.free(priority_json);
    std.debug.print("  Encoded Priority: {s}\n", .{priority_json});
    // Output: "CRITICAL"

    // =========================================================================
    // 4. Timestamped wrapper
    // =========================================================================
    std.debug.print("\n=== 4. Timestamped Wrapper ===\n", .{});

    const User = struct {
        name: []const u8,
        age: u32,
    };

    const timestamped_user = Timestamped(User){
        .data = .{ .name = "Alice", .age = 30 },
        .timestamp = 1710513000,
    };

    const ts_json = try json.encode(allocator, timestamped_user, .{
        .allocator = allocator,
        .indent = "  ",
    });
    defer allocator.free(ts_json);
    std.debug.print("  Timestamped User:\n{s}\n", .{ts_json});

    // =========================================================================
    // 5. Struct containing custom types
    // =========================================================================
    std.debug.print("\n=== 5. Struct with Custom Types ===\n", .{});

    const Event = struct {
        id: u64,
        location: Point,
        time: DateTime,
        priority: Priority,
    };

    const event = Event{
        .id = 12345,
        .location = .{ .x = 40.7128, .y = -74.0060 },
        .time = .{
            .year = 2024,
            .month = 7,
            .day = 4,
            .hour = 19,
            .minute = 0,
            .second = 0,
        },
        .priority = .high,
    };

    const event_json = try json.encode(allocator, event, .{
        .allocator = allocator,
        .indent = "  ",
    });
    defer allocator.free(event_json);
    std.debug.print("  Event with custom types:\n{s}\n", .{event_json});

    std.debug.print("\nAll examples completed successfully!\n", .{});
}
