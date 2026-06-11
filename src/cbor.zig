// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! CBOR Encoding (RFC 8949)
//!
//! Concise Binary Object Representation - a binary data format
//! designed to be a compact superset of JSON semantics.
//!
//! Specification: https://www.rfc-editor.org/rfc/rfc8949
//!
//! Features:
//! - Encode JSON values to CBOR binary format
//! - Decode CBOR binary format to JSON values
//! - Support for all major CBOR types
//! - Compact encoding for small values
//! - Streaming encode/decode support

const std = @import("std");
const json = @import("json.zig");

/// CBOR major types (3 high bits of the initial byte)
pub const MajorType = enum(u3) {
    /// Unsigned integer (0-23 in initial byte, or 24-27 for 1-8 byte integers)
    unsigned_int = 0,
    /// Negative integer (-1 - value)
    negative_int = 1,
    /// Byte string
    byte_string = 2,
    /// Text string (UTF-8)
    text_string = 3,
    /// Array
    array = 4,
    /// Map (object)
    map = 5,
    /// Tagged value
    tagged = 6,
    /// Simple/float
    simple_or_float = 7,
};

/// CBOR simple values
pub const SimpleValue = enum(u8) {
    false_val = 20,
    true_val = 21,
    null_val = 22,
    undefined = 23,
    // 24-31 reserved for 1-byte extended values
    half_float = 25,
    single_float = 26,
    double_float = 27,
    break_code = 31,
};

/// Well-known CBOR tags
pub const Tag = enum(u64) {
    /// Standard date/time string (RFC 3339)
    datetime_string = 0,
    /// Epoch-based date/time (seconds since 1970-01-01T00:00Z)
    epoch_datetime = 1,
    /// Positive bignum
    positive_bignum = 2,
    /// Negative bignum
    negative_bignum = 3,
    /// Decimal fraction
    decimal_fraction = 4,
    /// Bigfloat
    bigfloat = 5,
    /// Base64url encoding hint
    base64url = 21,
    /// Base64 encoding hint
    base64 = 22,
    /// Base16 encoding hint
    base16 = 23,
    /// Encoded CBOR data item
    cbor_data = 24,
    /// URI (RFC 3986)
    uri = 32,
    /// Base64url without padding
    base64url_nopad = 33,
    /// Base64
    base64_enc = 34,
    /// Regular expression
    regex = 35,
    /// MIME message
    mime = 36,
    /// Self-describe CBOR (magic number)
    self_describe = 55799,

    pub fn fromInt(value: u64) ?Tag {
        return std.meta.intToEnum(Tag, value) catch null;
    }
};

/// CBOR encoding options
pub const EncodeOptions = struct {
    /// Use canonical CBOR encoding (deterministic)
    canonical: bool = false,
    /// Maximum nesting depth
    max_depth: u16 = 256,
    /// Encode numbers as minimal size
    minimal_encoding: bool = true,
    /// Add self-describe tag (55799)
    self_describe: bool = false,
};

/// CBOR decoding options
pub const DecodeOptions = struct {
    /// Maximum nesting depth
    max_depth: u16 = 256,
    /// Maximum string length
    max_string_len: usize = 1024 * 1024,
    /// Allow indefinite length items
    allow_indefinite: bool = true,
    /// Strict mode (reject unknown tags)
    strict: bool = false,
};

/// CBOR encode/decode errors
pub const CborError = error{
    InvalidMajorType,
    InvalidSimpleValue,
    InvalidUtf8,
    UnexpectedBreak,
    NestingTooDeep,
    StringTooLong,
    UnexpectedEof,
    IntegerOverflow,
    UnsupportedTag,
    InvalidFloat,
    /// Wire-declared length exceeds what the remaining input can possibly
    /// supply (e.g. a definite-length array/map header claiming far more
    /// items than there are bytes left). Guards against unbounded
    /// pre-allocation from an attacker-controlled length prefix.
    InvalidLength,
    /// A chunk of an indefinite-length byte/text string was not a
    /// definite-length string of the matching major type. Per RFC 8949
    /// 3.2.3 the chunks MUST be definite-length strings of the same major
    /// type; in particular a nested indefinite-length string is malformed
    /// (NEW-001 -- also defends against unbounded recursion on such input).
    InvalidString,
    OutOfMemory,
};

/// CBOR Encoder
pub const Encoder = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    options: EncodeOptions,
    depth: u16,

    pub fn init(allocator: std.mem.Allocator, options: EncodeOptions) Self {
        return .{
            .allocator = allocator,
            .buffer = .empty,
            .options = options,
            .depth = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
    }

    /// Get the encoded CBOR bytes
    pub fn toBytes(self: *Self) []const u8 {
        return self.buffer.items;
    }

    /// Get owned copy of encoded bytes
    pub fn toOwnedBytes(self: *Self) ![]u8 {
        return self.buffer.toOwnedSlice(self.allocator);
    }

    /// Reset the encoder for reuse
    pub fn reset(self: *Self) void {
        self.buffer.clearRetainingCapacity();
        self.depth = 0;
    }

    /// Encode a JSON value to CBOR
    pub fn encode(self: *Self, value: json.Value) !void {
        if (self.options.self_describe and self.depth == 0) {
            try self.writeTag(@intFromEnum(Tag.self_describe));
        }

        try self.encodeValue(value);
    }

    fn encodeValue(self: *Self, value: json.Value) CborError!void {
        if (self.depth > self.options.max_depth) {
            return error.NestingTooDeep;
        }

        switch (value) {
            .null => try self.writeSimple(SimpleValue.null_val),
            .bool => |b| try self.writeSimple(if (b) SimpleValue.true_val else SimpleValue.false_val),
            .str => |s| try self.writeTextString(s),
            .num => |n| try self.encodeNumber(n),
            .arr => |arr| {
                self.depth += 1;
                defer self.depth -= 1;

                try self.writeArrayHeader(arr.len);
                for (arr) |item| {
                    try self.encodeValue(item);
                }
            },
            .obj => |obj| {
                self.depth += 1;
                defer self.depth -= 1;

                if (self.options.canonical) {
                    try self.encodeMapCanonical(obj);
                } else {
                    try self.writeMapHeader(obj.len);
                    for (obj) |member| {
                        try self.writeTextString(member.k);
                        try self.encodeValue(member.v);
                    }
                }
            },
        }
    }

    fn encodeNumber(self: *Self, num: json.Number) !void {
        // Try to parse as integer first
        const lexeme = num.lexeme;

        // Check for special values
        if (std.mem.eql(u8, lexeme, "NaN")) {
            try self.writeFloat64(std.math.nan(f64));
            return;
        }
        if (std.mem.eql(u8, lexeme, "Infinity")) {
            try self.writeFloat64(std.math.inf(f64));
            return;
        }
        if (std.mem.eql(u8, lexeme, "-Infinity")) {
            try self.writeFloat64(-std.math.inf(f64));
            return;
        }

        // Try integer parsing
        if (std.mem.indexOf(u8, lexeme, ".") == null and
            std.mem.indexOf(u8, lexeme, "e") == null and
            std.mem.indexOf(u8, lexeme, "E") == null)
        {
            if (num.sign >= 0) {
                // Unsigned integer
                const val = std.fmt.parseInt(u64, lexeme, 10) catch {
                    // Fall through to float
                    const f = std.fmt.parseFloat(f64, lexeme) catch return error.InvalidFloat;
                    try self.writeFloat64(f);
                    return;
                };
                try self.writeUnsignedInt(val);
            } else {
                // Negative integer
                const val = std.fmt.parseInt(i64, lexeme, 10) catch {
                    const f = std.fmt.parseFloat(f64, lexeme) catch return error.InvalidFloat;
                    try self.writeFloat64(f);
                    return;
                };
                if (val < 0) {
                    try self.writeNegativeInt(@intCast(-val - 1));
                } else {
                    try self.writeUnsignedInt(@intCast(val));
                }
            }
        } else {
            // Float
            const f = std.fmt.parseFloat(f64, lexeme) catch return error.InvalidFloat;
            try self.writeFloat64(f);
        }
    }

    fn encodeMapCanonical(self: *Self, obj: []const json.Member) !void {
        // For canonical encoding, sort keys by:
        // 1. Length (shorter first)
        // 2. Lexicographic order

        // Create sorted indices
        const indices = try self.allocator.alloc(usize, obj.len);
        defer self.allocator.free(indices);
        for (indices, 0..) |*idx, i| {
            idx.* = i;
        }

        // Sort by canonical key order
        std.mem.sort(usize, indices, obj, struct {
            pub fn lessThan(context: []const json.Member, a: usize, b: usize) bool {
                const key_a = context[a].k;
                const key_b = context[b].k;

                // Shorter keys first
                if (key_a.len != key_b.len) {
                    return key_a.len < key_b.len;
                }

                // Lexicographic order
                return std.mem.lessThan(u8, key_a, key_b);
            }
        }.lessThan);

        try self.writeMapHeader(obj.len);
        for (indices) |idx| {
            try self.writeTextString(obj[idx].k);
            try self.encodeValue(obj[idx].v);
        }
    }

    // =========================================================================
    // Low-level encoding functions
    // =========================================================================

    fn writeInitialByte(self: *Self, major: MajorType, additional: u5) !void {
        const byte = (@as(u8, @intFromEnum(major)) << 5) | @as(u8, additional);
        try self.buffer.append(self.allocator, byte);
    }

    fn writeUnsignedInt(self: *Self, value: u64) !void {
        try self.writeTypedInt(.unsigned_int, value);
    }

    fn writeNegativeInt(self: *Self, value: u64) !void {
        try self.writeTypedInt(.negative_int, value);
    }

    fn writeTypedInt(self: *Self, major: MajorType, value: u64) !void {
        if (value <= 23) {
            try self.writeInitialByte(major, @intCast(value));
        } else if (value <= 0xFF) {
            try self.writeInitialByte(major, 24);
            try self.buffer.append(self.allocator, @intCast(value));
        } else if (value <= 0xFFFF) {
            try self.writeInitialByte(major, 25);
            try self.buffer.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(value))));
        } else if (value <= 0xFFFFFFFF) {
            try self.writeInitialByte(major, 26);
            try self.buffer.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(value))));
        } else {
            try self.writeInitialByte(major, 27);
            try self.buffer.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u64, value)));
        }
    }

    fn writeByteString(self: *Self, data: []const u8) !void {
        try self.writeTypedInt(.byte_string, data.len);
        try self.buffer.appendSlice(self.allocator, data);
    }

    fn writeTextString(self: *Self, text: []const u8) !void {
        try self.writeTypedInt(.text_string, text.len);
        try self.buffer.appendSlice(self.allocator, text);
    }

    fn writeArrayHeader(self: *Self, length: usize) !void {
        try self.writeTypedInt(.array, length);
    }

    fn writeMapHeader(self: *Self, length: usize) !void {
        try self.writeTypedInt(.map, length);
    }

    fn writeTag(self: *Self, tag: u64) !void {
        try self.writeTypedInt(.tagged, tag);
    }

    fn writeSimple(self: *Self, value: SimpleValue) !void {
        const v = @intFromEnum(value);
        if (v <= 23) {
            try self.writeInitialByte(.simple_or_float, @intCast(v));
        } else {
            try self.writeInitialByte(.simple_or_float, 24);
            try self.buffer.append(self.allocator, v);
        }
    }

    fn writeFloat16(self: *Self, value: f16) !void {
        try self.writeInitialByte(.simple_or_float, 25);
        try self.buffer.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @bitCast(value))));
    }

    fn writeFloat32(self: *Self, value: f32) !void {
        try self.writeInitialByte(.simple_or_float, 26);
        try self.buffer.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, @bitCast(value))));
    }

    fn writeFloat64(self: *Self, value: f64) !void {
        if (self.options.minimal_encoding) {
            // Try smaller representations
            const f32_val: f32 = @floatCast(value);
            if (@as(f64, f32_val) == value) {
                // Check f16
                const f16_val: f16 = @floatCast(f32_val);
                if (@as(f32, f16_val) == f32_val) {
                    return self.writeFloat16(f16_val);
                }
                return self.writeFloat32(f32_val);
            }
        }

        try self.writeInitialByte(.simple_or_float, 27);
        try self.buffer.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u64, @bitCast(value))));
    }

    /// Write an indefinite length array start
    pub fn writeIndefiniteArrayStart(self: *Self) !void {
        try self.writeInitialByte(.array, 31);
    }

    /// Write an indefinite length map start
    pub fn writeIndefiniteMapStart(self: *Self) !void {
        try self.writeInitialByte(.map, 31);
    }

    /// Write a break code (end of indefinite length item)
    pub fn writeBreak(self: *Self) !void {
        try self.writeSimple(.break_code);
    }
};

