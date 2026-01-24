// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! JSON Unmarshaling
//!
//! Decodes JSON into native Zig types with full type safety.
//! Supports all primitive types, structs, enums, unions, optionals, and collections.
//!
//! Features:
//! - Type-safe decoding with comptime reflection
//! - Struct field tags via json_config for custom field names
//! - Custom unmarshaler interface via jsonUnmarshal method
//! - Proper memory management with free() function

const std = @import("std");
const json = @import("json.zig");
const encode_mod = @import("encode.zig");
const number_mod = @import("number.zig");
const pointer = @import("pointer.zig");

const Value = json.Value;
const Member = json.Member;
const Number = json.Number;
const FieldConfig = encode_mod.FieldConfig;
const BinaryFormat = encode_mod.BinaryFormat;

// ============================================================================
// Error Types
// ============================================================================

/// Unmarshaling error types
pub const UnmarshalError = error{
    /// JSON type doesn't match expected Zig type
    TypeMismatch,
    /// Required struct field is missing from JSON
    MissingField,
    /// JSON object contains unknown field (when ignore_unknown_fields is false)
    UnknownField,
    /// Value format is invalid (e.g., bad enum string)
    InvalidFormat,
    /// Integer value overflows target type
    IntegerOverflow,
    /// Duplicate field in JSON object
    DuplicateField,
    /// Memory allocation failed
    OutOfMemory,
    /// JSON parsing failed
    JsonParse,
};

/// Error kinds for detailed error reporting
pub const UnmarshalErrorKind = enum {
    type_mismatch,
    missing_field,
    unknown_field,
    invalid_format,
    integer_overflow,
    duplicate_field,
    json_parse,
};

/// Detailed unmarshal error with JSON Pointer path and context
pub const UnmarshalErrorInfo = struct {
    /// JSON Pointer path to the error location (e.g., "/users/0/email")
    path: []const u8,
    /// The kind of error
    kind: UnmarshalErrorKind,
    /// Expected type or value (for diagnostics)
    expected: ?[]const u8 = null,
    /// Actual type or value found
    found: ?[]const u8 = null,
    /// Human-readable error message
    message: []const u8,

    /// Format error as a string
    pub fn format(self: UnmarshalErrorInfo, allocator: std.mem.Allocator) ![]u8 {
        if (self.expected != null and self.found != null) {
            return std.fmt.allocPrint(allocator, "{s} at {s}: expected {s}, found {s}", .{
                self.message, self.path, self.expected.?, self.found.?,
            });
        } else {
            return std.fmt.allocPrint(allocator, "{s} at {s}", .{ self.message, self.path });
        }
    }
};

/// Result type for unmarshaling with detailed error info
pub fn UnmarshalResult(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: UnmarshalErrorInfo,
    };
}

/// Helper to create an error with duped path (so path survives after defer frees original)
fn makePathError(allocator: std.mem.Allocator, path: []const u8, kind: UnmarshalErrorKind, message: []const u8, expected: ?[]const u8, found: ?[]const u8) UnmarshalErrorInfo {
    return .{
        .path = allocator.dupe(u8, path) catch "",
        .kind = kind,
        .message = message,
        .expected = expected,
        .found = found,
    };
}

/// Unmarshaling options
pub const UnmarshalOptions = struct {
    /// Ignore unknown fields in JSON objects (default: true)
    /// Set to false to reject/error on unknown fields (strict mode)
    ignore_unknown_fields: bool = true,
    /// Use field tags from json_config for name mapping (default: true)
    use_field_tags: bool = true,
    /// Default binary decoding format for []u8 (overridable per-field)
    default_binary_format: BinaryFormat = .utf8,
    /// Allow "NaN", "Infinity", "-Infinity" strings for float fields
    allow_nan_infinity: bool = false,
    /// Match field names case-insensitively
    match_case_insensitive: bool = false,
};

/// Parse JSON string and unmarshal to type T
pub fn unmarshal(comptime T: type, allocator: std.mem.Allocator, input: []const u8) UnmarshalError!T {
    var err = json.ParseError.init();
    var doc = json.parse(allocator, input, .{}, &err) catch return error.JsonParse;
    defer doc.deinit();

    return fromValue(T, allocator, doc.root);
}

/// Unmarshal from existing Value tree
pub fn fromValue(comptime T: type, allocator: std.mem.Allocator, value: Value) UnmarshalError!T {
    return fromValueInternal(T, allocator, value, .{});
}

/// Unmarshal with custom options
pub fn fromValueWithOptions(comptime T: type, allocator: std.mem.Allocator, value: Value, opts: UnmarshalOptions) UnmarshalError!T {
    return fromValueInternal(T, allocator, value, opts);
}

/// Parse JSON and unmarshal with detailed error information
pub fn unmarshalWithInfo(comptime T: type, allocator: std.mem.Allocator, input: []const u8) UnmarshalResult(T) {
    var err = json.ParseError.init();
    var doc = json.parse(allocator, input, .{}, &err) catch {
        return .{ .err = .{
            .path = "",
            .kind = .json_parse,
            .message = "JSON parsing failed",
            .expected = null,
            .found = null,
        } };
    };
    defer doc.deinit();

    return fromValueWithInfo(T, allocator, doc.root, .{});
}

/// Unmarshal from Value with detailed error information
pub fn fromValueWithInfo(comptime T: type, allocator: std.mem.Allocator, value: Value, opts: UnmarshalOptions) UnmarshalResult(T) {
    return fromValueInternalWithPath(T, allocator, value, opts, "");
}

/// Free memory allocated during unmarshaling
pub fn free(comptime T: type, allocator: std.mem.Allocator, value: *T) void {
    freeInternal(T, allocator, value);
}

// ============================================================================
// Internal implementation
// ============================================================================

fn fromValueInternal(comptime T: type, allocator: std.mem.Allocator, value: Value, opts: UnmarshalOptions) UnmarshalError!T {
    const info = @typeInfo(T);

    // Check for custom unmarshaler first
    if (comptime encode_mod.hasJsonUnmarshal(T)) {
        return T.jsonUnmarshal(allocator, value) catch return error.InvalidFormat;
    }

    switch (info) {
        .bool => {
            if (value != .bool) return error.TypeMismatch;
            return value.bool;
        },

        .int => {
            if (value != .num) return error.TypeMismatch;
            return numberToInt(T, value.num) catch return error.IntegerOverflow;
        },

        .float => {
            if (value == .num) {
                return numberToFloat(T, value.num) catch return error.InvalidFormat;
            } else if (value == .str and opts.allow_nan_infinity) {
                return parseNanInfinity(T, value.str) orelse return error.InvalidFormat;
            }
            return error.TypeMismatch;
        },

        .optional => |opt| {
            if (value == .null) return null;
            return try fromValueInternal(opt.child, allocator, value, opts);
        },

        .pointer => |ptr| {
            switch (ptr.size) {
                .slice => {
                    if (ptr.child == u8) {
                        // String type - decode based on binary format
                        if (value != .str) return error.TypeMismatch;
                        return decodeBinary(allocator, value.str, opts.default_binary_format) catch return error.InvalidFormat;
                    } else {
                        // Array of other type
                        if (value != .arr) return error.TypeMismatch;
                        var result = allocator.alloc(ptr.child, value.arr.len) catch return error.OutOfMemory;
                        errdefer allocator.free(result);

                        for (value.arr, 0..) |item, i| {
                            result[i] = try fromValueInternal(ptr.child, allocator, item, opts);
                        }
                        return result;
                    }
                },
                .one => {
                    // Pointer to single value - allocate and decode
                    const ptr_val = allocator.create(ptr.child) catch return error.OutOfMemory;
                    errdefer allocator.destroy(ptr_val);
                    ptr_val.* = try fromValueInternal(ptr.child, allocator, value, opts);
                    return ptr_val;
                },
                else => return error.TypeMismatch,
            }
        },

        .array => |arr| {
            if (arr.child == u8) {
                // Fixed-size string
                if (value != .str) return error.TypeMismatch;
                if (value.str.len != arr.len) return error.InvalidFormat;
                var result: [arr.len]u8 = undefined;
                @memcpy(&result, value.str);
                return result;
            } else {
                // Fixed-size array
                if (value != .arr) return error.TypeMismatch;
                if (value.arr.len != arr.len) return error.InvalidFormat;
                var result: [arr.len]arr.child = undefined;
                for (value.arr, 0..) |item, i| {
                    result[i] = try fromValueInternal(arr.child, allocator, item, opts);
                }
                return result;
            }
        },

        .@"struct" => |s| {
            // Special case: json.Value - return as-is
            if (T == Value) {
                return value;
            }
            if (value != .obj) return error.TypeMismatch;
            return unmarshalStruct(T, s, allocator, value.obj, opts);
        },

        .@"enum" => {
            if (value == .str) {
                return std.meta.stringToEnum(T, value.str) orelse return error.InvalidFormat;
            } else if (value == .num) {
                const int_val = numberToInt(std.meta.Tag(T), value.num) catch return error.IntegerOverflow;
                return @enumFromInt(int_val);
            }
            return error.TypeMismatch;
        },

        .@"union" => |u| {
            if (u.tag_type) |_| {
                return unmarshalTaggedUnion(T, u, allocator, value, opts);
            }
            return error.TypeMismatch;
        },

        .void => {
            if (value != .null) return error.TypeMismatch;
            return {};
        },

        .null => {
            if (value != .null) return error.TypeMismatch;
            return null;
        },

        else => @compileError("Cannot unmarshal type: " ++ @typeName(T)),
    }
}

