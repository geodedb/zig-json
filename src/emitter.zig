// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! JSON Emitter (Stringify)
//!
//! Provides two modes:
//! - stringify: Minified JSON output
//! - debugJson: Sorted keys, non-ASCII escaped for reproducible output
//!
//! Also provides a streaming Encoder for incremental JSON generation.

const std = @import("std");
const json = @import("json.zig");
const unicode = @import("unicode.zig");
const encode_mod = @import("encode.zig");

const Value = json.Value;
const Member = json.Member;

/// Maximum nesting depth enforced when emitting caller-built `Value` trees via
/// `stringify`/`debugJson`. Mirrors the parser's default `max_depth` (256) so a
/// programmatically-built deep or cyclic tree returns `error.DepthLimit`
/// instead of overflowing the stack (uncatchable abort). See ASR-016.
pub const default_max_depth: u16 = 256;

/// Streaming JSON encoder options
pub const EncoderOptions = struct {
    /// Indentation string (null for minified output)
    indent: ?[]const u8 = null,
    /// Escape forward slashes
    escape_slash: bool = false,
    /// Escape non-ASCII characters as \uXXXX
    escape_non_ascii: bool = false,
    /// Maximum nesting depth for `writeValue`. A caller-built `Value` tree that
    /// nests deeper than this returns `error.DepthLimit` rather than overflowing
    /// the stack. Bounds deep and cyclic trees alike. See ASR-016.
    max_depth: u16 = default_max_depth,
};

