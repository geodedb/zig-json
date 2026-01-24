// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! JSON Schema Generation from Zig Types
//!
//! Generates JSON Schema (draft 2020-12) documents from Zig type definitions.
//!
//! Features:
//! - Struct to object schema with properties
//! - Enum to string enum schema
//! - Optional types to nullable schema
//! - Tagged unions to oneOf/anyOf schema
//! - Array/slice to array schema
//! - Respects json_config for field customization

const std = @import("std");
const json = @import("json.zig");

const Value = json.Value;
const Member = json.Member;
const FieldConfig = json.FieldConfig;

/// Schema generation options
pub const GenOptions = struct {
    /// Include $schema and $id in root schema
    include_meta: bool = true,
    /// Schema $id URI
    id: ?[]const u8 = null,
    /// Include descriptions from doc comments (when available)
    include_descriptions: bool = true,
    /// Use definitions/$defs for referenced types
    use_defs: bool = true,
};

/// Generate JSON Schema for a Zig type
pub fn generate(comptime T: type, allocator: std.mem.Allocator, options: GenOptions) !Value {
    var members: std.ArrayList(Member) = .empty;
    errdefer members.deinit(allocator);

    // Add meta properties for root schema
    if (options.include_meta) {
        try members.append(allocator, .{
            .k = try allocator.dupe(u8, "$schema"),
            .v = .{ .str = try allocator.dupe(u8, "https://json-schema.org/draft/2020-12/schema") },
        });
        if (options.id) |id| {
            try members.append(allocator, .{
                .k = try allocator.dupe(u8, "$id"),
                .v = .{ .str = try allocator.dupe(u8, id) },
            });
        }
    }

    // Generate schema for the type
    const type_schema = try generateType(T, allocator);

    // Merge type schema members into root
    if (type_schema == .obj) {
        for (type_schema.obj) |m| {
            try members.append(allocator, m);
        }
        // Free the original slice (not its contents - we moved those)
        allocator.free(type_schema.obj);
    }

    return .{ .obj = try members.toOwnedSlice(allocator) };
}

/// Generate schema for a specific type (internal)
fn generateType(comptime T: type, allocator: std.mem.Allocator) !Value {
    const info = @typeInfo(T);

    return switch (info) {
        .bool => try makeSchema(allocator, "boolean", null),
        .int, .comptime_int => try makeIntSchema(allocator, T),
        .float, .comptime_float => try makeSchema(allocator, "number", null),
        .pointer => |ptr| try generatePointerSchema(ptr, allocator),
        .array => |arr| try generateArraySchema(arr.child, allocator, arr.len),
        .optional => |opt| try generateOptionalSchema(opt.child, allocator),
        .@"struct" => try generateStructSchema(T, allocator),
        .@"enum" => try generateEnumSchema(T, allocator),
        .@"union" => try generateUnionSchema(T, allocator),
        else => try makeSchema(allocator, "object", null), // Fallback
    };
}

/// Generate schema for pointer types (slices, strings)
fn generatePointerSchema(comptime ptr: std.builtin.Type.Pointer, allocator: std.mem.Allocator) !Value {
    if (ptr.size == .slice) {
        if (ptr.child == u8) {
            // []u8 or []const u8 is a string
            return try makeSchema(allocator, "string", null);
        }
        // Other slices are arrays
        return try generateArraySchema(ptr.child, allocator, null);
    }
    // Single-item pointer - schema for the child
    return try generateType(ptr.child, allocator);
}

/// Generate schema for array types
fn generateArraySchema(comptime Child: type, allocator: std.mem.Allocator, comptime length: ?usize) !Value {
    var members: std.ArrayList(Member) = .empty;
    errdefer members.deinit(allocator);

    try members.append(allocator, .{
        .k = try allocator.dupe(u8, "type"),
        .v = .{ .str = try allocator.dupe(u8, "array") },
    });

    const items_schema = try generateType(Child, allocator);
    try members.append(allocator, .{
        .k = try allocator.dupe(u8, "items"),
        .v = items_schema,
    });

    if (length) |len| {
        try members.append(allocator, .{
            .k = try allocator.dupe(u8, "minItems"),
            .v = try makeNumber(allocator, len),
        });
        try members.append(allocator, .{
            .k = try allocator.dupe(u8, "maxItems"),
            .v = try makeNumber(allocator, len),
        });
    }

    return .{ .obj = try members.toOwnedSlice(allocator) };
}

/// Generate schema for optional types
fn generateOptionalSchema(comptime Child: type, allocator: std.mem.Allocator) !Value {
    var members: std.ArrayList(Member) = .empty;
    errdefer members.deinit(allocator);

    // anyOf with null and the child type
    var options: std.ArrayList(Value) = .empty;
    errdefer options.deinit(allocator);

    try options.append(allocator, try generateType(Child, allocator));
    try options.append(allocator, try makeSchema(allocator, "null", null));

    try members.append(allocator, .{
        .k = try allocator.dupe(u8, "anyOf"),
        .v = .{ .arr = try options.toOwnedSlice(allocator) },
    });

    return .{ .obj = try members.toOwnedSlice(allocator) };
}