/// Internal unmarshaling with path tracking for detailed errors
fn fromValueInternalWithPath(comptime T: type, allocator: std.mem.Allocator, value: Value, opts: UnmarshalOptions, path: []const u8) UnmarshalResult(T) {
    const info = @typeInfo(T);

    // Check for custom unmarshaler first
    if (comptime encode_mod.hasJsonUnmarshal(T)) {
        const result = T.jsonUnmarshal(allocator, value) catch {
            return .{ .err = makePathError(allocator, path, .invalid_format, "Custom unmarshaler failed", @typeName(T), valueTypeName(value)) };
        };
        return .{ .ok = result };
    }

    switch (info) {
        .bool => {
            if (value != .bool) {
                return .{ .err = makePathError(allocator, path, .type_mismatch, "Type mismatch", "bool", valueTypeName(value)) };
            }
            return .{ .ok = value.bool };
        },

        .int => {
            if (value != .num) {
                return .{ .err = makePathError(allocator, path, .type_mismatch, "Type mismatch", "number", valueTypeName(value)) };
            }
            const result = numberToInt(T, value.num) catch {
                return .{ .err = makePathError(allocator, path, .integer_overflow, "Integer overflow", @typeName(T), value.num.lexeme) };
            };
            return .{ .ok = result };
        },

        .float => {
            if (value == .num) {
                const result = numberToFloat(T, value.num) catch {
                    return .{ .err = makePathError(allocator, path, .invalid_format, "Invalid float format", @typeName(T), value.num.lexeme) };
                };
                return .{ .ok = result };
            } else if (value == .str and opts.allow_nan_infinity) {
                if (parseNanInfinity(T, value.str)) |result| {
                    return .{ .ok = result };
                }
                return .{ .err = makePathError(allocator, path, .invalid_format, "Invalid NaN/Infinity string", "NaN, Infinity, or -Infinity", value.str) };
            }
            return .{ .err = makePathError(allocator, path, .type_mismatch, "Type mismatch", "number", valueTypeName(value)) };
        },

        .optional => |opt| {
            if (value == .null) return .{ .ok = null };
            const child_result = fromValueInternalWithPath(opt.child, allocator, value, opts, path);
            switch (child_result) {
                .ok => |v| return .{ .ok = v },
                .err => |e| return .{ .err = e },
            }
        },

        .pointer => |ptr| {
            switch (ptr.size) {
                .slice => {
                    if (ptr.child == u8) {
                        if (value != .str) {
                            return .{ .err = makePathError(allocator, path, .type_mismatch, "Type mismatch", "string", valueTypeName(value)) };
                        }
                        const result = decodeBinary(allocator, value.str, opts.default_binary_format) catch {
                            return .{ .err = makePathError(allocator, path, .invalid_format, "Binary decode failed", null, null) };
                        };
                        return .{ .ok = result };
                    } else {
                        if (value != .arr) {
                            return .{ .err = makePathError(allocator, path, .type_mismatch, "Type mismatch", "array", valueTypeName(value)) };
                        }
                        var result = allocator.alloc(ptr.child, value.arr.len) catch {
                            return .{ .err = makePathError(allocator, path, .type_mismatch, "Out of memory", null, null) };
                        };
                        errdefer allocator.free(result);

                        for (value.arr, 0..) |item, i| {
                            const item_path = pointer.appendIndex(path, i, allocator) catch {
                                return .{ .err = makePathError(allocator, path, .type_mismatch, "Out of memory building path", null, null) };
                            };
                            defer allocator.free(item_path);

                            const item_result = fromValueInternalWithPath(ptr.child, allocator, item, opts, item_path);
                            switch (item_result) {
                                .ok => |v| result[i] = v,
                                .err => |e| return .{ .err = e },
                            }
                        }
                        return .{ .ok = result };
                    }
                },
                .one => {
                    const ptr_val = allocator.create(ptr.child) catch {
                        return .{ .err = makePathError(allocator, path, .type_mismatch, "Out of memory", null, null) };
                    };
                    errdefer allocator.destroy(ptr_val);
                    const child_result = fromValueInternalWithPath(ptr.child, allocator, value, opts, path);
                    switch (child_result) {
                        .ok => |v| {
                            ptr_val.* = v;
                            return .{ .ok = ptr_val };
                        },
                        .err => |e| return .{ .err = e },
                    }
                },
                else => return .{ .err = makePathError(allocator, path, .type_mismatch, "Unsupported pointer type", @typeName(T), null) },
            }
        },

        .array => |arr| {
            if (arr.child == u8) {
                if (value != .str) {
                    return .{ .err = makePathError(allocator, path, .type_mismatch, "Type mismatch", "string", valueTypeName(value)) };
                }
                if (value.str.len != arr.len) {
                    return .{ .err = makePathError(allocator, path, .invalid_format, "String length mismatch", null, null) };
                }
                var result: [arr.len]u8 = undefined;
                @memcpy(&result, value.str);
                return .{ .ok = result };
            } else {
                if (value != .arr) {
                    return .{ .err = makePathError(allocator, path, .type_mismatch, "Type mismatch", "array", valueTypeName(value)) };
                }
                if (value.arr.len != arr.len) {
                    return .{ .err = makePathError(allocator, path, .invalid_format, "Array length mismatch", null, null) };
                }
                var result: [arr.len]arr.child = undefined;
                for (value.arr, 0..) |item, i| {
                    const item_path = pointer.appendIndex(path, i, allocator) catch {
                        return .{ .err = makePathError(allocator, path, .type_mismatch, "Out of memory building path", null, null) };
                    };
                    defer allocator.free(item_path);

                    const item_result = fromValueInternalWithPath(arr.child, allocator, item, opts, item_path);
                    switch (item_result) {
                        .ok => |v| result[i] = v,
                        .err => |e| return .{ .err = e },
                    }
                }
                return .{ .ok = result };
            }
        },

        .@"struct" => |s| {
            if (T == Value) {
                return .{ .ok = value };
            }
            if (value != .obj) {
                return .{ .err = makePathError(allocator, path, .type_mismatch, "Type mismatch", "object", valueTypeName(value)) };
            }
            return unmarshalStructWithPath(T, s, allocator, value.obj, opts, path);
        },

        .@"enum" => {
            if (value == .str) {
                const result = std.meta.stringToEnum(T, value.str) orelse {
                    return .{ .err = makePathError(allocator, path, .invalid_format, "Invalid enum value", @typeName(T), value.str) };
                };
                return .{ .ok = result };
            } else if (value == .num) {
                const int_val = numberToInt(std.meta.Tag(T), value.num) catch {
                    return .{ .err = makePathError(allocator, path, .integer_overflow, "Enum integer overflow", @typeName(T), value.num.lexeme) };
                };
                return .{ .ok = @enumFromInt(int_val) };
            }
            return .{ .err = makePathError(allocator, path, .type_mismatch, "Type mismatch", "string or number", valueTypeName(value)) };
        },

        .@"union" => |u| {
            if (u.tag_type) |_| {
                return unmarshalTaggedUnionWithPath(T, u, allocator, value, opts, path);
            }
            return .{ .err = makePathError(allocator, path, .type_mismatch, "Untagged unions not supported", @typeName(T), null) };
        },

        .void => {
            if (value != .null) {
                return .{ .err = makePathError(allocator, path, .type_mismatch, "Type mismatch", "null", valueTypeName(value)) };
            }
            return .{ .ok = {} };
        },

        .null => {
            if (value != .null) {
                return .{ .err = makePathError(allocator, path, .type_mismatch, "Type mismatch", "null", valueTypeName(value)) };
            }
            return .{ .ok = null };
        },

        else => @compileError("Cannot unmarshal type: " ++ @typeName(T)),
    }
}