/// Streaming JSON encoder for incremental generation
/// Provides SAX-style JSON building with beginObject/endObject pattern
pub fn Encoder(comptime WriterType: type) type {
    return struct {
        writer: WriterType,
        options: EncoderOptions,
        /// Stack to track context (object/array) and first element status
        state_stack: std.ArrayList(State),
        allocator: std.mem.Allocator,
        depth: usize,

        const Self = @This();
        /// Errors:
        /// - WriteFailed: underlying writer failed
        /// - InvalidState: state-machine misuse (e.g. closing an unopened
        ///   container or a mismatched begin/end pair)
        /// - DepthLimit: nesting in a writeValue() tree exceeded max_depth
        const Error = error{ WriteFailed, InvalidState, DepthLimit } || std.mem.Allocator.Error;

        const StateKind = enum { object, array };
        const State = struct {
            kind: StateKind,
            first: bool,
        };

        /// Initialize a new streaming encoder
        pub fn init(allocator: std.mem.Allocator, writer: WriterType, options: EncoderOptions) Self {
            return .{
                .writer = writer,
                .options = options,
                .state_stack = .empty,
                .allocator = allocator,
                .depth = 0,
            };
        }

        /// Clean up encoder resources
        pub fn deinit(self: *Self) void {
            self.state_stack.deinit(self.allocator);
        }

        /// Begin a JSON object
        pub fn beginObject(self: *Self) Error!void {
            try self.writeCommaIfNeeded();
            try self.writer.writeByte('{');
            try self.state_stack.append(self.allocator, .{ .kind = .object, .first = true });
            self.depth += 1;
        }

        /// End the current JSON object
        pub fn endObject(self: *Self) Error!void {
            if (self.state_stack.items.len == 0) return error.InvalidState; // Closing an unopened container
            const last_idx = self.state_stack.items.len - 1;
            const state = self.state_stack.items[last_idx];
            if (state.kind != .object) return error.InvalidState; // Mismatched begin/end pair
            self.state_stack.items.len = last_idx;
            self.depth -= 1;
            if (!state.first) {
                try self.writeNewline();
            }
            try self.writer.writeByte('}');
            self.markNotFirst();
        }

        /// Begin a JSON array
        pub fn beginArray(self: *Self) Error!void {
            try self.writeCommaIfNeeded();
            try self.writer.writeByte('[');
            try self.state_stack.append(self.allocator, .{ .kind = .array, .first = true });
            self.depth += 1;
        }

        /// End the current JSON array
        pub fn endArray(self: *Self) Error!void {
            if (self.state_stack.items.len == 0) return error.InvalidState; // Closing an unopened container
            const last_idx = self.state_stack.items.len - 1;
            const state = self.state_stack.items[last_idx];
            if (state.kind != .array) return error.InvalidState; // Mismatched begin/end pair
            self.state_stack.items.len = last_idx;
            self.depth -= 1;
            if (!state.first) {
                try self.writeNewline();
            }
            try self.writer.writeByte(']');
            self.markNotFirst();
        }

        /// Write an object key (must be inside an object)
        pub fn writeKey(self: *Self, key: []const u8) Error!void {
            try self.writeCommaIfNeeded();
            try self.writeNewline();
            try self.writeStringValue(key);
            try self.writer.writeByte(':');
            if (self.options.indent != null) try self.writer.writeByte(' ');
            // Don't mark as not-first yet, the value will do that
            if (self.state_stack.items.len > 0) {
                self.state_stack.items[self.state_stack.items.len - 1].first = true;
            }
        }

        /// Write a null value
        pub fn writeNull(self: *Self) Error!void {
            try self.writeCommaIfNeeded();
            try self.writer.writeAll("null");
            self.markNotFirst();
        }

        /// Write a boolean value
        pub fn writeBool(self: *Self, value: bool) Error!void {
            try self.writeCommaIfNeeded();
            try self.writer.writeAll(if (value) "true" else "false");
            self.markNotFirst();
        }

        /// Write a string value
        pub fn writeString(self: *Self, value: []const u8) Error!void {
            try self.writeCommaIfNeeded();
            try self.writeStringValue(value);
            self.markNotFirst();
        }

        /// Write an integer value
        pub fn writeInt(self: *Self, value: anytype) Error!void {
            try self.writeCommaIfNeeded();
            try self.writer.print("{d}", .{value});
            self.markNotFirst();
        }

        /// Write a float value. NaN and the infinities, which JSON cannot
        /// express, are written as null, as encode() writes them by default.
        pub fn writeFloat(self: *Self, value: anytype) Error!void {
            try self.writeCommaIfNeeded();
            // SONNY-2417: classify in the value's own type (comptime_float as
            // f128) and render with encode()'s formatter, so a streamed float
            // is byte-for-byte what encode() writes at every width. Narrowing
            // to f64 wrote null for finite f80/f128 above floatMax(f64), and
            // "{d}" printed the invalid literal "(float)" for f80/f128
            // decimals longer than 347 bytes.
            const f = if (@TypeOf(value) == comptime_float) @as(f128, value) else value;
            if (std.math.isNan(f) or std.math.isInf(f)) {
                try self.writer.writeAll("null");
            } else {
                var buf: [encode_mod.float_lexeme_buf_len]u8 = undefined;
                try self.writer.writeAll(encode_mod.renderFloatLexeme(&buf, value));
            }
            self.markNotFirst();
        }

        /// Write a raw JSON value (must be valid JSON)
        pub fn writeRaw(self: *Self, raw: []const u8) Error!void {
            try self.writeCommaIfNeeded();
            try self.writer.writeAll(raw);
            self.markNotFirst();
        }

        /// Write a json.Value
        ///
        /// A caller-built `Value` tree that nests deeper than
        /// `options.max_depth` (or contains a cycle) returns `error.DepthLimit`
        /// instead of overflowing the stack. See ASR-016.
        pub fn writeValue(self: *Self, value: Value) Error!void {
            switch (value) {
                .null => try self.writeNull(),
                .bool => |b| try self.writeBool(b),
                .num => |n| try self.writeRaw(n.lexeme),
                .str => |s| try self.writeString(s),
                .arr => |arr| {
                    // self.depth tracks open-container nesting; beginArray has
                    // not yet incremented it, so guard before descending.
                    if (self.depth >= self.options.max_depth) return error.DepthLimit;
                    try self.beginArray();
                    for (arr) |item| {
                        try self.writeValue(item);
                    }
                    try self.endArray();
                },
                .obj => |obj| {
                    if (self.depth >= self.options.max_depth) return error.DepthLimit;
                    try self.beginObject();
                    for (obj) |m| {
                        try self.writeKey(m.k);
                        try self.writeValue(m.v);
                    }
                    try self.endObject();
                },
            }
        }

        // Internal helpers

        fn writeCommaIfNeeded(self: *Self) Error!void {
            if (self.state_stack.items.len > 0) {
                const state = &self.state_stack.items[self.state_stack.items.len - 1];
                if (!state.first) {
                    try self.writer.writeByte(',');
                }
            }
        }

        fn markNotFirst(self: *Self) void {
            if (self.state_stack.items.len > 0) {
                self.state_stack.items[self.state_stack.items.len - 1].first = false;
            }
        }

        fn writeNewline(self: *Self) Error!void {
            if (self.options.indent) |indent| {
                try self.writer.writeByte('\n');
                for (0..self.depth) |_| {
                    try self.writer.writeAll(indent);
                }
            }
        }

        fn writeStringValue(self: *Self, s: []const u8) Error!void {
            try self.writer.writeByte('"');

            var i: usize = 0;
            while (i < s.len) {
                const c = s[i];

                if (c == '"') {
                    try self.writer.writeAll("\\\"");
                    i += 1;
                } else if (c == '\\') {
                    try self.writer.writeAll("\\\\");
                    i += 1;
                } else if (c == '\n') {
                    try self.writer.writeAll("\\n");
                    i += 1;
                } else if (c == '\r') {
                    try self.writer.writeAll("\\r");
                    i += 1;
                } else if (c == '\t') {
                    try self.writer.writeAll("\\t");
                    i += 1;
                } else if (c == 0x08) {
                    try self.writer.writeAll("\\b");
                    i += 1;
                } else if (c == 0x0C) {
                    try self.writer.writeAll("\\f");
                    i += 1;
                } else if (c == '/' and self.options.escape_slash) {
                    try self.writer.writeAll("\\/");
                    i += 1;
                } else if (c < 0x20) {
                    try self.writer.writeAll("\\u00");
                    const hex = "0123456789ABCDEF";
                    try self.writer.writeByte(hex[(c >> 4) & 0xF]);
                    try self.writer.writeByte(hex[c & 0xF]);
                    i += 1;
                } else if (c >= 0x80 and self.options.escape_non_ascii) {
                    const seq_len = unicode.utf8SeqLen(c) catch {
                        try self.writer.writeByte(c);
                        i += 1;
                        continue;
                    };

                    if (i + seq_len > s.len) {
                        try self.writer.writeByte(c);
                        i += 1;
                        continue;
                    }

                    const seq = s[i..][0..seq_len];
                    const cp = unicode.decodeUtf8(seq) catch {
                        try self.writer.writeByte(c);
                        i += 1;
                        continue;
                    };

                    if (cp <= 0xFFFF) {
                        try self.writeUnicodeEscape(@intCast(cp));
                    } else {
                        const hi: u16 = @intCast(((cp - 0x10000) >> 10) + 0xD800);
                        const lo: u16 = @intCast(((cp - 0x10000) & 0x3FF) + 0xDC00);
                        try self.writeUnicodeEscape(hi);
                        try self.writeUnicodeEscape(lo);
                    }
                    i += seq_len;
                } else {
                    try self.writer.writeByte(c);
                    i += 1;
                }
            }

            try self.writer.writeByte('"');
        }

        fn writeUnicodeEscape(self: *Self, cp: u16) Error!void {
            const hex = "0123456789ABCDEF";
            try self.writer.writeAll("\\u");
            try self.writer.writeByte(hex[(cp >> 12) & 0xF]);
            try self.writer.writeByte(hex[(cp >> 8) & 0xF]);
            try self.writer.writeByte(hex[(cp >> 4) & 0xF]);
            try self.writer.writeByte(hex[cp & 0xF]);
        }
    };
}

