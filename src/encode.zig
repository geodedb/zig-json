// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! JSON Encoder
//!
//! Encodes arbitrary Zig types to JSON with comptime type reflection.
//! Supports all primitive types, structs, enums, unions, optionals, and collections.
//!
//! Features:
//! - Comptime type introspection for automatic serialization
//! - Writer-based streaming API
//! - Pretty-print formatting with configurable indentation
//! - toValue() conversion for building JSON Value trees
//! - Struct field tags via json_config for custom field names and behavior
//! - Custom marshaler interface via jsonMarshal method

const std = @import("std");
const json = @import("json.zig");
const unicode = @import("unicode.zig");
const number_mod = @import("number.zig");

const Value = json.Value;
const Member = json.Member;
const Number = json.Number;

/// Free memory allocated for a Value tree
/// Used to clean up Values returned by custom marshalers
fn freeValue(allocator: std.mem.Allocator, value: Value) void {
    switch (value) {
        .null, .bool => {},
        .num => |n| {
            // Free lexeme and digits (digits often points into lexeme)
            if (n.lexeme.ptr != n.digits.ptr) {
                allocator.free(n.digits);
            }
            allocator.free(n.lexeme);
        },
        .str => |s| allocator.free(s),
        .arr => |arr| {
            for (arr) |item| {
                freeValue(allocator, item);
            }
            allocator.free(arr);
        },
        .obj => |obj| {
            for (obj) |member| {
                allocator.free(member.k);
                freeValue(allocator, member.v);
            }
            allocator.free(obj);
        },
    }
}

/// Binary encoding format for []u8 fields
pub const BinaryFormat = enum {
    /// UTF-8 string (current default behavior)
    utf8,
    /// RFC 4648 standard Base64
    base64,
    /// RFC 4648 URL-safe Base64
    base64url,
    /// Lowercase hexadecimal
    hex,
    /// Uppercase hexadecimal
    hex_upper,
    /// RFC 4648 Base32
    base32,
};

/// Field configuration for struct serialization
/// Used in `pub const json_config` declarations within structs
pub const FieldConfig = struct {
    /// Custom JSON key name (null = use field name)
    name: ?[]const u8 = null,
    /// Skip this field entirely (like "-" in Go)
    skip: bool = false,
    /// Omit field if value is null/zero/empty
    omitempty: bool = false,
    /// Encode numbers as JSON strings
    stringify: bool = false,
    /// Binary encoding format for []u8 fields
    binary_format: ?BinaryFormat = null,
    /// Flatten this struct's fields into parent object
    @"inline": bool = false,
    /// Capture unknown JSON members into this field
    /// Field type must be []json.Member or ?[]json.Member
    unknown: bool = false,
};

/// Encoding options
pub const EncodeOptions = struct {
    /// Pretty print with indentation (null = minified)
    indent: ?[]const u8 = null,
    /// Emit null for optional fields that are null (otherwise skip them)
    emit_null_optional_fields: bool = false,
    /// Escape non-ASCII characters as \uXXXX
    escape_non_ascii: bool = false,
    /// Escape '/' as '\/'
    escape_slash: bool = false,
    /// Allocator for custom marshalers (optional, required only if using jsonMarshal)
    allocator: ?std.mem.Allocator = null,
    /// Sort object keys alphabetically for deterministic output
    deterministic: bool = false,
    /// Encode all numbers as JSON strings (global setting)
    stringify_numbers: bool = false,
    /// Default binary encoding format for []u8 (overridable per-field)
    default_binary_format: BinaryFormat = .utf8,
    /// Encode NaN and Infinity as strings ("NaN", "Infinity", "-Infinity") instead of null
    allow_nan_infinity: bool = false,
    /// Encode nil/empty slices as null instead of []
    format_nil_slice_as_null: bool = false,
    /// Use std.fmt.Formatter (format method) for types that have it
    /// When enabled, types with a format() method will be encoded as JSON strings
    use_fmt_formatter: bool = false,
};

/// Default options for minified output
pub const minified: EncodeOptions = .{};

/// Pretty-print with 2-space indentation
pub const pretty_2: EncodeOptions = .{ .indent = "  " };

/// Pretty-print with 4-space indentation
pub const pretty_4: EncodeOptions = .{ .indent = "    " };

/// Pretty-print with tab indentation
pub const pretty_tab: EncodeOptions = .{ .indent = "\t" };

/// Encode any Zig value to a JSON string
pub fn encode(allocator: std.mem.Allocator, value: anytype, options: EncodeOptions) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try encodeToWriter(&aw.writer, value, options);
    return aw.toOwnedSlice();
}

/// Encode any Zig value to a writer
pub fn encodeToWriter(writer: anytype, value: anytype, options: EncodeOptions) !void {
    try encodeValue(writer, value, options, 0);
}

/// Convert any Zig value to a json.Value tree
pub fn toValue(allocator: std.mem.Allocator, value: anytype, options: EncodeOptions) !Value {
    return toValueInternal(allocator, value, options);
}

// ============================================================================
// Internal encoding implementation
// ============================================================================

/// Check if a type has a custom jsonMarshal method
pub fn hasJsonMarshal(comptime T: type) bool {
    const info = @typeInfo(T);
    return switch (info) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(T, "jsonMarshal"),
        else => false,
    };
}

/// Check if a type has a custom jsonUnmarshal method
pub fn hasJsonUnmarshal(comptime T: type) bool {
    const info = @typeInfo(T);
    return switch (info) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(T, "jsonUnmarshal"),
        else => false,
    };
}

/// Check if a type has a std.fmt.Formatter compatible format() method
pub fn hasFmtFormatter(comptime T: type) bool {
    const info = @typeInfo(T);
    return switch (info) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(T, "format"),
        else => false,
    };
}

/// Check if a value is "empty" for omitempty purposes
fn isEmptyValue(value: anytype) bool {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    return switch (info) {
        .optional => value == null,
        .pointer => |ptr| switch (ptr.size) {
            .slice => value.len == 0,
            else => false,
        },
        .int, .comptime_int => value == 0,
        .float, .comptime_float => value == 0.0,
        .bool => !value,
        .array => |arr| arr.len == 0,
        else => false,
    };
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

fn encodeValue(writer: anytype, value: anytype, options: EncodeOptions, depth: usize) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    // Check for custom marshaler first (before any other type handling)
    // Custom marshaler requires an allocator in EncodeOptions
    if (comptime hasJsonMarshal(T)) {
        if (options.allocator) |alloc| {
            const result = try value.jsonMarshal(alloc);
            defer freeValue(alloc, result);
            try encodeJsonValue(writer, result, options, depth);
            return;
        }
        // If no allocator provided, fall through to default encoding
    }

    // Check for std.fmt.Formatter support (format method)
    // Must have allocator to build the string, and must not have jsonMarshal (which takes priority)
    if (comptime hasFmtFormatter(T) and !hasJsonMarshal(T)) {
        if (options.use_fmt_formatter) {
            try encodeFmtFormatter(writer, value, options);
            return;
        }
    }

    switch (info) {
        .null => try writer.writeAll("null"),
        .void => try writer.writeAll("null"),
        .bool => try writer.writeAll(if (value) "true" else "false"),

        .int, .comptime_int => try encodeInt(writer, value, options.stringify_numbers),
        .float, .comptime_float => try encodeFloat(writer, value, options.stringify_numbers, options.allow_nan_infinity),

        .optional => {
            if (value) |v| {
                try encodeValue(writer, v, options, depth);
            } else {
                try writer.writeAll("null");
            }
        },

        .@"enum" => try encodeEnum(writer, value),

        .@"union" => {
            // Special case: json.Value should be encoded as JSON directly
            if (T == Value) {
                try encodeJsonValue(writer, value, options, depth);
            } else {
                try encodeUnion(writer, value, options, depth);
            }
        },

        .@"struct" => |s| {
            if (s.is_tuple) {
                try encodeTuple(writer, value, options, depth);
            } else {
                try encodeStruct(writer, value, options, depth);
            }
        },

        .array => |arr| {
            if (arr.child == u8) {
                try encodeString(writer, &value, options);
            } else {
                try encodeArray(writer, &value, options, depth);
            }
        },

        .pointer => |ptr| {
            switch (ptr.size) {
                .one => {
                    // Dereference single-item pointer
                    try encodeValue(writer, value.*, options, depth);
                },
                .slice => {
                    // Check for nil/empty slice -> null conversion
                    if (value.len == 0 and options.format_nil_slice_as_null) {
                        try writer.writeAll("null");
                    } else if (ptr.child == u8) {
                        try encodeBinary(writer, value, options.default_binary_format, options);
                    } else {
                        try encodeArray(writer, value, options, depth);
                    }
                },
                .many, .c => {
                    // Can't determine length, encode as null
                    try writer.writeAll("null");
                },
            }
        },

        .error_set => try encodeString(writer, @errorName(value), options),

        .@"fn", .@"opaque", .frame, .@"anyframe", .noreturn => {
            try writer.writeAll("null");
        },

        .type => try encodeString(writer, @typeName(value), options),

        .undefined => try writer.writeAll("null"),

        else => @compileError("Cannot encode type: " ++ @typeName(T)),
    }
}