/// Get JSON value type name for error messages
fn valueTypeName(value: Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "bool",
        .num => "number",
        .str => "string",
        .arr => "array",
        .obj => "object",
    };
}

fn unmarshalStruct(
    comptime T: type,
    comptime s: std.builtin.Type.Struct,
    allocator: std.mem.Allocator,
    obj: []const Member,
    opts: UnmarshalOptions,
) UnmarshalError!T {
    var result: T = undefined;
    var fields_found: [s.fields.len]bool = [_]bool{false} ** s.fields.len;

    // Find unknown field at comptime (if any)
    const unknown_field_idx = comptime findUnknownFieldIndex(T, s);

    // Initialize inline struct fields and unknown field
    inline for (s.fields, 0..) |field, i| {
        const field_cfg = comptime getFieldConfig(T, field.name);
        if (field_cfg.@"inline") {
            const ft_info = @typeInfo(field.type);
            if (ft_info == .@"struct") {
                // Initialize with defaults/zeroes before populating
                @field(result, field.name) = std.mem.zeroes(field.type);
                fields_found[i] = true; // Mark as found - we'll populate it inline
            } else if (ft_info == .optional) {
                @field(result, field.name) = null;
                fields_found[i] = true;
            }
        } else if (field_cfg.unknown) {
            // Mark unknown field as found - we'll populate it with collected members
            fields_found[i] = true;
        }
    }

    // List to collect unknown members (only used if there's an unknown field)
    var unknown_list: std.ArrayList(Member) = .empty;
    var unknown_list_initialized = false;
    errdefer {
        // Clean up any cloned members on error
        if (unknown_list_initialized) {
            for (unknown_list.items) |m| {
                allocator.free(m.k);
                freeClonedValue(allocator, m.v);
            }
            unknown_list.deinit(allocator);
        }
    }

    // Process each JSON member
    for (obj) |member| {
        var matched = false;
        inline for (s.fields, 0..) |field, i| {
            const json_name = comptime getJsonFieldName(T, field.name);
            const field_cfg = comptime getFieldConfig(T, field.name);

            // Skip if field is configured to be skipped or unknown
            if (comptime field_cfg.skip or field_cfg.unknown) {
                // Don't match this field
            } else if (comptime field_cfg.@"inline") {
                // Check if this key matches a field in the inline struct
                if (try tryUnmarshalInlineField(field.type, &@field(result, field.name), allocator, member, opts)) {
                    matched = true;
                }
            } else if (matchFieldName(member.k, json_name, opts.match_case_insensitive)) {
                @field(result, field.name) = try fromValueInternal(
                    field.type,
                    allocator,
                    member.v,
                    opts,
                );
                fields_found[i] = true;
                matched = true;
            }
        }

        if (!matched) {
            if (unknown_field_idx != null) {
                // Collect into unknown field - deep copy to own the memory
                const cloned = try cloneMember(allocator, member);
                try unknown_list.append(allocator, cloned);
                unknown_list_initialized = true;
            } else if (!opts.ignore_unknown_fields) {
                return error.UnknownField;
            }
        }
    }

    // Assign collected unknown members to the unknown field
    if (unknown_field_idx) |idx| {
        const unknown_slice = try unknown_list.toOwnedSlice(allocator);
        inline for (s.fields, 0..) |field, i| {
            if (i == idx) {
                const field_cfg = comptime getFieldConfig(T, field.name);
                if (field_cfg.unknown) {
                    try assignUnknownMembers(field.type, &@field(result, field.name), unknown_slice, allocator);
                }
            }
        }
    } else if (unknown_list_initialized) {
        // Clean up if we collected but have no unknown field (shouldn't happen normally)
        for (unknown_list.items) |m| {
            allocator.free(m.k);
            freeClonedValue(allocator, m.v);
        }
        unknown_list.deinit(allocator);
    }

    // Check required fields and set defaults
    inline for (s.fields, 0..) |field, i| {
        const field_cfg = comptime getFieldConfig(T, field.name);

        if (!fields_found[i]) {
            // Check if field has a default value
            if (comptime field.default_value_ptr) |default_ptr| {
                const default_val: *const field.type = @ptrCast(@alignCast(default_ptr));
                @field(result, field.name) = default_val.*;
            } else if (comptime field_cfg.skip) {
                // Skipped field without default - zero initialize
                @field(result, field.name) = std.mem.zeroes(field.type);
            } else if (@typeInfo(field.type) == .optional) {
                @field(result, field.name) = null;
            } else {
                return error.MissingField;
            }
        }
    }

    return result;
}

/// Find the index of the unknown field (if any)
fn findUnknownFieldIndex(comptime T: type, comptime s: std.builtin.Type.Struct) ?usize {
    inline for (s.fields, 0..) |field, i| {
        const field_cfg = comptime getFieldConfig(T, field.name);
        if (field_cfg.unknown) {
            return i;
        }
    }
    return null;
}

/// Check if a type is StringHashMap(Value)
fn isStringHashMapValue(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    // Check if it's a StringHashMap by looking for characteristic methods
    if (!@hasDecl(T, "put") or !@hasDecl(T, "get") or !@hasDecl(T, "iterator")) return false;
    // Check if it has the right key/value types by checking the KV type
    if (@hasDecl(T, "KV")) {
        const KV = T.KV;
        const kv_info = @typeInfo(KV);
        if (kv_info == .@"struct") {
            inline for (kv_info.@"struct".fields) |field| {
                if (std.mem.eql(u8, field.name, "key") and field.type == []const u8) {
                    // Found key field with correct type
                } else if (std.mem.eql(u8, field.name, "value") and field.type == Value) {
                    return true;
                }
            }
        }
    }
    return false;
}

/// Assign unknown members to []Member, ?[]Member, or StringHashMap(Value)
fn assignUnknownMembers(comptime T: type, ptr: *T, members: []Member, allocator: std.mem.Allocator) !void {
    const info = @typeInfo(T);
    if (info == .optional) {
        const Child = info.optional.child;
        if (comptime isStringHashMapValue(Child)) {
            if (members.len > 0) {
                var map = Child.init(allocator);
                for (members) |m| {
                    try map.put(m.k, m.v);
                }
                ptr.* = map;
            } else {
                ptr.* = null;
            }
            // Free the slice since we've moved the data to the map
            allocator.free(members);
        } else {
            if (members.len > 0) {
                ptr.* = members;
            } else {
                ptr.* = null;
            }
        }
    } else if (comptime isStringHashMapValue(T)) {
        // Initialize the map and populate it
        ptr.* = T.init(allocator);
        for (members) |m| {
            try ptr.put(m.k, m.v);
        }
        // Free the slice since we've moved the data to the map
        allocator.free(members);
    } else {
        ptr.* = members;
    }
}

/// Deep clone a Member (key and value)
fn cloneMember(allocator: std.mem.Allocator, member: Member) std.mem.Allocator.Error!Member {
    return .{
        .k = try allocator.dupe(u8, member.k),
        .v = try cloneValue(allocator, member.v),
    };
}

