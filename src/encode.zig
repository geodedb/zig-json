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
    /// Maximum nesting depth for recursion over runtime-data-driven structures:
    /// runtime `json.Value` trees, runtime slices, and `*T` pointer chains.
    /// Exceeding this returns `error.DepthLimit` instead of overflowing the
    /// stack on a deep or cyclic (self-referential pointer) input. Mirrors the
    /// parser's default `max_depth` (256). See ASR-016.
    max_depth: u16 = 256,
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
///
/// Returns `error.DepthLimit` if recursion over runtime-data-driven structures
/// (runtime `json.Value`, slices, or `*T` pointer chains) exceeds
/// `options.max_depth`. This bounds deep or cyclic inputs. See ASR-016.
pub fn toValue(allocator: std.mem.Allocator, value: anytype, options: EncodeOptions) !Value {
    return toValueInternal(allocator, value, options, 0);
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

// Explicit `anyerror` return type breaks the inferred-error-set dependency
// loop that arises for self-referential pointer types (e.g. a struct with a
// `?*@This()` field), matching encodeArray/encodeJsonValue below.
fn encodeValue(writer: anytype, value: anytype, options: EncodeOptions, depth: usize) anyerror!void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    // ASR-016: bound recursion driven by runtime data (json.Value trees,
    // runtime slices, and *T pointer chains). Comptime-typed nesting is already
    // statically bounded, but a self-referential pointer graph is not. The cap
    // converts an otherwise-uncatchable stack overflow into a clean error.
    if (depth >= options.max_depth) return error.DepthLimit;

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
                    // Dereference single-item pointer. Increment depth so a
                    // self-referential pointer chain is bounded by max_depth
                    // (otherwise a *T cycle recurses forever). See ASR-016.
                    try encodeValue(writer, value.*, options, depth + 1);
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

/// SONNY-2405: size of the buffer renderFloatLexeme renders into. It is the
/// bound std.Io.Writer.printFloat itself uses for "{d}": the longest decimal
/// rendering of any f64 (std.fmt.float.bufferSize(.decimal, f64) == 347).
const float_lexeme_buf_len = std.fmt.float.bufferSize(.decimal, f64);

/// SONNY-2405: render a finite float as a JSON number lexeme. encodeFloat
/// (the writer path) and toValueInternal (the json.Value path) both use it, so
/// encode(x) and toValue(x) spell every float identically.
///
/// Decimal first: whenever "{d}" could render the value (std.Io.Writer renders
/// "{d}" into this same 347-byte bound), the result is byte-for-byte that text,
/// which this library has always emitted (3.25 -> "3.25", 2.0 -> "2",
/// floatMax(f64) -> its 309 digits). Consumers depend on that spelling:
/// diffPatch compares numbers by lexeme, cborEncode encodes an integral lexeme
/// as a CBOR integer, and docs/EXAMPLES.md documents it.
///
/// Scientific fallback: only f80/f128 (and comptime_float, which is f128)
/// values can have a longer decimal form; floatMin(f80)'s is over 4,900
/// characters. "{d}" printed the invalid literal "(float)" for those, so they now
/// use shortest round-trip scientific notation ("3.3621031431120935063e-4932"),
/// which fits in std.fmt.float.min_buffer_size (53) bytes for every float type.
fn renderFloatLexeme(buf: *[float_lexeme_buf_len]u8, value: anytype) []const u8 {
    return std.fmt.float.render(buf, value, .{ .mode = .decimal }) catch
        // Scientific mode without a precision cannot fail once the buffer holds
        // min_buffer_size bytes (see std.fmt.float.formatScientific).
        std.fmt.float.render(buf, value, .{ .mode = .scientific }) catch unreachable;
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

    // SONNY-2405: the formatter shared with toValue (see renderFloatLexeme).
    var buf: [float_lexeme_buf_len]u8 = undefined;
    const lexeme = renderFloatLexeme(&buf, value);
    if (stringify) {
        try writer.writeByte('"');
        try writer.writeAll(lexeme);
        try writer.writeByte('"');
    } else {
        try writer.writeAll(lexeme);
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
            try encodeInt(writer, @intFromEnum(value), false);
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
        // SONNY-2405: this is an O(n^2) bubble sort, and each of its
        // n(n-1)/2 comparisons walks the two JSON names' common prefix with
        // std.mem.order at about two backward branches per byte, so the
        // comptime cost scales with fields^2 x name length. json_config
        // names count (JSON-LD IRIs can be hundreds of bytes). Measured on
        // Zig 0.16.0 with every name sharing all but its last few bytes (the
        // worst case), the sort needs about n(n-1)/2 * (2 * longest + 8)
        // branches: 24 fields x 344-byte names ~191,000, 64 x 300 ~1.2M,
        // 256 x 40 ~2.8M. The default quota is 1,000, and a bound on the
        // field count alone undercounts long names. So find the longest name
        // under a linear budget, then allow n^2 * (4 * longest + 64): at
        // least 4x the measured need at every size, capped at the u32
        // maximum @setEvalBranchQuota accepts.
        const n = info.fields.len;
        @setEvalBranchQuota(1_000 + 64 * n);
        var longest: usize = 0;
        for (info.fields) |field| longest = @max(longest, getJsonName(T, field.name).len);
        const budget: u64 = 1_000 + @as(u64, n) * n * (4 * longest + 64);
        @setEvalBranchQuota(@intCast(@min(budget, std.math.maxInt(u32))));
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
            try encodeStringified(writer, field_value, options, depth + 1);
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
///
/// NQUAL-009: `depth` is threaded through so the non-numeric fallback re-enters
/// `encodeValue` at the current depth rather than resetting to 0. Resetting
/// would let a value reached through a `stringify`-marked struct field escape
/// the `max_depth` recursion guard.
fn encodeStringified(writer: anytype, value: anytype, options: EncodeOptions, depth: usize) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    switch (info) {
        // Per-field stringify always stringifies, regardless of global option
        .int, .comptime_int => try encodeInt(writer, value, true),
        .float, .comptime_float => try encodeFloat(writer, value, true, options.allow_nan_infinity),
        .optional => {
            if (value) |v| {
                try encodeStringified(writer, v, options, depth);
            } else {
                try writer.writeAll("null");
            }
        },
        else => {
            // For non-numeric types, just encode normally, preserving the
            // recursion depth so the max_depth guard still applies.
            try encodeValue(writer, value, options, depth);
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

fn encodeJsonValue(writer: anytype, v: Value, options: EncodeOptions, depth: usize) anyerror!void {
    // ASR-016: bound recursion over runtime json.Value trees (deep or cyclic).
    if (depth >= options.max_depth) return error.DepthLimit;
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

// Explicit `anyerror` return type breaks the inferred-error-set dependency
// loop that arises for self-referential pointer types.
fn toValueInternal(allocator: std.mem.Allocator, value: anytype, options: EncodeOptions, depth: u16) anyerror!Value {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    // ASR-016: bound recursion driven by runtime data (json.Value trees,
    // runtime slices, and *T pointer chains) so a deep or cyclic input returns
    // a clean error instead of overflowing the stack.
    if (depth >= options.max_depth) return error.DepthLimit;

    switch (info) {
        .null, .void, .undefined => return .null,
        .bool => return .{ .bool = value },

        .int, .comptime_int => {
            // SONNY-2405: allocate the lexeme at its exact length. It used to
            // be formatted into a fixed 32-byte buffer with `catch
            // unreachable`, which overflowed for any integer whose decimal
            // form is 33 characters or more (u128 from 10^32, i128 from
            // -10^31, or wider comptime_ints): a panic in safe modes, and in
            // ReleaseFast undefined behaviour (observed as silent truncation
            // to 32 characters, or a hang).
            const lexeme = try std.fmt.allocPrint(allocator, "{d}", .{value});
            errdefer allocator.free(lexeme);
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
            // SONNY-2405: "{d}" (fixed decimal) on a float is unbounded by
            // magnitude (floatMax(f64) needs 309 digits, floatTrueMin(f64)
            // 326), so the old fixed 32-byte buffer panicked (`catch
            // unreachable` on NoSpaceLeft) for large or tiny magnitudes.
            // Rendering every float as "{e}" instead would change every
            // lexeme (1.0 -> "1e0"), which diffPatch, cborEncode and the
            // documented output all observe. So take the lexeme from
            // renderFloatLexeme, the formatter encodeFloat uses. toValue(x)
            // then spells x exactly as encode(x) does: unchanged for every
            // value that rendered before, and valid for the rest.
            var buf: [float_lexeme_buf_len]u8 = undefined;
            const lexeme = try allocator.dupe(u8, renderFloatLexeme(&buf, value));
            errdefer allocator.free(lexeme);
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
                return toValueInternal(allocator, v, options, depth);
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
                            members[0].v = try toValueInternal(allocator, @field(value, field.name), options, depth + 1);
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
                    arr[i] = try toValueInternal(allocator, @field(value, field.name), options, depth + 1);
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
                                idx = try appendStructMembers(allocator, members, idx, actual, options, depth);
                            }
                        } else if (ft_info == .@"struct") {
                            idx = try appendStructMembers(allocator, members, idx, fv, options, depth);
                        }
                        continue;
                    }

                    if (@typeInfo(field.type) == .optional) {
                        if (fv == null and !options.emit_null_optional_fields) continue;
                    }
                    const json_name = field_cfg.name orelse field.name;
                    members[idx].k = try allocator.dupe(u8, json_name);
                    members[idx].v = try toValueInternal(allocator, fv, options, depth + 1);
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
                    vals[i] = try toValueInternal(allocator, item, options, depth + 1);
                }
                return .{ .arr = vals };
            }
        },

        .pointer => |ptr| {
            switch (ptr.size) {
                // Increment depth so a self-referential *T pointer chain is
                // bounded by max_depth rather than recursing forever. See ASR-016.
                .one => return toValueInternal(allocator, value.*, options, depth + 1),
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
                            vals[i] = try toValueInternal(allocator, item, options, depth + 1);
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
    depth: u16,
) !usize {
    const T = @TypeOf(value);
    const s = @typeInfo(T).@"struct";
    var idx = start_idx;

    inline for (s.fields) |field| {
        if (field.name.len > 0 and field.name[0] == '_') continue;
        const field_cfg = comptime getFieldConfig(T, field.name);
        if (field_cfg.skip) continue;

        const fv = @field(value, field.name);

        // Handle nested inline fields recursively (flattened, same depth)
        if (field_cfg.@"inline") {
            const ft_info = @typeInfo(field.type);
            if (ft_info == .optional) {
                if (fv) |actual| {
                    idx = try appendStructMembers(allocator, members, idx, actual, options, depth);
                }
            } else if (ft_info == .@"struct") {
                idx = try appendStructMembers(allocator, members, idx, fv, options, depth);
            }
            continue;
        }

        if (@typeInfo(field.type) == .optional) {
            if (fv == null and !options.emit_null_optional_fields) continue;
        }

        const json_name = field_cfg.name orelse field.name;
        members[idx].k = try allocator.dupe(u8, json_name);
        members[idx].v = try toValueInternal(allocator, fv, options, depth + 1);
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

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// SONNY-2405: shared oracle for the wide-struct tests. Deterministic
/// encoding must emit every JSON name in the order a *runtime* sort produces
/// (the sort under test runs at comptime, under a branch quota); both the
/// sorted and the declaration-order encodings must unmarshal back to a deeply
/// equal value; and the json.Value path (toValue, then encode) must reproduce
/// the writer path byte-for-byte.
fn expectWideStructRoundTrip(comptime T: type, value: T) !void {
    const a = std.testing.allocator;
    const fields = @typeInfo(T).@"struct".fields;

    var expected: [fields.len][]const u8 = undefined;
    inline for (fields, 0..) |field, i| expected[i] = comptime getJsonName(T, field.name);
    std.mem.sort([]const u8, &expected, {}, lessThanString);

    const sorted = try encode(a, value, .{ .deterministic = true });
    defer a.free(sorted);
    var perr = json.ParseError.init();
    var doc = try json.parse(a, sorted, .{}, &perr);
    defer doc.deinit();
    try std.testing.expect(doc.root == .obj);
    try std.testing.expectEqual(fields.len, doc.root.obj.len);
    for (expected, doc.root.obj) |name, member| {
        try std.testing.expectEqualStrings(name, member.k);
    }

    const declared = try encode(a, value, .{});
    defer a.free(declared);
    for ([_][]const u8{ sorted, declared }) |text| {
        var back = try json.unmarshal(T, a, text);
        defer json.free(T, a, &back);
        try std.testing.expectEqualDeep(value, back);
    }

    const tree = try toValue(a, value, .{});
    defer freeValue(a, tree);
    const reencoded = try encode(a, tree, .{});
    defer a.free(reencoded);
    try std.testing.expectEqualStrings(declared, reencoded);

    // SONNY-2417: the other typed inverses must give the value back too:
    // fromValue on the toValue tree, and the path-tracking unmarshalWithInfo
    // on the text.
    var from_tree = try json.fromValue(T, a, tree);
    defer json.free(T, a, &from_tree);
    try std.testing.expectEqualDeep(value, from_tree);

    switch (json.unmarshalWithInfo(T, a, declared)) {
        .ok => |ok| {
            var back = ok;
            defer json.free(T, a, &back);
            try std.testing.expectEqualDeep(value, back);
        },
        .err => |e| {
            std.debug.print("unmarshalWithInfo: {s} at '{s}'\n", .{ e.message, e.path });
            a.free(e.path);
            return error.TestUnexpectedResult;
        },
    }
}

// SONNY-2405: a struct with enough fields to exceed the default comptime
// branch quota (1000) in getSortedFieldIndices's bubble sort. Each of the
// O(n^2) comparisons calls std.mem.order over the field-name bytes, so cost
// scales with both field count AND name length; these 24 ~20-byte names need
// roughly 1,100 branches, just past the default quota. This is a
// *compile-time* regression, not a runtime panic: before the fix this test
// does not compile at all. (24 short single-word field names do NOT
// reproduce it.)
test "SONNY-2405: encode wide struct (24 mixed fields) with deterministic sorting round-trips" {
    const Wide = struct {
        scenario_name_field: i32 = 0,
        duration_nanoseconds: []const u8 = "duration_nanoseconds",
        iteration_count_val: bool = false,
        mean_latency_ns_val: f64 = 3.25,
        median_latency_ns_v: i32 = 40,
        stddev_latency_ns_v: []const u8 = "stddev_latency_ns_v",
        minimum_latency_val: bool = true,
        maximum_latency_val: f64 = 7.25,
        p50_latency_ns_val_: i32 = 80,
        p95_latency_ns_val_: []const u8 = "p95_latency_ns_val_",
        p99_latency_ns_val_: bool = false,
        throughput_ops_sec_: f64 = 11.25,
        allocations_count_v: i32 = 120,
        bytes_allocated_val: []const u8 = "bytes_allocated_val",
        gc_pause_time_ns_v_: bool = true,
        cpu_utilization_pct: f64 = 15.25,
        memory_peak_bytes_v: i32 = 160,
        cache_hit_ratio_val: []const u8 = "cache_hit_ratio_val",
        error_count_total_v: bool = false,
        warning_count_val_v: f64 = 19.25,
        retry_count_total_v: i32 = 200,
        timeout_count_val_v: []const u8 = "timeout_count_val_v",
        success_rate_pct_v_: bool = true,
        baseline_delta_pct_: f64 = 23.25,
    };

    try expectWideStructRoundTrip(Wide, .{});
}

// SONNY-2405: 64 fields sharing a 30-byte name prefix, declared in reverse
// order, so every comparison walks most of the name. The sort needs ~143,000
// branches here against the 1,000 default.
test "SONNY-2405 wide: 64 fields round-trip through deterministic encode and unmarshal" {
    const Wide64 = struct {
        benchmark_result_metric_field_063: i32 = -100,
        benchmark_result_metric_field_062: []const u8 = "value 1",
        benchmark_result_metric_field_061: bool = false,
        benchmark_result_metric_field_060: f64 = 3.25,
        benchmark_result_metric_field_059: u64 = 4000012,
        benchmark_result_metric_field_058: i64 = -5000165,
        benchmark_result_metric_field_057: i32 = -58,
        benchmark_result_metric_field_056: []const u8 = "value 7",
        benchmark_result_metric_field_055: bool = true,
        benchmark_result_metric_field_054: f64 = 0.1,
        benchmark_result_metric_field_053: u64 = 10000030,
        benchmark_result_metric_field_052: i64 = -11000363,
        benchmark_result_metric_field_051: i32 = -16,
        benchmark_result_metric_field_050: []const u8 = "value 13",
        benchmark_result_metric_field_049: bool = false,
        benchmark_result_metric_field_048: f64 = -2.5,
        benchmark_result_metric_field_047: u64 = 16000048,
        benchmark_result_metric_field_046: i64 = -17000561,
        benchmark_result_metric_field_045: i32 = 26,
        benchmark_result_metric_field_044: []const u8 = "value 19",
        benchmark_result_metric_field_043: bool = true,
        benchmark_result_metric_field_042: f64 = 1e21,
        benchmark_result_metric_field_041: u64 = 22000066,
        benchmark_result_metric_field_040: i64 = -23000759,
        benchmark_result_metric_field_039: i32 = 68,
        benchmark_result_metric_field_038: []const u8 = "value 25",
        benchmark_result_metric_field_037: bool = false,
        benchmark_result_metric_field_036: f64 = 1.5e-7,
        benchmark_result_metric_field_035: u64 = 28000084,
        benchmark_result_metric_field_034: i64 = -29000957,
        benchmark_result_metric_field_033: i32 = 110,
        benchmark_result_metric_field_032: []const u8 = "value 31",
        benchmark_result_metric_field_031: bool = true,
        benchmark_result_metric_field_030: f64 = 10.5,
        benchmark_result_metric_field_029: u64 = 34000102,
        benchmark_result_metric_field_028: i64 = -35001155,
        benchmark_result_metric_field_027: i32 = 152,
        benchmark_result_metric_field_026: []const u8 = "value 37",
        benchmark_result_metric_field_025: bool = false,
        benchmark_result_metric_field_024: f64 = 3.25,
        benchmark_result_metric_field_023: u64 = 40000120,
        benchmark_result_metric_field_022: i64 = -41001353,
        benchmark_result_metric_field_021: i32 = 194,
        benchmark_result_metric_field_020: []const u8 = "value 43",
        benchmark_result_metric_field_019: bool = true,
        benchmark_result_metric_field_018: f64 = 0.1,
        benchmark_result_metric_field_017: u64 = 46000138,
        benchmark_result_metric_field_016: i64 = -47001551,
        benchmark_result_metric_field_015: i32 = 236,
        benchmark_result_metric_field_014: []const u8 = "value 49",
        benchmark_result_metric_field_013: bool = false,
        benchmark_result_metric_field_012: f64 = -2.5,
        benchmark_result_metric_field_011: u64 = 52000156,
        benchmark_result_metric_field_010: i64 = -53001749,
        benchmark_result_metric_field_009: i32 = 278,
        benchmark_result_metric_field_008: []const u8 = "value 55",
        benchmark_result_metric_field_007: bool = true,
        benchmark_result_metric_field_006: f64 = 1e21,
        benchmark_result_metric_field_005: u64 = 58000174,
        benchmark_result_metric_field_004: i64 = -59001947,
        benchmark_result_metric_field_003: i32 = 320,
        benchmark_result_metric_field_002: []const u8 = "value 61",
        benchmark_result_metric_field_001: bool = false,
        benchmark_result_metric_field_000: f64 = 1.5e-7,
    };

    try expectWideStructRoundTrip(Wide64, .{});
}

// SONNY-2405: the sort's comptime cost scales with JSON-name length as well
// as field count, so a quota sized from the field count alone is not enough.
// json_config names such as JSON-LD IRIs can be long: these 24 share a
// 342-byte prefix and need ~192,000 branches, more than the field-count-only
// bound of 1,000 + 24 * 24 * 256 = 148,456.
test "SONNY-2405 wide: long shared-prefix JSON names (IRIs) scale the sort quota" {
    const iri_prefix = "https://schema.example.org/" ++ ("benchmarks/vocabulary/" ** 14) ++ "metric_";
    const LongNames = struct {
        m23: i32 = -100,
        m22: []const u8 = "value 1",
        m21: bool = false,
        m20: f64 = 3.25,
        m19: u64 = 4000012,
        m18: i64 = -5000165,
        m17: i32 = -58,
        m16: []const u8 = "value 7",
        m15: bool = true,
        m14: f64 = 0.1,
        m13: u64 = 10000030,
        m12: i64 = -11000363,
        m11: i32 = -16,
        m10: []const u8 = "value 13",
        m09: bool = false,
        m08: f64 = -2.5,
        m07: u64 = 16000048,
        m06: i64 = -17000561,
        m05: i32 = 26,
        m04: []const u8 = "value 19",
        m03: bool = true,
        m02: f64 = 1e21,
        m01: u64 = 22000066,
        m00: i64 = -23000759,

        pub const json_config = .{
            .m23 = FieldConfig{ .name = iri_prefix ++ "23" },
            .m22 = FieldConfig{ .name = iri_prefix ++ "22" },
            .m21 = FieldConfig{ .name = iri_prefix ++ "21" },
            .m20 = FieldConfig{ .name = iri_prefix ++ "20" },
            .m19 = FieldConfig{ .name = iri_prefix ++ "19" },
            .m18 = FieldConfig{ .name = iri_prefix ++ "18" },
            .m17 = FieldConfig{ .name = iri_prefix ++ "17" },
            .m16 = FieldConfig{ .name = iri_prefix ++ "16" },
            .m15 = FieldConfig{ .name = iri_prefix ++ "15" },
            .m14 = FieldConfig{ .name = iri_prefix ++ "14" },
            .m13 = FieldConfig{ .name = iri_prefix ++ "13" },
            .m12 = FieldConfig{ .name = iri_prefix ++ "12" },
            .m11 = FieldConfig{ .name = iri_prefix ++ "11" },
            .m10 = FieldConfig{ .name = iri_prefix ++ "10" },
            .m09 = FieldConfig{ .name = iri_prefix ++ "09" },
            .m08 = FieldConfig{ .name = iri_prefix ++ "08" },
            .m07 = FieldConfig{ .name = iri_prefix ++ "07" },
            .m06 = FieldConfig{ .name = iri_prefix ++ "06" },
            .m05 = FieldConfig{ .name = iri_prefix ++ "05" },
            .m04 = FieldConfig{ .name = iri_prefix ++ "04" },
            .m03 = FieldConfig{ .name = iri_prefix ++ "03" },
            .m02 = FieldConfig{ .name = iri_prefix ++ "02" },
            .m01 = FieldConfig{ .name = iri_prefix ++ "01" },
            .m00 = FieldConfig{ .name = iri_prefix ++ "00" },
        };
    };

    try expectWideStructRoundTrip(LongNames, .{});
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

test "encode non-exhaustive enum with named tag" {
    const Code = enum(u8) { a, b, _ };
    const s = try encode(std.testing.allocator, Code.b, .{});
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("\"b\"", s);
}

test "encode non-exhaustive enum value with no tag name" {
    // QUAL-007: exercises the encodeInt fallback branch in encodeEnum for a
    // non-exhaustive enum value that has no associated tag name. Previously this
    // branch failed to compile because encodeInt was called with 2 args.
    const Code = enum(u8) { a, b, _ };
    const c: Code = @enumFromInt(99);
    const s = try encode(std.testing.allocator, c, .{});
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("99", s);
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

// SONNY-2405: toValue's float lexeme was built with std.fmt.bufPrint into a
// fixed 32-byte buffer using the "{d}" (fixed decimal) specifier, then
// `catch unreachable`d NoSpaceLeft. "{d}" on floats never uses scientific
// notation, so its length is unbounded by magnitude: floatMax(f64) needs
// 309 decimal digits and floatTrueMin(f64) needs 326 (std.fmt.float.
// bufferSize(.decimal, f64) == 347). Both panicked before the fix.
test "SONNY-2405: toValue of extreme f64 magnitudes produces valid JSON numbers (no panic)" {
    const values = [_]f64{
        std.math.floatMax(f64),
        -std.math.floatMax(f64),
        std.math.floatTrueMin(f64),
        1e308,
    };

    for (values) |v| {
        // toValue: builds a Value tree directly; this is the path that panics today.
        const val = try toValue(std.testing.allocator, v, .{});
        defer freeValue(std.testing.allocator, val);
        try std.testing.expect(val == .num);
        const round_tripped = try std.fmt.parseFloat(f64, val.num.lexeme);
        try std.testing.expectEqual(v, round_tripped);

        // The lexeme must itself be a JSON number, not merely something
        // std.fmt.parseFloat accepts.
        var lex_perr = json.ParseError.init();
        var lex_doc = try json.parse(std.testing.allocator, val.num.lexeme, .{}, &lex_perr);
        defer lex_doc.deinit();
        try std.testing.expect(lex_doc.root == .num);
        try std.testing.expectEqual(v, try std.fmt.parseFloat(f64, lex_doc.root.num.lexeme));

        // encode (writer path) rendered these before the fix too: std.Io.Writer
        // formats "{d}" into a fixed 347-byte buffer
        // (std.fmt.float.bufferSize(.decimal, f64)), which holds every f64
        // decimal. It does not hold wider types' decimals (see the tiny
        // f80/f128 test below). Pinned here alongside the toValue fix.
        const s = try encode(std.testing.allocator, v, .{});
        defer std.testing.allocator.free(s);
        const s_round_tripped = try std.fmt.parseFloat(f64, s);
        try std.testing.expectEqual(v, s_round_tripped);

        // The encoded text must itself be valid, parseable JSON.
        var perr = json.ParseError.init();
        var doc = try json.parse(std.testing.allocator, s, .{}, &perr);
        defer doc.deinit();
        try std.testing.expect(doc.root == .num);
        const doc_round_tripped = try std.fmt.parseFloat(f64, doc.root.num.lexeme);
        try std.testing.expectEqual(v, doc_round_tripped);
    }
}

// SONNY-2405: pin the existing NaN/Infinity policy so the buffer/format fix
// above cannot change it. Per EncodeOptions.allow_nan_infinity: false (the
// default) maps NaN/+-Inf to JSON null; true maps them to the string
// sentinels "NaN" / "Infinity" / "-Infinity". Do not change this policy.
test "SONNY-2405: toValue NaN/Infinity follow the allow_nan_infinity policy unchanged" {
    {
        const nan_val = try toValue(std.testing.allocator, std.math.nan(f64), .{});
        defer freeValue(std.testing.allocator, nan_val);
        try std.testing.expect(nan_val == .null);

        const inf_val = try toValue(std.testing.allocator, std.math.inf(f64), .{});
        defer freeValue(std.testing.allocator, inf_val);
        try std.testing.expect(inf_val == .null);

        const ninf_val = try toValue(std.testing.allocator, -std.math.inf(f64), .{});
        defer freeValue(std.testing.allocator, ninf_val);
        try std.testing.expect(ninf_val == .null);
    }
    {
        const nan_val = try toValue(std.testing.allocator, std.math.nan(f64), .{ .allow_nan_infinity = true });
        defer freeValue(std.testing.allocator, nan_val);
        try std.testing.expect(nan_val == .str);
        try std.testing.expectEqualStrings("NaN", nan_val.str);

        const inf_val = try toValue(std.testing.allocator, std.math.inf(f64), .{ .allow_nan_infinity = true });
        defer freeValue(std.testing.allocator, inf_val);
        try std.testing.expectEqualStrings("Infinity", inf_val.str);

        const ninf_val = try toValue(std.testing.allocator, -std.math.inf(f64), .{ .allow_nan_infinity = true });
        defer freeValue(std.testing.allocator, ninf_val);
        try std.testing.expectEqualStrings("-Infinity", ninf_val.str);
    }
}

// SONNY-2405: encode and toValue share one float formatter. For every value
// the library could already render, it must produce the same "{d}"
// (fixed-decimal) text as before SONNY-2405. Consumers compare and classify
// lexemes (see the diffPatch and CBOR tests below), and docs/EXAMPLES.md
// documents them.
test "SONNY-2405 float: toValue and encode keep the decimal spelling of ordinary floats" {
    const a = std.testing.allocator;
    const cases = .{
        .{ @as(f64, 3.25), "3.25" },
        .{ @as(f64, 1.0), "1" },
        .{ @as(f64, 2.0), "2" },
        .{ @as(f64, 0.1), "0.1" },
        .{ @as(f64, 10.5), "10.5" },
        .{ @as(f64, -2.5), "-2.5" },
        .{ @as(f64, 0.0), "0" },
        .{ -@as(f64, 0.0), "-0" },
        .{ @as(f64, 1e21), "1000000000000000000000" },
        .{ @as(f64, 1.5e-7), "0.00000015" },
        .{ @as(f32, 3.25), "3.25" },
        .{ @as(f32, 0.1), "0.1" },
        .{ @as(f16, 1.5), "1.5" },
        .{ 1.5, "1.5" }, // comptime_float
        // SONNY-2405: pin the 347-byte threshold. A 53-byte
        // (std.fmt.float.min_buffer_size) buffer cannot hold either lexeme
        // below and would fall back to scientific notation instead
        // (confirmed with a mutant: 1e60 becomes "1e60", 1/3 becomes
        // "3.333...e-1"), so these two catch a regression the shorter cases
        // above do not.
        .{ @as(f64, 1e60), "1" ++ "0" ** 60 }, // needs 61 decimal bytes
        .{ 1.0 / 3.0, "0.3333333333333333333333333333333333" }, // comptime_float (== f128); needs 36 decimal bytes but still overflows a 53-byte buffer
    };
    inline for (cases) |case| {
        const v = try toValue(a, case[0], .{});
        defer freeValue(a, v);
        try std.testing.expect(v == .num);
        try std.testing.expectEqualStrings(case[1], v.num.lexeme);

        const s = try encode(a, case[0], .{});
        defer a.free(s);
        try std.testing.expectEqualStrings(case[1], s);
    }
}

// docs/EXAMPLES.md, "Custom Marshaler": this exact output is documented.
test "SONNY-2405 float: docs/EXAMPLES.md custom marshaler output is unchanged" {
    const Point3D = struct {
        x: f64,
        y: f64,
        z: f64,

        pub fn jsonMarshal(self: @This(), alloc: std.mem.Allocator) !Value {
            var arr = try alloc.alloc(Value, 3);
            arr[0] = try toValue(alloc, self.x, .{});
            arr[1] = try toValue(alloc, self.y, .{});
            arr[2] = try toValue(alloc, self.z, .{});
            return .{ .arr = arr };
        }
    };

    const p = Point3D{ .x = 1.0, .y = 2.0, .z = 3.0 };
    const out = try encode(std.testing.allocator, p, .{ .allocator = std.testing.allocator });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("[1,2,3]", out);
}

// diffPatch compares numbers by lexeme (patch.zig valuesEqual), so a toValue
// float spelled differently from the parsed text shows up as a spurious
// "replace".
test "SONNY-2405 float: diffPatch sees no change between parsed JSON and toValue of the same floats" {
    const a = std.testing.allocator;
    const Rec = struct { x: f64, n: i32 };

    var perr = json.ParseError.init();
    var doc = try json.parse(a, "{\"x\":1.5,\"n\":2}", .{}, &perr);
    defer doc.deinit();

    const tree = try toValue(a, Rec{ .x = 1.5, .n = 2 }, .{});
    defer freeValue(a, tree);
    const ops = try json.diffPatch(a, doc.root, tree);
    defer json.freeDiffOperations(a, ops);
    try std.testing.expectEqual(@as(usize, 0), ops.len);
}

// cborEncode encodes an integral lexeme ("2") as a CBOR integer and anything
// with a '.' or exponent as a float, so the lexeme spelling decides the bytes.
test "SONNY-2405 float: cborEncode keeps an integral toValue float a CBOR integer" {
    const a = std.testing.allocator;
    const v = try toValue(a, @as(f64, 2.0), .{});
    defer freeValue(a, v);
    const bytes = try json.cborEncode(a, v, .{});
    defer a.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x02}, bytes);
}

// SONNY-2405: with one formatter behind both paths, encode(x) and toValue(x)
// spell every finite float identically. That includes the extremes that used
// to panic in toValue (anything longer than 32 bytes in decimal) or print the
// invalid literal "(float)" in encode (decimal longer than 347 bytes, e.g.
// tiny f80/f128 values). SONNY-2417: and f80/f128 values above floatMax(f64),
// which the NaN/Inf check used to see as infinite after narrowing to f64.
test "SONNY-2405 float: encode and toValue spell every float identically" {
    const a = std.testing.allocator;
    inline for (.{ f16, f32, f64, f80, f128 }) |T| {
        const M = std.math;
        const common = [_]T{
            M.floatTrueMin(T), -M.floatTrueMin(T), M.floatMin(T), M.floatEps(T), 1.0 / 3.0,
            3.25,              1.0,                0.0,           -@as(T, 0.0),  0.1,
        };
        const large = [_]T{ M.floatMax(T), -M.floatMax(T) };
        for (common ++ large) |v| {
            const s = try encode(a, v, .{});
            defer a.free(s);
            const tv = try toValue(a, v, .{});
            defer freeValue(a, tv);
            try std.testing.expect(tv == .num);
            try std.testing.expectEqualStrings(s, tv.num.lexeme);
        }
    }
}

// SONNY-2405: encode printed the invalid literal "(float)" for these.
// std.Io.Writer renders "{d}" into a fixed 347-byte buffer and substitutes
// "(float)" when the decimal does not fit, and tiny f80/f128 values need
// thousands of decimal digits. They must come out as JSON numbers that
// json.parse accepts and that round-trip exactly.
test "SONNY-2405 float: tiny f80/f128 values encode as valid JSON numbers" {
    const a = std.testing.allocator;
    inline for (.{ f80, f128 }) |T| {
        const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
        const values = [_]T{
            std.math.floatTrueMin(T),
            -std.math.floatTrueMin(T),
            std.math.floatMin(T),
            1e-400,
            (@as(T, 1.0) / @as(T, 3.0)) * @as(T, 1e-310),
        };
        for (values) |v| {
            const s = try encode(a, v, .{});
            defer a.free(s);
            var perr = json.ParseError.init();
            var doc = try json.parse(a, s, .{}, &perr);
            defer doc.deinit();
            try std.testing.expect(doc.root == .num);
            const back = try std.fmt.parseFloat(T, s);
            try std.testing.expectEqual(@as(Bits, @bitCast(v)), @as(Bits, @bitCast(back)));
        }
    }
}

/// SONNY-2405: toValue must render the integer `value` as exactly `expected`,
/// keep sign/digits/exp10 consistent with it, agree byte-for-byte with the
/// writer path, and produce a lexeme json.parse accepts as a number.
fn expectIntegerLexeme(value: anytype, expected: []const u8) !void {
    const a = std.testing.allocator;
    const v = try toValue(a, value, .{});
    defer freeValue(a, v);
    try std.testing.expect(v == .num);
    try std.testing.expectEqualStrings(expected, v.num.lexeme);
    const negative = expected[0] == '-';
    try std.testing.expectEqual(@as(i8, if (negative) -1 else 1), v.num.sign);
    try std.testing.expectEqualStrings(expected[@intFromBool(negative)..], v.num.digits);
    try std.testing.expectEqual(@as(i32, 0), v.num.exp10);

    const s = try encode(a, value, .{});
    defer a.free(s);
    try std.testing.expectEqualStrings(expected, s);

    var perr = json.ParseError.init();
    var doc = try json.parse(a, v.num.lexeme, .{}, &perr);
    defer doc.deinit();
    try std.testing.expect(doc.root == .num);
    try std.testing.expectEqualStrings(expected, doc.root.num.lexeme);
}

// SONNY-2405: toValue formatted integers into a fixed 32-byte buffer and
// `catch unreachable`d NoSpaceLeft. Any integer whose decimal form is 33
// characters or more overflowed: u128/i128 from 10^32 up, negative i128 from
// -10^31 down (33 characters with the sign), and wider comptime_ints. That
// was undefined behaviour: a panic in Debug/ReleaseSafe, and in ReleaseFast
// either silent truncation or a hang. encode() was never affected: it prints
// straight to its writer.
// Expected strings were computed independently (Python int arithmetic).
test "SONNY-2405 int: toValue lexemes that fit the old 32-byte buffer are unchanged (control)" {
    try expectIntegerLexeme(@as(u64, std.math.maxInt(u64)), "18446744073709551615");
    try expectIntegerLexeme(@as(u128, 99999999999999999999999999999999), "99999999999999999999999999999999");
    try expectIntegerLexeme(@as(i32, -42), "-42");
    try expectIntegerLexeme(@as(u8, 0), "0");
}

test "SONNY-2405 int: toValue of 10^32, the first 33-digit value" {
    try expectIntegerLexeme(@as(u128, 100000000000000000000000000000000), "100000000000000000000000000000000");
}

test "SONNY-2405 int: toValue of a UUID-style u128" {
    try expectIntegerLexeme(@as(u128, 0x3d6f4f0e_7b1c_4a8e_9c2d_5e6f7a8b9c0d), "81660856151831056012349132679412423693");
}

test "SONNY-2405 int: toValue of maxInt(u128)" {
    try expectIntegerLexeme(@as(u128, std.math.maxInt(u128)), "340282366920938463463374607431768211455");
}

test "SONNY-2405 int: toValue of minInt(i128)" {
    try expectIntegerLexeme(@as(i128, std.math.minInt(i128)), "-170141183460469231731687303715884105728");
}

test "SONNY-2405 int: toValue of comptime_int 1 << 200" {
    try expectIntegerLexeme(1 << 200, "1606938044258990275541962092341162602522202993782792835301376");
}

test "SONNY-2405 int: toValue of a struct with a u128 id field" {
    const a = std.testing.allocator;
    const Rec = struct { id: u128, n: u8 };
    const rec = Rec{ .id = 0x3d6f4f0e_7b1c_4a8e_9c2d_5e6f7a8b9c0d, .n = 1 };

    const tree = try toValue(a, rec, .{});
    defer freeValue(a, tree);
    try std.testing.expect(tree == .obj);
    try std.testing.expectEqualStrings("id", tree.obj[0].k);
    try std.testing.expectEqualStrings("81660856151831056012349132679412423693", tree.obj[0].v.num.lexeme);

    const direct = try encode(a, rec, .{});
    defer a.free(direct);
    try std.testing.expectEqualStrings("{\"id\":81660856151831056012349132679412423693,\"n\":1}", direct);
    const via_tree = try encode(a, tree, .{});
    defer a.free(via_tree);
    try std.testing.expectEqualStrings(direct, via_tree);
}

// SONNY-2417: every field an `inline for` unrolls spends a few backward
// branches of the enclosing function's comptime quota, which defaults to
// 1,000. Measured on Zig 0.16.0: toValueInternal spends 4 per field,
// unmarshalStruct 10 and unmarshalStructWithPath 9, so the typed unmarshal
// paths (json.unmarshal, fromValue, unmarshalWithInfo) stopped compiling at
// about 100 fields and json.toValue at about 250. The fields cycle through
// the integer, string, bool and float kinds of a typed contract, declared in
// reverse name order so deterministic encoding reorders every one.
test "SONNY-2417 wide: a 128-field struct round-trips through typed unmarshal" {
    const Wide128 = struct {
        contract_field_127: i32 = -100,
        contract_field_126: []const u8 = "value 1",
        contract_field_125: bool = false,
        contract_field_124: f64 = 3.25,
        contract_field_123: u64 = 4000012,
        contract_field_122: i64 = -5000165,
        contract_field_121: i32 = -58,
        contract_field_120: []const u8 = "value 7",
        contract_field_119: bool = true,
        contract_field_118: f64 = 0.1,
        contract_field_117: u64 = 10000030,
        contract_field_116: i64 = -11000363,
        contract_field_115: i32 = -16,
        contract_field_114: []const u8 = "value 13",
        contract_field_113: bool = false,
        contract_field_112: f64 = -2.5,
        contract_field_111: u64 = 16000048,
        contract_field_110: i64 = -17000561,
        contract_field_109: i32 = 26,
        contract_field_108: []const u8 = "value 19",
        contract_field_107: bool = true,
        contract_field_106: f64 = 1e21,
        contract_field_105: u64 = 22000066,
        contract_field_104: i64 = -23000759,
        contract_field_103: i32 = 68,
        contract_field_102: []const u8 = "value 25",
        contract_field_101: bool = false,
        contract_field_100: f64 = 1.5e-7,
        contract_field_099: u64 = 28000084,
        contract_field_098: i64 = -29000957,
        contract_field_097: i32 = 110,
        contract_field_096: []const u8 = "value 31",
        contract_field_095: bool = true,
        contract_field_094: f64 = 10.5,
        contract_field_093: u64 = 34000102,
        contract_field_092: i64 = -35001155,
        contract_field_091: i32 = 152,
        contract_field_090: []const u8 = "value 37",
        contract_field_089: bool = false,
        contract_field_088: f64 = 3.25,
        contract_field_087: u64 = 40000120,
        contract_field_086: i64 = -41001353,
        contract_field_085: i32 = 194,
        contract_field_084: []const u8 = "value 43",
        contract_field_083: bool = true,
        contract_field_082: f64 = 0.1,
        contract_field_081: u64 = 46000138,
        contract_field_080: i64 = -47001551,
        contract_field_079: i32 = 236,
        contract_field_078: []const u8 = "value 49",
        contract_field_077: bool = false,
        contract_field_076: f64 = -2.5,
        contract_field_075: u64 = 52000156,
        contract_field_074: i64 = -53001749,
        contract_field_073: i32 = 278,
        contract_field_072: []const u8 = "value 55",
        contract_field_071: bool = true,
        contract_field_070: f64 = 1e21,
        contract_field_069: u64 = 58000174,
        contract_field_068: i64 = -59001947,
        contract_field_067: i32 = 320,
        contract_field_066: []const u8 = "value 61",
        contract_field_065: bool = false,
        contract_field_064: f64 = 1.5e-7,
        contract_field_063: u64 = 64000192,
        contract_field_062: i64 = -65002145,
        contract_field_061: i32 = 362,
        contract_field_060: []const u8 = "value 67",
        contract_field_059: bool = true,
        contract_field_058: f64 = 10.5,
        contract_field_057: u64 = 70000210,
        contract_field_056: i64 = -71002343,
        contract_field_055: i32 = 404,
        contract_field_054: []const u8 = "value 73",
        contract_field_053: bool = false,
        contract_field_052: f64 = 3.25,
        contract_field_051: u64 = 76000228,
        contract_field_050: i64 = -77002541,
        contract_field_049: i32 = 446,
        contract_field_048: []const u8 = "value 79",
        contract_field_047: bool = true,
        contract_field_046: f64 = 0.1,
        contract_field_045: u64 = 82000246,
        contract_field_044: i64 = -83002739,
        contract_field_043: i32 = 488,
        contract_field_042: []const u8 = "value 85",
        contract_field_041: bool = false,
        contract_field_040: f64 = -2.5,
        contract_field_039: u64 = 88000264,
        contract_field_038: i64 = -89002937,
        contract_field_037: i32 = 530,
        contract_field_036: []const u8 = "value 91",
        contract_field_035: bool = true,
        contract_field_034: f64 = 1e21,
        contract_field_033: u64 = 94000282,
        contract_field_032: i64 = -95003135,
        contract_field_031: i32 = 572,
        contract_field_030: []const u8 = "value 97",
        contract_field_029: bool = false,
        contract_field_028: f64 = 1.5e-7,
        contract_field_027: u64 = 100000300,
        contract_field_026: i64 = -101003333,
        contract_field_025: i32 = 614,
        contract_field_024: []const u8 = "value 103",
        contract_field_023: bool = true,
        contract_field_022: f64 = 10.5,
        contract_field_021: u64 = 106000318,
        contract_field_020: i64 = -107003531,
        contract_field_019: i32 = 656,
        contract_field_018: []const u8 = "value 109",
        contract_field_017: bool = false,
        contract_field_016: f64 = 3.25,
        contract_field_015: u64 = 112000336,
        contract_field_014: i64 = -113003729,
        contract_field_013: i32 = 698,
        contract_field_012: []const u8 = "value 115",
        contract_field_011: bool = true,
        contract_field_010: f64 = 0.1,
        contract_field_009: u64 = 118000354,
        contract_field_008: i64 = -119003927,
        contract_field_007: i32 = 740,
        contract_field_006: []const u8 = "value 121",
        contract_field_005: bool = false,
        contract_field_004: f64 = -2.5,
        contract_field_003: u64 = 124000372,
        contract_field_002: i64 = -125004125,
        contract_field_001: i32 = 782,
        contract_field_000: []const u8 = "value 127",
    };

    try expectWideStructRoundTrip(Wide128, .{});
}

test "SONNY-2417 wide: a 256-field struct round-trips through toValue" {
    const Wide256 = struct {
        contract_field_255: i32 = -100,
        contract_field_254: []const u8 = "value 1",
        contract_field_253: bool = false,
        contract_field_252: f64 = 3.25,
        contract_field_251: u64 = 4000012,
        contract_field_250: i64 = -5000165,
        contract_field_249: i32 = -58,
        contract_field_248: []const u8 = "value 7",
        contract_field_247: bool = true,
        contract_field_246: f64 = 0.1,
        contract_field_245: u64 = 10000030,
        contract_field_244: i64 = -11000363,
        contract_field_243: i32 = -16,
        contract_field_242: []const u8 = "value 13",
        contract_field_241: bool = false,
        contract_field_240: f64 = -2.5,
        contract_field_239: u64 = 16000048,
        contract_field_238: i64 = -17000561,
        contract_field_237: i32 = 26,
        contract_field_236: []const u8 = "value 19",
        contract_field_235: bool = true,
        contract_field_234: f64 = 1e21,
        contract_field_233: u64 = 22000066,
        contract_field_232: i64 = -23000759,
        contract_field_231: i32 = 68,
        contract_field_230: []const u8 = "value 25",
        contract_field_229: bool = false,
        contract_field_228: f64 = 1.5e-7,
        contract_field_227: u64 = 28000084,
        contract_field_226: i64 = -29000957,
        contract_field_225: i32 = 110,
        contract_field_224: []const u8 = "value 31",
        contract_field_223: bool = true,
        contract_field_222: f64 = 10.5,
        contract_field_221: u64 = 34000102,
        contract_field_220: i64 = -35001155,
        contract_field_219: i32 = 152,
        contract_field_218: []const u8 = "value 37",
        contract_field_217: bool = false,
        contract_field_216: f64 = 3.25,
        contract_field_215: u64 = 40000120,
        contract_field_214: i64 = -41001353,
        contract_field_213: i32 = 194,
        contract_field_212: []const u8 = "value 43",
        contract_field_211: bool = true,
        contract_field_210: f64 = 0.1,
        contract_field_209: u64 = 46000138,
        contract_field_208: i64 = -47001551,
        contract_field_207: i32 = 236,
        contract_field_206: []const u8 = "value 49",
        contract_field_205: bool = false,
        contract_field_204: f64 = -2.5,
        contract_field_203: u64 = 52000156,
        contract_field_202: i64 = -53001749,
        contract_field_201: i32 = 278,
        contract_field_200: []const u8 = "value 55",
        contract_field_199: bool = true,
        contract_field_198: f64 = 1e21,
        contract_field_197: u64 = 58000174,
        contract_field_196: i64 = -59001947,
        contract_field_195: i32 = 320,
        contract_field_194: []const u8 = "value 61",
        contract_field_193: bool = false,
        contract_field_192: f64 = 1.5e-7,
        contract_field_191: u64 = 64000192,
        contract_field_190: i64 = -65002145,
        contract_field_189: i32 = 362,
        contract_field_188: []const u8 = "value 67",
        contract_field_187: bool = true,
        contract_field_186: f64 = 10.5,
        contract_field_185: u64 = 70000210,
        contract_field_184: i64 = -71002343,
        contract_field_183: i32 = 404,
        contract_field_182: []const u8 = "value 73",
        contract_field_181: bool = false,
        contract_field_180: f64 = 3.25,
        contract_field_179: u64 = 76000228,
        contract_field_178: i64 = -77002541,
        contract_field_177: i32 = 446,
        contract_field_176: []const u8 = "value 79",
        contract_field_175: bool = true,
        contract_field_174: f64 = 0.1,
        contract_field_173: u64 = 82000246,
        contract_field_172: i64 = -83002739,
        contract_field_171: i32 = 488,
        contract_field_170: []const u8 = "value 85",
        contract_field_169: bool = false,
        contract_field_168: f64 = -2.5,
        contract_field_167: u64 = 88000264,
        contract_field_166: i64 = -89002937,
        contract_field_165: i32 = 530,
        contract_field_164: []const u8 = "value 91",
        contract_field_163: bool = true,
        contract_field_162: f64 = 1e21,
        contract_field_161: u64 = 94000282,
        contract_field_160: i64 = -95003135,
        contract_field_159: i32 = 572,
        contract_field_158: []const u8 = "value 97",
        contract_field_157: bool = false,
        contract_field_156: f64 = 1.5e-7,
        contract_field_155: u64 = 100000300,
        contract_field_154: i64 = -101003333,
        contract_field_153: i32 = 614,
        contract_field_152: []const u8 = "value 103",
        contract_field_151: bool = true,
        contract_field_150: f64 = 10.5,
        contract_field_149: u64 = 106000318,
        contract_field_148: i64 = -107003531,
        contract_field_147: i32 = 656,
        contract_field_146: []const u8 = "value 109",
        contract_field_145: bool = false,
        contract_field_144: f64 = 3.25,
        contract_field_143: u64 = 112000336,
        contract_field_142: i64 = -113003729,
        contract_field_141: i32 = 698,
        contract_field_140: []const u8 = "value 115",
        contract_field_139: bool = true,
        contract_field_138: f64 = 0.1,
        contract_field_137: u64 = 118000354,
        contract_field_136: i64 = -119003927,
        contract_field_135: i32 = 740,
        contract_field_134: []const u8 = "value 121",
        contract_field_133: bool = false,
        contract_field_132: f64 = -2.5,
        contract_field_131: u64 = 124000372,
        contract_field_130: i64 = -125004125,
        contract_field_129: i32 = 782,
        contract_field_128: []const u8 = "value 127",
        contract_field_127: bool = true,
        contract_field_126: f64 = 1e21,
        contract_field_125: u64 = 130000390,
        contract_field_124: i64 = -131004323,
        contract_field_123: i32 = 824,
        contract_field_122: []const u8 = "value 133",
        contract_field_121: bool = false,
        contract_field_120: f64 = 1.5e-7,
        contract_field_119: u64 = 136000408,
        contract_field_118: i64 = -137004521,
        contract_field_117: i32 = 866,
        contract_field_116: []const u8 = "value 139",
        contract_field_115: bool = true,
        contract_field_114: f64 = 10.5,
        contract_field_113: u64 = 142000426,
        contract_field_112: i64 = -143004719,
        contract_field_111: i32 = 908,
        contract_field_110: []const u8 = "value 145",
        contract_field_109: bool = false,
        contract_field_108: f64 = 3.25,
        contract_field_107: u64 = 148000444,
        contract_field_106: i64 = -149004917,
        contract_field_105: i32 = 950,
        contract_field_104: []const u8 = "value 151",
        contract_field_103: bool = true,
        contract_field_102: f64 = 0.1,
        contract_field_101: u64 = 154000462,
        contract_field_100: i64 = -155005115,
        contract_field_099: i32 = 992,
        contract_field_098: []const u8 = "value 157",
        contract_field_097: bool = false,
        contract_field_096: f64 = -2.5,
        contract_field_095: u64 = 160000480,
        contract_field_094: i64 = -161005313,
        contract_field_093: i32 = 1034,
        contract_field_092: []const u8 = "value 163",
        contract_field_091: bool = true,
        contract_field_090: f64 = 1e21,
        contract_field_089: u64 = 166000498,
        contract_field_088: i64 = -167005511,
        contract_field_087: i32 = 1076,
        contract_field_086: []const u8 = "value 169",
        contract_field_085: bool = false,
        contract_field_084: f64 = 1.5e-7,
        contract_field_083: u64 = 172000516,
        contract_field_082: i64 = -173005709,
        contract_field_081: i32 = 1118,
        contract_field_080: []const u8 = "value 175",
        contract_field_079: bool = true,
        contract_field_078: f64 = 10.5,
        contract_field_077: u64 = 178000534,
        contract_field_076: i64 = -179005907,
        contract_field_075: i32 = 1160,
        contract_field_074: []const u8 = "value 181",
        contract_field_073: bool = false,
        contract_field_072: f64 = 3.25,
        contract_field_071: u64 = 184000552,
        contract_field_070: i64 = -185006105,
        contract_field_069: i32 = 1202,
        contract_field_068: []const u8 = "value 187",
        contract_field_067: bool = true,
        contract_field_066: f64 = 0.1,
        contract_field_065: u64 = 190000570,
        contract_field_064: i64 = -191006303,
        contract_field_063: i32 = 1244,
        contract_field_062: []const u8 = "value 193",
        contract_field_061: bool = false,
        contract_field_060: f64 = -2.5,
        contract_field_059: u64 = 196000588,
        contract_field_058: i64 = -197006501,
        contract_field_057: i32 = 1286,
        contract_field_056: []const u8 = "value 199",
        contract_field_055: bool = true,
        contract_field_054: f64 = 1e21,
        contract_field_053: u64 = 202000606,
        contract_field_052: i64 = -203006699,
        contract_field_051: i32 = 1328,
        contract_field_050: []const u8 = "value 205",
        contract_field_049: bool = false,
        contract_field_048: f64 = 1.5e-7,
        contract_field_047: u64 = 208000624,
        contract_field_046: i64 = -209006897,
        contract_field_045: i32 = 1370,
        contract_field_044: []const u8 = "value 211",
        contract_field_043: bool = true,
        contract_field_042: f64 = 10.5,
        contract_field_041: u64 = 214000642,
        contract_field_040: i64 = -215007095,
        contract_field_039: i32 = 1412,
        contract_field_038: []const u8 = "value 217",
        contract_field_037: bool = false,
        contract_field_036: f64 = 3.25,
        contract_field_035: u64 = 220000660,
        contract_field_034: i64 = -221007293,
        contract_field_033: i32 = 1454,
        contract_field_032: []const u8 = "value 223",
        contract_field_031: bool = true,
        contract_field_030: f64 = 0.1,
        contract_field_029: u64 = 226000678,
        contract_field_028: i64 = -227007491,
        contract_field_027: i32 = 1496,
        contract_field_026: []const u8 = "value 229",
        contract_field_025: bool = false,
        contract_field_024: f64 = -2.5,
        contract_field_023: u64 = 232000696,
        contract_field_022: i64 = -233007689,
        contract_field_021: i32 = 1538,
        contract_field_020: []const u8 = "value 235",
        contract_field_019: bool = true,
        contract_field_018: f64 = 1e21,
        contract_field_017: u64 = 238000714,
        contract_field_016: i64 = -239007887,
        contract_field_015: i32 = 1580,
        contract_field_014: []const u8 = "value 241",
        contract_field_013: bool = false,
        contract_field_012: f64 = 1.5e-7,
        contract_field_011: u64 = 244000732,
        contract_field_010: i64 = -245008085,
        contract_field_009: i32 = 1622,
        contract_field_008: []const u8 = "value 247",
        contract_field_007: bool = true,
        contract_field_006: f64 = 10.5,
        contract_field_005: u64 = 250000750,
        contract_field_004: i64 = -251008283,
        contract_field_003: i32 = 1664,
        contract_field_002: []const u8 = "value 253",
        contract_field_001: bool = false,
        contract_field_000: f64 = 3.25,
    };

    try expectWideStructRoundTrip(Wide256, .{});
}

// SONNY-2417: toValue of any struct with an optional field did not compile
// ("comptime control flow inside runtime block"): the member loop skipped a
// null optional with `continue` under a runtime `if`, which an `inline for`
// cannot do. appendStructMembers, which flattens `inline` fields, had the
// same loop. toValue(x) must now encode exactly like encode(x), with and
// without emit_null_optional_fields, and fromValue must give x back.
test "SONNY-2417 optional: toValue of structs with optional fields matches encode and round-trips" {
    const Limits = struct {
        max_bytes: ?u64 = null,
        max_depth: ?u16 = null,
    };
    const Rule = struct {
        id: []const u8,
        effect: enum { allow, deny },
        note: ?[]const u8 = null,
        weight: ?f64 = null,
        limits: ?Limits = null,
    };
    const Audit = struct {
        trace_id: ?[]const u8 = null,
        attempt: u32 = 1,
    };
    const Policy = struct {
        name: []const u8,
        version: u32,
        description: ?[]const u8 = null,
        primary: Rule,
        fallback: ?Rule = null,
        audit: Audit = .{},

        pub const json_config = .{
            .audit = FieldConfig{ .@"inline" = true },
        };
    };

    const cases = [_]Policy{
        .{
            .name = "every optional set",
            .version = 3,
            .description = "all present",
            .primary = .{ .id = "r1", .effect = .allow, .note = "first", .weight = 0.5, .limits = .{ .max_bytes = 4096 } },
            .fallback = .{ .id = "fb", .effect = .deny, .limits = .{ .max_depth = 8 } },
            .audit = .{ .trace_id = "t-1", .attempt = 2 },
        },
        .{ .name = "every optional null", .version = 1, .primary = .{ .id = "r2", .effect = .deny } },
    };

    const a = std.testing.allocator;
    for (cases) |p| {
        inline for (.{ false, true }) |emit_null| {
            const opts: EncodeOptions = .{ .emit_null_optional_fields = emit_null };
            const tree = try toValue(a, p, opts);
            defer freeValue(a, tree);
            const direct = try encode(a, p, opts);
            defer a.free(direct);
            const via_tree = try encode(a, tree, .{});
            defer a.free(via_tree);
            try std.testing.expectEqualStrings(direct, via_tree);

            var back = try json.fromValue(Policy, a, tree);
            defer json.free(Policy, a, &back);
            try std.testing.expectEqualDeep(p, back);
        }
    }
}

// SONNY-2417: encodeFloat and toValueInternal checked for NaN/Inf on an f64
// narrowing of the value, and @floatCast to f64 turns every finite f80/f128
// above floatMax(f64) into an infinity. Those values came out as JSON null,
// or with allow_nan_infinity as "Infinity"/"-Infinity", instead of numbers.
// comptime_float (f128 inside the compiler) was narrowed the same way. Both
// paths must emit the same valid JSON number under either setting, and
// json.parse must accept it and give back the exact value.
test "SONNY-2417 float: f80/f128 values above floatMax(f64) encode as JSON numbers" {
    const a = std.testing.allocator;
    inline for (.{ f80, f128 }) |T| {
        const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
        const values = [_]T{
            std.math.floatMax(T),
            -std.math.floatMax(T),
            @as(T, std.math.floatMax(f64)) * 2,
            1e309,
            -1e4000,
        };
        for (values) |v| {
            inline for (.{ false, true }) |allow_nan_infinity| {
                const opts: EncodeOptions = .{ .allow_nan_infinity = allow_nan_infinity };
                const s = try encode(a, v, opts);
                defer a.free(s);
                const tv = try toValue(a, v, opts);
                defer freeValue(a, tv);
                try std.testing.expect(tv == .num);
                try std.testing.expectEqualStrings(s, tv.num.lexeme);

                var perr = json.ParseError.init();
                var doc = try json.parse(a, s, .{}, &perr);
                defer doc.deinit();
                try std.testing.expect(doc.root == .num);
                const back = try std.fmt.parseFloat(T, doc.root.num.lexeme);
                try std.testing.expectEqual(@as(Bits, @bitCast(v)), @as(Bits, @bitCast(back)));
            }
        }
    }

    const s = try encode(a, 1e400, .{});
    defer a.free(s);
    try std.testing.expectEqualStrings("1e400", s);
    const tv = try toValue(a, -1e400, .{});
    defer freeValue(a, tv);
    try std.testing.expect(tv == .num);
    try std.testing.expectEqualStrings("-1e400", tv.num.lexeme);
}

// SONNY-2417: checking NaN/Inf in the value's own type must leave the policy
// for real f80/f128 NaN and infinities unchanged: null by default, the
// "NaN"/"Infinity"/"-Infinity" sentinels with allow_nan_infinity.
test "SONNY-2417 float: f80/f128 NaN and infinities keep the allow_nan_infinity policy" {
    const a = std.testing.allocator;
    inline for (.{ f80, f128 }) |T| {
        const specials = [_]T{ std.math.nan(T), std.math.inf(T), -std.math.inf(T) };
        const sentinels = [_][]const u8{ "NaN", "Infinity", "-Infinity" };
        for (specials, sentinels) |v, sentinel| {
            const s_null = try encode(a, v, .{});
            defer a.free(s_null);
            try std.testing.expectEqualStrings("null", s_null);
            const tv_null = try toValue(a, v, .{});
            defer freeValue(a, tv_null);
            try std.testing.expect(tv_null == .null);

            const s_str = try encode(a, v, .{ .allow_nan_infinity = true });
            defer a.free(s_str);
            try std.testing.expectEqualStrings(sentinel, s_str[1 .. s_str.len - 1]);
            try std.testing.expect(s_str[0] == '"' and s_str[s_str.len - 1] == '"');
            const tv_str = try toValue(a, v, .{ .allow_nan_infinity = true });
            defer freeValue(a, tv_str);
            try std.testing.expect(tv_str == .str);
            try std.testing.expectEqualStrings(sentinel, tv_str.str);
        }
    }
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

test "NQUAL-009: stringify field with deeply nested value still hits depth limit" {
    const a = std.testing.allocator;

    // A `stringify`-marked field whose value is a non-numeric, deeply nested
    // json.Value tree. Before the fix, encodeStringified re-entered encodeValue
    // at depth 0, resetting the recursion counter and escaping the max_depth
    // guard. With depth threaded through, the nested value is bounded by
    // max_depth like any other recursion site.
    const Wrapper = struct {
        payload: Value,

        pub const json_config = .{
            .payload = FieldConfig{ .stringify = true },
        };
    };

    const nested = try buildNestedValueArray(a, 32, .null);
    defer freeNestedValueArray(a, nested);

    const w = Wrapper{ .payload = nested };

    // A small max_depth must trip the guard rather than silently encoding the
    // whole tree (or overflowing the stack on a deeper input).
    try std.testing.expectError(error.DepthLimit, encode(a, w, .{ .max_depth = 4 }));
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

// ============================================================================
// Depth-limit / DoS-guard Tests (ASR-016)
// ============================================================================

/// Build a json.Value tree of nested single-element arrays of the given depth.
fn buildNestedValueArray(a: std.mem.Allocator, depth: usize, leaf: Value) !Value {
    var v = leaf;
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        const arr = try a.alloc(Value, 1);
        arr[0] = v;
        v = .{ .arr = arr };
    }
    return v;
}

fn freeNestedValueArray(a: std.mem.Allocator, v: Value) void {
    switch (v) {
        .arr => |arr| {
            for (arr) |item| freeNestedValueArray(a, item);
            a.free(arr);
        },
        else => {},
    }
}

test "encode deeply nested json.Value returns DepthLimit (no crash)" {
    const a = std.testing.allocator;
    const v = try buildNestedValueArray(a, 100_000, .null);
    defer freeNestedValueArray(a, v);

    try std.testing.expectError(error.DepthLimit, encode(a, v, .{}));
}

test "encode nested json.Value within depth limit succeeds" {
    const a = std.testing.allocator;
    const v = try buildNestedValueArray(a, 100, .{ .bool = true });
    defer freeNestedValueArray(a, v);

    const result = try encode(a, v, .{});
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "true") != null);
}

test "toValue deeply nested json.Value returns DepthLimit (no crash)" {
    const a = std.testing.allocator;
    const v = try buildNestedValueArray(a, 100_000, .null);
    defer freeNestedValueArray(a, v);

    // toValue builds an owned tree; on the error path it leaves the partial
    // tree allocated (the caller owns cleanup), so use an arena to reclaim it.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    try std.testing.expectError(error.DepthLimit, toValue(arena.allocator(), v, .{}));
}

test "encode cyclic pointer graph returns DepthLimit (no crash)" {
    // ASR-016: a self-referential *T pointer chain would recurse forever and
    // overflow the stack. The depth cap converts that into a clean error.
    const Node = struct {
        value: i32,
        next: ?*const @This(),
    };

    var node: Node = .{ .value = 1, .next = null };
    node.next = &node; // cycle: node -> node -> node -> ...

    try std.testing.expectError(error.DepthLimit, encode(std.testing.allocator, node, .{}));
}

test "encode respects custom max_depth" {
    const a = std.testing.allocator;
    // 10 levels of nesting with a cap of 4 must fail.
    const v = try buildNestedValueArray(a, 10, .null);
    defer freeNestedValueArray(a, v);

    try std.testing.expectError(error.DepthLimit, encode(a, v, .{ .max_depth = 4 }));

    // The same tree is fine with a generous cap.
    const result = try encode(a, v, .{ .max_depth = 64 });
    defer a.free(result);
    try std.testing.expect(result.len > 0);
}