/// Encode binary data using specified format
fn encodeBinary(writer: anytype, data: []const u8, format: BinaryFormat, options: EncodeOptions) !void {
    try writer.writeByte('"');
    switch (format) {
        .utf8 => try encodeStringContents(writer, data, options),
        .base64 => {
            const encoder = std.base64.standard;
            // Encode in chunks to avoid allocating large buffers
            var i: usize = 0;
            while (i < data.len) {
                const chunk_end = @min(i + 48, data.len); // 48 bytes -> 64 base64 chars
                const chunk = data[i..chunk_end];
                var buf: [64]u8 = undefined;
                const encoded = encoder.Encoder.encode(&buf, chunk);
                try writer.writeAll(encoded);
                i = chunk_end;
            }
        },
        .base64url => {
            const encoder = std.base64.url_safe_no_pad;
            var i: usize = 0;
            while (i < data.len) {
                const chunk_end = @min(i + 48, data.len);
                const chunk = data[i..chunk_end];
                var buf: [64]u8 = undefined;
                const encoded = encoder.Encoder.encode(&buf, chunk);
                try writer.writeAll(encoded);
                i = chunk_end;
            }
        },
        .hex => {
            for (data) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
        },
        .hex_upper => {
            for (data) |byte| {
                try writer.print("{X:0>2}", .{byte});
            }
        },
        .base32 => {
            // Standard RFC 4648 Base32
            const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
            var i: usize = 0;
            while (i < data.len) {
                const remaining = data.len - i;
                // Process 5 bytes at a time (produces 8 base32 chars)
                if (remaining >= 5) {
                    const b0 = data[i];
                    const b1 = data[i + 1];
                    const b2 = data[i + 2];
                    const b3 = data[i + 3];
                    const b4 = data[i + 4];
                    try writer.writeByte(alphabet[b0 >> 3]);
                    try writer.writeByte(alphabet[((b0 & 0x07) << 2) | (b1 >> 6)]);
                    try writer.writeByte(alphabet[(b1 >> 1) & 0x1F]);
                    try writer.writeByte(alphabet[((b1 & 0x01) << 4) | (b2 >> 4)]);
                    try writer.writeByte(alphabet[((b2 & 0x0F) << 1) | (b3 >> 7)]);
                    try writer.writeByte(alphabet[(b3 >> 2) & 0x1F]);
                    try writer.writeByte(alphabet[((b3 & 0x03) << 3) | (b4 >> 5)]);
                    try writer.writeByte(alphabet[b4 & 0x1F]);
                    i += 5;
                } else {
                    // Handle remaining bytes with padding
                    var buf: [5]u8 = .{ 0, 0, 0, 0, 0 };
                    @memcpy(buf[0..remaining], data[i..]);

                    try writer.writeByte(alphabet[buf[0] >> 3]);
                    try writer.writeByte(alphabet[((buf[0] & 0x07) << 2) | (buf[1] >> 6)]);
                    if (remaining > 1) {
                        try writer.writeByte(alphabet[(buf[1] >> 1) & 0x1F]);
                        try writer.writeByte(alphabet[((buf[1] & 0x01) << 4) | (buf[2] >> 4)]);
                    } else {
                        try writer.writeAll("======");
                        break;
                    }
                    if (remaining > 2) {
                        try writer.writeByte(alphabet[((buf[2] & 0x0F) << 1) | (buf[3] >> 7)]);
                    } else {
                        try writer.writeAll("====");
                        break;
                    }
                    if (remaining > 3) {
                        try writer.writeByte(alphabet[(buf[3] >> 2) & 0x1F]);
                        try writer.writeByte(alphabet[((buf[3] & 0x03) << 3) | (buf[4] >> 5)]);
                    } else {
                        try writer.writeAll("===");
                        break;
                    }
                    try writer.writeByte(alphabet[buf[4] & 0x1F]);
                    break;
                }
            }
        },
    }
    try writer.writeByte('"');
}

/// Encode string contents (without surrounding quotes)
fn encodeStringContents(writer: anytype, s: []const u8, options: EncodeOptions) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];

        if (c < 0x20) {
            // Control characters
            switch (c) {
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                0x08 => try writer.writeAll("\\b"), // backspace
                0x0C => try writer.writeAll("\\f"), // form feed
                else => try writer.print("\\u{X:0>4}", .{c}),
            }
            i += 1;
        } else if (c == '"') {
            try writer.writeAll("\\\"");
            i += 1;
        } else if (c == '\\') {
            try writer.writeAll("\\\\");
            i += 1;
        } else if (c == '/' and options.escape_slash) {
            try writer.writeAll("\\/");
            i += 1;
        } else if (c >= 0x80 and options.escape_non_ascii) {
            // UTF-8 multi-byte: decode and emit \uXXXX
            const len = std.unicode.utf8ByteSequenceLength(c) catch {
                // Invalid UTF-8, emit replacement char
                try writer.writeAll("\\uFFFD");
                i += 1;
                continue;
            };
            if (i + len > s.len) {
                try writer.writeAll("\\uFFFD");
                i += 1;
                continue;
            }
            const cp = std.unicode.utf8Decode(s[i..][0..len]) catch {
                try writer.writeAll("\\uFFFD");
                i += 1;
                continue;
            };

            if (cp <= 0xFFFF) {
                try writer.print("\\u{X:0>4}", .{cp});
            } else {
                // Surrogate pair for characters > U+FFFF
                const adj = cp - 0x10000;
                const high: u16 = @intCast(0xD800 + (adj >> 10));
                const low: u16 = @intCast(0xDC00 + (adj & 0x3FF));
                try writer.print("\\u{X:0>4}\\u{X:0>4}", .{ high, low });
            }
            i += len;
        } else {
            // Regular character, output as-is
            try writer.writeByte(c);
            i += 1;
        }
    }
}