/// CBOR Decoder
pub const Decoder = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    data: []const u8,
    pos: usize,
    options: DecodeOptions,
    depth: u16,

    pub fn init(allocator: std.mem.Allocator, data: []const u8, options: DecodeOptions) Self {
        return .{
            .allocator = allocator,
            .data = data,
            .pos = 0,
            .options = options,
            .depth = 0,
        };
    }

    /// Decode CBOR to a JSON value
    pub fn decode(self: *Self) CborError!json.Value {
        return self.decodeValue();
    }

    fn decodeValue(self: *Self) CborError!json.Value {
        // NEW-001: enforce the recursion cap here, in the single entry point for
        // every value, and account depth on EVERY recursion -- not just for
        // arrays/maps. Tagged values and the chunks of indefinite-length
        // strings also re-enter decodeValue; counting only containers let those
        // paths recurse until the native stack overflowed. The matching
        // increments were removed from decodeArray/decodeMap so depth is counted
        // exactly once per level and the observable container limit is unchanged.
        if (self.depth > self.options.max_depth) {
            return error.NestingTooDeep;
        }
        self.depth += 1;
        defer self.depth -= 1;

        if (self.pos >= self.data.len) {
            return error.UnexpectedEof;
        }

        const initial = self.data[self.pos];
        self.pos += 1;

        const major: MajorType = @enumFromInt(initial >> 5);
        const additional: u5 = @truncate(initial);

        return switch (major) {
            .unsigned_int => self.decodeUnsignedInt(additional),
            .negative_int => self.decodeNegativeInt(additional),
            .byte_string => self.decodeByteString(additional),
            .text_string => self.decodeTextString(additional),
            .array => self.decodeArray(additional),
            .map => self.decodeMap(additional),
            .tagged => self.decodeTagged(additional),
            .simple_or_float => self.decodeSimpleOrFloat(additional),
        };
    }

    fn readBytes(self: *Self, count: usize) ![]const u8 {
        // Non-wrapping bounds check: `self.pos + count` can overflow when
        // `count` is attacker-controlled and large (see ASR-018). Confirm
        // `pos <= len` first, then compare against the remaining budget.
        if (self.pos > self.data.len or count > self.data.len - self.pos) {
            return error.UnexpectedEof;
        }
        const result = self.data[self.pos..][0..count];
        self.pos += count;
        return result;
    }

    /// Number of unconsumed bytes remaining in the input.
    fn remaining(self: *Self) usize {
        return if (self.pos <= self.data.len) self.data.len - self.pos else 0;
    }

    fn readArgument(self: *Self, additional: u5) !u64 {
        if (additional <= 23) {
            return additional;
        }
        switch (additional) {
            24 => {
                const bytes = try self.readBytes(1);
                return bytes[0];
            },
            25 => {
                const bytes = try self.readBytes(2);
                return std.mem.bigToNative(u16, @bitCast(bytes[0..2].*));
            },
            26 => {
                const bytes = try self.readBytes(4);
                return std.mem.bigToNative(u32, @bitCast(bytes[0..4].*));
            },
            27 => {
                const bytes = try self.readBytes(8);
                return std.mem.bigToNative(u64, @bitCast(bytes[0..8].*));
            },
            31 => return 0xFFFFFFFFFFFFFFFF, // Indefinite length marker
            else => return error.InvalidSimpleValue,
        }
    }

    fn decodeUnsignedInt(self: *Self, additional: u5) !json.Value {
        const value = try self.readArgument(additional);
        var buf: [32]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return error.IntegerOverflow;
        const lexeme = try self.allocator.dupe(u8, formatted);
        return .{ .num = .{
            .lexeme = lexeme,
            .sign = 1,
            .digits = lexeme,
            .exp10 = 0,
        } };
    }

    fn decodeNegativeInt(self: *Self, additional: u5) !json.Value {
        const value = try self.readArgument(additional);
        // CBOR negative int is -1 - value
        const actual: i128 = -1 - @as(i128, value);

        var buf: [40]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, "{d}", .{actual}) catch return error.IntegerOverflow;
        const lexeme = try self.allocator.dupe(u8, formatted);
        return .{ .num = .{
            .lexeme = lexeme,
            .sign = -1,
            .digits = if (lexeme[0] == '-') lexeme[1..] else lexeme,
            .exp10 = 0,
        } };
    }

    fn decodeByteString(self: *Self, additional: u5) !json.Value {
        const length = try self.readArgument(additional);

        if (length == 0xFFFFFFFFFFFFFFFF) {
            // Indefinite length
            if (!self.options.allow_indefinite) {
                return error.InvalidMajorType;
            }
            return self.decodeIndefiniteByteString();
        }

        if (length > self.options.max_string_len) {
            return error.StringTooLong;
        }

        const bytes = try self.readBytes(@intCast(length));
        // Encode as base64 for JSON representation
        const base64 = try encodeBase64(self.allocator, bytes);
        return .{ .str = base64 };
    }

    fn decodeIndefiniteByteString(self: *Self) !json.Value {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);

        while (true) {
            if (self.pos >= self.data.len) return error.UnexpectedEof;
            if (self.data[self.pos] == 0xFF) {
                self.pos += 1; // consume break
                break;
            }

            // RFC 8949 3.2.3: every chunk MUST be a definite-length byte string
            // of the same major type. Reject anything else (notably a nested
            // indefinite-length string) up front, before recursing -- this is
            // both spec-correctness and defense-in-depth against the NEW-001
            // unbounded-recursion DoS.
            try self.expectDefiniteStringChunk(.byte_string);

            const chunk = try self.decodeValue();
            if (chunk != .str) {
                freeValue(self.allocator, chunk);
                return error.InvalidString;
            }
            // Decode base64 back to bytes and append
            // For simplicity, we'll just concatenate the base64 strings
            try result.appendSlice(self.allocator, chunk.str);
            self.allocator.free(chunk.str);
        }

        return .{ .str = try result.toOwnedSlice(self.allocator) };
    }

    /// RFC 8949 3.2.3 guard for indefinite-length string chunks. Peeks (without
    /// consuming) the next item's initial byte and requires it to be a
    /// definite-length string of the expected major type. Rejects nested
    /// indefinite-length strings (additional == 31) and any other major type.
    fn expectDefiniteStringChunk(self: *Self, expected: MajorType) CborError!void {
        if (self.pos >= self.data.len) return error.UnexpectedEof;
        const initial = self.data[self.pos];
        const major: MajorType = @enumFromInt(initial >> 5);
        const additional: u5 = @truncate(initial);
        if (major != expected or additional == 31) {
            return error.InvalidString;
        }
    }

    fn decodeTextString(self: *Self, additional: u5) !json.Value {
        const length = try self.readArgument(additional);

        if (length == 0xFFFFFFFFFFFFFFFF) {
            // Indefinite length
            if (!self.options.allow_indefinite) {
                return error.InvalidMajorType;
            }
            return self.decodeIndefiniteTextString();
        }

        if (length > self.options.max_string_len) {
            return error.StringTooLong;
        }

        const bytes = try self.readBytes(@intCast(length));
        // Validate UTF-8
        if (!std.unicode.utf8ValidateSlice(bytes)) {
            return error.InvalidUtf8;
        }
        return .{ .str = try self.allocator.dupe(u8, bytes) };
    }

    fn decodeIndefiniteTextString(self: *Self) !json.Value {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);

        while (true) {
            if (self.pos >= self.data.len) return error.UnexpectedEof;
            if (self.data[self.pos] == 0xFF) {
                self.pos += 1; // consume break
                break;
            }

            // RFC 8949 3.2.3: every chunk MUST be a definite-length text string.
            // See decodeIndefiniteByteString for the rationale (NEW-001).
            try self.expectDefiniteStringChunk(.text_string);

            const chunk = try self.decodeValue();
            if (chunk != .str) {
                freeValue(self.allocator, chunk);
                return error.InvalidString;
            }
            try result.appendSlice(self.allocator, chunk.str);
            self.allocator.free(chunk.str);
        }

        return .{ .str = try result.toOwnedSlice(self.allocator) };
    }

    fn decodeArray(self: *Self, additional: u5) !json.Value {
        // NEW-001: depth is now accounted in decodeValue (the single recursion
        // entry point), so this no longer increments self.depth -- doing so here
        // would double-count and halve the effective limit.
        const length = try self.readArgument(additional);

        if (length == 0xFFFFFFFFFFFFFFFF) {
            // Indefinite length
            if (!self.options.allow_indefinite) {
                return error.InvalidMajorType;
            }
            return self.decodeIndefiniteArray();
        }

        // ASR-004: Reject a wire-declared length that cannot possibly be
        // satisfied by the remaining input. Every array element occupies at
        // least one byte, so a `length` larger than the bytes left is a lie
        // and would otherwise force a huge pre-allocation. Grow an ArrayList
        // as elements are actually decoded rather than pre-allocating from
        // the (attacker-controlled) prefix.
        if (length > self.remaining()) {
            return error.InvalidLength;
        }

        // ASR-012: free already-decoded elements on a late error.
        var items: std.ArrayList(json.Value) = .empty;
        errdefer {
            for (items.items) |item| {
                freeValue(self.allocator, item);
            }
            items.deinit(self.allocator);
        }

        try items.ensureTotalCapacityPrecise(self.allocator, @intCast(length));

        var i: u64 = 0;
        while (i < length) : (i += 1) {
            const item = try self.decodeValue();
            items.appendAssumeCapacity(item);
        }

        return .{ .arr = try items.toOwnedSlice(self.allocator) };
    }

    fn decodeIndefiniteArray(self: *Self) !json.Value {
        var items: std.ArrayList(json.Value) = .empty;
        errdefer {
            for (items.items) |item| {
                freeValue(self.allocator, item);
            }
            items.deinit(self.allocator);
        }

        while (true) {
            if (self.pos >= self.data.len) return error.UnexpectedEof;
            if (self.data[self.pos] == 0xFF) {
                self.pos += 1; // consume break
                break;
            }

            const item = try self.decodeValue();
            try items.append(self.allocator, item);
        }

        return .{ .arr = try items.toOwnedSlice(self.allocator) };
    }

    fn decodeMap(self: *Self, additional: u5) !json.Value {
        // NEW-001: depth is accounted in decodeValue now; see decodeArray.
        const length = try self.readArgument(additional);

        if (length == 0xFFFFFFFFFFFFFFFF) {
            // Indefinite length
            if (!self.options.allow_indefinite) {
                return error.InvalidMajorType;
            }
            return self.decodeIndefiniteMap();
        }

        // ASR-004: Each map pair occupies at least two bytes (a key item and
        // a value item), so a `length` larger than half the remaining input
        // is impossible. Reject before allocating to prevent unbounded
        // pre-allocation from the wire-declared length prefix.
        if (length > self.remaining() / 2) {
            return error.InvalidLength;
        }

        // ASR-012: free already-decoded members (and any dangling key) on a
        // late error.
        var members: std.ArrayList(json.Member) = .empty;
        errdefer {
            for (members.items) |m| {
                self.allocator.free(m.k);
                freeValue(self.allocator, m.v);
            }
            members.deinit(self.allocator);
        }

        try members.ensureTotalCapacityPrecise(self.allocator, @intCast(length));

        var i: u64 = 0;
        while (i < length) : (i += 1) {
            const key = try self.decodeValue();
            if (key != .str) {
                freeValue(self.allocator, key);
                return error.InvalidMajorType;
            }
            // Ensure the key is freed if decoding the value fails.
            errdefer self.allocator.free(key.str);

            const value = try self.decodeValue();
            members.appendAssumeCapacity(.{ .k = key.str, .v = value });
        }

        return .{ .obj = try members.toOwnedSlice(self.allocator) };
    }

    fn decodeIndefiniteMap(self: *Self) !json.Value {
        var members: std.ArrayList(json.Member) = .empty;
        errdefer {
            for (members.items) |m| {
                self.allocator.free(m.k);
                freeValue(self.allocator, m.v);
            }
            members.deinit(self.allocator);
        }

        while (true) {
            if (self.pos >= self.data.len) return error.UnexpectedEof;
            if (self.data[self.pos] == 0xFF) {
                self.pos += 1; // consume break
                break;
            }

            const key = try self.decodeValue();
            if (key != .str) {
                freeValue(self.allocator, key);
                return error.InvalidMajorType;
            }
            const value = try self.decodeValue();
            try members.append(self.allocator, .{ .k = key.str, .v = value });
        }

        return .{ .obj = try members.toOwnedSlice(self.allocator) };
    }

    fn decodeTagged(self: *Self, additional: u5) !json.Value {
        const tag = try self.readArgument(additional);

        // Skip self-describe tag
        if (tag == @intFromEnum(Tag.self_describe)) {
            return self.decodeValue();
        }

        // For other tags, just decode the value
        // A more complete implementation would handle specific tags
        const value = try self.decodeValue();

        // For now, return the value without tag information
        // JSON doesn't have a standard way to represent CBOR tags
        return value;
    }

    fn decodeSimpleOrFloat(self: *Self, additional: u5) !json.Value {
        switch (additional) {
            20 => return .{ .bool = false },
            21 => return .{ .bool = true },
            22 => return .null,
            23 => return .null, // undefined -> null in JSON
            24 => {
                const simple = try self.readBytes(1);
                if (simple[0] == 22) return .null;
                if (simple[0] == 23) return .null; // undefined
                return error.InvalidSimpleValue;
            },
            25 => {
                // Half-precision float
                const bytes = try self.readBytes(2);
                const bits = std.mem.bigToNative(u16, @bitCast(bytes[0..2].*));
                const f16_val: f16 = @bitCast(bits);
                const f64_val: f64 = f16_val;
                return floatToValue(self.allocator, f64_val);
            },
            26 => {
                // Single-precision float
                const bytes = try self.readBytes(4);
                const bits = std.mem.bigToNative(u32, @bitCast(bytes[0..4].*));
                const f32_val: f32 = @bitCast(bits);
                return floatToValue(self.allocator, f32_val);
            },
            27 => {
                // Double-precision float
                const bytes = try self.readBytes(8);
                const bits = std.mem.bigToNative(u64, @bitCast(bytes[0..8].*));
                const f64_val: f64 = @bitCast(bits);
                return floatToValue(self.allocator, f64_val);
            },
            31 => return error.UnexpectedBreak,
            else => return error.InvalidSimpleValue,
        }
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Convert a decoded CBOR float into a JSON number value.
///
/// Handles the NaN / +Infinity / -Infinity special cases (which `{d}`
/// formatting cannot round-trip into a valid JSON number lexeme) before
/// falling back to decimal formatting. Shared by both the non-streaming
/// `Decoder` and the `StreamingDecoder` so the two produce identical output
/// for the same bytes (QUAL-017).
fn floatToValue(allocator: std.mem.Allocator, value: anytype) CborError!json.Value {
    const f64_val: f64 = @floatCast(value);

    // Handle special values. The lexeme is heap-allocated like every other
    // decoded number so that freeValue() can free it uniformly -- returning a
    // string literal here would make freeValue() perform an invalid free.
    if (std.math.isNan(f64_val)) {
        const lexeme = try allocator.dupe(u8, "NaN");
        return .{ .num = .{ .lexeme = lexeme, .sign = 1, .digits = lexeme, .exp10 = 0 } };
    } else if (std.math.isInf(f64_val)) {
        if (f64_val < 0) {
            const lexeme = try allocator.dupe(u8, "-Infinity");
            return .{ .num = .{ .lexeme = lexeme, .sign = -1, .digits = lexeme[1..], .exp10 = 0 } };
        }
        const lexeme = try allocator.dupe(u8, "Infinity");
        return .{ .num = .{ .lexeme = lexeme, .sign = 1, .digits = lexeme, .exp10 = 0 } };
    }

    var buf: [32]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{d}", .{f64_val}) catch {
        return error.InvalidFloat;
    };
    const lexeme = try allocator.dupe(u8, formatted);
    return .{ .num = .{
        .lexeme = lexeme,
        .sign = if (f64_val < 0) @as(i8, -1) else @as(i8, 1),
        .digits = lexeme,
        .exp10 = 0,
    } };
}