/// Free a cloned Value tree
fn freeClonedValue(allocator: std.mem.Allocator, value: Value) void {
    switch (value) {
        .null, .bool => {},
        .num => |n| {
            // Free lexeme, and digits if it doesn't point into lexeme
            const digits_ptr = @intFromPtr(n.digits.ptr);
            const lexeme_ptr = @intFromPtr(n.lexeme.ptr);
            const lexeme_end = lexeme_ptr + n.lexeme.len;
            if (digits_ptr < lexeme_ptr or digits_ptr >= lexeme_end) {
                allocator.free(n.digits);
            }
            allocator.free(n.lexeme);
        },
        .str => |s| allocator.free(s),
        .arr => |arr| {
            for (arr) |item| freeClonedValue(allocator, item);
            allocator.free(arr);
        },
        .obj => |obj| {
            for (obj) |m| {
                allocator.free(m.k);
                freeClonedValue(allocator, m.v);
            }
            allocator.free(obj);
        },
    }
}

/// Deep clone a Value tree
fn cloneValue(allocator: std.mem.Allocator, value: Value) std.mem.Allocator.Error!Value {
    switch (value) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .num => |n| {
            const lexeme = try allocator.dupe(u8, n.lexeme);
            // Digits often point into lexeme, need to adjust
            const digits_ptr = @intFromPtr(n.digits.ptr);
            const lexeme_ptr = @intFromPtr(n.lexeme.ptr);
            const lexeme_end = lexeme_ptr + n.lexeme.len;
            const digits = if (digits_ptr >= lexeme_ptr and digits_ptr < lexeme_end) blk: {
                const offset = digits_ptr - lexeme_ptr;
                break :blk lexeme[offset .. offset + n.digits.len];
            } else try allocator.dupe(u8, n.digits);
            return .{ .num = .{
                .lexeme = lexeme,
                .sign = n.sign,
                .digits = digits,
                .exp10 = n.exp10,
            } };
        },
        .str => |s| return .{ .str = try allocator.dupe(u8, s) },
        .arr => |arr| {
            const items = try allocator.alloc(Value, arr.len);
            for (arr, 0..) |item, i| {
                items[i] = try cloneValue(allocator, item);
            }
            return .{ .arr = items };
        },
        .obj => |obj| {
            const members = try allocator.alloc(Member, obj.len);
            for (obj, 0..) |m, i| {
                members[i] = try cloneMember(allocator, m);
            }
            return .{ .obj = members };
        },
    }
}

/// Try to unmarshal a JSON member into an inline struct field
/// Returns true if the key matched and was handled
fn tryUnmarshalInlineField(
    comptime FieldType: type,
    result_ptr: anytype,
    allocator: std.mem.Allocator,
    member: Member,
    opts: UnmarshalOptions,
) UnmarshalError!bool {
    const ft_info = @typeInfo(FieldType);

    if (ft_info == .optional) {
        const ChildType = ft_info.optional.child;
        const child_info = @typeInfo(ChildType);
        if (child_info == .@"struct") {
            // Check if this key matches any field in the inline struct
            // We need to do a "dry run" check first since we can't uninitialize if no match
            if (inlineStructHasKey(ChildType, member.k, opts.match_case_insensitive)) {
                // Initialize the optional if needed
                if (result_ptr.* == null) {
                    result_ptr.* = std.mem.zeroes(ChildType);
                }
                return tryUnmarshalInlineStructMember(ChildType, &result_ptr.*.?, allocator, member, opts);
            }
        }
    } else if (ft_info == .@"struct") {
        return tryUnmarshalInlineStructMember(FieldType, result_ptr, allocator, member, opts);
    }

    return false;
}

/// Check at runtime if a key matches any field in an inline struct
fn inlineStructHasKey(comptime T: type, key: []const u8, case_insensitive: bool) bool {
    const s = @typeInfo(T).@"struct";

    inline for (s.fields) |field| {
        const json_name = comptime getJsonFieldName(T, field.name);
        const field_cfg = comptime getFieldConfig(T, field.name);

        if (comptime field_cfg.skip) {
            continue;
        } else if (comptime field_cfg.@"inline") {
            // Recursively check nested inline structs
            const nested_info = @typeInfo(field.type);
            if (nested_info == .@"struct") {
                if (inlineStructHasKey(field.type, key, case_insensitive)) return true;
            } else if (nested_info == .optional) {
                const child_info = @typeInfo(nested_info.optional.child);
                if (child_info == .@"struct") {
                    if (inlineStructHasKey(nested_info.optional.child, key, case_insensitive)) return true;
                }
            }
        } else if (matchFieldName(key, json_name, case_insensitive)) {
            return true;
        }
    }

    return false;
}

/// Try to match and unmarshal a member into an inline struct
fn tryUnmarshalInlineStructMember(
    comptime T: type,
    result_ptr: *T,
    allocator: std.mem.Allocator,
    member: Member,
    opts: UnmarshalOptions,
) UnmarshalError!bool {
    const s = @typeInfo(T).@"struct";

    inline for (s.fields) |field| {
        const json_name = comptime getJsonFieldName(T, field.name);
        const field_cfg = comptime getFieldConfig(T, field.name);

        if (comptime field_cfg.skip) {
            continue;
        } else if (comptime field_cfg.@"inline") {
            // Recursively check nested inline fields
            if (try tryUnmarshalInlineField(field.type, &@field(result_ptr.*, field.name), allocator, member, opts)) {
                return true;
            }
        } else if (matchFieldName(member.k, json_name, opts.match_case_insensitive)) {
            @field(result_ptr.*, field.name) = try fromValueInternal(
                field.type,
                allocator,
                member.v,
                opts,
            );
            return true;
        }
    }

    return false;
}

fn unmarshalTaggedUnion(
    comptime T: type,
    comptime u: std.builtin.Type.Union,
    allocator: std.mem.Allocator,
    value: Value,
    opts: UnmarshalOptions,
) UnmarshalError!T {
    if (value != .obj) return error.TypeMismatch;
    if (value.obj.len != 1) return error.InvalidFormat;

    const member = value.obj[0];

    inline for (u.fields) |field| {
        if (std.mem.eql(u8, field.name, member.k)) {
            if (field.type == void) {
                return @unionInit(T, field.name, {});
            } else {
                const payload = try fromValueInternal(field.type, allocator, member.v, opts);
                return @unionInit(T, field.name, payload);
            }
        }
    }

    return error.InvalidFormat;
}

/// Struct unmarshaling with path tracking
fn unmarshalStructWithPath(
    comptime T: type,
    comptime s: std.builtin.Type.Struct,
    allocator: std.mem.Allocator,
    obj: []const Member,
    opts: UnmarshalOptions,
    path: []const u8,
) UnmarshalResult(T) {
    var result: T = undefined;
    var fields_found: [s.fields.len]bool = [_]bool{false} ** s.fields.len;

    // Initialize inline struct fields first
    inline for (s.fields, 0..) |field, i| {
        const field_cfg = comptime getFieldConfig(T, field.name);
        if (field_cfg.@"inline") {
            const ft_info = @typeInfo(field.type);
            if (ft_info == .@"struct") {
                @field(result, field.name) = std.mem.zeroes(field.type);
                fields_found[i] = true;
            } else if (ft_info == .optional) {
                @field(result, field.name) = null;
                fields_found[i] = true;
            }
        }
    }

    // Process each JSON member
    for (obj) |member| {
        var matched = false;
        inline for (s.fields, 0..) |field, i| {
            const json_name = comptime getJsonFieldName(T, field.name);
            const field_cfg = comptime getFieldConfig(T, field.name);

            if (comptime field_cfg.skip) {
                // Don't match this field
            } else if (comptime field_cfg.@"inline") {
                // Check if this key matches a field in the inline struct
                const inline_result = tryUnmarshalInlineFieldWithPath(field.type, &@field(result, field.name), allocator, member, opts, path);
                switch (inline_result) {
                    .matched => matched = true,
                    .not_matched => {},
                    .err => |e| return .{ .err = e },
                }
            } else if (matchFieldName(member.k, json_name, opts.match_case_insensitive)) {
                const field_path = pointer.append(path, json_name, allocator) catch {
                    return .{ .err = makePathError(allocator, path, .type_mismatch, "Out of memory building path", null, null) };
                };
                defer allocator.free(field_path);

                const field_result = fromValueInternalWithPath(field.type, allocator, member.v, opts, field_path);
                switch (field_result) {
                    .ok => |v| {
                        @field(result, field.name) = v;
                        fields_found[i] = true;
                        matched = true;
                    },
                    .err => |e| return .{ .err = e },
                }
            }
        }

        if (!matched and !opts.ignore_unknown_fields) {
            return .{ .err = makePathError(allocator, path, .unknown_field, "Unknown field", null, member.k) };
        }
    }

    // Check required fields and set defaults
    inline for (s.fields, 0..) |field, i| {
        const field_cfg = comptime getFieldConfig(T, field.name);

        if (!fields_found[i]) {
            if (comptime field.default_value_ptr) |default_ptr| {
                const default_val: *const field.type = @ptrCast(@alignCast(default_ptr));
                @field(result, field.name) = default_val.*;
            } else if (comptime field_cfg.skip) {
                @field(result, field.name) = std.mem.zeroes(field.type);
            } else if (@typeInfo(field.type) == .optional) {
                @field(result, field.name) = null;
            } else {
                return .{ .err = makePathError(allocator, path, .missing_field, "Missing required field", field.name, null) };
            }
        }
    }

    return .{ .ok = result };
}