/// Encode a value using its std.fmt.Formatter (format method) as a JSON string
fn encodeFmtFormatter(writer: anytype, value: anytype, options: EncodeOptions) !void {
    // Write opening quote
    try writer.writeByte('"');

    // Use a buffer to capture format output, then escape it
    var buf: [4096]u8 = undefined;
    var fmt_writer: std.Io.Writer = .fixed(&buf);
    value.format(&fmt_writer) catch {};
    const formatted = fmt_writer.buffered();

    // Escape and write the formatted output
    for (formatted) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            '/' => {
                if (options.escape_slash) {
                    try writer.writeAll("\\/");
                } else {
                    try writer.writeByte(c);
                }
            },
            else => {
                if (c < 0x20) {
                    try writer.writeAll("\\u00");
                    const hex = "0123456789ABCDEF";
                    try writer.writeByte(hex[(c >> 4) & 0xF]);
                    try writer.writeByte(hex[c & 0xF]);
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }

    // Write closing quote
    try writer.writeByte('"');
}

fn encodeInt(writer: anytype, value: anytype, stringify: bool) !void {
    if (stringify) {
        try writer.writeByte('"');
        try writer.print("{d}", .{value});
        try writer.writeByte('"');
    } else {
        try writer.print("{d}", .{value});
    }
}

fn encodeFloat(writer: anytype, value: anytype, stringify: bool, allow_nan_infinity: bool) !void {
    const T = @TypeOf(value);

    // Handle special float values
    if (@typeInfo(T) == .float or @typeInfo(T) == .comptime_float) {
        const f: f64 = if (@typeInfo(T) == .comptime_float) value else @floatCast(value);

        if (std.math.isNan(f)) {
            if (allow_nan_infinity) {
                try writer.writeAll("\"NaN\"");
            } else {
                try writer.writeAll("null");
            }
            return;
        }
        if (std.math.isInf(f)) {
            if (allow_nan_infinity) {
                if (f < 0) {
                    try writer.writeAll("\"-Infinity\"");
                } else {
                    try writer.writeAll("\"Infinity\"");
                }
            } else {
                try writer.writeAll("null");
            }
            return;
        }
    }

    // Use Zig's float formatting
    if (stringify) {
        try writer.writeByte('"');
        try writer.print("{d}", .{value});
        try writer.writeByte('"');
    } else {
        try writer.print("{d}", .{value});
    }
}

fn encodeString(writer: anytype, s: []const u8, options: EncodeOptions) !void {
    try writer.writeByte('"');

    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];

        if (c == '"') {
            try writer.writeAll("\\\"");
            i += 1;
        } else if (c == '\\') {
            try writer.writeAll("\\\\");
            i += 1;
        } else if (c == '\n') {
            try writer.writeAll("\\n");
            i += 1;
        } else if (c == '\r') {
            try writer.writeAll("\\r");
            i += 1;
        } else if (c == '\t') {
            try writer.writeAll("\\t");
            i += 1;
        } else if (c == 0x08) {
            try writer.writeAll("\\b");
            i += 1;
        } else if (c == 0x0C) {
            try writer.writeAll("\\f");
            i += 1;
        } else if (c == '/' and options.escape_slash) {
            try writer.writeAll("\\/");
            i += 1;
        } else if (c < 0x20) {
            // Control characters
            try writer.writeAll("\\u00");
            const hex = "0123456789ABCDEF";
            try writer.writeByte(hex[(c >> 4) & 0xF]);
            try writer.writeByte(hex[c & 0xF]);
            i += 1;
        } else if (c >= 0x80 and options.escape_non_ascii) {
            // Non-ASCII: escape as \uXXXX
            const seq_len = unicode.utf8SeqLen(c) catch {
                try writer.writeByte(c);
                i += 1;
                continue;
            };

            if (i + seq_len > s.len) {
                try writer.writeByte(c);
                i += 1;
                continue;
            }

            const seq = s[i..][0..seq_len];
            const cp = unicode.decodeUtf8(seq) catch {
                try writer.writeByte(c);
                i += 1;
                continue;
            };

            if (cp <= 0xFFFF) {
                try emitUnicodeEscape(writer, @intCast(cp));
            } else {
                // Surrogate pair for characters > U+FFFF
                const hi: u16 = @intCast(((cp - 0x10000) >> 10) + 0xD800);
                const lo: u16 = @intCast(((cp - 0x10000) & 0x3FF) + 0xDC00);
                try emitUnicodeEscape(writer, hi);
                try emitUnicodeEscape(writer, lo);
            }
            i += seq_len;
        } else {
            try writer.writeByte(c);
            i += 1;
        }
    }

    try writer.writeByte('"');
}

fn emitUnicodeEscape(writer: anytype, cp: u16) !void {
    const hex = "0123456789ABCDEF";
    try writer.writeAll("\\u");
    try writer.writeByte(hex[(cp >> 12) & 0xF]);
    try writer.writeByte(hex[(cp >> 8) & 0xF]);
    try writer.writeByte(hex[(cp >> 4) & 0xF]);
    try writer.writeByte(hex[cp & 0xF]);
}

fn encodeEnum(writer: anytype, value: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T).@"enum";

    if (info.is_exhaustive) {
        try encodeString(writer, @tagName(value), .{});
    } else {
        // Non-exhaustive enum - try to get tag name, fall back to int
        if (std.enums.tagName(T, value)) |name| {
            try encodeString(writer, name, .{});
        } else {
            try encodeInt(writer, @intFromEnum(value));
        }
    }
}

fn encodeUnion(writer: anytype, value: anytype, options: EncodeOptions, depth: usize) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T).@"union";

    if (info.tag_type) |_| {
        // Tagged union - encode as object { "tag": payload }
        try writer.writeByte('{');
        try writeNewline(writer, options, depth + 1);

        const tag_name = @tagName(value);
        try encodeString(writer, tag_name, options);
        try writer.writeByte(':');
        if (options.indent != null) try writer.writeByte(' ');

        inline for (info.fields) |field| {
            if (std.mem.eql(u8, field.name, tag_name)) {
                if (field.type == void) {
                    try writer.writeAll("null");
                } else {
                    try encodeValue(writer, @field(value, field.name), options, depth + 1);
                }
                break;
            }
        }

        try writeNewline(writer, options, depth);
        try writer.writeByte('}');
    } else {
        // Untagged union - can't safely encode
        try writer.writeAll("null");
    }
}

/// Get sorted field indices for deterministic output (comptime)
fn getSortedFieldIndices(comptime T: type, comptime info: std.builtin.Type.Struct) [info.fields.len]usize {
    comptime {
        var indices: [info.fields.len]usize = undefined;
        for (0..info.fields.len) |i| {
            indices[i] = i;
        }
        // Bubble sort by JSON name
        for (0..info.fields.len) |i| {
            for (i + 1..info.fields.len) |j| {
                const name_i = getJsonName(T, info.fields[indices[i]].name);
                const name_j = getJsonName(T, info.fields[indices[j]].name);
                if (std.mem.order(u8, name_i, name_j) == .gt) {
                    const tmp = indices[i];
                    indices[i] = indices[j];
                    indices[j] = tmp;
                }
            }
        }
        return indices;
    }
}

/// Get JSON name for a field (from config or field name)
fn getJsonName(comptime T: type, comptime field_name: []const u8) []const u8 {
    const cfg = comptime getFieldConfig(T, field_name);
    return cfg.name orelse field_name;
}

fn encodeStruct(writer: anytype, value: anytype, options: EncodeOptions, depth: usize) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T).@"struct";

    // Special case: if the struct is json.Value, encode it directly
    if (T == Value) {
        try encodeJsonValue(writer, value, options, depth);
        return;
    }

    // Special case: if the struct is json.Number, encode the lexeme
    if (T == Number) {
        if (options.stringify_numbers) {
            try writer.writeByte('"');
            try writer.writeAll(value.lexeme);
            try writer.writeByte('"');
        } else {
            try writer.writeAll(value.lexeme);
        }
        return;
    }

    try writer.writeByte('{');

    var first = true;

    // For deterministic output, iterate fields in alphabetically sorted order
    // For normal output, iterate in declaration order
    // Both paths use inline for to unroll at comptime
    if (options.deterministic) {
        const sorted_indices = comptime getSortedFieldIndices(T, info);
        inline for (sorted_indices) |field_idx| {
            try encodeStructField(writer, value, info.fields[field_idx], options, depth, &first);
        }
    } else {
        inline for (info.fields) |field| {
            try encodeStructField(writer, value, field, options, depth, &first);
        }
    }

    if (!first) {
        try writeNewline(writer, options, depth);
    }
    try writer.writeByte('}');
}