fn freeValue(allocator: std.mem.Allocator, value: json.Value) void {
    switch (value) {
        .null, .bool => {},
        .num => |n| {
            // Free the lexeme if it was heap-allocated
            // We always allocate lexeme in CBOR decoding
            if (n.lexeme.len > 0) {
                allocator.free(n.lexeme);
            }
        },
        .str => |s| allocator.free(s),
        .arr => |arr| {
            for (arr) |item| {
                freeValue(allocator, item);
            }
            allocator.free(arr);
        },
        .obj => |obj| {
            for (obj) |m| {
                allocator.free(m.k);
                freeValue(allocator, m.v);
            }
            allocator.free(obj);
        },
    }
}

fn encodeBase64(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const output_len = ((data.len + 2) / 3) * 4;
    const output = try allocator.alloc(u8, output_len);
    errdefer allocator.free(output);

    var i: usize = 0;
    var j: usize = 0;

    while (i + 3 <= data.len) {
        const n = (@as(u32, data[i]) << 16) | (@as(u32, data[i + 1]) << 8) | data[i + 2];
        output[j] = alphabet[(n >> 18) & 0x3F];
        output[j + 1] = alphabet[(n >> 12) & 0x3F];
        output[j + 2] = alphabet[(n >> 6) & 0x3F];
        output[j + 3] = alphabet[n & 0x3F];
        i += 3;
        j += 4;
    }

    const remaining = data.len - i;
    if (remaining == 1) {
        const n = @as(u32, data[i]) << 16;
        output[j] = alphabet[(n >> 18) & 0x3F];
        output[j + 1] = alphabet[(n >> 12) & 0x3F];
        output[j + 2] = '=';
        output[j + 3] = '=';
    } else if (remaining == 2) {
        const n = (@as(u32, data[i]) << 16) | (@as(u32, data[i + 1]) << 8);
        output[j] = alphabet[(n >> 18) & 0x3F];
        output[j + 1] = alphabet[(n >> 12) & 0x3F];
        output[j + 2] = alphabet[(n >> 6) & 0x3F];
        output[j + 3] = '=';
    }

    return output;
}