/// Result type for inline field matching with path tracking
const InlineMatchResult = union(enum) {
    matched: void,
    not_matched: void,
    err: UnmarshalErrorInfo,
};

/// Try to unmarshal a JSON member into an inline struct field with path tracking
fn tryUnmarshalInlineFieldWithPath(
    comptime FieldType: type,
    result_ptr: anytype,
    allocator: std.mem.Allocator,
    member: Member,
    opts: UnmarshalOptions,
    path: []const u8,
) InlineMatchResult {
    const ft_info = @typeInfo(FieldType);

    if (ft_info == .optional) {
        const ChildType = ft_info.optional.child;
        const child_info = @typeInfo(ChildType);
        if (child_info == .@"struct") {
            if (result_ptr.* == null) {
                result_ptr.* = std.mem.zeroes(ChildType);
            }
            return tryUnmarshalInlineStructMemberWithPath(ChildType, &result_ptr.*.?, allocator, member, opts, path);
        }
    } else if (ft_info == .@"struct") {
        return tryUnmarshalInlineStructMemberWithPath(FieldType, result_ptr, allocator, member, opts, path);
    }

    return .not_matched;
}

/// Try to match and unmarshal a member into an inline struct with path tracking
fn tryUnmarshalInlineStructMemberWithPath(
    comptime T: type,
    result_ptr: *T,
    allocator: std.mem.Allocator,
    member: Member,
    opts: UnmarshalOptions,
    path: []const u8,
) InlineMatchResult {
    const s = @typeInfo(T).@"struct";

    inline for (s.fields) |field| {
        const json_name = comptime getJsonFieldName(T, field.name);
        const field_cfg = comptime getFieldConfig(T, field.name);

        if (comptime field_cfg.skip) {
            continue;
        } else if (comptime field_cfg.@"inline") {
            const nested_result = tryUnmarshalInlineFieldWithPath(field.type, &@field(result_ptr.*, field.name), allocator, member, opts, path);
            switch (nested_result) {
                .matched => return .matched,
                .not_matched => {},
                .err => |e| return .{ .err = e },
            }
        } else if (matchFieldName(member.k, json_name, opts.match_case_insensitive)) {
            const field_path = pointer.append(path, json_name, allocator) catch {
                return .{ .err = makePathError(allocator, path, .type_mismatch, "Out of memory building path", null, null) };
            };
            defer allocator.free(field_path);

            const field_result = fromValueInternalWithPath(field.type, allocator, member.v, opts, field_path);
            switch (field_result) {
                .ok => |v| {
                    @field(result_ptr.*, field.name) = v;
                    return .matched;
                },
                .err => |e| return .{ .err = e },
            }
        }
    }

    return .not_matched;
}

/// Tagged union unmarshaling with path tracking
fn unmarshalTaggedUnionWithPath(
    comptime T: type,
    comptime u: std.builtin.Type.Union,
    allocator: std.mem.Allocator,
    value: Value,
    opts: UnmarshalOptions,
    path: []const u8,
) UnmarshalResult(T) {
    if (value != .obj) {
        return .{ .err = makePathError(allocator, path, .type_mismatch, "Type mismatch", "object", valueTypeName(value)) };
    }
    if (value.obj.len != 1) {
        return .{ .err = makePathError(allocator, path, .invalid_format, "Tagged union must have exactly one field", null, null) };
    }

    const member = value.obj[0];

    inline for (u.fields) |field| {
        if (std.mem.eql(u8, field.name, member.k)) {
            if (field.type == void) {
                return .{ .ok = @unionInit(T, field.name, {}) };
            } else {
                const field_path = pointer.append(path, field.name, allocator) catch {
                    return .{ .err = makePathError(allocator, path, .type_mismatch, "Out of memory building path", null, null) };
                };
                defer allocator.free(field_path);

                const payload_result = fromValueInternalWithPath(field.type, allocator, member.v, opts, field_path);
                switch (payload_result) {
                    .ok => |payload| return .{ .ok = @unionInit(T, field.name, payload) },
                    .err => |e| return .{ .err = e },
                }
            }
        }
    }

    return .{ .err = makePathError(allocator, path, .invalid_format, "Unknown union variant", @typeName(T), member.k) };
}

/// Get JSON field name from json_config or use field name
fn getJsonFieldName(comptime T: type, comptime field_name: []const u8) []const u8 {
    const cfg = getFieldConfig(T, field_name);
    return cfg.name orelse field_name;
}

/// Get field config for a field if json_config is defined
fn getFieldConfig(comptime T: type, comptime field_name: []const u8) FieldConfig {
    if (@hasDecl(T, "json_config")) {
        const config = T.json_config;
        const ConfigType = @TypeOf(config);
        if (@hasField(ConfigType, field_name)) {
            return @field(config, field_name);
        }
    }
    return .{};
}

fn numberToInt(comptime T: type, num: Number) !T {
    // Check if number is an integer
    if (!num.isInteger()) {
        return error.InvalidFormat;
    }

    // Parse from lexeme
    const result = std.fmt.parseInt(T, num.lexeme, 10) catch return error.IntegerOverflow;
    return result;
}

fn numberToFloat(comptime T: type, num: Number) !T {
    return std.fmt.parseFloat(T, num.lexeme) catch return error.InvalidFormat;
}

/// Parse NaN/Infinity string to float
fn parseNanInfinity(comptime T: type, str: []const u8) ?T {
    if (std.mem.eql(u8, str, "NaN")) {
        return std.math.nan(T);
    } else if (std.mem.eql(u8, str, "Infinity")) {
        return std.math.inf(T);
    } else if (std.mem.eql(u8, str, "-Infinity")) {
        return -std.math.inf(T);
    }
    return null;
}

/// Decode binary data from string based on format
fn decodeBinary(allocator: std.mem.Allocator, str: []const u8, format: BinaryFormat) ![]u8 {
    switch (format) {
        .utf8 => {
            // Just duplicate the string as-is
            return allocator.dupe(u8, str);
        },
        .base64 => {
            const decoder = std.base64.standard.Decoder;
            const size = decoder.calcSizeForSlice(str) catch return error.InvalidFormat;
            const buf = allocator.alloc(u8, size) catch return error.OutOfMemory;
            errdefer allocator.free(buf);
            decoder.decode(buf, str) catch return error.InvalidFormat;
            return buf;
        },
        .base64url => {
            const decoder = std.base64.url_safe_no_pad.Decoder;
            const size = decoder.calcSizeForSlice(str) catch return error.InvalidFormat;
            const buf = allocator.alloc(u8, size) catch return error.OutOfMemory;
            errdefer allocator.free(buf);
            decoder.decode(buf, str) catch return error.InvalidFormat;
            return buf;
        },
        .hex, .hex_upper => {
            // Hex decode: 2 chars per byte
            if (str.len % 2 != 0) return error.InvalidFormat;
            const size = str.len / 2;
            const buf = allocator.alloc(u8, size) catch return error.OutOfMemory;
            errdefer allocator.free(buf);
            for (0..size) |i| {
                const high = hexValue(str[i * 2]) orelse return error.InvalidFormat;
                const low = hexValue(str[i * 2 + 1]) orelse return error.InvalidFormat;
                buf[i] = (high << 4) | low;
            }
            return buf;
        },
        .base32 => {
            // Base32 decode: 8 chars -> 5 bytes
            const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
            // Remove padding and calculate size
            var len = str.len;
            while (len > 0 and str[len - 1] == '=') len -= 1;
            const out_size = (len * 5) / 8;
            const buf = allocator.alloc(u8, out_size) catch return error.OutOfMemory;
            errdefer allocator.free(buf);

            var acc: u64 = 0;
            var bits: u6 = 0;
            var out_idx: usize = 0;
            for (str[0..len]) |c| {
                const val = std.mem.indexOfScalar(u8, alphabet, std.ascii.toUpper(c)) orelse return error.InvalidFormat;
                acc = (acc << 5) | val;
                bits += 5;
                if (bits >= 8) {
                    bits -= 8;
                    buf[out_idx] = @truncate(acc >> bits);
                    out_idx += 1;
                }
            }
            return buf;
        },
    }
}