/// Helper to encode a single struct field
fn encodeStructField(
    writer: anytype,
    value: anytype,
    comptime field: std.builtin.Type.StructField,
    options: EncodeOptions,
    depth: usize,
    first: *bool,
) !void {
    const T = @TypeOf(value);

    // Skip fields that start with underscore (private)
    if (field.name.len > 0 and field.name[0] == '_') return;

    // Get field configuration from json_config if defined
    const field_cfg = comptime getFieldConfig(T, field.name);

    // Skip if field is configured to be skipped
    if (field_cfg.skip) return;

    const field_value = @field(value, field.name);

    // Handle inline fields - flatten nested struct's fields into parent
    if (field_cfg.@"inline") {
        const FieldType = field.type;
        const field_type_info = @typeInfo(FieldType);
        // Handle optional inline fields
        if (field_type_info == .optional) {
            if (field_value) |actual_value| {
                try encodeInlineStructFields(writer, actual_value, options, depth, first);
            }
            // If null, skip entirely
        } else if (field_type_info == .@"struct") {
            try encodeInlineStructFields(writer, field_value, options, depth, first);
        }
        // Non-struct inline fields are silently ignored (could add compile error)
        return;
    }

    // Handle unknown member capture - emit each captured member as a field
    if (field_cfg.unknown) {
        // Try []Member first
        if (getMemberSlice(field.type, field_value)) |members| {
            for (members) |m| {
                if (!first.*) try writer.writeByte(',');
                first.* = false;
                try writeNewline(writer, options, depth + 1);
                try encodeString(writer, m.k, options);
                try writer.writeByte(':');
                if (options.indent != null) try writer.writeByte(' ');
                try encodeJsonValue(writer, m.v, options, depth + 1);
            }
        } else if (getStringHashMap(field.type, field_value)) |map| {
            // Iterate over StringHashMap(Value)
            var iter = map.iterator();
            while (iter.next()) |entry| {
                if (!first.*) try writer.writeByte(',');
                first.* = false;
                try writeNewline(writer, options, depth + 1);
                try encodeString(writer, entry.key_ptr.*, options);
                try writer.writeByte(':');
                if (options.indent != null) try writer.writeByte(' ');
                try encodeJsonValue(writer, entry.value_ptr.*, options, depth + 1);
            }
        }
        return;
    }

    // Determine if we should skip this field
    const skip = blk: {
        // Check omitempty
        if (field_cfg.omitempty and isEmptyValue(field_value)) {
            break :blk true;
        }
        // Check optional null (if not emit_null_optional_fields)
        if (@typeInfo(field.type) == .optional) {
            if (field_value == null and !options.emit_null_optional_fields) {
                break :blk true;
            }
        }
        break :blk false;
    };

    if (!skip) {
        if (!first.*) try writer.writeByte(',');
        first.* = false;

        try writeNewline(writer, options, depth + 1);

        // Use custom name if configured, otherwise use field name
        const json_name = field_cfg.name orelse field.name;
        try encodeString(writer, json_name, options);
        try writer.writeByte(':');
        if (options.indent != null) try writer.writeByte(' ');

        // Handle stringify option for numbers
        if (field_cfg.stringify) {
            try encodeStringified(writer, field_value, options);
        } else if (field_cfg.binary_format) |bin_fmt| {
            // Handle binary format for []u8 fields
            const field_info = @typeInfo(field.type);
            if (field_info == .pointer and field_info.pointer.size == .slice and field_info.pointer.child == u8) {
                try encodeBinary(writer, field_value, bin_fmt, options);
            } else {
                // Not a []u8 slice, encode normally
                try encodeValue(writer, field_value, options, depth + 1);
            }
        } else {
            try encodeValue(writer, field_value, options, depth + 1);
        }
    }
}

/// Helper to encode struct fields inline (without braces) for flatten support
fn encodeInlineStructFields(
    writer: anytype,
    value: anytype,
    options: EncodeOptions,
    depth: usize,
    first: *bool,
) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T).@"struct";

    // For deterministic output, iterate fields in alphabetically sorted order
    if (options.deterministic) {
        const sorted_indices = comptime getSortedFieldIndices(T, info);
        inline for (sorted_indices) |field_idx| {
            try encodeStructField(writer, value, info.fields[field_idx], options, depth, first);
        }
    } else {
        inline for (info.fields) |nested_field| {
            try encodeStructField(writer, value, nested_field, options, depth, first);
        }
    }
}

/// Extract []Member from either []Member or ?[]Member
fn getMemberSlice(comptime T: type, value: T) ?[]const Member {
    const info = @typeInfo(T);
    if (info == .optional) {
        if (value) |v| {
            return getMemberSlice(@TypeOf(v), v);
        }
        return null;
    } else if (info == .pointer and info.pointer.size == .slice) {
        if (info.pointer.child == Member) {
            return value;
        }
    }
    return null;
}

/// Check if a type is StringHashMap(Value) and return pointer to it
fn getStringHashMap(comptime T: type, value: anytype) ?*const std.StringHashMap(Value) {
    const info = @typeInfo(T);
    if (info == .optional) {
        if (value) |*v| {
            return getStringHashMap(@TypeOf(v.*), v.*);
        }
        return null;
    } else if (info == .@"struct") {
        // Check if it's a StringHashMap by checking for characteristic types
        if (@hasDecl(T, "KV") and @hasDecl(T, "iterator")) {
            const KV = T.KV;
            const kv_info = @typeInfo(KV);
            if (kv_info == .@"struct") {
                var has_string_key = false;
                var has_value_value = false;
                inline for (kv_info.@"struct".fields) |field| {
                    if (std.mem.eql(u8, field.name, "key") and field.type == []const u8) {
                        has_string_key = true;
                    } else if (std.mem.eql(u8, field.name, "value") and field.type == Value) {
                        has_value_value = true;
                    }
                }
                if (has_string_key and has_value_value) {
                    return &value;
                }
            }
        }
    }
    return null;
}

/// Encode a value as a stringified number (for stringify field option)
fn encodeStringified(writer: anytype, value: anytype, options: EncodeOptions) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    switch (info) {
        // Per-field stringify always stringifies, regardless of global option
        .int, .comptime_int => try encodeInt(writer, value, true),
        .float, .comptime_float => try encodeFloat(writer, value, true, options.allow_nan_infinity),
        .optional => {
            if (value) |v| {
                try encodeStringified(writer, v, options);
            } else {
                try writer.writeAll("null");
            }
        },
        else => {
            // For non-numeric types, just encode normally
            try encodeValue(writer, value, options, 0);
        },
    }
}

fn encodeTuple(writer: anytype, value: anytype, options: EncodeOptions, depth: usize) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T).@"struct";

    try writer.writeByte('[');

    inline for (info.fields, 0..) |field, i| {
        if (i > 0) try writer.writeByte(',');
        try writeNewline(writer, options, depth + 1);
        try encodeValue(writer, @field(value, field.name), options, depth + 1);
    }

    if (info.fields.len > 0) {
        try writeNewline(writer, options, depth);
    }
    try writer.writeByte(']');
}

fn encodeArray(writer: anytype, arr: anytype, options: EncodeOptions, depth: usize) anyerror!void {
    try writer.writeByte('[');

    for (arr, 0..) |item, i| {
        if (i > 0) try writer.writeByte(',');
        try writeNewline(writer, options, depth + 1);
        try encodeValue(writer, item, options, depth + 1);
    }

    if (arr.len > 0) {
        try writeNewline(writer, options, depth);
    }
    try writer.writeByte(']');
}