/// Create a streaming encoder for any writer type
pub fn encoder(allocator: std.mem.Allocator, writer: anytype, options: EncoderOptions) Encoder(@TypeOf(writer)) {
    return Encoder(@TypeOf(writer)).init(allocator, writer, options);
}

/// Stringify a value to minified JSON
///
/// Returns `error.DepthLimit` if the `Value` tree nests deeper than
/// `default_max_depth`. This bounds deep or cyclic caller-built trees so they
/// fail with a catchable error instead of overflowing the stack. See ASR-016.
pub fn stringify(a: std.mem.Allocator, v: Value) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try emitValue(a, &buf, v, false, 0);
    return buf.toOwnedSlice(a);
}

/// Debug JSON: sorted keys, non-ASCII escaped
///
/// Returns `error.DepthLimit` if the `Value` tree nests deeper than
/// `default_max_depth` (see `stringify`).
pub fn debugJson(a: std.mem.Allocator, v: Value) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try emitValue(a, &buf, v, true, 0);
    return buf.toOwnedSlice(a);
}

fn emitValue(a: std.mem.Allocator, buf: *std.ArrayList(u8), v: Value, debug_mode: bool, depth: u16) !void {
    switch (v) {
        .null => try buf.appendSlice(a, "null"),
        .bool => |b| try buf.appendSlice(a, if (b) "true" else "false"),
        .num => |n| try buf.appendSlice(a, n.lexeme),
        .str => |s| try emitString(a, buf, s, debug_mode),
        .arr => |arr| {
            // Bound recursion over runtime-sized, caller-built trees (and
            // cyclic pointer graphs) before descending. See ASR-016.
            if (depth >= default_max_depth) return error.DepthLimit;
            try buf.append(a, '[');
            for (arr, 0..) |item, i| {
                if (i > 0) try buf.append(a, ',');
                try emitValue(a, buf, item, debug_mode, depth + 1);
            }
            try buf.append(a, ']');
        },
        .obj => |obj| {
            if (depth >= default_max_depth) return error.DepthLimit;
            try buf.append(a, '{');

            if (debug_mode) {
                // Sort keys for reproducible output
                const sorted = try a.alloc(Member, obj.len);
                defer a.free(sorted);
                @memcpy(sorted, obj);

                std.mem.sort(Member, sorted, {}, struct {
                    fn lessThan(_: void, lhs: Member, rhs: Member) bool {
                        return std.mem.order(u8, lhs.k, rhs.k) == .lt;
                    }
                }.lessThan);

                for (sorted, 0..) |m, i| {
                    if (i > 0) try buf.append(a, ',');
                    try emitString(a, buf, m.k, debug_mode);
                    try buf.append(a, ':');
                    try emitValue(a, buf, m.v, debug_mode, depth + 1);
                }
            } else {
                for (obj, 0..) |m, i| {
                    if (i > 0) try buf.append(a, ',');
                    try emitString(a, buf, m.k, debug_mode);
                    try buf.append(a, ':');
                    try emitValue(a, buf, m.v, debug_mode, depth + 1);
                }
            }

            try buf.append(a, '}');
        },
    }
}