/// Convert hex character to value
fn hexValue(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

/// Case-insensitive string comparison
fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

/// Match field name with optional case-insensitivity
fn matchFieldName(json_key: []const u8, comptime field_name: []const u8, case_insensitive: bool) bool {
    if (case_insensitive) {
        return eqlIgnoreCase(json_key, field_name);
    } else {
        return std.mem.eql(u8, json_key, field_name);
    }
}

// ============================================================================
// Memory freeing
// ============================================================================

fn freeInternal(comptime T: type, allocator: std.mem.Allocator, value: *T) void {
    const info = @typeInfo(T);

    switch (info) {
        .pointer => |ptr| {
            switch (ptr.size) {
                .slice => {
                    if (ptr.child != u8) {
                        // Free nested allocations in slice elements
                        for (value.*) |*item| {
                            freeInternal(ptr.child, allocator, item);
                        }
                    }
                    allocator.free(value.*);
                },
                .one => {
                    freeInternal(ptr.child, allocator, value.*);
                    allocator.destroy(value.*);
                },
                else => {},
            }
        },

        .@"struct" => |s| {
            inline for (s.fields) |field| {
                freeInternal(field.type, allocator, &@field(value.*, field.name));
            }
        },

        .optional => |opt| {
            if (value.*) |*v| {
                freeInternal(opt.child, allocator, v);
            }
        },

        .@"union" => |u| {
            if (u.tag_type) |_| {
                inline for (u.fields) |field| {
                    if (std.mem.eql(u8, @tagName(value.*), field.name)) {
                        if (field.type != void) {
                            freeInternal(field.type, allocator, &@field(value.*, field.name));
                        }
                    }
                }
            }
        },

        .array => |arr| {
            if (arr.child != u8) {
                for (&value.*) |*item| {
                    freeInternal(arr.child, allocator, item);
                }
            }
        },

        else => {
            // Primitives don't need freeing
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "unmarshal bool" {
    const t = try unmarshal(bool, std.testing.allocator, "true");
    try std.testing.expect(t == true);

    const f = try unmarshal(bool, std.testing.allocator, "false");
    try std.testing.expect(f == false);
}

test "unmarshal integers" {
    const i = try unmarshal(i32, std.testing.allocator, "42");
    try std.testing.expectEqual(@as(i32, 42), i);

    const neg = try unmarshal(i32, std.testing.allocator, "-123");
    try std.testing.expectEqual(@as(i32, -123), neg);

    const big = try unmarshal(u64, std.testing.allocator, "18446744073709551615");
    try std.testing.expectEqual(@as(u64, 18446744073709551615), big);
}

test "unmarshal floats" {
    const f = try unmarshal(f64, std.testing.allocator, "3.14");
    try std.testing.expect(@abs(f - 3.14) < 0.001);
}

test "unmarshal string" {
    const s = try unmarshal([]const u8, std.testing.allocator, "\"hello\"");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("hello", s);
}

test "unmarshal optional" {
    const some = try unmarshal(?i32, std.testing.allocator, "42");
    try std.testing.expectEqual(@as(?i32, 42), some);

    const none = try unmarshal(?i32, std.testing.allocator, "null");
    try std.testing.expectEqual(@as(?i32, null), none);
}

test "unmarshal array" {
    const arr = try unmarshal([]i32, std.testing.allocator, "[1, 2, 3]");
    defer std.testing.allocator.free(arr);
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqual(@as(i32, 1), arr[0]);
    try std.testing.expectEqual(@as(i32, 2), arr[1]);
    try std.testing.expectEqual(@as(i32, 3), arr[2]);
}

test "unmarshal fixed array" {
    const arr = try unmarshal([3]i32, std.testing.allocator, "[1, 2, 3]");
    try std.testing.expectEqual(@as(i32, 1), arr[0]);
    try std.testing.expectEqual(@as(i32, 2), arr[1]);
    try std.testing.expectEqual(@as(i32, 3), arr[2]);
}

test "unmarshal struct" {
    const Point = struct { x: i32, y: i32 };
    const p = try unmarshal(Point, std.testing.allocator, "{\"x\": 10, \"y\": 20}");
    try std.testing.expectEqual(@as(i32, 10), p.x);
    try std.testing.expectEqual(@as(i32, 20), p.y);
}

test "unmarshal struct with optional field" {
    const Person = struct {
        name: []const u8,
        age: ?i32 = null,
    };

    const p = try unmarshal(Person, std.testing.allocator, "{\"name\": \"Alice\"}");
    defer std.testing.allocator.free(p.name);
    try std.testing.expectEqualStrings("Alice", p.name);
    try std.testing.expectEqual(@as(?i32, null), p.age);
}

test "unmarshal struct with default value" {
    const Config = struct {
        name: []const u8,
        timeout: i32 = 30,
    };

    const c = try unmarshal(Config, std.testing.allocator, "{\"name\": \"test\"}");
    defer std.testing.allocator.free(c.name);
    try std.testing.expectEqualStrings("test", c.name);
    try std.testing.expectEqual(@as(i32, 30), c.timeout);
}

test "unmarshal enum" {
    const Color = enum { red, green, blue };

    const c = try unmarshal(Color, std.testing.allocator, "\"green\"");
    try std.testing.expectEqual(Color.green, c);
}

test "unmarshal tagged union" {
    const Shape = union(enum) {
        circle: f32,
        point: void,
    };

    const circle = try unmarshal(Shape, std.testing.allocator, "{\"circle\": 5.0}");
    try std.testing.expect(circle == .circle);
    try std.testing.expect(@abs(circle.circle - 5.0) < 0.001);

    const point = try unmarshal(Shape, std.testing.allocator, "{\"point\": null}");
    try std.testing.expect(point == .point);
}

test "unmarshal with custom field name" {
    const Person = struct {
        first_name: []const u8,
        last_name: []const u8,

        pub const json_config = .{
            .first_name = FieldConfig{ .name = "firstName" },
            .last_name = FieldConfig{ .name = "lastName" },
        };
    };

    const p = try unmarshal(Person, std.testing.allocator, "{\"firstName\": \"John\", \"lastName\": \"Doe\"}");
    defer {
        std.testing.allocator.free(p.first_name);
        std.testing.allocator.free(p.last_name);
    }
    try std.testing.expectEqualStrings("John", p.first_name);
    try std.testing.expectEqualStrings("Doe", p.last_name);
}

test "unmarshal nested struct" {
    const Inner = struct { value: i32 };
    const Outer = struct {
        name: []const u8,
        inner: Inner,
    };

    const o = try unmarshal(Outer, std.testing.allocator, "{\"name\": \"test\", \"inner\": {\"value\": 42}}");
    defer std.testing.allocator.free(o.name);
    try std.testing.expectEqualStrings("test", o.name);
    try std.testing.expectEqual(@as(i32, 42), o.inner.value);
}

test "unmarshal array of strings" {
    const arr = try unmarshal([][]const u8, std.testing.allocator, "[\"hello\", \"world\"]");
    defer {
        for (arr) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(arr);
    }
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqualStrings("hello", arr[0]);
    try std.testing.expectEqualStrings("world", arr[1]);
}

test "free nested struct" {
    const Inner = struct { name: []const u8 };
    const Outer = struct {
        inner: Inner,
        items: [][]const u8,
    };

    var o = try unmarshal(Outer, std.testing.allocator,
        \\{"inner": {"name": "test"}, "items": ["a", "b"]}
    );
    free(Outer, std.testing.allocator, &o);
}

test "unmarshal with skip field" {
    const Config = struct {
        name: []const u8,
        internal_id: u64 = 0,

        pub const json_config = .{
            .internal_id = FieldConfig{ .skip = true },
        };
    };

    // Should work even though internal_id is in JSON
    const c = try unmarshal(Config, std.testing.allocator, "{\"name\": \"test\", \"internal_id\": 999}");
    defer std.testing.allocator.free(c.name);
    try std.testing.expectEqualStrings("test", c.name);
    // internal_id should be default (0), not 999
    try std.testing.expectEqual(@as(u64, 0), c.internal_id);
}

test "unmarshalWithInfo returns detailed error for type mismatch" {
    const Simple = struct { value: i32 };

    const result = unmarshalWithInfo(Simple, std.testing.allocator, "{\"value\": \"not a number\"}");
    switch (result) {
        .ok => try std.testing.expect(false), // Should be error
        .err => |err| {
            defer if (err.path.len > 0) std.testing.allocator.free(err.path);
            try std.testing.expectEqualStrings("/value", err.path);
            try std.testing.expect(err.kind == .type_mismatch);
            try std.testing.expect(err.expected != null);
            try std.testing.expect(err.found != null);
        },
    }
}

test "unmarshalWithInfo returns path for nested error" {
    const Inner = struct { count: u32 };
    const Outer = struct { inner: Inner };

    const result = unmarshalWithInfo(Outer, std.testing.allocator, "{\"inner\": {\"count\": \"bad\"}}");
    switch (result) {
        .ok => try std.testing.expect(false),
        .err => |err| {
            defer if (err.path.len > 0) std.testing.allocator.free(err.path);
            try std.testing.expectEqualStrings("/inner/count", err.path);
            try std.testing.expect(err.kind == .type_mismatch);
        },
    }
}

test "unmarshalWithInfo returns path for array element error" {
    // Use fixed-size array to avoid partial slice allocation issues
    const result = unmarshalWithInfo([4]i32, std.testing.allocator, "[1, 2, \"three\", 4]");
    switch (result) {
        .ok => try std.testing.expect(false),
        .err => |err| {
            defer if (err.path.len > 0) std.testing.allocator.free(err.path);
            try std.testing.expectEqualStrings("/2", err.path);
            try std.testing.expect(err.kind == .type_mismatch);
        },
    }
}

test "unmarshalWithInfo returns error for missing required field" {
    // Use simple types to avoid partial allocation issues
    const Required = struct { id: u32, age: u32 };

    const result = unmarshalWithInfo(Required, std.testing.allocator, "{\"id\": 1}");
    switch (result) {
        .ok => try std.testing.expect(false),
        .err => |err| {
            defer if (err.path.len > 0) std.testing.allocator.free(err.path);
            try std.testing.expect(err.kind == .missing_field);
            // Path should point to the struct (empty path is not allocated)
            try std.testing.expectEqualStrings("", err.path);
        },
    }
}

test "unmarshalWithInfo success returns ok variant" {
    const Simple = struct { value: i32 };

    const result = unmarshalWithInfo(Simple, std.testing.allocator, "{\"value\": 42}");
    switch (result) {
        .ok => |v| try std.testing.expectEqual(@as(i32, 42), v.value),
        .err => try std.testing.expect(false),
    }
}

test "UnmarshalErrorInfo format" {
    const err = UnmarshalErrorInfo{
        .path = "/users/0/email",
        .kind = .type_mismatch,
        .expected = "string",
        .found = "number",
        .message = "Type mismatch",
    };

    const formatted = try err.format(std.testing.allocator);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("Type mismatch at /users/0/email: expected string, found number", formatted);
}

test "unmarshal with hex binary format" {
    const Data = struct { data: []const u8 };

    var members = [_]json.Member{.{ .k = "data", .v = .{ .str = "deadbeef" } }};
    const result = try fromValueWithOptions(Data, std.testing.allocator, json.Value{
        .obj = &members,
    }, .{ .default_binary_format = .hex });
    defer std.testing.allocator.free(result.data);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF }, result.data);
}

test "unmarshal with base64 binary format" {
    const Data = struct { data: []const u8 };

    var members = [_]json.Member{.{ .k = "data", .v = .{ .str = "SGVsbG8sIFdvcmxkIQ==" } }};
    const result = try fromValueWithOptions(Data, std.testing.allocator, json.Value{
        .obj = &members,
    }, .{ .default_binary_format = .base64 });
    defer std.testing.allocator.free(result.data);

    try std.testing.expectEqualStrings("Hello, World!", result.data);
}

test "unmarshal inline struct fields" {
    const Metadata = struct {
        created_at: i64,
        updated_at: i64,
    };

    const User = struct {
        id: u64,
        name: []const u8,
        metadata: Metadata,

        pub const json_config = .{
            .metadata = FieldConfig{ .@"inline" = true },
        };
    };

    // JSON with flattened fields
    const input =
        \\{"id":1,"name":"Alice","created_at":123,"updated_at":456}
    ;

    const result = try unmarshal(User, std.testing.allocator, input);
    defer std.testing.allocator.free(result.name);

    try std.testing.expectEqual(@as(u64, 1), result.id);
    try std.testing.expectEqualStrings("Alice", result.name);
    try std.testing.expectEqual(@as(i64, 123), result.metadata.created_at);
    try std.testing.expectEqual(@as(i64, 456), result.metadata.updated_at);
}

test "unmarshal inline optional struct fields" {
    const Extra = struct {
        version: u32,
    };

    const Config = struct {
        name: []const u8,
        extra: ?Extra = null,

        pub const json_config = .{
            .extra = FieldConfig{ .@"inline" = true },
        };
    };

    // With inline field present
    const input1 =
        \\{"name":"test","version":42}
    ;

    const result1 = try unmarshal(Config, std.testing.allocator, input1);
    defer std.testing.allocator.free(result1.name);

    try std.testing.expectEqualStrings("test", result1.name);
    try std.testing.expect(result1.extra != null);
    try std.testing.expectEqual(@as(u32, 42), result1.extra.?.version);

    // Without inline field
    const input2 =
        \\{"name":"test2"}
    ;

    const result2 = try unmarshal(Config, std.testing.allocator, input2);
    defer std.testing.allocator.free(result2.name);

    try std.testing.expectEqualStrings("test2", result2.name);
    try std.testing.expect(result2.extra == null);
}

test "inline struct round-trip" {
    const json_mod = @import("json.zig");

    const Inner = struct {
        x: i32,
        y: i32,
    };

    const Outer = struct {
        id: u32,
        pos: Inner,

        pub const json_config = .{
            .pos = FieldConfig{ .@"inline" = true },
        };
    };

    const original = Outer{
        .id = 100,
        .pos = .{ .x = 10, .y = 20 },
    };

    // Encode
    const encoded = try json_mod.encode(std.testing.allocator, original, .{});
    defer std.testing.allocator.free(encoded);

    // Verify flattened
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"pos\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"x\":10") != null);

    // Decode
    const decoded = try unmarshal(Outer, std.testing.allocator, encoded);

    try std.testing.expectEqual(@as(u32, 100), decoded.id);
    try std.testing.expectEqual(@as(i32, 10), decoded.pos.x);
    try std.testing.expectEqual(@as(i32, 20), decoded.pos.y);
}