fn encodeJsonValue(writer: anytype, v: Value, options: EncodeOptions, depth: usize) !void {
    switch (v) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .num => |n| {
            if (options.stringify_numbers) {
                try writer.writeByte('"');
                try writer.writeAll(n.lexeme);
                try writer.writeByte('"');
            } else {
                try writer.writeAll(n.lexeme);
            }
        },
        .str => |s| try encodeString(writer, s, options),
        .arr => |arr| {
            try writer.writeByte('[');
            for (arr, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try writeNewline(writer, options, depth + 1);
                try encodeJsonValue(writer, item, options, depth + 1);
            }
            if (arr.len > 0) {
                try writeNewline(writer, options, depth);
            }
            try writer.writeByte(']');
        },
        .obj => |obj| {
            try writer.writeByte('{');

            // For deterministic output, sort members by key
            if (options.deterministic and options.allocator != null and obj.len > 0) {
                const alloc = options.allocator.?;
                // Create sorted index array
                var indices = try alloc.alloc(usize, obj.len);
                defer alloc.free(indices);
                for (0..obj.len) |i| {
                    indices[i] = i;
                }
                // Sort indices by key
                std.mem.sort(usize, indices, obj, struct {
                    fn lessThan(ctx: []const Member, a: usize, b: usize) bool {
                        return std.mem.order(u8, ctx[a].k, ctx[b].k) == .lt;
                    }
                }.lessThan);
                // Output in sorted order
                for (indices, 0..) |idx, i| {
                    if (i > 0) try writer.writeByte(',');
                    try writeNewline(writer, options, depth + 1);
                    try encodeString(writer, obj[idx].k, options);
                    try writer.writeByte(':');
                    if (options.indent != null) try writer.writeByte(' ');
                    try encodeJsonValue(writer, obj[idx].v, options, depth + 1);
                }
            } else {
                // Original order
                for (obj, 0..) |m, i| {
                    if (i > 0) try writer.writeByte(',');
                    try writeNewline(writer, options, depth + 1);
                    try encodeString(writer, m.k, options);
                    try writer.writeByte(':');
                    if (options.indent != null) try writer.writeByte(' ');
                    try encodeJsonValue(writer, m.v, options, depth + 1);
                }
            }

            if (obj.len > 0) {
                try writeNewline(writer, options, depth);
            }
            try writer.writeByte('}');
        },
    }
}

fn writeNewline(writer: anytype, options: EncodeOptions, depth: usize) !void {
    if (options.indent) |indent| {
        try writer.writeByte('\n');
        for (0..depth) |_| {
            try writer.writeAll(indent);
        }
    }
}

// ============================================================================
// toValue implementation - converts Zig types to json.Value tree
// ============================================================================

fn toValueInternal(allocator: std.mem.Allocator, value: anytype, options: EncodeOptions) !Value {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    switch (info) {
        .null, .void, .undefined => return .null,
        .bool => return .{ .bool = value },

        .int, .comptime_int => {
            // Format integer as string lexeme
            var buf: [32]u8 = undefined;
            const lexeme_slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
            const lexeme = try allocator.dupe(u8, lexeme_slice);
            const digits = try normalizeDigits(allocator, lexeme);
            return .{ .num = .{
                .lexeme = lexeme,
                .sign = if (value < 0) -1 else 1,
                .digits = digits,
                .exp10 = 0,
            } };
        },

        .float, .comptime_float => {
            const f: f64 = if (@typeInfo(T) == .comptime_float) value else @floatCast(value);
            if (std.math.isNan(f)) {
                if (options.allow_nan_infinity) {
                    return .{ .str = try allocator.dupe(u8, "NaN") };
                }
                return .null;
            }
            if (std.math.isInf(f)) {
                if (options.allow_nan_infinity) {
                    if (f < 0) {
                        return .{ .str = try allocator.dupe(u8, "-Infinity") };
                    } else {
                        return .{ .str = try allocator.dupe(u8, "Infinity") };
                    }
                }
                return .null;
            }
            var buf: [32]u8 = undefined;
            const lexeme_slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
            const lexeme = try allocator.dupe(u8, lexeme_slice);
            const num = try number_mod.parseNumber(lexeme, allocator);
            return .{ .num = .{
                .lexeme = lexeme,
                .sign = num.sign,
                .digits = num.digits,
                .exp10 = num.exp10,
            } };
        },

        .optional => {
            if (value) |v| {
                return toValueInternal(allocator, v, options);
            } else {
                return .null;
            }
        },

        .@"enum" => {
            const name = @tagName(value);
            return .{ .str = try allocator.dupe(u8, name) };
        },

        .@"union" => |u| {
            if (u.tag_type) |_| {
                const tag_name = @tagName(value);
                var members = try allocator.alloc(Member, 1);
                members[0].k = try allocator.dupe(u8, tag_name);

                inline for (u.fields) |field| {
                    if (std.mem.eql(u8, field.name, tag_name)) {
                        if (field.type == void) {
                            members[0].v = .null;
                        } else {
                            members[0].v = try toValueInternal(allocator, @field(value, field.name), options);
                        }
                        break;
                    }
                }

                return .{ .obj = members };
            } else {
                return .null;
            }
        },

        .@"struct" => |s| {
            if (T == Value) {
                return value;
            }
            if (T == Number) {
                return .{ .num = value };
            }

            if (s.is_tuple) {
                var arr = try allocator.alloc(Value, s.fields.len);
                inline for (s.fields, 0..) |field, i| {
                    arr[i] = try toValueInternal(allocator, @field(value, field.name), options);
                }
                return .{ .arr = arr };
            } else {
                // Count non-null optional fields, accounting for inline fields
                var count: usize = 0;
                inline for (s.fields) |field| {
                    if (field.name.len > 0 and field.name[0] == '_') continue;
                    const field_cfg = comptime getFieldConfig(T, field.name);
                    if (field_cfg.skip) continue;

                    const fv = @field(value, field.name);

                    // Handle inline fields - count nested struct's fields
                    if (field_cfg.@"inline") {
                        const ft_info = @typeInfo(field.type);
                        if (ft_info == .optional) {
                            if (fv) |actual| {
                                count += countStructFields(@TypeOf(actual), actual, options);
                            }
                        } else if (ft_info == .@"struct") {
                            count += countStructFields(field.type, fv, options);
                        }
                        continue;
                    }

                    if (@typeInfo(field.type) == .optional) {
                        if (fv != null or options.emit_null_optional_fields) count += 1;
                    } else {
                        count += 1;
                    }
                }

                var members = try allocator.alloc(Member, count);
                var idx: usize = 0;
                inline for (s.fields) |field| {
                    if (field.name.len > 0 and field.name[0] == '_') continue;
                    const field_cfg = comptime getFieldConfig(T, field.name);
                    if (field_cfg.skip) continue;

                    const fv = @field(value, field.name);

                    // Handle inline fields - flatten nested struct's members
                    if (field_cfg.@"inline") {
                        const ft_info = @typeInfo(field.type);
                        if (ft_info == .optional) {
                            if (fv) |actual| {
                                idx = try appendStructMembers(allocator, members, idx, actual, options);
                            }
                        } else if (ft_info == .@"struct") {
                            idx = try appendStructMembers(allocator, members, idx, fv, options);
                        }
                        continue;
                    }

                    if (@typeInfo(field.type) == .optional) {
                        if (fv == null and !options.emit_null_optional_fields) continue;
                    }
                    const json_name = field_cfg.name orelse field.name;
                    members[idx].k = try allocator.dupe(u8, json_name);
                    members[idx].v = try toValueInternal(allocator, fv, options);
                    idx += 1;
                }
                return .{ .obj = members };
            }
        },

        .array => |arr| {
            if (arr.child == u8) {
                return .{ .str = try allocator.dupe(u8, &value) };
            } else {
                var vals = try allocator.alloc(Value, arr.len);
                for (&value, 0..) |item, i| {
                    vals[i] = try toValueInternal(allocator, item, options);
                }
                return .{ .arr = vals };
            }
        },

        .pointer => |ptr| {
            switch (ptr.size) {
                .one => return toValueInternal(allocator, value.*, options),
                .slice => {
                    // Check for nil/empty slice -> null conversion
                    if (value.len == 0 and options.format_nil_slice_as_null) {
                        return .null;
                    }
                    if (ptr.child == u8) {
                        return .{ .str = try allocator.dupe(u8, value) };
                    } else {
                        var vals = try allocator.alloc(Value, value.len);
                        for (value, 0..) |item, i| {
                            vals[i] = try toValueInternal(allocator, item, options);
                        }
                        return .{ .arr = vals };
                    }
                },
                else => return .null,
            }
        },

        .error_set => {
            return .{ .str = try allocator.dupe(u8, @errorName(value)) };
        },

        .type => {
            return .{ .str = try allocator.dupe(u8, @typeName(value)) };
        },

        else => return .null,
    }
}