// =============================================================================
// Convenience Functions
// =============================================================================

/// Encode a JSON value to CBOR bytes
pub fn encode(allocator: std.mem.Allocator, value: json.Value, options: EncodeOptions) ![]u8 {
    var encoder = Encoder.init(allocator, options);
    defer encoder.deinit();
    try encoder.encode(value);
    return encoder.toOwnedBytes();
}

/// Decode CBOR bytes to a JSON value
pub fn decode(allocator: std.mem.Allocator, data: []const u8, options: DecodeOptions) !json.Value {
    var decoder = Decoder.init(allocator, data, options);
    return decoder.decode();
}

/// Free a decoded JSON value
pub fn free(allocator: std.mem.Allocator, value: json.Value) void {
    freeValue(allocator, value);
}

// =============================================================================
// Diagnostic Notation
// =============================================================================

/// Convert CBOR to diagnostic notation string
pub fn toDiagnostic(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var decoder = Decoder.init(allocator, data, .{});
    const value = try decoder.decode();
    defer freeValue(allocator, value);

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    try valueToDiagnostic(&result, allocator, value);

    return result.toOwnedSlice(allocator);
}

fn valueToDiagnostic(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: json.Value) !void {
    switch (value) {
        .null => try output.appendSlice(allocator, "null"),
        .bool => |b| try output.appendSlice(allocator, if (b) "true" else "false"),
        .str => |s| {
            try output.append(allocator, '"');
            for (s) |c| {
                switch (c) {
                    '"' => try output.appendSlice(allocator, "\\\""),
                    '\\' => try output.appendSlice(allocator, "\\\\"),
                    '\n' => try output.appendSlice(allocator, "\\n"),
                    '\r' => try output.appendSlice(allocator, "\\r"),
                    '\t' => try output.appendSlice(allocator, "\\t"),
                    else => {
                        if (c < 0x20) {
                            try output.appendSlice(allocator, "\\u00");
                            const hex = "0123456789abcdef";
                            try output.append(allocator, hex[c >> 4]);
                            try output.append(allocator, hex[c & 0xF]);
                        } else {
                            try output.append(allocator, c);
                        }
                    },
                }
            }
            try output.append(allocator, '"');
        },
        .num => |n| try output.appendSlice(allocator, n.lexeme),
        .arr => |arr| {
            try output.append(allocator, '[');
            for (arr, 0..) |item, i| {
                if (i > 0) try output.appendSlice(allocator, ", ");
                try valueToDiagnostic(output, allocator, item);
            }
            try output.append(allocator, ']');
        },
        .obj => |obj| {
            try output.append(allocator, '{');
            for (obj, 0..) |m, i| {
                if (i > 0) try output.appendSlice(allocator, ", ");
                try output.append(allocator, '"');
                try output.appendSlice(allocator, m.k);
                try output.appendSlice(allocator, "\": ");
                try valueToDiagnostic(output, allocator, m.v);
            }
            try output.append(allocator, '}');
        },
    }
}

// =============================================================================
// Streaming Decoder
// =============================================================================

/// State for streaming CBOR decoder
pub const StreamingState = enum {
    /// Ready to receive data
    ready,
    /// Waiting for more data
    need_data,
    /// Decoding in progress
    decoding,
    /// Decoding completed successfully
    completed,
    /// Error occurred
    failed,
};

/// Result from streaming decode operation
pub const StreamingDecodeResult = union(enum) {
    /// Need more data to continue (minimum bytes needed)
    need_data: usize,
    /// Decoded a value
    value: json.Value,
    /// Error occurred
    err: CborError,
};