/// Generate schema for struct types
fn generateStructSchema(comptime T: type, allocator: std.mem.Allocator) !Value {
    const info = @typeInfo(T).@"struct";
    var members: std.ArrayList(Member) = .empty;
    errdefer members.deinit(allocator);

    try members.append(allocator, .{
        .k = try allocator.dupe(u8, "type"),
        .v = .{ .str = try allocator.dupe(u8, "object") },
    });

    // Build properties
    var props: std.ArrayList(Member) = .empty;
    errdefer props.deinit(allocator);

    var required: std.ArrayList(Value) = .empty;
    errdefer required.deinit(allocator);

    inline for (info.fields) |field| {
        const cfg = comptime getFieldConfig(T, field.name);

        // Skip fields marked as skip
        if (comptime cfg.skip) continue;

        // Get the JSON field name
        const json_name = comptime cfg.name orelse field.name;

        // Generate schema for field type
        const field_schema = try generateType(field.type, allocator);

        try props.append(allocator, .{
            .k = try allocator.dupe(u8, json_name),
            .v = field_schema,
        });

        // Non-optional fields without defaults are required
        const is_optional = comptime @typeInfo(field.type) == .optional;
        const has_default = comptime field.default_value_ptr != null;
        if (comptime (!is_optional and !has_default and !cfg.omitempty)) {
            try required.append(allocator, .{
                .str = try allocator.dupe(u8, json_name),
            });
        }
    }

    try members.append(allocator, .{
        .k = try allocator.dupe(u8, "properties"),
        .v = .{ .obj = try props.toOwnedSlice(allocator) },
    });

    if (required.items.len > 0) {
        try members.append(allocator, .{
            .k = try allocator.dupe(u8, "required"),
            .v = .{ .arr = try required.toOwnedSlice(allocator) },
        });
    } else {
        required.deinit(allocator);
    }

    return .{ .obj = try members.toOwnedSlice(allocator) };
}

/// Generate schema for enum types
fn generateEnumSchema(comptime T: type, allocator: std.mem.Allocator) !Value {
    const info = @typeInfo(T).@"enum";
    var members: std.ArrayList(Member) = .empty;
    errdefer members.deinit(allocator);

    try members.append(allocator, .{
        .k = try allocator.dupe(u8, "type"),
        .v = .{ .str = try allocator.dupe(u8, "string") },
    });

    var enum_values: std.ArrayList(Value) = .empty;
    errdefer enum_values.deinit(allocator);

    inline for (info.fields) |field| {
        try enum_values.append(allocator, .{
            .str = try allocator.dupe(u8, field.name),
        });
    }

    try members.append(allocator, .{
        .k = try allocator.dupe(u8, "enum"),
        .v = .{ .arr = try enum_values.toOwnedSlice(allocator) },
    });

    return .{ .obj = try members.toOwnedSlice(allocator) };
}

/// Generate schema for union types
fn generateUnionSchema(comptime T: type, allocator: std.mem.Allocator) !Value {
    const info = @typeInfo(T).@"union";
    var members: std.ArrayList(Member) = .empty;
    errdefer members.deinit(allocator);

    var options: std.ArrayList(Value) = .empty;
    errdefer options.deinit(allocator);

    inline for (info.fields) |field| {
        try options.append(allocator, try generateType(field.type, allocator));
    }

    try members.append(allocator, .{
        .k = try allocator.dupe(u8, "oneOf"),
        .v = .{ .arr = try options.toOwnedSlice(allocator) },
    });

    return .{ .obj = try members.toOwnedSlice(allocator) };
}

/// Make a simple schema with just a type
fn makeSchema(allocator: std.mem.Allocator, type_name: []const u8, format: ?[]const u8) !Value {
    var members: std.ArrayList(Member) = .empty;
    errdefer members.deinit(allocator);

    try members.append(allocator, .{
        .k = try allocator.dupe(u8, "type"),
        .v = .{ .str = try allocator.dupe(u8, type_name) },
    });

    if (format) |fmt| {
        try members.append(allocator, .{
            .k = try allocator.dupe(u8, "format"),
            .v = .{ .str = try allocator.dupe(u8, fmt) },
        });
    }

    return .{ .obj = try members.toOwnedSlice(allocator) };
}