/// Count the number of members a struct will produce (for inline field counting)
fn countStructFields(comptime T: type, value: T, options: EncodeOptions) usize {
    const s = @typeInfo(T).@"struct";
    var count: usize = 0;

    inline for (s.fields) |field| {
        if (field.name.len > 0 and field.name[0] == '_') continue;
        const field_cfg = comptime getFieldConfig(T, field.name);
        if (field_cfg.skip) continue;

        const fv = @field(value, field.name);

        // Handle nested inline fields recursively
        if (field_cfg.@"inline") {
            const ft_info = @typeInfo(field.type);
            if (ft_info == .optional) {
                if (fv) |actual| {
                    count += countStructFields(@TypeOf(actual), actual, options);
                }
            } else if (ft_info == .@"struct") {
                count += countStructFields(field.type, fv, options);
            }
            continue;
        }

        if (@typeInfo(field.type) == .optional) {
            if (fv != null or options.emit_null_optional_fields) count += 1;
        } else {
            count += 1;
        }
    }
    return count;
}

/// Append struct fields as members to the given slice (for inline field flattening)
fn appendStructMembers(
    allocator: std.mem.Allocator,
    members: []Member,
    start_idx: usize,
    value: anytype,
    options: EncodeOptions,
) !usize {
    const T = @TypeOf(value);
    const s = @typeInfo(T).@"struct";
    var idx = start_idx;

    inline for (s.fields) |field| {
        if (field.name.len > 0 and field.name[0] == '_') continue;
        const field_cfg = comptime getFieldConfig(T, field.name);
        if (field_cfg.skip) continue;

        const fv = @field(value, field.name);

        // Handle nested inline fields recursively
        if (field_cfg.@"inline") {
            const ft_info = @typeInfo(field.type);
            if (ft_info == .optional) {
                if (fv) |actual| {
                    idx = try appendStructMembers(allocator, members, idx, actual, options);
                }
            } else if (ft_info == .@"struct") {
                idx = try appendStructMembers(allocator, members, idx, fv, options);
            }
            continue;
        }

        if (@typeInfo(field.type) == .optional) {
            if (fv == null and !options.emit_null_optional_fields) continue;
        }

        const json_name = field_cfg.name orelse field.name;
        members[idx].k = try allocator.dupe(u8, json_name);
        members[idx].v = try toValueInternal(allocator, fv, options);
        idx += 1;
    }
    return idx;
}

fn normalizeDigits(allocator: std.mem.Allocator, lexeme: []const u8) ![]const u8 {
    var start: usize = 0;
    if (lexeme.len > 0 and lexeme[0] == '-') {
        start = 1;
    }
    // Strip leading zeros but keep at least one digit
    while (start < lexeme.len - 1 and lexeme[start] == '0') {
        start += 1;
    }
    return allocator.dupe(u8, lexeme[start..]);
}

// ============================================================================
// Tests
// ============================================================================

test "encode null" {
    const result = try encode(std.testing.allocator, null, .{});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("null", result);
}

test "encode bool" {
    const t = try encode(std.testing.allocator, true, .{});
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("true", t);

    const f = try encode(std.testing.allocator, false, .{});
    defer std.testing.allocator.free(f);
    try std.testing.expectEqualStrings("false", f);
}

test "encode integers" {
    const i = try encode(std.testing.allocator, @as(i32, 42), .{});
    defer std.testing.allocator.free(i);
    try std.testing.expectEqualStrings("42", i);

    const neg = try encode(std.testing.allocator, @as(i32, -123), .{});
    defer std.testing.allocator.free(neg);
    try std.testing.expectEqualStrings("-123", neg);

    const big = try encode(std.testing.allocator, @as(u64, 18446744073709551615), .{});
    defer std.testing.allocator.free(big);
    try std.testing.expectEqualStrings("18446744073709551615", big);
}

test "encode floats" {
    const f = try encode(std.testing.allocator, @as(f64, 3.14), .{});
    defer std.testing.allocator.free(f);
    try std.testing.expect(std.mem.startsWith(u8, f, "3.14"));

    const nan = try encode(std.testing.allocator, std.math.nan(f64), .{});
    defer std.testing.allocator.free(nan);
    try std.testing.expectEqualStrings("null", nan);

    const inf = try encode(std.testing.allocator, std.math.inf(f64), .{});
    defer std.testing.allocator.free(inf);
    try std.testing.expectEqualStrings("null", inf);
}

test "encode string" {
    const s = try encode(std.testing.allocator, "hello", .{});
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("\"hello\"", s);
}

test "encode string with escapes" {
    const s = try encode(std.testing.allocator, "a\nb\t\"c\\d", .{});
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("\"a\\nb\\t\\\"c\\\\d\"", s);
}

test "encode slice" {
    const arr = [_]i32{ 1, 2, 3 };
    const s = try encode(std.testing.allocator, &arr, .{});
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("[1,2,3]", s);
}

test "encode optional" {
    const some: ?i32 = 42;
    const s = try encode(std.testing.allocator, some, .{});
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("42", s);

    const none: ?i32 = null;
    const n = try encode(std.testing.allocator, none, .{});
    defer std.testing.allocator.free(n);
    try std.testing.expectEqualStrings("null", n);
}

test "encode struct" {
    const Point = struct { x: i32, y: i32 };
    const p = Point{ .x = 10, .y = 20 };
    const s = try encode(std.testing.allocator, p, .{});
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("{\"x\":10,\"y\":20}", s);
}

test "encode struct with optional field" {
    const Person = struct { name: []const u8, age: ?i32 };
    const p = Person{ .name = "Alice", .age = null };

    // Without emit_null_optional_fields
    const s1 = try encode(std.testing.allocator, p, .{});
    defer std.testing.allocator.free(s1);
    try std.testing.expectEqualStrings("{\"name\":\"Alice\"}", s1);

    // With emit_null_optional_fields
    const s2 = try encode(std.testing.allocator, p, .{ .emit_null_optional_fields = true });
    defer std.testing.allocator.free(s2);
    try std.testing.expectEqualStrings("{\"name\":\"Alice\",\"age\":null}", s2);
}

test "encode enum" {
    const Color = enum { red, green, blue };
    const c = Color.green;
    const s = try encode(std.testing.allocator, c, .{});
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("\"green\"", s);
}

test "encode tagged union" {
    const Shape = union(enum) {
        circle: f32,
        rectangle: struct { w: f32, h: f32 },
        point: void,
    };

    const circle = Shape{ .circle = 5.0 };
    const s = try encode(std.testing.allocator, circle, .{});
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.startsWith(u8, s, "{\"circle\":"));
}

test "encode tuple" {
    const t = .{ 1, "hello", true };
    const s = try encode(std.testing.allocator, t, .{});
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("[1,\"hello\",true]", s);
}

test "encode pretty print" {
    const Point = struct { x: i32, y: i32 };
    const p = Point{ .x = 1, .y = 2 };
    const s = try encode(std.testing.allocator, p, pretty_2);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("{\n  \"x\": 1,\n  \"y\": 2\n}", s);
}

test "encode json.Value" {
    const v = Value{ .str = "test" };
    const s = try encode(std.testing.allocator, v, .{});
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("\"test\"", s);
}

test "encode nested struct" {
    const Inner = struct { value: i32 };
    const Outer = struct { name: []const u8, inner: Inner };
    const o = Outer{ .name = "test", .inner = .{ .value = 42 } };
    const s = try encode(std.testing.allocator, o, .{});
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("{\"name\":\"test\",\"inner\":{\"value\":42}}", s);
}

test "toValue struct" {
    const Point = struct { x: i32, y: i32 };
    const p = Point{ .x = 10, .y = 20 };
    const v = try toValue(std.testing.allocator, p, .{});

    // Clean up
    defer {
        for (v.obj) |m| {
            std.testing.allocator.free(m.k);
            std.testing.allocator.free(m.v.num.lexeme);
            std.testing.allocator.free(m.v.num.digits);
        }
        std.testing.allocator.free(v.obj);
    }

    try std.testing.expect(v == .obj);
    try std.testing.expectEqual(@as(usize, 2), v.obj.len);
}

test "encode escape non-ascii" {
    const s = try encode(std.testing.allocator, "café", .{ .escape_non_ascii = true });
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("\"caf\\u00E9\"", s);
}

test "encode escape slash" {
    const s = try encode(std.testing.allocator, "a/b", .{ .escape_slash = true });
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("\"a\\/b\"", s);
}