fn emitString(a: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8, escape_non_ascii: bool) !void {
    try buf.append(a, '"');

    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];

        if (c == '"') {
            try buf.appendSlice(a, "\\\"");
            i += 1;
        } else if (c == '\\') {
            try buf.appendSlice(a, "\\\\");
            i += 1;
        } else if (c == '\n') {
            try buf.appendSlice(a, "\\n");
            i += 1;
        } else if (c == '\r') {
            try buf.appendSlice(a, "\\r");
            i += 1;
        } else if (c == '\t') {
            try buf.appendSlice(a, "\\t");
            i += 1;
        } else if (c == 0x08) {
            try buf.appendSlice(a, "\\b");
            i += 1;
        } else if (c == 0x0C) {
            try buf.appendSlice(a, "\\f");
            i += 1;
        } else if (c < 0x20) {
            // Control characters
            try buf.appendSlice(a, "\\u00");
            const hex = "0123456789ABCDEF";
            try buf.append(a, hex[(c >> 4) & 0xF]);
            try buf.append(a, hex[c & 0xF]);
            i += 1;
        } else if (c >= 0x80 and escape_non_ascii) {
            // Non-ASCII: escape as \uXXXX
            const seq_len = unicode.utf8SeqLen(c) catch {
                try buf.append(a, c);
                i += 1;
                continue;
            };

            if (i + seq_len > s.len) {
                try buf.append(a, c);
                i += 1;
                continue;
            }

            const seq = s[i..][0..seq_len];
            const cp = unicode.decodeUtf8(seq) catch {
                try buf.append(a, c);
                i += 1;
                continue;
            };

            if (cp <= 0xFFFF) {
                try emitUnicodeEscape(a, buf, @intCast(cp));
            } else {
                // Surrogate pair for characters > U+FFFF
                const hi: u16 = @intCast(((cp - 0x10000) >> 10) + 0xD800);
                const lo: u16 = @intCast(((cp - 0x10000) & 0x3FF) + 0xDC00);
                try emitUnicodeEscape(a, buf, hi);
                try emitUnicodeEscape(a, buf, lo);
            }
            i += seq_len;
        } else {
            try buf.append(a, c);
            i += 1;
        }
    }

    try buf.append(a, '"');
}