/// Streaming CBOR decoder for incremental decoding
/// Supports partial data input and yields values as they become available
pub const StreamingDecoder = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// Input buffer for streaming data
    buffer: std.ArrayList(u8),
    /// Current read position
    pos: usize,
    /// Decode options
    options: DecodeOptions,
    /// Current state
    state: StreamingState,
    /// Value stack for nested structures
    value_stack: std.ArrayList(StackEntry),
    /// Current nesting depth
    depth: u16,
    /// Total bytes consumed
    bytes_consumed: usize,

    /// Stack entry for nested containers
    const StackEntry = struct {
        /// Container type being built
        container_type: ContainerType,
        /// Items in array
        items: std.ArrayList(json.Value),
        /// Members in object
        members: std.ArrayList(json.Member),
        /// Expected item count (or max for indefinite)
        expected_count: u64,
        /// Current item count
        current_count: u64,
        /// Pending key for object
        pending_key: ?[]const u8,
        /// Is indefinite length
        indefinite: bool,

        const ContainerType = enum { array, object };

        fn deinit(self: *StackEntry, alloc: std.mem.Allocator) void {
            for (self.items.items) |item| {
                freeValue(alloc, item);
            }
            self.items.deinit(alloc);
            for (self.members.items) |m| {
                alloc.free(m.k);
                freeValue(alloc, m.v);
            }
            self.members.deinit(alloc);
            if (self.pending_key) |k| alloc.free(k);
        }
    };

    /// Initialize streaming decoder
    pub fn init(allocator: std.mem.Allocator, options: DecodeOptions) Self {
        return .{
            .allocator = allocator,
            .buffer = .empty,
            .pos = 0,
            .options = options,
            .state = .ready,
            .value_stack = .empty,
            .depth = 0,
            .bytes_consumed = 0,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
        for (self.value_stack.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.value_stack.deinit(self.allocator);
    }

    /// Add data to the decoder buffer
    pub fn addData(self: *Self, data: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, data);
        if (self.state == .need_data) {
            self.state = .ready;
        }
    }

    /// Get current buffer contents (for debugging)
    pub fn getBuffer(self: *Self) []const u8 {
        return self.buffer.items;
    }

    /// Get bytes consumed so far
    pub fn getBytesConsumed(self: *Self) usize {
        return self.bytes_consumed;
    }

    /// Reset the decoder for reuse
    pub fn reset(self: *Self) void {
        self.buffer.clearRetainingCapacity();
        self.pos = 0;
        for (self.value_stack.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.value_stack.clearRetainingCapacity();
        self.depth = 0;
        self.bytes_consumed = 0;
        self.state = .ready;
    }

    /// Decode the next value from the buffer
    pub fn decodeNext(self: *Self) StreamingDecodeResult {
        if (self.state == .failed) {
            return .{ .err = error.InvalidMajorType };
        }

        self.state = .decoding;

        // Check if we're in the middle of filling a container
        if (self.value_stack.items.len > 0) {
            return self.continueContainer();
        }

        // Try to decode a new top-level value
        const result = self.decodeValue() catch |err| {
            if (err == error.UnexpectedEof) {
                self.state = .need_data;
                return .{ .need_data = self.minBytesNeeded() };
            }
            self.state = .failed;
            return .{ .err = err };
        };

        // If we just started a container, continue filling it
        if (self.value_stack.items.len > 0) {
            return self.continueContainer();
        }

        // Top-level primitive value
        self.state = .completed;
        self.compactBuffer();
        return .{ .value = result };
    }

    /// Continue filling a container
    fn continueContainer(self: *Self) StreamingDecodeResult {
        while (self.value_stack.items.len > 0) {
            const entry = &self.value_stack.items[self.value_stack.items.len - 1];

            // Check if container is complete
            const complete = if (entry.indefinite) blk: {
                if (self.pos < self.buffer.items.len and self.buffer.items[self.pos] == 0xFF) {
                    self.pos += 1; // consume break
                    break :blk true;
                }
                break :blk false;
            } else entry.current_count >= entry.expected_count;

            if (complete) {
                // Container complete - build value
                self.depth -= 1;
                const value: json.Value = if (entry.container_type == .array)
                    .{ .arr = entry.items.toOwnedSlice(self.allocator) catch return .{ .err = error.OutOfMemory } }
                else
                    .{ .obj = entry.members.toOwnedSlice(self.allocator) catch return .{ .err = error.OutOfMemory } };

                _ = self.value_stack.pop();

                // Add to parent or return
                if (self.value_stack.items.len > 0) {
                    self.addToContainer(value) catch |err| {
                        return .{ .err = err };
                    };
                    continue;
                } else {
                    self.state = .completed;
                    self.compactBuffer();
                    return .{ .value = value };
                }
            }

            // Need more items - try to decode next element
            const elem = self.decodeValue() catch |err| {
                if (err == error.UnexpectedEof) {
                    self.state = .need_data;
                    return .{ .need_data = self.minBytesNeeded() };
                }
                self.state = .failed;
                return .{ .err = err };
            };

            // If we started a nested container, loop to fill it
            if (self.value_stack.items.len > 1) {
                continue;
            }

            // Add element to container
            self.addToContainer(elem) catch |err| {
                self.state = .failed;
                return .{ .err = err };
            };
        }

        // Should not reach here
        self.state = .failed;
        return .{ .err = error.InvalidMajorType };
    }

    /// Compact the buffer by removing consumed bytes
    fn compactBuffer(self: *Self) void {
        if (self.pos > 0 and self.pos <= self.buffer.items.len) {
            const remaining = self.buffer.items.len - self.pos;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[self.pos..]);
            }
            self.buffer.shrinkRetainingCapacity(remaining);
            self.bytes_consumed += self.pos;
            self.pos = 0;
        }
    }

    /// Get minimum bytes needed for next decode attempt
    fn minBytesNeeded(self: *Self) usize {
        // At minimum we need 1 byte for the header
        if (self.pos >= self.buffer.items.len) return 1;

        const initial = self.buffer.items[self.pos];
        const additional: u5 = @truncate(initial);

        // Calculate bytes needed based on additional info
        return switch (additional) {
            0...23 => 1,
            24 => 2,
            25 => 3,
            26 => 5,
            27 => 9,
            else => 1,
        };
    }

    fn decodeValue(self: *Self) CborError!json.Value {
        // NEW-001: the recursion cap is enforced here, the single entry point
        // for every value. Container nesting is accounted iteratively (see
        // decodeArray/decodeMap, which persist a depth increment that
        // continueContainer pops on completion). The one path that recurses on
        // the NATIVE stack is decodeTagged -> decodeValue; that recursion is now
        // counted there (see decodeTagged), so a deep tag chain hits this cap
        // and returns error.NestingTooDeep instead of overflowing the stack.
        if (self.depth > self.options.max_depth) {
            return error.NestingTooDeep;
        }

        if (self.pos >= self.buffer.items.len) {
            return error.UnexpectedEof;
        }

        const initial = self.buffer.items[self.pos];
        self.pos += 1;

        const major: MajorType = @enumFromInt(initial >> 5);
        const additional: u5 = @truncate(initial);

        return switch (major) {
            .unsigned_int => self.decodeUnsignedInt(additional),
            .negative_int => self.decodeNegativeInt(additional),
            .byte_string => self.decodeByteString(additional),
            .text_string => self.decodeTextString(additional),
            .array => self.decodeArray(additional),
            .map => self.decodeMap(additional),
            .tagged => self.decodeTagged(additional),
            .simple_or_float => self.decodeSimpleOrFloat(additional),
        };
    }

    fn readBytes(self: *Self, count: usize) ![]const u8 {
        // Non-wrapping bounds check (ASR-018): `self.pos + count` can
        // overflow when `count` is attacker-controlled and large.
        if (self.pos > self.buffer.items.len or count > self.buffer.items.len - self.pos) {
            return error.UnexpectedEof;
        }
        const result = self.buffer.items[self.pos..][0..count];
        self.pos += count;
        return result;
    }

    fn readArgument(self: *Self, additional: u5) !u64 {
        if (additional <= 23) {
            return additional;
        }
        switch (additional) {
            24 => {
                const bytes = try self.readBytes(1);
                return bytes[0];
            },
            25 => {
                const bytes = try self.readBytes(2);
                return std.mem.bigToNative(u16, @bitCast(bytes[0..2].*));
            },
            26 => {
                const bytes = try self.readBytes(4);
                return std.mem.bigToNative(u32, @bitCast(bytes[0..4].*));
            },
            27 => {
                const bytes = try self.readBytes(8);
                return std.mem.bigToNative(u64, @bitCast(bytes[0..8].*));
            },
            31 => return 0xFFFFFFFFFFFFFFFF,
            else => return error.InvalidSimpleValue,
        }
    }

    fn decodeUnsignedInt(self: *Self, additional: u5) !json.Value {
        const value = try self.readArgument(additional);
        var buf: [32]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return error.IntegerOverflow;
        const lexeme = try self.allocator.dupe(u8, formatted);
        return .{ .num = .{
            .lexeme = lexeme,
            .sign = 1,
            .digits = lexeme,
            .exp10 = 0,
        } };
    }

    fn decodeNegativeInt(self: *Self, additional: u5) !json.Value {
        const value = try self.readArgument(additional);
        const actual: i128 = -1 - @as(i128, value);
        var buf: [40]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, "{d}", .{actual}) catch return error.IntegerOverflow;
        const lexeme = try self.allocator.dupe(u8, formatted);
        return .{ .num = .{
            .lexeme = lexeme,
            .sign = -1,
            .digits = if (lexeme[0] == '-') lexeme[1..] else lexeme,
            .exp10 = 0,
        } };
    }

    fn decodeByteString(self: *Self, additional: u5) !json.Value {
        const length = try self.readArgument(additional);
        if (length == 0xFFFFFFFFFFFFFFFF) {
            return error.InvalidMajorType; // Streaming doesn't handle indefinite byte strings
        }
        if (length > self.options.max_string_len) {
            return error.StringTooLong;
        }
        const bytes = try self.readBytes(@intCast(length));
        const base64 = try encodeBase64(self.allocator, bytes);
        return .{ .str = base64 };
    }

    fn decodeTextString(self: *Self, additional: u5) !json.Value {
        const length = try self.readArgument(additional);
        if (length == 0xFFFFFFFFFFFFFFFF) {
            return error.InvalidMajorType; // Streaming doesn't handle indefinite text strings
        }
        if (length > self.options.max_string_len) {
            return error.StringTooLong;
        }
        const bytes = try self.readBytes(@intCast(length));
        const str = try self.allocator.dupe(u8, bytes);
        return .{ .str = str };
    }

    fn decodeArray(self: *Self, additional: u5) !json.Value {
        const count = try self.readArgument(additional);
        const indefinite = count == 0xFFFFFFFFFFFFFFFF;

        if (indefinite and !self.options.allow_indefinite) {
            return error.InvalidMajorType;
        }

        // Empty array
        if (!indefinite and count == 0) {
            return .{ .arr = &[_]json.Value{} };
        }

        // Push array container onto stack. The depth increment persists until
        // continueContainer pops this entry when the container completes.
        self.depth += 1;
        try self.value_stack.append(self.allocator, .{
            .container_type = .array,
            .items = .empty,
            .members = .empty,
            .expected_count = if (indefinite) 0xFFFFFFFFFFFFFFFF else count,
            .current_count = 0,
            .pending_key = null,
            .indefinite = indefinite,
        });

        // Return placeholder - will be replaced when container completes
        return .null;
    }

    fn decodeMap(self: *Self, additional: u5) !json.Value {
        const count = try self.readArgument(additional);
        const indefinite = count == 0xFFFFFFFFFFFFFFFF;

        if (indefinite and !self.options.allow_indefinite) {
            return error.InvalidMajorType;
        }

        // Empty object
        if (!indefinite and count == 0) {
            return .{ .obj = &[_]json.Member{} };
        }

        // Push object container onto stack
        self.depth += 1;
        try self.value_stack.append(self.allocator, .{
            .container_type = .object,
            .items = .empty,
            .members = .empty,
            .expected_count = if (indefinite) 0xFFFFFFFFFFFFFFFF else count,
            .current_count = 0,
            .pending_key = null,
            .indefinite = indefinite,
        });

        // Return placeholder
        return .null;
    }

    fn decodeTagged(self: *Self, additional: u5) !json.Value {
        _ = try self.readArgument(additional); // Skip tag
        // NEW-001: a tagged value recurses into decodeValue on the native stack
        // (it does not push onto value_stack the way containers do). Count this
        // recursion so a deep tag chain (e.g. 0xc0 repeated) trips the depth cap
        // in decodeValue and returns error.NestingTooDeep instead of overflowing
        // the stack. The increment brackets exactly the recursive call: if the
        // wrapped value is itself a container, that container's own increment
        // persists on value_stack and is popped later by continueContainer.
        self.depth += 1;
        defer self.depth -= 1;
        return self.decodeValue();
    }

    fn decodeSimpleOrFloat(self: *Self, additional: u5) !json.Value {
        // QUAL-017: keep this in lockstep with the non-streaming
        // Decoder.decodeSimpleOrFloat / floatToValue so both decoders yield
        // identical results for the same bytes (including the simple-value
        // case 24 and NaN/Infinity special-casing).
        switch (additional) {
            20 => return .{ .bool = false },
            21 => return .{ .bool = true },
            22 => return .null,
            23 => return .null, // undefined -> null
            24 => {
                const simple = try self.readBytes(1);
                if (simple[0] == 22) return .null;
                if (simple[0] == 23) return .null; // undefined
                return error.InvalidSimpleValue;
            },
            25 => {
                // Half-precision float
                const bytes = try self.readBytes(2);
                const bits = std.mem.bigToNative(u16, @bitCast(bytes[0..2].*));
                const f16_val: f16 = @bitCast(bits);
                const f64_val: f64 = f16_val;
                return floatToValue(self.allocator, f64_val);
            },
            26 => {
                // Single-precision float
                const bytes = try self.readBytes(4);
                const f32_val: f32 = @bitCast(std.mem.bigToNative(u32, @bitCast(bytes[0..4].*)));
                return floatToValue(self.allocator, f32_val);
            },
            27 => {
                // Double-precision float
                const bytes = try self.readBytes(8);
                const f64_val: f64 = @bitCast(std.mem.bigToNative(u64, @bitCast(bytes[0..8].*)));
                return floatToValue(self.allocator, f64_val);
            },
            31 => return error.UnexpectedBreak,
            else => return error.InvalidSimpleValue,
        }
    }

    fn addToContainer(self: *Self, value: json.Value) !void {
        var entry = &self.value_stack.items[self.value_stack.items.len - 1];

        if (entry.container_type == .array) {
            try entry.items.append(self.allocator, value);
            entry.current_count += 1;
        } else {
            // Object - alternate between key and value
            if (entry.pending_key == null) {
                // This is a key
                if (value != .str) {
                    freeValue(self.allocator, value);
                    return error.InvalidMajorType;
                }
                entry.pending_key = value.str;
            } else {
                // This is a value
                try entry.members.append(self.allocator, .{ .k = entry.pending_key.?, .v = value });
                entry.pending_key = null;
                entry.current_count += 1;
            }
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "encode unsigned integers" {
    const allocator = std.testing.allocator;

    // Small integers (0-23)
    {
        const value = json.Value{ .num = .{ .lexeme = "0", .sign = 1, .digits = "0", .exp10 = 0 } };
        const cbor = try encode(allocator, value, .{});
        defer allocator.free(cbor);
        try std.testing.expectEqual(@as(usize, 1), cbor.len);
        try std.testing.expectEqual(@as(u8, 0x00), cbor[0]);
    }

    {
        const value = json.Value{ .num = .{ .lexeme = "23", .sign = 1, .digits = "23", .exp10 = 0 } };
        const cbor = try encode(allocator, value, .{});
        defer allocator.free(cbor);
        try std.testing.expectEqual(@as(usize, 1), cbor.len);
        try std.testing.expectEqual(@as(u8, 0x17), cbor[0]);
    }

    // One-byte integer (24-255)
    {
        const value = json.Value{ .num = .{ .lexeme = "24", .sign = 1, .digits = "24", .exp10 = 0 } };
        const cbor = try encode(allocator, value, .{});
        defer allocator.free(cbor);
        try std.testing.expectEqual(@as(usize, 2), cbor.len);
        try std.testing.expectEqual(@as(u8, 0x18), cbor[0]);
        try std.testing.expectEqual(@as(u8, 24), cbor[1]);
    }
}

test "encode strings" {
    const allocator = std.testing.allocator;

    {
        const value = json.Value{ .str = "hello" };
        const cbor = try encode(allocator, value, .{});
        defer allocator.free(cbor);
        try std.testing.expectEqual(@as(usize, 6), cbor.len);
        try std.testing.expectEqual(@as(u8, 0x65), cbor[0]); // text string, length 5
        try std.testing.expectEqualStrings("hello", cbor[1..]);
    }
}

test "encode arrays" {
    const allocator = std.testing.allocator;

    var items = [_]json.Value{
        .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } },
        .{ .num = .{ .lexeme = "2", .sign = 1, .digits = "2", .exp10 = 0 } },
        .{ .num = .{ .lexeme = "3", .sign = 1, .digits = "3", .exp10 = 0 } },
    };

    const value = json.Value{ .arr = &items };
    const cbor = try encode(allocator, value, .{});
    defer allocator.free(cbor);

    try std.testing.expectEqual(@as(u8, 0x83), cbor[0]); // array, 3 items
    try std.testing.expectEqual(@as(u8, 0x01), cbor[1]); // 1
    try std.testing.expectEqual(@as(u8, 0x02), cbor[2]); // 2
    try std.testing.expectEqual(@as(u8, 0x03), cbor[3]); // 3
}