// ============================================================================
// Field Tag Tests
// ============================================================================

test "encode struct with custom field name" {
    const Person = struct {
        first_name: []const u8,
        last_name: []const u8,

        pub const json_config = .{
            .first_name = FieldConfig{ .name = "firstName" },
            .last_name = FieldConfig{ .name = "lastName" },
        };
    };

    const p = Person{ .first_name = "John", .last_name = "Doe" };
    const s = try encode(std.testing.allocator, p, .{});
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("{\"firstName\":\"John\",\"lastName\":\"Doe\"}", s);
}

test "encode struct with skip field" {
    const Config = struct {
        name: []const u8,
        internal_id: u64,
        password: []const u8,

        pub const json_config = .{
            .internal_id = FieldConfig{ .skip = true },
            .password = FieldConfig{ .skip = true },
        };
    };

    const c = Config{ .name = "test", .internal_id = 12345, .password = "secret" };
    const s = try encode(std.testing.allocator, c, .{});
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("{\"name\":\"test\"}", s);
}

test "encode struct with omitempty" {
    const Response = struct {
        status: i32,
        message: []const u8,
        error_code: i32,

        pub const json_config = .{
            .error_code = FieldConfig{ .omitempty = true },
            .message = FieldConfig{ .omitempty = true },
        };
    };

    // Non-empty values
    const r1 = Response{ .status = 200, .message = "OK", .error_code = 0 };
    const s1 = try encode(std.testing.allocator, r1, .{});
    defer std.testing.allocator.free(s1);
    try std.testing.expectEqualStrings("{\"status\":200,\"message\":\"OK\"}", s1);

    // With values
    const r2 = Response{ .status = 500, .message = "Error", .error_code = 42 };
    const s2 = try encode(std.testing.allocator, r2, .{});
    defer std.testing.allocator.free(s2);
    try std.testing.expectEqualStrings("{\"status\":500,\"message\":\"Error\",\"error_code\":42}", s2);
}

test "encode struct with stringify" {
    const BigId = struct {
        id: u64,
        name: []const u8,

        pub const json_config = .{
            .id = FieldConfig{ .stringify = true },
        };
    };

    const b = BigId{ .id = 9007199254740993, .name = "test" };
    const s = try encode(std.testing.allocator, b, .{});
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("{\"id\":\"9007199254740993\",\"name\":\"test\"}", s);
}

test "encode struct with combined field config" {
    const ApiResponse = struct {
        data: []const u8,
        count: i32,
        internal: u64,
        empty_field: []const u8,

        pub const json_config = .{
            .data = FieldConfig{ .name = "payload" },
            .internal = FieldConfig{ .skip = true },
            .empty_field = FieldConfig{ .omitempty = true },
        };
    };

    const r = ApiResponse{ .data = "hello", .count = 10, .internal = 999, .empty_field = "" };
    const s = try encode(std.testing.allocator, r, .{});
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("{\"payload\":\"hello\",\"count\":10}", s);
}

// ============================================================================
// Custom Marshaler Tests
// ============================================================================

test "encode with custom marshaler" {
    const Point = struct {
        x: f64,
        y: f64,

        // Custom marshaler: encode as [x, y] array instead of object
        pub fn jsonMarshal(self: @This(), allocator: std.mem.Allocator) !Value {
            var arr = try allocator.alloc(Value, 2);
            arr[0] = try toValue(allocator, self.x, .{});
            arr[1] = try toValue(allocator, self.y, .{});
            return .{ .arr = arr };
        }
    };

    const p = Point{ .x = 10.0, .y = 20.0 };
    const s = try encode(std.testing.allocator, p, .{ .allocator = std.testing.allocator });
    defer std.testing.allocator.free(s);
    // Should be encoded as array [10, 20]
    try std.testing.expect(std.mem.startsWith(u8, s, "["));
    try std.testing.expect(std.mem.endsWith(u8, s, "]"));
}

test "encode with stringify_numbers option" {
    const Data = struct { value: i32, score: f64 };
    const d = Data{ .value = 42, .score = 3.14 };

    const result = try encode(std.testing.allocator, d, .{ .stringify_numbers = true });
    defer std.testing.allocator.free(result);

    // Numbers should be quoted as strings
    try std.testing.expect(std.mem.indexOf(u8, result, "\"42\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"3.14\"") != null);
}

test "encode with deterministic option" {
    const Data = struct { zebra: i32, apple: i32, mango: i32 };
    const d = Data{ .zebra = 1, .apple = 2, .mango = 3 };

    const result = try encode(std.testing.allocator, d, .{ .deterministic = true });
    defer std.testing.allocator.free(result);

    // Fields should be sorted alphabetically: apple, mango, zebra
    const apple_pos = std.mem.indexOf(u8, result, "apple") orelse 0;
    const mango_pos = std.mem.indexOf(u8, result, "mango") orelse 0;
    const zebra_pos = std.mem.indexOf(u8, result, "zebra") orelse 0;

    try std.testing.expect(apple_pos < mango_pos);
    try std.testing.expect(mango_pos < zebra_pos);
}

test "encode json.Value with deterministic sorting" {
    // Create a json.Value object with keys in non-alphabetical order
    var members = [_]Member{
        .{ .k = "zebra", .v = .{ .bool = true } },
        .{ .k = "apple", .v = .{ .bool = false } },
    };

    const v = Value{ .obj = &members };

    const result = try encode(std.testing.allocator, v, .{
        .deterministic = true,
        .allocator = std.testing.allocator,
    });
    defer std.testing.allocator.free(result);

    // Fields should be sorted alphabetically: apple, zebra
    const apple_pos = std.mem.indexOf(u8, result, "apple") orelse 0;
    const zebra_pos = std.mem.indexOf(u8, result, "zebra") orelse 0;

    try std.testing.expect(apple_pos < zebra_pos);
}

test "encode with default_binary_format hex" {
    const data: []const u8 = &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };

    const result = try encode(std.testing.allocator, data, .{ .default_binary_format = .hex });
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("\"deadbeef\"", result);
}

test "encode with default_binary_format hex_upper" {
    const data: []const u8 = &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };

    const result = try encode(std.testing.allocator, data, .{ .default_binary_format = .hex_upper });
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("\"DEADBEEF\"", result);
}

test "encode with default_binary_format base64" {
    const data: []const u8 = "Hello, World!";

    const result = try encode(std.testing.allocator, data, .{ .default_binary_format = .base64 });
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("\"SGVsbG8sIFdvcmxkIQ==\"", result);
}

test "encode struct with binary_format field config" {
    const Data = struct {
        name: []const u8,
        hash: []const u8,

        pub const json_config = .{
            .hash = FieldConfig{ .binary_format = .hex },
        };
    };

    const d = Data{
        .name = "test",
        .hash = &[_]u8{ 0xAB, 0xCD, 0xEF },
    };

    const result = try encode(std.testing.allocator, d, .{});
    defer std.testing.allocator.free(result);

    // name should be utf8, hash should be hex
    try std.testing.expect(std.mem.indexOf(u8, result, "\"test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"abcdef\"") != null);
}

test "encode inline struct fields" {
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

    const user = User{
        .id = 1,
        .name = "Alice",
        .metadata = .{ .created_at = 123, .updated_at = 456 },
    };

    const result = try encode(std.testing.allocator, user, .{});
    defer std.testing.allocator.free(result);

    // Should be flattened: {"id":1,"name":"Alice","created_at":123,"updated_at":456}
    // Not nested: {"id":1,"name":"Alice","metadata":{"created_at":123,...}}
    try std.testing.expect(std.mem.indexOf(u8, result, "\"metadata\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"created_at\":123") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"updated_at\":456") != null);
}