fn emitUnicodeEscape(a: std.mem.Allocator, buf: *std.ArrayList(u8), cp: u16) !void {
    const hex = "0123456789ABCDEF";
    try buf.appendSlice(a, "\\u");
    try buf.append(a, hex[(cp >> 12) & 0xF]);
    try buf.append(a, hex[(cp >> 8) & 0xF]);
    try buf.append(a, hex[(cp >> 4) & 0xF]);
    try buf.append(a, hex[cp & 0xF]);
}

test "stringify null" {
    const result = try stringify(std.testing.allocator, .null);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("null", result);
}

test "stringify bool" {
    const result = try stringify(std.testing.allocator, .{ .bool = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("true", result);
}

test "stringify string" {
    const result = try stringify(std.testing.allocator, .{ .str = "hello" });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\"hello\"", result);
}

test "stringify string with escapes" {
    const result = try stringify(std.testing.allocator, .{ .str = "a\nb" });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\"a\\nb\"", result);
}

test "stringify array" {
    var items = [_]Value{ .{ .bool = true }, .{ .bool = false } };
    const result = try stringify(std.testing.allocator, .{ .arr = &items });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("[true,false]", result);
}

test "stringify empty object" {
    var members = [_]Member{};
    const result = try stringify(std.testing.allocator, .{ .obj = &members });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{}", result);
}

test "debugJson sorts keys" {
    var members = [_]Member{
        .{ .k = "z", .v = .{ .bool = true } },
        .{ .k = "a", .v = .{ .bool = false } },
    };
    const result = try debugJson(std.testing.allocator, .{ .obj = &members });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"a\":false,\"z\":true}", result);
}

test "debugJson escapes non-ascii" {
    const result = try debugJson(std.testing.allocator, .{ .str = "\xC2\xA9" }); // copyright symbol
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\"\\u00A9\"", result);
}

test "debugJson escapes emoji as surrogate pair" {
    const result = try debugJson(std.testing.allocator, .{ .str = "\xF0\x9F\x98\x80" }); // grinning face
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\"\\uD83D\\uDE00\"", result);
}

/// Build a `Value` tree of nested single-element arrays `[[[...x...]]]` of the
/// given depth (depth == 0 returns the leaf). Caller owns the returned tree and
/// must free it with `freeNestedArray`.
fn buildNestedArray(a: std.mem.Allocator, depth: usize, leaf: Value) !Value {
    var v = leaf;
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        const arr = try a.alloc(Value, 1);
        arr[0] = v;
        v = .{ .arr = arr };
    }
    return v;
}

fn freeNestedArray(a: std.mem.Allocator, v: Value) void {
    switch (v) {
        .arr => |arr| {
            for (arr) |item| freeNestedArray(a, item);
            a.free(arr);
        },
        else => {},
    }
}