/// Make integer schema with min/max based on bit width
fn makeIntSchema(allocator: std.mem.Allocator, comptime T: type) !Value {
    var members: std.ArrayList(Member) = .empty;
    errdefer members.deinit(allocator);

    try members.append(allocator, .{
        .k = try allocator.dupe(u8, "type"),
        .v = .{ .str = try allocator.dupe(u8, "integer") },
    });

    // Add min/max based on signedness and bit width
    const info = @typeInfo(T).int;
    if (info.signedness == .signed) {
        const min = std.math.minInt(T);
        const max = std.math.maxInt(T);
        try members.append(allocator, .{
            .k = try allocator.dupe(u8, "minimum"),
            .v = try makeSignedNumber(allocator, min),
        });
        try members.append(allocator, .{
            .k = try allocator.dupe(u8, "maximum"),
            .v = try makeSignedNumber(allocator, max),
        });
    } else {
        const max = std.math.maxInt(T);
        try members.append(allocator, .{
            .k = try allocator.dupe(u8, "minimum"),
            .v = try makeNumber(allocator, 0),
        });
        try members.append(allocator, .{
            .k = try allocator.dupe(u8, "maximum"),
            .v = try makeNumber(allocator, max),
        });
    }

    return .{ .obj = try members.toOwnedSlice(allocator) };
}

/// Create a number value from a usize
fn makeNumber(allocator: std.mem.Allocator, n: usize) !Value {
    var buf: [32]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
    const lexeme = try allocator.dupe(u8, str);
    return .{ .num = .{
        .lexeme = lexeme,
        .sign = 1,
        .digits = lexeme,
        .exp10 = 0,
    } };
}

/// Create a number value from an i128
fn makeSignedNumber(allocator: std.mem.Allocator, n: i128) !Value {
    var buf: [64]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
    const lexeme = try allocator.dupe(u8, str);
    const sign: i8 = if (n < 0) -1 else 1;
    const digits = if (n < 0) lexeme[1..] else lexeme;
    return .{ .num = .{
        .lexeme = lexeme,
        .sign = sign,
        .digits = digits,
        .exp10 = 0,
    } };
}

/// Get field config for a struct field
fn getFieldConfig(comptime T: type, comptime field_name: []const u8) FieldConfig {
    if (@hasDecl(T, "json_config")) {
        const cfg = @field(T, "json_config");
        if (@hasField(@TypeOf(cfg), field_name)) {
            return @field(cfg, field_name);
        }
    }
    return .{};
}

/// Free a generated schema value
pub fn freeSchema(allocator: std.mem.Allocator, value: Value) void {
    json.patch_mod.freeValue(allocator, value);
}

// ============================================================================
// Tests
// ============================================================================

test "generate schema for simple struct" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u32,
        email: ?[]const u8 = null,
    };

    const schema = try generate(Person, allocator, .{ .include_meta = false });
    defer freeSchema(allocator, schema);

    // Should have type=object and properties
    var found_type = false;
    var found_props = false;
    for (schema.obj) |m| {
        if (std.mem.eql(u8, m.k, "type")) {
            try std.testing.expectEqualStrings("object", m.v.str);
            found_type = true;
        }
        if (std.mem.eql(u8, m.k, "properties")) {
            found_props = true;
            try std.testing.expect(m.v == .obj);
        }
    }
    try std.testing.expect(found_type);
    try std.testing.expect(found_props);
}

test "generate schema for enum" {
    const allocator = std.testing.allocator;

    const Status = enum { pending, active, completed };

    const schema = try generate(Status, allocator, .{ .include_meta = false });
    defer freeSchema(allocator, schema);

    var found_type = false;
    var found_enum = false;
    for (schema.obj) |m| {
        if (std.mem.eql(u8, m.k, "type")) {
            try std.testing.expectEqualStrings("string", m.v.str);
            found_type = true;
        }
        if (std.mem.eql(u8, m.k, "enum")) {
            found_enum = true;
            try std.testing.expectEqual(@as(usize, 3), m.v.arr.len);
        }
    }
    try std.testing.expect(found_type);
    try std.testing.expect(found_enum);
}

test "generate schema with json_config" {
    const allocator = std.testing.allocator;

    const Config = struct {
        user_name: []const u8,
        api_key: []const u8,

        pub const json_config = .{
            .user_name = FieldConfig{ .name = "userName" },
            .api_key = FieldConfig{ .skip = true },
        };
    };

    const schema = try generate(Config, allocator, .{ .include_meta = false });
    defer freeSchema(allocator, schema);

    // Find properties
    for (schema.obj) |m| {
        if (std.mem.eql(u8, m.k, "properties")) {
            // Should have userName but not api_key
            var found_userName = false;
            var found_api_key = false;
            for (m.v.obj) |prop| {
                if (std.mem.eql(u8, prop.k, "userName")) found_userName = true;
                if (std.mem.eql(u8, prop.k, "api_key")) found_api_key = true;
            }
            try std.testing.expect(found_userName);
            try std.testing.expect(!found_api_key);
        }
    }
}