test "encode objects" {
    const allocator = std.testing.allocator;

    var members = [_]json.Member{
        .{ .k = "a", .v = .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } } },
    };

    const value = json.Value{ .obj = &members };
    const cbor = try encode(allocator, value, .{});
    defer allocator.free(cbor);

    try std.testing.expectEqual(@as(u8, 0xA1), cbor[0]); // map, 1 pair
}

test "encode booleans and null" {
    const allocator = std.testing.allocator;

    {
        const cbor = try encode(allocator, .{ .bool = true }, .{});
        defer allocator.free(cbor);
        try std.testing.expectEqual(@as(u8, 0xF5), cbor[0]); // true
    }

    {
        const cbor = try encode(allocator, .{ .bool = false }, .{});
        defer allocator.free(cbor);
        try std.testing.expectEqual(@as(u8, 0xF4), cbor[0]); // false
    }

    {
        const cbor = try encode(allocator, .null, .{});
        defer allocator.free(cbor);
        try std.testing.expectEqual(@as(u8, 0xF6), cbor[0]); // null
    }
}

test "decode unsigned integers" {
    const allocator = std.testing.allocator;

    // 0
    {
        const data = [_]u8{0x00};
        const value = try decode(allocator, &data, .{});
        defer free(allocator, value);
        try std.testing.expect(value == .num);
        try std.testing.expectEqualStrings("0", value.num.lexeme);
    }

    // 23
    {
        const data = [_]u8{0x17};
        const value = try decode(allocator, &data, .{});
        defer free(allocator, value);
        try std.testing.expect(value == .num);
        try std.testing.expectEqualStrings("23", value.num.lexeme);
    }

    // 24
    {
        const data = [_]u8{ 0x18, 24 };
        const value = try decode(allocator, &data, .{});
        defer free(allocator, value);
        try std.testing.expect(value == .num);
        try std.testing.expectEqualStrings("24", value.num.lexeme);
    }
}

test "decode strings" {
    const allocator = std.testing.allocator;

    const data = [_]u8{ 0x65, 'h', 'e', 'l', 'l', 'o' };
    const value = try decode(allocator, &data, .{});
    defer free(allocator, value);

    try std.testing.expect(value == .str);
    try std.testing.expectEqualStrings("hello", value.str);
}

test "decode arrays" {
    const allocator = std.testing.allocator;

    const data = [_]u8{ 0x83, 0x01, 0x02, 0x03 };
    const value = try decode(allocator, &data, .{});
    defer free(allocator, value);

    try std.testing.expect(value == .arr);
    try std.testing.expectEqual(@as(usize, 3), value.arr.len);
}

test "decode booleans and null" {
    const allocator = std.testing.allocator;

    {
        const data = [_]u8{0xF5};
        const value = try decode(allocator, &data, .{});
        try std.testing.expect(value == .bool);
        try std.testing.expect(value.bool == true);
    }

    {
        const data = [_]u8{0xF4};
        const value = try decode(allocator, &data, .{});
        try std.testing.expect(value == .bool);
        try std.testing.expect(value.bool == false);
    }

    {
        const data = [_]u8{0xF6};
        const value = try decode(allocator, &data, .{});
        try std.testing.expect(value == .null);
    }
}

test "round-trip" {
    const allocator = std.testing.allocator;

    var members = [_]json.Member{
        .{ .k = "name", .v = .{ .str = "Alice" } },
        .{ .k = "age", .v = .{ .num = .{ .lexeme = "30", .sign = 1, .digits = "30", .exp10 = 0 } } },
        .{ .k = "active", .v = .{ .bool = true } },
    };

    const original = json.Value{ .obj = &members };

    const cbor = try encode(allocator, original, .{});
    defer allocator.free(cbor);

    const decoded = try decode(allocator, cbor, .{});
    defer free(allocator, decoded);

    try std.testing.expect(decoded == .obj);
    try std.testing.expectEqual(@as(usize, 3), decoded.obj.len);
}

test "canonical encoding" {
    const allocator = std.testing.allocator;

    var members = [_]json.Member{
        .{ .k = "bb", .v = .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } } },
        .{ .k = "a", .v = .{ .num = .{ .lexeme = "2", .sign = 1, .digits = "2", .exp10 = 0 } } },
        .{ .k = "aaa", .v = .{ .num = .{ .lexeme = "3", .sign = 1, .digits = "3", .exp10 = 0 } } },
    };

    const value = json.Value{ .obj = &members };
    const cbor = try encode(allocator, value, .{ .canonical = true });
    defer allocator.free(cbor);

    // Canonical order: "a" (len 1), "bb" (len 2), "aaa" (len 3)
    const decoded = try decode(allocator, cbor, .{});
    defer free(allocator, decoded);

    try std.testing.expect(decoded == .obj);
    try std.testing.expectEqualStrings("a", decoded.obj[0].k);
    try std.testing.expectEqualStrings("bb", decoded.obj[1].k);
    try std.testing.expectEqualStrings("aaa", decoded.obj[2].k);
}

test "StreamingDecoder simple values" {
    const allocator = std.testing.allocator;

    // Test integer streaming
    {
        var decoder = StreamingDecoder.init(allocator, .{});
        defer decoder.deinit();

        // CBOR for integer 42 (0x18 0x2a)
        try decoder.addData(&[_]u8{ 0x18, 0x2a });

        const result = decoder.decodeNext();
        try std.testing.expect(result == .value);
        defer free(allocator, result.value);

        try std.testing.expect(result.value == .num);
    }

    // Test need_data handling
    {
        var decoder = StreamingDecoder.init(allocator, .{});
        defer decoder.deinit();

        // Only send header, not the value
        try decoder.addData(&[_]u8{0x18}); // Need 1 more byte

        const result = decoder.decodeNext();
        try std.testing.expect(result == .need_data);
    }
}

test "StreamingDecoder array" {
    const allocator = std.testing.allocator;

    var decoder = StreamingDecoder.init(allocator, .{});
    defer decoder.deinit();

    // CBOR for [1, 2, 3]: 0x83 0x01 0x02 0x03
    try decoder.addData(&[_]u8{ 0x83, 0x01, 0x02, 0x03 });

    const result = decoder.decodeNext();
    try std.testing.expect(result == .value);
    defer free(allocator, result.value);

    try std.testing.expect(result.value == .arr);
    try std.testing.expectEqual(@as(usize, 3), result.value.arr.len);
}

test "StreamingDecoder incremental" {
    const allocator = std.testing.allocator;

    var decoder = StreamingDecoder.init(allocator, .{});
    defer decoder.deinit();

    // CBOR for [1, 2] - send byte by byte
    // 0x82 0x01 0x02

    // First byte: array of 2 elements
    try decoder.addData(&[_]u8{0x82});
    var result = decoder.decodeNext();
    try std.testing.expect(result == .need_data);

    // Add first element
    try decoder.addData(&[_]u8{0x01});
    result = decoder.decodeNext();
    try std.testing.expect(result == .need_data);

    // Add second element - should complete
    try decoder.addData(&[_]u8{0x02});
    result = decoder.decodeNext();
    try std.testing.expect(result == .value);
    defer free(allocator, result.value);

    try std.testing.expect(result.value == .arr);
    try std.testing.expectEqual(@as(usize, 2), result.value.arr.len);
}