test "stringify deeply nested array returns DepthLimit (no crash)" {
    // ASR-016: a 100000-deep caller-built tree must return a catchable error,
    // not overflow the stack.
    const a = std.testing.allocator;
    const v = try buildNestedArray(a, 100_000, .null);
    defer freeNestedArray(a, v);

    try std.testing.expectError(error.DepthLimit, stringify(a, v));
}

test "debugJson deeply nested array returns DepthLimit (no crash)" {
    const a = std.testing.allocator;
    const v = try buildNestedArray(a, 100_000, .null);
    defer freeNestedArray(a, v);

    try std.testing.expectError(error.DepthLimit, debugJson(a, v));
}

test "stringify within depth limit still serializes" {
    const a = std.testing.allocator;
    // 200 levels of nesting is comfortably under default_max_depth (256).
    const v = try buildNestedArray(a, 200, .{ .bool = true });
    defer freeNestedArray(a, v);

    const result = try stringify(a, v);
    defer a.free(result);

    // 200 '[' then "true" then 200 ']'.
    try std.testing.expectEqual(@as(usize, 200 + 4 + 200), result.len);
    try std.testing.expect(std.mem.indexOf(u8, result, "true") != null);
}

test "streaming encoder writeValue deeply nested returns DepthLimit (no crash)" {
    const a = std.testing.allocator;
    const v = try buildNestedArray(a, 100_000, .null);
    defer freeNestedArray(a, v);

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();

    var enc = encoder(a, &aw.writer, .{});
    defer enc.deinit();

    try std.testing.expectError(error.DepthLimit, enc.writeValue(v));
}

test "streaming encoder writeValue within depth limit serializes" {
    const a = std.testing.allocator;
    const v = try buildNestedArray(a, 100, .{ .bool = true });
    defer freeNestedArray(a, v);

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();

    var enc = encoder(a, &aw.writer, .{});
    defer enc.deinit();

    try enc.writeValue(v);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "true") != null);
}

test "streaming encoder simple object" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var enc = encoder(std.testing.allocator, &aw.writer, .{});
    defer enc.deinit();

    try enc.beginObject();
    try enc.writeKey("name");
    try enc.writeString("Alice");
    try enc.writeKey("age");
    try enc.writeInt(@as(u32, 30));
    try enc.endObject();

    try std.testing.expectEqualStrings("{\"name\":\"Alice\",\"age\":30}", aw.written());
}

test "streaming encoder nested structure" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var enc = encoder(std.testing.allocator, &aw.writer, .{});
    defer enc.deinit();

    try enc.beginObject();
    try enc.writeKey("user");
    try enc.beginObject();
    try enc.writeKey("id");
    try enc.writeInt(@as(u32, 1));
    try enc.endObject();
    try enc.writeKey("items");
    try enc.beginArray();
    try enc.writeString("a");
    try enc.writeString("b");
    try enc.endArray();
    try enc.endObject();

    try std.testing.expectEqualStrings("{\"user\":{\"id\":1},\"items\":[\"a\",\"b\"]}", aw.written());
}

test "streaming encoder with indent" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var enc = encoder(std.testing.allocator, &aw.writer, .{ .indent = "  " });
    defer enc.deinit();

    try enc.beginObject();
    try enc.writeKey("name");
    try enc.writeString("test");
    try enc.endObject();

    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "  ") != null);
}

test "streaming encoder array values" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var enc = encoder(std.testing.allocator, &aw.writer, .{});
    defer enc.deinit();

    try enc.beginArray();
    try enc.writeNull();
    try enc.writeBool(true);
    try enc.writeInt(@as(i32, 42));
    try enc.writeFloat(@as(f64, 3.14));
    try enc.endArray();

    try std.testing.expectEqualStrings("[null,true,42,3.14]", aw.written());
}

test "streaming encoder writeValue" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var enc = encoder(std.testing.allocator, &aw.writer, .{});
    defer enc.deinit();

    var members = [_]Member{
        .{ .k = "key", .v = .{ .str = "value" } },
    };

    try enc.writeValue(.{ .obj = &members });

    try std.testing.expectEqualStrings("{\"key\":\"value\"}", aw.written());
}