test "encode inline optional struct fields" {
    const Metadata = struct {
        version: u32,
    };

    const Config = struct {
        name: []const u8,
        meta: ?Metadata,

        pub const json_config = .{
            .meta = FieldConfig{ .@"inline" = true },
        };
    };

    // With value
    const config1 = Config{
        .name = "test",
        .meta = .{ .version = 42 },
    };

    const result1 = try encode(std.testing.allocator, config1, .{});
    defer std.testing.allocator.free(result1);

    try std.testing.expect(std.mem.indexOf(u8, result1, "\"meta\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, result1, "\"version\":42") != null);

    // Without value
    const config2 = Config{
        .name = "test2",
        .meta = null,
    };

    const result2 = try encode(std.testing.allocator, config2, .{});
    defer std.testing.allocator.free(result2);

    try std.testing.expect(std.mem.indexOf(u8, result2, "\"version\"") == null);
}

test "toValue with inline struct fields" {
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

    const v = Outer{
        .id = 100,
        .pos = .{ .x = 10, .y = 20 },
    };

    const value = try toValue(std.testing.allocator, v, .{});
    defer {
        for (value.obj) |m| {
            std.testing.allocator.free(m.k);
            switch (m.v) {
                .num => |n| {
                    std.testing.allocator.free(n.lexeme);
                    if (n.lexeme.ptr != n.digits.ptr) {
                        std.testing.allocator.free(n.digits);
                    }
                },
                else => {},
            }
        }
        std.testing.allocator.free(value.obj);
    }

    // Should have 3 members: id, x, y (not id, pos)
    try std.testing.expectEqual(@as(usize, 3), value.obj.len);

    // Check that x and y are at the top level
    var found_x = false;
    var found_y = false;
    var found_pos = false;
    for (value.obj) |m| {
        if (std.mem.eql(u8, m.k, "x")) found_x = true;
        if (std.mem.eql(u8, m.k, "y")) found_y = true;
        if (std.mem.eql(u8, m.k, "pos")) found_pos = true;
    }
    try std.testing.expect(found_x);
    try std.testing.expect(found_y);
    try std.testing.expect(!found_pos);
}

test "encode struct with unknown member capture" {
    const Config = struct {
        name: []const u8,
        version: u32,
        extra: []const Member,

        pub const json_config = .{
            .extra = FieldConfig{ .unknown = true },
        };
    };

    // Create some extra members
    var extra_members = [_]Member{
        .{ .k = "foo", .v = .{ .str = "bar" } },
        .{ .k = "debug", .v = .{ .bool = true } },
    };

    const config = Config{
        .name = "app",
        .version = 1,
        .extra = &extra_members,
    };

    const result = try encode(std.testing.allocator, config, .{});
    defer std.testing.allocator.free(result);

    // Should contain all fields including the unknown ones
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"version\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"foo\":\"bar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"debug\":true") != null);
    // The extra field itself should NOT be present
    try std.testing.expect(std.mem.indexOf(u8, result, "\"extra\"") == null);
}

test "encode struct with optional unknown member capture" {
    const Config = struct {
        name: []const u8,
        extra: ?[]const Member,

        pub const json_config = .{
            .extra = FieldConfig{ .unknown = true },
        };
    };

    // With extra members
    var extra_members = [_]Member{
        .{ .k = "key", .v = .{ .num = .{ .lexeme = "42", .sign = 1, .digits = "42", .exp10 = 0 } } },
    };

    const config1 = Config{
        .name = "test",
        .extra = &extra_members,
    };

    const result1 = try encode(std.testing.allocator, config1, .{});
    defer std.testing.allocator.free(result1);

    try std.testing.expect(std.mem.indexOf(u8, result1, "\"key\":42") != null);

    // Without extra members
    const config2 = Config{
        .name = "test2",
        .extra = null,
    };

    const result2 = try encode(std.testing.allocator, config2, .{});
    defer std.testing.allocator.free(result2);

    try std.testing.expectEqualStrings("{\"name\":\"test2\"}", result2);
}

test "encode NaN with allow_nan_infinity" {
    // Without option - encodes as null
    const nan1 = try encode(std.testing.allocator, std.math.nan(f64), .{});
    defer std.testing.allocator.free(nan1);
    try std.testing.expectEqualStrings("null", nan1);

    // With option - encodes as "NaN" string
    const nan2 = try encode(std.testing.allocator, std.math.nan(f64), .{ .allow_nan_infinity = true });
    defer std.testing.allocator.free(nan2);
    try std.testing.expectEqualStrings("\"NaN\"", nan2);
}

test "encode Infinity with allow_nan_infinity" {
    // Positive infinity
    const inf1 = try encode(std.testing.allocator, std.math.inf(f64), .{ .allow_nan_infinity = true });
    defer std.testing.allocator.free(inf1);
    try std.testing.expectEqualStrings("\"Infinity\"", inf1);

    // Negative infinity
    const inf2 = try encode(std.testing.allocator, -std.math.inf(f64), .{ .allow_nan_infinity = true });
    defer std.testing.allocator.free(inf2);
    try std.testing.expectEqualStrings("\"-Infinity\"", inf2);
}

test "encode struct with NaN/Infinity fields" {
    const Data = struct { nan_val: f64, inf_val: f64, neg_inf_val: f64 };
    const d = Data{
        .nan_val = std.math.nan(f64),
        .inf_val = std.math.inf(f64),
        .neg_inf_val = -std.math.inf(f64),
    };

    const result = try encode(std.testing.allocator, d, .{ .allow_nan_infinity = true });
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"nan_val\":\"NaN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"inf_val\":\"Infinity\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"neg_inf_val\":\"-Infinity\"") != null);
}

test "encode empty slice as empty array by default" {
    const arr: []const i32 = &[_]i32{};
    const result = try encode(std.testing.allocator, arr, .{});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("[]", result);
}

test "encode empty slice as null with format_nil_slice_as_null" {
    const arr: []const i32 = &[_]i32{};
    const result = try encode(std.testing.allocator, arr, .{ .format_nil_slice_as_null = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("null", result);
}

test "encode empty string as empty string by default" {
    const s: []const u8 = "";
    const result = try encode(std.testing.allocator, s, .{});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\"\"", result);
}

test "encode empty string as null with format_nil_slice_as_null" {
    const s: []const u8 = "";
    const result = try encode(std.testing.allocator, s, .{ .format_nil_slice_as_null = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("null", result);
}

test "encode struct with empty slices using format_nil_slice_as_null" {
    const Data = struct {
        items: []const i32,
        name: []const u8,
    };

    const d = Data{
        .items = &[_]i32{},
        .name = "",
    };

    const result = try encode(std.testing.allocator, d, .{ .format_nil_slice_as_null = true });
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"items\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":null") != null);
}

test "encode type with format method using use_fmt_formatter" {
    const Point = struct {
        x: i32,
        y: i32,

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("({d}, {d})", .{ self.x, self.y });
        }
    };

    const p = Point{ .x = 10, .y = 20 };

    // Without use_fmt_formatter - encodes as struct
    const result1 = try encode(std.testing.allocator, p, .{});
    defer std.testing.allocator.free(result1);
    try std.testing.expect(std.mem.indexOf(u8, result1, "\"x\":10") != null);

    // With use_fmt_formatter - uses format method
    const result2 = try encode(std.testing.allocator, p, .{ .use_fmt_formatter = true });
    defer std.testing.allocator.free(result2);
    try std.testing.expectEqualStrings("\"(10, 20)\"", result2);
}

test "encode fmt.Formatter escapes special characters" {
    const Message = struct {
        text: []const u8,

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll(self.text);
        }
    };

    const m = Message{ .text = "Hello\nWorld\"Test" };

    const result = try encode(std.testing.allocator, m, .{ .use_fmt_formatter = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\"Hello\\nWorld\\\"Test\"", result);
}

test "encode fmt.Formatter with struct containing formatter" {
    const Color = struct {
        r: u8,
        g: u8,
        b: u8,

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("#{X:0>2}{X:0>2}{X:0>2}", .{ self.r, self.g, self.b });
        }
    };

    const Data = struct {
        name: []const u8,
        color: Color,
    };

    const d = Data{
        .name = "red",
        .color = Color{ .r = 255, .g = 0, .b = 0 },
    };

    // With use_fmt_formatter, nested structs with format also get formatted
    const result = try encode(std.testing.allocator, d, .{ .use_fmt_formatter = true });
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"red\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"color\":\"#FF0000\"") != null);
}