// =============================================================================
// Edge Case Tests
// =============================================================================

test "encode/decode empty string" {
    const allocator = std.testing.allocator;

    const value = json.Value{ .str = "" };
    const cbor = try encode(allocator, value, .{});
    defer allocator.free(cbor);

    const decoded = try decode(allocator, cbor, .{});
    defer free(allocator, decoded);

    try std.testing.expect(decoded == .str);
    try std.testing.expectEqualStrings("", decoded.str);
}

test "encode/decode nested empty containers" {
    const allocator = std.testing.allocator;

    // [[[]]]
    var inner_arr = [_]json.Value{};
    var mid_arr = [_]json.Value{.{ .arr = &inner_arr }};
    var outer_arr = [_]json.Value{.{ .arr = &mid_arr }};
    const value = json.Value{ .arr = &outer_arr };

    const cbor = try encode(allocator, value, .{});
    defer allocator.free(cbor);

    const decoded = try decode(allocator, cbor, .{});
    defer free(allocator, decoded);

    try std.testing.expect(decoded == .arr);
    try std.testing.expectEqual(@as(usize, 1), decoded.arr.len);
    try std.testing.expect(decoded.arr[0] == .arr);
}

test "encode/decode negative integers" {
    const allocator = std.testing.allocator;

    const value = json.Value{ .num = .{
        .lexeme = "-1",
        .sign = -1,
        .digits = "1",
        .exp10 = 0,
    } };

    const cbor = try encode(allocator, value, .{});
    defer allocator.free(cbor);

    const decoded = try decode(allocator, cbor, .{});
    defer free(allocator, decoded);

    try std.testing.expect(decoded == .num);
    try std.testing.expectEqual(@as(i8, -1), decoded.num.sign);
}

test "encode/decode unicode strings" {
    const allocator = std.testing.allocator;

    const value = json.Value{ .str = "日本語 🎉 emoji" };
    const cbor = try encode(allocator, value, .{});
    defer allocator.free(cbor);

    const decoded = try decode(allocator, cbor, .{});
    defer free(allocator, decoded);

    try std.testing.expect(decoded == .str);
    try std.testing.expectEqualStrings("日本語 🎉 emoji", decoded.str);
}

test "decode half-precision float" {
    const allocator = std.testing.allocator;

    // CBOR for half-precision 1.5: 0xf9 0x3e 0x00
    const cbor = &[_]u8{ 0xf9, 0x3e, 0x00 };
    const decoded = try decode(allocator, cbor, .{});
    defer free(allocator, decoded);

    try std.testing.expect(decoded == .num);
}

test "decode single-precision float" {
    const allocator = std.testing.allocator;

    // CBOR for single-precision 3.14: 0xfa followed by IEEE 754 bytes
    const cbor = &[_]u8{ 0xfa, 0x40, 0x48, 0xf5, 0xc3 };
    const decoded = try decode(allocator, cbor, .{});
    defer free(allocator, decoded);

    try std.testing.expect(decoded == .num);
}

test "encode with self-describe tag" {
    const allocator = std.testing.allocator;

    const value = json.Value{ .null = {} };
    const cbor = try encode(allocator, value, .{ .self_describe = true });
    defer allocator.free(cbor);

    // Should start with tag 55799 (0xd9 0xd9 0xf7)
    try std.testing.expect(cbor.len >= 3);
    try std.testing.expectEqual(@as(u8, 0xd9), cbor[0]);
}

// =============================================================================
// Security / DoS Regression Tests
// =============================================================================

// ASR-004: A definite-length array/map header may declare a count up to ~2^64.
// The decoder must reject a count that exceeds what the remaining input could
// possibly supply, BEFORE attempting any allocation proportional to that count.
// These payloads are only 5 bytes but claim ~100M elements; with the budget
// check they return error.InvalidLength promptly and allocate nothing.

test "ASR-004: array header claiming huge count with too few bytes errors" {
    const allocator = std.testing.allocator;

    // 0x9a = array, additional 26 (u32 count follows). 0x06000000 = 100663296.
    const data = [_]u8{ 0x9a, 0x06, 0x00, 0x00, 0x00 };
    try std.testing.expectError(error.InvalidLength, decode(allocator, &data, .{}));
}

test "ASR-004: map header claiming huge count with too few bytes errors" {
    const allocator = std.testing.allocator;

    // 0xba = map, additional 26 (u32 count follows). 0x06000000 = 100663296 pairs.
    const data = [_]u8{ 0xba, 0x06, 0x00, 0x00, 0x00 };
    try std.testing.expectError(error.InvalidLength, decode(allocator, &data, .{}));
}

test "ASR-004: array header with 64-bit count beyond input errors" {
    const allocator = std.testing.allocator;

    // 0x9b = array, additional 27 (u64 count follows). Count = 2^63.
    const data = [_]u8{ 0x9b, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expectError(error.InvalidLength, decode(allocator, &data, .{}));
}

test "ASR-004: map count larger than half remaining bytes errors" {
    const allocator = std.testing.allocator;

    // 0xb8 = map, additional 24 (1-byte count). Count = 3 pairs = needs >=6 bytes,
    // but only 2 follow. A map pair needs >=2 bytes so 3 > 2/2 is rejected.
    const data = [_]u8{ 0xb8, 0x03, 0x01, 0x02 };
    try std.testing.expectError(error.InvalidLength, decode(allocator, &data, .{}));
}

test "ASR-004: valid definite-length array/map still decode" {
    const allocator = std.testing.allocator;

    // Array [1,2,3]: header claims 3, exactly 3 bytes follow.
    {
        const data = [_]u8{ 0x83, 0x01, 0x02, 0x03 };
        const value = try decode(allocator, &data, .{});
        defer free(allocator, value);
        try std.testing.expect(value == .arr);
        try std.testing.expectEqual(@as(usize, 3), value.arr.len);
    }
    // Map {"a":1}: 0xa1, "a" (0x61 0x61), 1 (0x01).
    {
        const data = [_]u8{ 0xa1, 0x61, 0x61, 0x01 };
        const value = try decode(allocator, &data, .{});
        defer free(allocator, value);
        try std.testing.expect(value == .obj);
        try std.testing.expectEqual(@as(usize, 1), value.obj.len);
        try std.testing.expectEqualStrings("a", value.obj[0].k);
    }
}

// ASR-012: A definite-length array/map that decodes several valid entries and
// then hits a malformed one must free everything already decoded -- no leak.
// std.testing.allocator fails the test on any leak.

test "ASR-012: array with valid entries then malformed errors without leak" {
    const allocator = std.testing.allocator;

    // Array of 3: "aa" (0x62 0x61 0x61), "bb" (0x62 0x62 0x62), then a truncated
    // string header (0x62 claims 2 bytes but none follow) -> UnexpectedEof.
    const data = [_]u8{ 0x83, 0x62, 0x61, 0x61, 0x62, 0x62, 0x62, 0x62 };
    try std.testing.expectError(error.UnexpectedEof, decode(allocator, &data, .{}));
}

test "ASR-012: map with valid entries then malformed value errors without leak" {
    const allocator = std.testing.allocator;

    // Map of 2: key "a"(0x61 0x61) -> val "x"(0x61 0x78), then key "b"(0x61 0x62)
    // -> truncated string value (0x62 claims 2 bytes but only 1 follows).
    // The decoded first member, the second member's key, and the partial value
    // must all be freed on error.
    const data = [_]u8{ 0xa2, 0x61, 0x61, 0x61, 0x78, 0x61, 0x62, 0x62, 0x63 };
    try std.testing.expectError(error.UnexpectedEof, decode(allocator, &data, .{}));
}

test "ASR-012: map with non-string key after valid entry errors without leak" {
    const allocator = std.testing.allocator;

    // Map of 2: "a":1 valid, then an integer key (0x02) which is invalid for a
    // JSON object key. The already-decoded member must be freed.
    const data = [_]u8{ 0xa2, 0x61, 0x61, 0x01, 0x02, 0x03 };
    try std.testing.expectError(error.InvalidMajorType, decode(allocator, &data, .{}));
}

// ASR-018: Non-wrapping bounds check. A string header claiming a count that
// would overflow pos+count must report UnexpectedEof rather than wrapping.
// Configure a large max_string_len so the count passes the StringTooLong gate
// and reaches readBytes, exercising the non-wrapping form `count > len - pos`.

test "ASR-018: huge string length does not wrap bounds check" {
    const allocator = std.testing.allocator;

    // 0x5b = byte string, additional 27 (u64 length). Length = 2^63, far beyond
    // the 8 bytes of input. With max_string_len raised, this reaches readBytes
    // and must error (UnexpectedEof), not wrap pos+count.
    const data = [_]u8{ 0x5b, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expectError(
        error.UnexpectedEof,
        decode(allocator, &data, .{ .max_string_len = std.math.maxInt(usize) }),
    );
}

// QUAL-017: The streaming and non-streaming decoders must produce equivalent
// output for the same bytes. Previously the streaming decoder omitted the
// simple-value case 24 and the NaN/Infinity special-casing.

fn decodeStreamingOne(allocator: std.mem.Allocator, data: []const u8) !json.Value {
    var decoder = StreamingDecoder.init(allocator, .{});
    defer decoder.deinit();
    try decoder.addData(data);
    const result = decoder.decodeNext();
    return switch (result) {
        .value => |v| v,
        .err => |e| e,
        .need_data => error.UnexpectedEof,
    };
}

fn expectDecodersEquivalent(data: []const u8) !void {
    const allocator = std.testing.allocator;

    const a = try decode(allocator, data, .{});
    defer free(allocator, a);

    const b = try decodeStreamingOne(allocator, data);
    defer free(allocator, b);

    try std.testing.expect(a.eql(b));
}

test "QUAL-017: decoders agree on half/single/double floats" {
    // Half-precision 1.5: 0xf9 0x3e 0x00
    try expectDecodersEquivalent(&[_]u8{ 0xf9, 0x3e, 0x00 });
    // Single-precision 3.14: 0xfa 0x40 0x48 0xf5 0xc3
    try expectDecodersEquivalent(&[_]u8{ 0xfa, 0x40, 0x48, 0xf5, 0xc3 });
    // Double-precision 1.1: 0xfb 0x3f 0xf1 0x99 0x99 0x99 0x99 0x99 0x9a
    try expectDecodersEquivalent(&[_]u8{ 0xfb, 0x3f, 0xf1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9a });
}

test "QUAL-017: decoders agree on NaN and Infinity" {
    const allocator = std.testing.allocator;

    // Half-precision NaN: 0xf9 0x7e 0x00
    {
        const nan_bytes = [_]u8{ 0xf9, 0x7e, 0x00 };
        try expectDecodersEquivalent(&nan_bytes);
        const v = try decodeStreamingOne(allocator, &nan_bytes);
        defer free(allocator, v);
        try std.testing.expect(v == .num);
        try std.testing.expectEqualStrings("NaN", v.num.lexeme);
    }
    // Half-precision +Infinity: 0xf9 0x7c 0x00
    {
        const inf_bytes = [_]u8{ 0xf9, 0x7c, 0x00 };
        try expectDecodersEquivalent(&inf_bytes);
        const v = try decodeStreamingOne(allocator, &inf_bytes);
        defer free(allocator, v);
        try std.testing.expect(v == .num);
        try std.testing.expectEqualStrings("Infinity", v.num.lexeme);
    }
    // Half-precision -Infinity: 0xf9 0xfc 0x00
    {
        const ninf_bytes = [_]u8{ 0xf9, 0xfc, 0x00 };
        try expectDecodersEquivalent(&ninf_bytes);
        const v = try decodeStreamingOne(allocator, &ninf_bytes);
        defer free(allocator, v);
        try std.testing.expect(v == .num);
        try std.testing.expectEqualStrings("-Infinity", v.num.lexeme);
    }
}

test "QUAL-017: decoders agree on simple-value 24 (null/undefined)" {
    const allocator = std.testing.allocator;

    // 0xf8 0x16 = simple value 22 (null) encoded via the 1-byte form.
    const null_bytes = [_]u8{ 0xf8, 0x16 };
    try expectDecodersEquivalent(&null_bytes);

    const v = try decodeStreamingOne(allocator, &null_bytes);
    defer free(allocator, v);
    try std.testing.expect(v == .null);

    // 0xf8 0x17 = simple value 23 (undefined -> null).
    try expectDecodersEquivalent(&[_]u8{ 0xf8, 0x17 });
}

// NEW-001: Stack-overflow DoS on untrusted input. The depth cap is enforced in
// decodeValue, but the increment used to live only in decodeArray/decodeMap, so
// recursive paths that re-enter decodeValue without going through a container --
// tagged values (major type 6) and the chunks of indefinite-length byte/text
// strings -- bypassed the cap and recursed until the native stack overflowed
// (an uncatchable SIGABRT/SIGSEGV in Debug, ReleaseSafe and ReleaseFast).
//
// Fix: in the non-streaming Decoder the cap check + increment now live in
// decodeValue itself, so every recursion is counted exactly once. In the
// iterative StreamingDecoder the cap stays in decodeValue and the one
// native-stack recursion (decodeTagged) now counts depth. Additionally, per
// RFC 8949 3.2.3, indefinite-length string chunks that are not definite-length
// strings of the matching major type are rejected (error.InvalidString). These
// tests assert the abusive payloads now return a recoverable error rather than
// aborting the process, and that the observable container depth limit is
// unchanged.

test "NEW-001: nested array depth limit is unchanged (control)" {
    const allocator = std.testing.allocator;

    // A chain of N single-element definite arrays (0x81) wrapping a 0x00 value.
    // With max_depth = M the innermost value's decodeValue is entered at depth N,
    // so it succeeds for N <= M and fails (NestingTooDeep) for N == M + 1. This
    // boundary must hold identically before and after moving the depth accounting.
    const max_depth: u16 = 4;

    // Exactly max_depth nested arrays -> decodes fine.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendNTimes(allocator, 0x81, max_depth);
        try buf.append(allocator, 0x00);

        const value = try decode(allocator, buf.items, .{ .max_depth = max_depth });
        defer free(allocator, value);
        try std.testing.expect(value == .arr);
    }

    // One level deeper -> NestingTooDeep, no crash.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendNTimes(allocator, 0x81, max_depth + 1);
        try buf.append(allocator, 0x00);

        try std.testing.expectError(
            error.NestingTooDeep,
            decode(allocator, buf.items, .{ .max_depth = max_depth }),
        );
    }

    // Indefinite-array depth is still counted too (the original working control).
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendNTimes(allocator, 0x9f, max_depth + 2); // open N indefinite arrays
        try buf.appendNTimes(allocator, 0xff, max_depth + 2); // close them
        try std.testing.expectError(
            error.NestingTooDeep,
            decode(allocator, buf.items, .{ .max_depth = max_depth, .allow_indefinite = true }),
        );
    }
}