test "streaming encoder endObject on empty stack returns InvalidState" {
    // QUAL-014: state-machine misuse must be distinguishable from OutOfMemory.
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var enc = encoder(std.testing.allocator, &aw.writer, .{});
    defer enc.deinit();

    try std.testing.expectError(error.InvalidState, enc.endObject());
}

test "streaming encoder endArray on empty stack returns InvalidState" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var enc = encoder(std.testing.allocator, &aw.writer, .{});
    defer enc.deinit();

    try std.testing.expectError(error.InvalidState, enc.endArray());
}

test "streaming encoder mismatched container end returns InvalidState" {
    // Open an object but try to close it as an array (and vice versa).
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var enc = encoder(std.testing.allocator, &aw.writer, .{});
    defer enc.deinit();

    try enc.beginObject();
    try std.testing.expectError(error.InvalidState, enc.endArray());

    var aw2: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw2.deinit();

    var enc2 = encoder(std.testing.allocator, &aw2.writer, .{});
    defer enc2.deinit();

    try enc2.beginArray();
    try std.testing.expectError(error.InvalidState, enc2.endObject());
}

/// SONNY-2417: the streaming encoder's output for a lone float.
fn streamFloat(a: std.mem.Allocator, value: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    var enc = encoder(a, &aw.writer, .{});
    defer enc.deinit();
    try enc.writeFloat(value);
    return a.dupe(u8, aw.written());
}

// SONNY-2417: writeFloat classified NaN/Inf on an f64 narrowing of the value,
// and @floatCast to f64 turns every finite f80/f128 above floatMax(f64) into
// an infinity, so the streaming encoder wrote null for them. It must write
// the number encode() writes, which json.parse accepts and which parses back
// to the exact value.
test "SONNY-2417 streaming: writeFloat of f80/f128 above floatMax(f64) is a JSON number" {
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
            const encoded = try json.encode(a, v, .{});
            defer a.free(encoded);
            const streamed = try streamFloat(a, v);
            defer a.free(streamed);
            try std.testing.expectEqualStrings(encoded, streamed);

            var perr = json.ParseError.init();
            var doc = try json.parse(a, streamed, .{}, &perr);
            defer doc.deinit();
            try std.testing.expect(doc.root == .num);
            const back = try std.fmt.parseFloat(T, streamed);
            try std.testing.expectEqual(@as(Bits, @bitCast(v)), @as(Bits, @bitCast(back)));
        }
    }
}

// SONNY-2417: writeFloat must write every float exactly as encode() does, at
// every width: ordinary values; the extremes, including f80/f128 decimals
// longer than 347 bytes, which "{d}" printed as the invalid literal
// "(float)"; and null for NaN and the infinities.
test "SONNY-2417 streaming: writeFloat matches encode byte-for-byte for every float width" {
    const a = std.testing.allocator;
    inline for (.{ f16, f32, f64, f80, f128 }) |T| {
        const M = std.math;
        const values = [_]T{
            M.floatTrueMin(T), -M.floatTrueMin(T), M.floatMin(T), M.floatEps(T), 1.0 / 3.0,
            3.25,              1.0,                0.0,           -@as(T, 0.0),  0.1,
            M.floatMax(T),     -M.floatMax(T),     M.nan(T),      M.inf(T),      -M.inf(T),
        };
        for (values) |v| {
            const encoded = try json.encode(a, v, .{});
            defer a.free(encoded);
            const streamed = try streamFloat(a, v);
            defer a.free(streamed);
            try std.testing.expectEqualStrings(encoded, streamed);
        }
    }
    inline for (.{ 0.1, 1.0 / 3.0, 1e400, -1e400 }) |v| {
        const encoded = try json.encode(a, v, .{});
        defer a.free(encoded);
        const streamed = try streamFloat(a, v);
        defer a.free(streamed);
        try std.testing.expectEqualStrings(encoded, streamed);
    }
}