test "unmarshal with unknown member capture" {
    const Config = struct {
        name: []const u8,
        version: u32,
        extra: []Member,

        pub const json_config = .{
            .extra = FieldConfig{ .unknown = true },
        };
    };

    const input =
        \\{"name":"app","version":1,"foo":"bar","debug":true}
    ;

    const result = try unmarshal(Config, std.testing.allocator, input);
    defer {
        std.testing.allocator.free(result.name);
        // Free the cloned Member contents
        for (result.extra) |m| {
            std.testing.allocator.free(m.k);
            freeClonedValue(std.testing.allocator, m.v);
        }
        std.testing.allocator.free(result.extra);
    }

    try std.testing.expectEqualStrings("app", result.name);
    try std.testing.expectEqual(@as(u32, 1), result.version);
    try std.testing.expectEqual(@as(usize, 2), result.extra.len);

    // Check that foo and debug were captured
    var found_foo = false;
    var found_debug = false;
    for (result.extra) |m| {
        if (std.mem.eql(u8, m.k, "foo")) {
            try std.testing.expectEqualStrings("bar", m.v.str);
            found_foo = true;
        }
        if (std.mem.eql(u8, m.k, "debug")) {
            try std.testing.expect(m.v.bool == true);
            found_debug = true;
        }
    }
    try std.testing.expect(found_foo);
    try std.testing.expect(found_debug);
}