test "NEW-001: deep tag chain returns NestingTooDeep, not a crash" {
    const allocator = std.testing.allocator;

    const max_depth: u16 = 8;

    // A chain of (max_depth + 2) tag(0) bytes (0xc0) wrapping a small value.
    // Before the fix, decodeTagged re-entered decodeValue without counting
    // depth, so this recursed until the stack overflowed. Now each tag counts.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendNTimes(allocator, 0xc0, max_depth + 2);
    try buf.append(allocator, 0x00);

    try std.testing.expectError(
        error.NestingTooDeep,
        decode(allocator, buf.items, .{ .max_depth = max_depth }),
    );
}

test "NEW-001: deep streaming tag chain returns NestingTooDeep, not a crash" {
    const allocator = std.testing.allocator;

    const max_depth: u16 = 8;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendNTimes(allocator, 0xc0, max_depth + 2);
    try buf.append(allocator, 0x00);

    var decoder = StreamingDecoder.init(allocator, .{ .max_depth = max_depth });
    defer decoder.deinit();
    try decoder.addData(buf.items);

    const result = decoder.decodeNext();
    try std.testing.expect(result == .err);
    try std.testing.expectEqual(error.NestingTooDeep, result.err);
}

test "NEW-001: nested indefinite byte string is rejected, not a crash" {
    const allocator = std.testing.allocator;

    // RFC 8949 3.2.3: the chunks of an indefinite-length string must themselves
    // be definite-length strings of the same major type. A chunk that is itself
    // an indefinite-length byte string (0x5f) is malformed and -- before the fix
    // -- recursed without counting depth. Both the RFC check and the depth cap
    // now stop it.
    {
        // Outer indefinite byte string, then a nested indefinite byte string.
        const data = [_]u8{ 0x5f, 0x5f, 0xff, 0xff };
        try std.testing.expectError(
            error.InvalidString,
            decode(allocator, &data, .{ .allow_indefinite = true }),
        );
    }

    // A long chain of nested indefinite byte strings (the DoS payload shape) is
    // also rejected promptly rather than overflowing the stack.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendNTimes(allocator, 0x5f, 16);
        try std.testing.expectError(
            error.InvalidString,
            decode(allocator, buf.items, .{ .max_depth = 8, .allow_indefinite = true }),
        );
    }
}

test "NEW-001: nested indefinite text string is rejected, not a crash" {
    const allocator = std.testing.allocator;

    {
        // Outer indefinite text string, then a nested indefinite text string.
        const data = [_]u8{ 0x7f, 0x7f, 0xff, 0xff };
        try std.testing.expectError(
            error.InvalidString,
            decode(allocator, &data, .{ .allow_indefinite = true }),
        );
    }

    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendNTimes(allocator, 0x7f, 16);
        try std.testing.expectError(
            error.InvalidString,
            decode(allocator, buf.items, .{ .max_depth = 8, .allow_indefinite = true }),
        );
    }
}

test "NEW-001: valid tagged values and indefinite strings still decode" {
    const allocator = std.testing.allocator;

    // Tag 0 (standard date/time) wrapping a text string "2013-03-21T20:04:00Z".
    {
        const data = [_]u8{
            0xc0, 0x74, '2', '0', '1', '3', '-', '0', '3', '-',
            '2',  '1',  'T', '2', '0', ':', '0', '4', ':', '0',
            '0',  'Z',
        };
        const value = try decode(allocator, &data, .{});
        defer free(allocator, value);
        try std.testing.expect(value == .str);
        try std.testing.expectEqualStrings("2013-03-21T20:04:00Z", value.str);
    }

    // Tag 2 (positive bignum) wrapping a 2-byte byte string.
    {
        const data = [_]u8{ 0xc2, 0x42, 0x01, 0x00 };
        const value = try decode(allocator, &data, .{});
        defer free(allocator, value);
        try std.testing.expect(value == .str); // byte string -> base64
    }

    // Valid indefinite-length text string with two definite-length chunks:
    // 0x7f, "Hello"(0x65 ...), "World"(0x65 ...), 0xff -> "HelloWorld".
    {
        const data = [_]u8{
            0x7f, 0x65, 'H', 'e', 'l', 'l', 'o',
            0x65, 'W',  'o', 'r', 'l', 'd', 0xff,
        };
        const value = try decode(allocator, &data, .{ .allow_indefinite = true });
        defer free(allocator, value);
        try std.testing.expect(value == .str);
        try std.testing.expectEqualStrings("HelloWorld", value.str);
    }

    // Valid indefinite-length byte string with two definite-length chunks.
    {
        const data = [_]u8{ 0x5f, 0x42, 0x01, 0x02, 0x43, 0x03, 0x04, 0x05, 0xff };
        const value = try decode(allocator, &data, .{ .allow_indefinite = true });
        defer free(allocator, value);
        try std.testing.expect(value == .str); // base64-joined chunks
    }
}