test "unmarshal with optional unknown member capture" {
    const Config = struct {
        name: []const u8,
        extra: ?[]Member = null,

        pub const json_config = .{
            .extra = FieldConfig{ .unknown = true },
        };
    };

    // With unknown fields
    const input1 =
        \\{"name":"test","key":42}
    ;

    const result1 = try unmarshal(Config, std.testing.allocator, input1);
    defer {
        std.testing.allocator.free(result1.name);
        if (result1.extra) |e| {
            for (e) |m| {
                std.testing.allocator.free(m.k);
                freeClonedValue(std.testing.allocator, m.v);
            }
            std.testing.allocator.free(e);
        }
    }

    try std.testing.expect(result1.extra != null);
    try std.testing.expectEqual(@as(usize, 1), result1.extra.?.len);

    // Without unknown fields
    const input2 =
        \\{"name":"test2"}
    ;

    const result2 = try unmarshal(Config, std.testing.allocator, input2);
    defer std.testing.allocator.free(result2.name);

    try std.testing.expect(result2.extra == null);
}

test "unknown member capture round-trip" {
    const json_mod = @import("json.zig");

    const Config = struct {
        name: []const u8,
        extra: []Member,

        pub const json_config = .{
            .extra = FieldConfig{ .unknown = true },
        };
    };

    // Start with JSON that has unknown fields
    const input =
        \\{"name":"app","foo":"bar","count":123}
    ;

    // Decode
    const decoded = try unmarshal(Config, std.testing.allocator, input);
    defer {
        std.testing.allocator.free(decoded.name);
        for (decoded.extra) |m| {
            std.testing.allocator.free(m.k);
            freeClonedValue(std.testing.allocator, m.v);
        }
        std.testing.allocator.free(decoded.extra);
    }

    // Re-encode
    const encoded = try json_mod.encode(std.testing.allocator, decoded, .{});
    defer std.testing.allocator.free(encoded);

    // Should have all the original fields
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"name\":\"app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"foo\":\"bar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"count\":123") != null);
}

test "unmarshal NaN with allow_nan_infinity" {
    const Data = struct { value: f64 };

    // Create a Value with "NaN" string
    var members = [_]json.Member{.{ .k = "value", .v = .{ .str = "NaN" } }};
    const result = try fromValueWithOptions(Data, std.testing.allocator, json.Value{
        .obj = &members,
    }, .{ .allow_nan_infinity = true });

    try std.testing.expect(std.math.isNan(result.value));
}

test "unmarshal Infinity with allow_nan_infinity" {
    const Data = struct { pos_inf: f64, neg_inf: f64 };

    var members = [_]json.Member{
        .{ .k = "pos_inf", .v = .{ .str = "Infinity" } },
        .{ .k = "neg_inf", .v = .{ .str = "-Infinity" } },
    };
    const result = try fromValueWithOptions(Data, std.testing.allocator, json.Value{
        .obj = &members,
    }, .{ .allow_nan_infinity = true });

    try std.testing.expect(std.math.isPositiveInf(result.pos_inf));
    try std.testing.expect(std.math.isNegativeInf(result.neg_inf));
}

test "NaN/Infinity round-trip" {
    const json_mod = @import("json.zig");

    const Data = struct { nan: f64, inf: f64, neg_inf: f64 };

    const original = Data{
        .nan = std.math.nan(f64),
        .inf = std.math.inf(f64),
        .neg_inf = -std.math.inf(f64),
    };

    // Encode with allow_nan_infinity
    const encoded = try json_mod.encode(std.testing.allocator, original, .{ .allow_nan_infinity = true });
    defer std.testing.allocator.free(encoded);

    // Parse and unmarshal with allow_nan_infinity
    var err = json.ParseError.init();
    var doc = try json.parse(std.testing.allocator, encoded, .{}, &err);
    defer doc.deinit();

    const decoded = try fromValueWithOptions(Data, std.testing.allocator, doc.root, .{ .allow_nan_infinity = true });

    try std.testing.expect(std.math.isNan(decoded.nan));
    try std.testing.expect(std.math.isPositiveInf(decoded.inf));
    try std.testing.expect(std.math.isNegativeInf(decoded.neg_inf));
}

test "unmarshal with case-insensitive field matching" {
    const Data = struct { firstName: []const u8, lastName: []const u8 };

    // JSON with different casing
    var members = [_]json.Member{
        .{ .k = "FIRSTNAME", .v = .{ .str = "John" } },
        .{ .k = "lastname", .v = .{ .str = "Doe" } },
    };
    const result = try fromValueWithOptions(Data, std.testing.allocator, json.Value{
        .obj = &members,
    }, .{ .match_case_insensitive = true });
    defer {
        std.testing.allocator.free(result.firstName);
        std.testing.allocator.free(result.lastName);
    }

    try std.testing.expectEqualStrings("John", result.firstName);
    try std.testing.expectEqualStrings("Doe", result.lastName);
}

test "unmarshal case-sensitive by default" {
    const Data = struct { name: []const u8, value: i32 = 0 };

    // JSON with different casing should fail to match (missing field error)
    var members = [_]json.Member{
        .{ .k = "NAME", .v = .{ .str = "test" } },
    };
    const result = fromValueWithOptions(Data, std.testing.allocator, json.Value{
        .obj = &members,
    }, .{ .match_case_insensitive = false });

    // Should fail due to missing required field 'name'
    try std.testing.expectError(error.MissingField, result);
}

test "case-insensitive matching with json_config custom names" {
    const Person = struct {
        first_name: []const u8,
        last_name: []const u8,

        pub const json_config = .{
            .first_name = FieldConfig{ .name = "firstName" },
            .last_name = FieldConfig{ .name = "lastName" },
        };
    };

    // JSON with mixed casing of the custom names
    var members = [_]json.Member{
        .{ .k = "FIRSTNAME", .v = .{ .str = "Alice" } },
        .{ .k = "LastName", .v = .{ .str = "Smith" } },
    };
    const result = try fromValueWithOptions(Person, std.testing.allocator, json.Value{
        .obj = &members,
    }, .{ .match_case_insensitive = true });
    defer {
        std.testing.allocator.free(result.first_name);
        std.testing.allocator.free(result.last_name);
    }

    try std.testing.expectEqualStrings("Alice", result.first_name);
    try std.testing.expectEqualStrings("Smith", result.last_name);
}

test "unmarshal with StringHashMap unknown capture" {
    const Config = struct {
        name: []const u8,
        extra: std.StringHashMap(Value),

        pub const json_config = .{
            .extra = FieldConfig{ .unknown = true },
        };
    };

    const input =
        \\{"name":"app","foo":"bar","count":42}
    ;

    var err = json.ParseError.init();
    var doc = try json.parse(std.testing.allocator, input, .{}, &err);
    defer doc.deinit();

    const result = try fromValueWithOptions(Config, std.testing.allocator, doc.root, .{});
    defer {
        std.testing.allocator.free(result.name);
        // Need to free the cloned values in the map
        var it = result.extra.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            freeClonedValue(std.testing.allocator, entry.value_ptr.*);
        }
        var extra_copy = result.extra;
        extra_copy.deinit();
    }

    try std.testing.expectEqualStrings("app", result.name);
    try std.testing.expect(result.extra.count() == 2);
    try std.testing.expect(result.extra.get("foo") != null);
    try std.testing.expect(result.extra.get("count") != null);
}
