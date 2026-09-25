// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Streaming JSON Tokenizer
//!
//! Provides memory-efficient token-by-token JSON parsing without
//! building a full Value tree. Useful for large JSON documents
//! or when you only need to extract specific values.
//!
//! Features:
//! - Iterator-based API for streaming access
//! - Low memory overhead (no tree construction)
//! - Precise error location reporting
//! - Skip functionality for efficient value traversal

const std = @import("std");
const unicode = @import("unicode.zig");
const json = @import("json.zig");
const number_mod = @import("number.zig");

/// Token types returned by the tokenizer
pub const TokenType = enum {
    object_start, // {
    object_end, // }
    array_start, // [
    array_end, // ]
    string, // "..."
    number, // numeric literal
    true_literal, // true
    false_literal, // false
    null_literal, // null
    colon, // :
    comma, // ,
    eof, // end of input
};

/// A single JSON token
pub const Token = struct {
    type: TokenType,
    /// For string tokens: the decoded string content (without quotes)
    /// For number tokens: the raw lexeme
    /// For other tokens: the literal characters
    bytes: []const u8,
    /// Line number (1-indexed)
    line: u32,
    /// Column number (1-indexed)
    col: u32,
    /// Byte offset in input. Widened to usize so inputs at or beyond 4 GiB do
    /// not truncate or panic on the offset cast.
    offset: usize,
};

/// Tokenizer error codes
pub const TokenizerError = error{
    UnexpectedEof,
    UnexpectedToken,
    InvalidUtf8,
    InvalidString,
    InvalidEscape,
    InvalidSurrogate,
    InvalidNumber,
    /// Nesting depth exceeded options.max_depth
    DepthLimit,
    /// String length exceeded options.max_string_len
    StringTooLong,
    OutOfMemory,
};

/// Tokenizer options
pub const TokenizerOptions = struct {
    /// Maximum nesting depth for skipValue
    max_depth: u16 = 256,
    /// Maximum string length to decode
    max_string_len: usize = 1024 * 1024,
};

/// Streaming JSON tokenizer
pub const Tokenizer = struct {
    input: []const u8,
    pos: usize,
    line: u32,
    col: u32,
    opts: TokenizerOptions,
    /// Allocator for string decoding
    allocator: std.mem.Allocator,
    /// Temporary storage for decoded strings
    string_buffer: std.ArrayList(u8),
    /// Peeked token (if any)
    peeked: ?Token,

    /// Initialize a new tokenizer
    pub fn init(allocator: std.mem.Allocator, input: []const u8, opts: TokenizerOptions) Tokenizer {
        return .{
            .input = input,
            .pos = 0,
            .line = 1,
            .col = 1,
            .opts = opts,
            .allocator = allocator,
            .string_buffer = .empty,
            .peeked = null,
        };
    }

    /// Clean up tokenizer resources
    pub fn deinit(self: *Tokenizer) void {
        self.string_buffer.deinit(self.allocator);
    }

    /// Get the next token
    pub fn next(self: *Tokenizer) TokenizerError!Token {
        // Return peeked token if available
        if (self.peeked) |token| {
            self.peeked = null;
            return token;
        }

        self.skipWhitespace();

        if (self.pos >= self.input.len) {
            return Token{
                .type = .eof,
                .bytes = "",
                .line = self.line,
                .col = self.col,
                .offset = self.pos,
            };
        }

        const start_line = self.line;
        const start_col = self.col;
        const start_pos = self.pos;
        const c = self.input[self.pos];

        return switch (c) {
            '{' => {
                self.advance();
                return Token{ .type = .object_start, .bytes = "{", .line = start_line, .col = start_col, .offset = start_pos };
            },
            '}' => {
                self.advance();
                return Token{ .type = .object_end, .bytes = "}", .line = start_line, .col = start_col, .offset = start_pos };
            },
            '[' => {
                self.advance();
                return Token{ .type = .array_start, .bytes = "[", .line = start_line, .col = start_col, .offset = start_pos };
            },
            ']' => {
                self.advance();
                return Token{ .type = .array_end, .bytes = "]", .line = start_line, .col = start_col, .offset = start_pos };
            },
            ':' => {
                self.advance();
                return Token{ .type = .colon, .bytes = ":", .line = start_line, .col = start_col, .offset = start_pos };
            },
            ',' => {
                self.advance();
                return Token{ .type = .comma, .bytes = ",", .line = start_line, .col = start_col, .offset = start_pos };
            },
            '"' => self.scanString(start_line, start_col, start_pos),
            't' => self.scanTrue(start_line, start_col, start_pos),
            'f' => self.scanFalse(start_line, start_col, start_pos),
            'n' => self.scanNull(start_line, start_col, start_pos),
            '-', '0'...'9' => self.scanNumber(start_line, start_col, start_pos),
            else => error.UnexpectedToken,
        };
    }

    /// Peek at the next token without consuming it
    pub fn peek(self: *Tokenizer) TokenizerError!Token {
        if (self.peeked) |token| {
            return token;
        }
        self.peeked = try self.next();
        return self.peeked.?;
    }

    /// Skip the current value (object, array, or primitive)
    /// Useful for efficiently skipping over values you don't need
    pub fn skipValue(self: *Tokenizer) TokenizerError!void {
        const token = try self.next();

        switch (token.type) {
            .object_start, .array_start => {
                // Track total nesting depth with a single iterative counter
                // (no recursion) so deeply nested input cannot overflow the
                // counter or the call stack. Enforce opts.max_depth.
                var depth: usize = 1;
                if (depth > self.opts.max_depth) return error.DepthLimit;
                while (depth > 0) {
                    const t = try self.next();
                    switch (t.type) {
                        .object_start, .array_start => {
                            depth += 1;
                            if (depth > self.opts.max_depth) return error.DepthLimit;
                        },
                        .object_end, .array_end => depth -= 1,
                        .eof => return error.UnexpectedEof,
                        else => {},
                    }
                }
            },
            .string, .number, .true_literal, .false_literal, .null_literal => {
                // Primitive values are already consumed
            },
            .eof => return error.UnexpectedEof,
            else => return error.UnexpectedToken,
        }
    }

    /// Reset the tokenizer to the beginning
    pub fn reset(self: *Tokenizer) void {
        self.pos = 0;
        self.line = 1;
        self.col = 1;
        self.peeked = null;
        self.string_buffer.clearRetainingCapacity();
    }

    // ========================================================================
    // Internal scanning functions
    // ========================================================================

    fn skipWhitespace(self: *Tokenizer) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            switch (c) {
                ' ', '\t', '\r' => {
                    self.pos += 1;
                    self.col += 1;
                },
                '\n' => {
                    self.pos += 1;
                    self.line += 1;
                    self.col = 1;
                },
                else => break,
            }
        }
    }

    fn advance(self: *Tokenizer) void {
        if (self.pos < self.input.len) {
            if (self.input[self.pos] == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
            self.pos += 1;
        }
    }

    fn scanString(self: *Tokenizer, start_line: u32, start_col: u32, start_pos: usize) TokenizerError!Token {
        self.advance(); // consume opening quote
        self.string_buffer.clearRetainingCapacity();

        while (self.pos < self.input.len) {
            const c = self.input[self.pos];

            if (c == '"') {
                self.advance(); // consume closing quote
                return Token{
                    .type = .string,
                    .bytes = self.string_buffer.items,
                    .line = start_line,
                    .col = start_col,
                    .offset = start_pos,
                };
            }

            // Bound the decoded string length to prevent unbounded memory use
            // from a hostile, very long string.
            if (self.string_buffer.items.len > self.opts.max_string_len) {
                return error.StringTooLong;
            }

            if (c == '\\') {
                self.advance();
                if (self.pos >= self.input.len) return error.UnexpectedEof;

                const escaped = self.input[self.pos];
                switch (escaped) {
                    '"' => self.string_buffer.append(self.allocator, '"') catch return error.OutOfMemory,
                    '\\' => self.string_buffer.append(self.allocator, '\\') catch return error.OutOfMemory,
                    '/' => self.string_buffer.append(self.allocator, '/') catch return error.OutOfMemory,
                    'b' => self.string_buffer.append(self.allocator, 0x08) catch return error.OutOfMemory,
                    'f' => self.string_buffer.append(self.allocator, 0x0C) catch return error.OutOfMemory,
                    'n' => self.string_buffer.append(self.allocator, '\n') catch return error.OutOfMemory,
                    'r' => self.string_buffer.append(self.allocator, '\r') catch return error.OutOfMemory,
                    't' => self.string_buffer.append(self.allocator, '\t') catch return error.OutOfMemory,
                    'u' => {
                        // Parse unicode escape
                        const cp = self.parseUnicodeEscape() catch return error.InvalidEscape;
                        self.appendCodepoint(cp) catch return error.OutOfMemory;
                        continue; // parseUnicodeEscape already advanced
                    },
                    else => return error.InvalidEscape,
                }
                self.advance();
            } else if (c < 0x20) {
                // Control characters are not allowed in strings
                return error.InvalidString;
            } else if (c >= 0x80) {
                // UTF-8 multi-byte sequence
                const seq_len = unicode.utf8SeqLen(c) catch return error.InvalidUtf8;
                if (self.pos + seq_len > self.input.len) return error.InvalidUtf8;

                const seq = self.input[self.pos..][0..seq_len];
                // Strictly validate the full sequence: reject malformed bytes,
                // overlong encodings, and UTF-16 surrogate code points.
                if (!unicode.isValidUtf8Seq(seq)) return error.InvalidUtf8;

                self.string_buffer.appendSlice(self.allocator, seq) catch return error.OutOfMemory;
                self.pos += seq_len;
                self.col += 1;
            } else {
                self.string_buffer.append(self.allocator, c) catch return error.OutOfMemory;
                self.advance();
            }
        }

        return error.UnexpectedEof;
    }

    fn parseUnicodeEscape(self: *Tokenizer) !u21 {
        self.advance(); // consume 'u'

        if (self.pos + 4 > self.input.len) return error.InvalidEscape;

        const hex = self.input[self.pos..][0..4];
        const cp1 = unicode.parseHex4(hex) orelse return error.InvalidEscape;
        self.pos += 4;
        self.col += 4;

        // Check for surrogate pair
        if (cp1 >= 0xD800 and cp1 <= 0xDBFF) {
            // High surrogate - expect low surrogate
            if (self.pos + 6 > self.input.len) return error.InvalidSurrogate;
            if (self.input[self.pos] != '\\' or self.input[self.pos + 1] != 'u') {
                return error.InvalidSurrogate;
            }
            self.pos += 2;
            self.col += 2;

            const hex2 = self.input[self.pos..][0..4];
            const cp2 = unicode.parseHex4(hex2) orelse return error.InvalidEscape;
            self.pos += 4;
            self.col += 4;

            if (cp2 < 0xDC00 or cp2 > 0xDFFF) {
                return error.InvalidSurrogate;
            }

            // Combine surrogate pair
            const high: u21 = cp1 - 0xD800;
            const low: u21 = cp2 - 0xDC00;
            return 0x10000 + (high << 10) + low;
        }

        if (cp1 >= 0xDC00 and cp1 <= 0xDFFF) {
            // Lone low surrogate
            return error.InvalidSurrogate;
        }

        return cp1;
    }

    fn appendCodepoint(self: *Tokenizer, cp: u21) !void {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidUtf8;
        try self.string_buffer.appendSlice(self.allocator, buf[0..len]);
    }

    fn scanTrue(self: *Tokenizer, start_line: u32, start_col: u32, start_pos: usize) TokenizerError!Token {
        if (self.pos + 4 > self.input.len) return error.UnexpectedEof;
        if (!std.mem.eql(u8, self.input[self.pos..][0..4], "true")) {
            return error.UnexpectedToken;
        }
        self.pos += 4;
        self.col += 4;
        return Token{
            .type = .true_literal,
            .bytes = "true",
            .line = start_line,
            .col = start_col,
            .offset = start_pos,
        };
    }

    fn scanFalse(self: *Tokenizer, start_line: u32, start_col: u32, start_pos: usize) TokenizerError!Token {
        if (self.pos + 5 > self.input.len) return error.UnexpectedEof;
        if (!std.mem.eql(u8, self.input[self.pos..][0..5], "false")) {
            return error.UnexpectedToken;
        }
        self.pos += 5;
        self.col += 5;
        return Token{
            .type = .false_literal,
            .bytes = "false",
            .line = start_line,
            .col = start_col,
            .offset = start_pos,
        };
    }

    fn scanNull(self: *Tokenizer, start_line: u32, start_col: u32, start_pos: usize) TokenizerError!Token {
        if (self.pos + 4 > self.input.len) return error.UnexpectedEof;
        if (!std.mem.eql(u8, self.input[self.pos..][0..4], "null")) {
            return error.UnexpectedToken;
        }
        self.pos += 4;
        self.col += 4;
        return Token{
            .type = .null_literal,
            .bytes = "null",
            .line = start_line,
            .col = start_col,
            .offset = start_pos,
        };
    }

    fn scanNumber(self: *Tokenizer, start_line: u32, start_col: u32, start_pos: usize) TokenizerError!Token {
        const num_start = self.pos;

        // Optional minus sign
        if (self.pos < self.input.len and self.input[self.pos] == '-') {
            self.advance();
        }

        // Integer part
        if (self.pos >= self.input.len) return error.UnexpectedEof;

        if (self.input[self.pos] == '0') {
            self.advance();
            // Leading zero must be followed by . or end of number
        } else if (self.input[self.pos] >= '1' and self.input[self.pos] <= '9') {
            self.advance();
            while (self.pos < self.input.len and self.input[self.pos] >= '0' and self.input[self.pos] <= '9') {
                self.advance();
            }
        } else {
            return error.InvalidNumber;
        }

        // Optional fractional part
        if (self.pos < self.input.len and self.input[self.pos] == '.') {
            self.advance();
            if (self.pos >= self.input.len or self.input[self.pos] < '0' or self.input[self.pos] > '9') {
                return error.InvalidNumber;
            }
            while (self.pos < self.input.len and self.input[self.pos] >= '0' and self.input[self.pos] <= '9') {
                self.advance();
            }
        }

        // Optional exponent part
        if (self.pos < self.input.len and (self.input[self.pos] == 'e' or self.input[self.pos] == 'E')) {
            self.advance();
            if (self.pos < self.input.len and (self.input[self.pos] == '+' or self.input[self.pos] == '-')) {
                self.advance();
            }
            if (self.pos >= self.input.len or self.input[self.pos] < '0' or self.input[self.pos] > '9') {
                return error.InvalidNumber;
            }
            while (self.pos < self.input.len and self.input[self.pos] >= '0' and self.input[self.pos] <= '9') {
                self.advance();
            }
        }

        return Token{
            .type = .number,
            .bytes = self.input[num_start..self.pos],
            .line = start_line,
            .col = start_col,
            .offset = start_pos,
        };
    }
};

// ============================================================================
// Streaming Value Reader
// ============================================================================

/// Read the next JSON value as a json.Value from the tokenizer
/// More memory-efficient for extracting specific values from large documents
/// Caller should call freeValue() when done with the returned value
pub fn readValue(tokenizer: *Tokenizer) TokenizerError!json.Value {
    return readValueDepth(tokenizer, 0);
}

/// Internal: read a value while tracking the current nesting depth so that
/// recursion through readArray/readObject is bounded by opts.max_depth.
fn readValueDepth(tokenizer: *Tokenizer, depth: usize) TokenizerError!json.Value {
    const token = try tokenizer.next();

    return switch (token.type) {
        .null_literal => .null,
        .true_literal => .{ .bool = true },
        .false_literal => .{ .bool = false },
        .string => .{ .str = tokenizer.allocator.dupe(u8, token.bytes) catch return error.OutOfMemory },
        .number => .{ .num = try parseNumberToken(tokenizer.allocator, token.bytes) },
        .array_start => try readArray(tokenizer, depth + 1),
        .object_start => try readObject(tokenizer, depth + 1),
        .eof => error.UnexpectedEof,
        else => error.UnexpectedToken,
    };
}

/// Free memory allocated by readValue
///
/// Note: unlike the public `json.freeValue` (which treats `.num` as
/// allocation-free because the main parser's numbers borrow into the arena),
/// the streaming tokenizer's `.num` values OWN both `digits` and `lexeme`:
/// `parseNumberToken` dupes the lexeme and `number.parseNumber` allocates the
/// normalized digit string. Both must be freed here -- matching `async.zig`'s
/// `freeValue` -- with no double-free (they are two distinct allocations).
pub fn freeValue(allocator: std.mem.Allocator, value: json.Value) void {
    switch (value) {
        .null, .bool => {}, // no allocation
        .num => |n| {
            allocator.free(n.digits);
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
            for (obj) |m| {
                allocator.free(m.k);
                freeValue(allocator, m.v);
            }
            allocator.free(obj);
        },
    }
}

/// Build a canonically-normalized `Number` from a numeric lexeme.
///
/// This routes through `number.parseNumber` -- exactly as `parser.zig` and
/// `async.zig` do -- so the streaming tokenizer agrees bit-for-bit with the
/// main and async parsers under `compare`/`isInteger`/`Value.eql`. Routing
/// through the shared routine fixes two bugs the old hand-rolled normalizer had:
///
///   1. An unchecked `exp10 = exp10 * 10 + digit` (and `@intCast` of the
///      fractional length) that panicked with "integer overflow" on adversarial
///      input such as `"1e99999999999"`. `parseNumber` saturates the exponent.
///   2. A fractional lexeme produced `digits = <integer part only>`, so `1.5`
///      decoded as `0.1`. `parseNumber` builds the full digit string.
///
/// `lexeme` borrows from a tokenizer-owned buffer (`self.input` for the slice
/// path, `number_buffer` for the reader path) that is reused/freed out from
/// under the returned token. We therefore dupe it -- mirroring `async.zig` --
/// so the returned `Number.lexeme` and the buffer `parseNumber` reads/normalizes
/// are the same independently-owned allocation. Both `lexeme` and `digits` are
/// heap-owned and released by this module's `freeValue` for `.num`.
fn parseNumberToken(allocator: std.mem.Allocator, lexeme: []const u8) error{OutOfMemory}!json.Number {
    const lexeme_owned = allocator.dupe(u8, lexeme) catch return error.OutOfMemory;
    errdefer allocator.free(lexeme_owned);
    return number_mod.parseNumber(lexeme_owned, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn readArray(tokenizer: *Tokenizer, depth: usize) TokenizerError!json.Value {
    if (depth > tokenizer.opts.max_depth) return error.DepthLimit;

    var items: std.ArrayList(json.Value) = .empty;
    // Free both the container spine AND any elements already parsed if we
    // return early on a malformed input, so a mid-parse error cannot leak.
    errdefer {
        for (items.items) |item| freeValue(tokenizer.allocator, item);
        items.deinit(tokenizer.allocator);
    }

    while (true) {
        const peek_token = try tokenizer.peek();
        if (peek_token.type == .array_end) {
            _ = try tokenizer.next(); // consume ]
            break;
        }

        const item = try readValueDepth(tokenizer, depth);
        items.append(tokenizer.allocator, item) catch {
            freeValue(tokenizer.allocator, item);
            return error.OutOfMemory;
        };

        const next_token = try tokenizer.peek();
        if (next_token.type == .comma) {
            _ = try tokenizer.next(); // consume comma
        } else if (next_token.type != .array_end) {
            return error.UnexpectedToken;
        }
    }

    const owned = items.toOwnedSlice(tokenizer.allocator) catch return error.OutOfMemory;
    return .{ .arr = owned };
}

fn readObject(tokenizer: *Tokenizer, depth: usize) TokenizerError!json.Value {
    if (depth > tokenizer.opts.max_depth) return error.DepthLimit;

    var members: std.ArrayList(json.Member) = .empty;
    // Free both the container spine AND any members already parsed (key + value)
    // if we return early on a malformed input.
    errdefer {
        for (members.items) |m| {
            tokenizer.allocator.free(m.k);
            freeValue(tokenizer.allocator, m.v);
        }
        members.deinit(tokenizer.allocator);
    }

    while (true) {
        const peek_token = try tokenizer.peek();
        if (peek_token.type == .object_end) {
            _ = try tokenizer.next(); // consume }
            break;
        }

        // Read key
        const key_token = try tokenizer.next();
        if (key_token.type != .string) return error.UnexpectedToken;

        // Dupe the key since tokenizer buffer will be reused. The duped key
        // must be freed on any error path until ownership transfers to
        // members.append; we free it explicitly on each such path rather than
        // with an iteration-scoped errdefer (which would double-free once the
        // member is owned by the function-level errdefer below).
        const key = tokenizer.allocator.dupe(u8, key_token.bytes) catch return error.OutOfMemory;

        // Read colon
        const colon_token = tokenizer.next() catch |err| {
            tokenizer.allocator.free(key);
            return err;
        };
        if (colon_token.type != .colon) {
            tokenizer.allocator.free(key);
            return error.UnexpectedToken;
        }

        // Read value
        const value = readValueDepth(tokenizer, depth) catch |err| {
            tokenizer.allocator.free(key);
            return err;
        };
        // key and value ownership transfers to members on success.
        members.append(tokenizer.allocator, .{ .k = key, .v = value }) catch {
            tokenizer.allocator.free(key);
            freeValue(tokenizer.allocator, value);
            return error.OutOfMemory;
        };

        const next_token = try tokenizer.peek();
        if (next_token.type == .comma) {
            _ = try tokenizer.next(); // consume comma
        } else if (next_token.type != .object_end) {
            return error.UnexpectedToken;
        }
    }

    const owned = members.toOwnedSlice(tokenizer.allocator) catch return error.OutOfMemory;
    return .{ .obj = owned };
}

// ============================================================================
// Tests
// ============================================================================

test "tokenize empty object" {
    var tokenizer = Tokenizer.init(std.testing.allocator, "{}", .{});
    defer tokenizer.deinit();

    const t1 = try tokenizer.next();
    try std.testing.expectEqual(TokenType.object_start, t1.type);

    const t2 = try tokenizer.next();
    try std.testing.expectEqual(TokenType.object_end, t2.type);

    const t3 = try tokenizer.next();
    try std.testing.expectEqual(TokenType.eof, t3.type);
}

test "tokenize empty array" {
    var tokenizer = Tokenizer.init(std.testing.allocator, "[]", .{});
    defer tokenizer.deinit();

    const t1 = try tokenizer.next();
    try std.testing.expectEqual(TokenType.array_start, t1.type);

    const t2 = try tokenizer.next();
    try std.testing.expectEqual(TokenType.array_end, t2.type);
}

test "tokenize primitives" {
    var tokenizer = Tokenizer.init(std.testing.allocator, "true false null", .{});
    defer tokenizer.deinit();

    const t1 = try tokenizer.next();
    try std.testing.expectEqual(TokenType.true_literal, t1.type);

    const t2 = try tokenizer.next();
    try std.testing.expectEqual(TokenType.false_literal, t2.type);

    const t3 = try tokenizer.next();
    try std.testing.expectEqual(TokenType.null_literal, t3.type);
}

test "tokenize string" {
    var tokenizer = Tokenizer.init(std.testing.allocator, "\"hello world\"", .{});
    defer tokenizer.deinit();

    const t = try tokenizer.next();
    try std.testing.expectEqual(TokenType.string, t.type);
    try std.testing.expectEqualStrings("hello world", t.bytes);
}

test "tokenize string with escapes" {
    var tokenizer = Tokenizer.init(std.testing.allocator, "\"hello\\nworld\\t!\"", .{});
    defer tokenizer.deinit();

    const t = try tokenizer.next();
    try std.testing.expectEqual(TokenType.string, t.type);
    try std.testing.expectEqualStrings("hello\nworld\t!", t.bytes);
}

test "tokenize string with unicode escape" {
    var tokenizer = Tokenizer.init(std.testing.allocator, "\"\\u0048\\u0065\\u006C\\u006C\\u006F\"", .{});
    defer tokenizer.deinit();

    const t = try tokenizer.next();
    try std.testing.expectEqual(TokenType.string, t.type);
    try std.testing.expectEqualStrings("Hello", t.bytes);
}

test "tokenize numbers" {
    var tokenizer = Tokenizer.init(std.testing.allocator, "42 -17 3.14 1e10 -2.5e-3", .{});
    defer tokenizer.deinit();

    const t1 = try tokenizer.next();
    try std.testing.expectEqual(TokenType.number, t1.type);
    try std.testing.expectEqualStrings("42", t1.bytes);

    const t2 = try tokenizer.next();
    try std.testing.expectEqual(TokenType.number, t2.type);
    try std.testing.expectEqualStrings("-17", t2.bytes);

    const t3 = try tokenizer.next();
    try std.testing.expectEqual(TokenType.number, t3.type);
    try std.testing.expectEqualStrings("3.14", t3.bytes);

    const t4 = try tokenizer.next();
    try std.testing.expectEqual(TokenType.number, t4.type);
    try std.testing.expectEqualStrings("1e10", t4.bytes);

    const t5 = try tokenizer.next();
    try std.testing.expectEqual(TokenType.number, t5.type);
    try std.testing.expectEqualStrings("-2.5e-3", t5.bytes);
}

test "tokenize object" {
    var tokenizer = Tokenizer.init(std.testing.allocator, "{\"name\": \"Alice\", \"age\": 30}", .{});
    defer tokenizer.deinit();

    try std.testing.expectEqual(TokenType.object_start, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.string, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.colon, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.string, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.comma, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.string, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.colon, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.number, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.object_end, (try tokenizer.next()).type);
}

test "peek token" {
    var tokenizer = Tokenizer.init(std.testing.allocator, "[1, 2]", .{});
    defer tokenizer.deinit();

    const peeked = try tokenizer.peek();
    try std.testing.expectEqual(TokenType.array_start, peeked.type);

    const next = try tokenizer.next();
    try std.testing.expectEqual(TokenType.array_start, next.type);
}

test "skip value - primitive" {
    var tokenizer = Tokenizer.init(std.testing.allocator, "42 true", .{});
    defer tokenizer.deinit();

    try tokenizer.skipValue();
    const t = try tokenizer.next();
    try std.testing.expectEqual(TokenType.true_literal, t.type);
}

test "skip value - object" {
    var tokenizer = Tokenizer.init(std.testing.allocator, "{\"a\": {\"b\": 1}, \"c\": 2} true", .{});
    defer tokenizer.deinit();

    try tokenizer.skipValue();
    const t = try tokenizer.next();
    try std.testing.expectEqual(TokenType.true_literal, t.type);
}

test "skip value - array" {
    var tokenizer = Tokenizer.init(std.testing.allocator, "[[1, 2], [3, 4]] false", .{});
    defer tokenizer.deinit();

    try tokenizer.skipValue();
    const t = try tokenizer.next();
    try std.testing.expectEqual(TokenType.false_literal, t.type);
}

test "line and column tracking" {
    var tokenizer = Tokenizer.init(std.testing.allocator, "{\n  \"key\": 1\n}", .{});
    defer tokenizer.deinit();

    const t1 = try tokenizer.next(); // {
    try std.testing.expectEqual(@as(u32, 1), t1.line);
    try std.testing.expectEqual(@as(u32, 1), t1.col);

    const t2 = try tokenizer.next(); // "key"
    try std.testing.expectEqual(@as(u32, 2), t2.line);
    try std.testing.expectEqual(@as(u32, 3), t2.col);
}

test "readValue primitive types" {
    // Test null
    {
        var tokenizer = Tokenizer.init(std.testing.allocator, "null", .{});
        defer tokenizer.deinit();
        const value = try readValue(&tokenizer);
        defer freeValue(std.testing.allocator, value);
        try std.testing.expect(value == .null);
    }

    // Test booleans
    {
        var tokenizer = Tokenizer.init(std.testing.allocator, "true", .{});
        defer tokenizer.deinit();
        const value = try readValue(&tokenizer);
        defer freeValue(std.testing.allocator, value);
        try std.testing.expect(value == .bool);
        try std.testing.expect(value.bool == true);
    }

    // Test string
    {
        var tokenizer = Tokenizer.init(std.testing.allocator, "\"hello\"", .{});
        defer tokenizer.deinit();
        const value = try readValue(&tokenizer);
        defer freeValue(std.testing.allocator, value);
        try std.testing.expect(value == .str);
        try std.testing.expectEqualStrings("hello", value.str);
    }

    // Test number
    {
        var tokenizer = Tokenizer.init(std.testing.allocator, "42", .{});
        defer tokenizer.deinit();
        const value = try readValue(&tokenizer);
        defer freeValue(std.testing.allocator, value);
        try std.testing.expect(value == .num);
        try std.testing.expectEqualStrings("42", value.num.lexeme);
    }
}

test "readValue array" {
    var tokenizer = Tokenizer.init(std.testing.allocator, "[1, true, \"test\"]", .{});
    defer tokenizer.deinit();
    const value = try readValue(&tokenizer);
    defer freeValue(std.testing.allocator, value);

    try std.testing.expect(value == .arr);
    try std.testing.expectEqual(@as(usize, 3), value.arr.len);
    try std.testing.expect(value.arr[0] == .num);
    try std.testing.expect(value.arr[1] == .bool);
    try std.testing.expect(value.arr[2] == .str);
}

test "readValue object" {
    var tokenizer = Tokenizer.init(std.testing.allocator, "{\"name\": \"Alice\", \"age\": 30}", .{});
    defer tokenizer.deinit();
    const value = try readValue(&tokenizer);
    defer freeValue(std.testing.allocator, value);

    try std.testing.expect(value == .obj);
    try std.testing.expectEqual(@as(usize, 2), value.obj.len);
    try std.testing.expectEqualStrings("name", value.obj[0].k);
    try std.testing.expect(value.obj[0].v == .str);
    try std.testing.expectEqualStrings("Alice", value.obj[0].v.str);
}

// ----------------------------------------------------------------------------
// Security / DoS regression tests (slice path)
// ----------------------------------------------------------------------------

test "readValue rejects deeply nested arrays at max_depth (no crash)" {
    const allocator = std.testing.allocator;
    // Build "[[[[...]" deeper than max_depth, never closed.
    const depth = 2000;
    const input = try allocator.alloc(u8, depth);
    defer allocator.free(input);
    @memset(input, '[');

    var tokenizer = Tokenizer.init(allocator, input, .{ .max_depth = 64 });
    defer tokenizer.deinit();

    // Must return the depth error rather than overflowing the stack.
    try std.testing.expectError(error.DepthLimit, readValue(&tokenizer));
}

test "readValue rejects deeply nested objects at max_depth (no crash)" {
    const allocator = std.testing.allocator;
    // Build {"a":{"a":{"a":... deeper than max_depth.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const depth = 1000;
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        try buf.appendSlice(allocator, "{\"a\":");
    }
    try buf.append(allocator, '1');

    var tokenizer = Tokenizer.init(allocator, buf.items, .{ .max_depth = 32 });
    defer tokenizer.deinit();

    try std.testing.expectError(error.DepthLimit, readValue(&tokenizer));
}

test "readValue accepts nesting within max_depth" {
    const allocator = std.testing.allocator;
    // 4 levels of nesting, max_depth 8 -> must parse fine.
    var tokenizer = Tokenizer.init(allocator, "[[[[1]]]]", .{ .max_depth = 8 });
    defer tokenizer.deinit();

    const value = try readValue(&tokenizer);
    defer freeValue(allocator, value);
    try std.testing.expect(value == .arr);
}

test "skipValue rejects deeply nested input at max_depth (no crash)" {
    const allocator = std.testing.allocator;
    const depth = 2000;
    const input = try allocator.alloc(u8, depth);
    defer allocator.free(input);
    @memset(input, '[');

    var tokenizer = Tokenizer.init(allocator, input, .{ .max_depth = 64 });
    defer tokenizer.deinit();

    try std.testing.expectError(error.DepthLimit, tokenizer.skipValue());
}

test "scanString rejects string longer than max_string_len" {
    const allocator = std.testing.allocator;
    // A 100-byte string with max_string_len = 8 -> StringTooLong.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '"');
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try buf.append(allocator, 'x');
    }
    try buf.append(allocator, '"');

    var tokenizer = Tokenizer.init(allocator, buf.items, .{ .max_string_len = 8 });
    defer tokenizer.deinit();

    try std.testing.expectError(error.StringTooLong, tokenizer.next());
}

test "scanString accepts string within max_string_len" {
    const allocator = std.testing.allocator;
    var tokenizer = Tokenizer.init(allocator, "\"short\"", .{ .max_string_len = 8 });
    defer tokenizer.deinit();

    const t = try tokenizer.next();
    try std.testing.expectEqual(TokenType.string, t.type);
    try std.testing.expectEqualStrings("short", t.bytes);
}

test "scanString rejects surrogate and overlong UTF-8 (slice path)" {
    const allocator = std.testing.allocator;

    // UTF-16 surrogate U+D800 encoded as raw bytes ED A0 80.
    {
        var tokenizer = Tokenizer.init(allocator, "\"\xED\xA0\x80\"", .{});
        defer tokenizer.deinit();
        try std.testing.expectError(error.InvalidUtf8, tokenizer.next());
    }

    // Overlong encoding of NUL via 4 bytes F0 80 80 80.
    {
        var tokenizer = Tokenizer.init(allocator, "\"\xF0\x80\x80\x80\"", .{});
        defer tokenizer.deinit();
        try std.testing.expectError(error.InvalidUtf8, tokenizer.next());
    }
}

test "readValue array malformed mid-parse does not leak" {
    // std.testing.allocator detects leaks. Use string elements (which dupe and
    // therefore allocate) so a leak of already-parsed elements would be caught;
    // the trailing @ triggers a mid-parse error after "aa" and "bb" are built.
    const allocator = std.testing.allocator;
    var tokenizer = Tokenizer.init(allocator, "[\"aa\", \"bb\", @]", .{});
    defer tokenizer.deinit();

    try std.testing.expectError(error.UnexpectedToken, readValue(&tokenizer));
}

test "readValue nested array malformed mid-parse does not leak" {
    // Already-parsed nested array [1,2] allocates a spine; the trailing @ errors.
    const allocator = std.testing.allocator;
    var tokenizer = Tokenizer.init(allocator, "[[1, 2], @]", .{});
    defer tokenizer.deinit();

    try std.testing.expectError(error.UnexpectedToken, readValue(&tokenizer));
}

test "readValue object malformed mid-parse does not leak" {
    // Errors after building member "a":"x" (duped key + duped value) and after
    // duping the second key "b" (missing colon). All must be freed.
    const allocator = std.testing.allocator;
    var tokenizer = Tokenizer.init(allocator, "{\"a\":\"x\",\"b\" 2}", .{});
    defer tokenizer.deinit();

    try std.testing.expectError(error.UnexpectedToken, readValue(&tokenizer));
}

test "readValue object malformed value does not leak duped key" {
    // Errors while reading the value for key "b" -- the duped key "b" and the
    // already-built member "a":"x" must all be freed.
    const allocator = std.testing.allocator;
    var tokenizer = Tokenizer.init(allocator, "{\"a\":\"x\",\"b\":@}", .{});
    defer tokenizer.deinit();

    try std.testing.expectError(error.UnexpectedToken, readValue(&tokenizer));
}

// ----------------------------------------------------------------------------
// Number parsing correctness + crash regression (NASR-001 / fractional bug)
//
// The streaming tokenizer previously hand-rolled number normalization with two
// bugs: an unchecked i32 exponent accumulation that PANICKED on a huge exponent,
// and a fractional path that kept only the integer digits (so `1.5` decoded as
// `0.1`). Both are now routed through `number.parseNumber`, so the streaming
// path agrees with `json.parse` (the main parser) under `Value.eql`.
// ----------------------------------------------------------------------------

/// Parse `input` through the slice streaming tokenizer's `readValue`.
fn streamReadValue(allocator: std.mem.Allocator, input: []const u8) !json.Value {
    var tokenizer = Tokenizer.init(allocator, input, .{});
    defer tokenizer.deinit();
    return readValue(&tokenizer);
}

test "readValue number agrees with main parser (fractional + exponent)" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{ "1.5", "-3.25e1", "1e2", "0.001", "123.456" };
    for (cases) |input| {
        // Streaming tokenizer result.
        const stream_val = try streamReadValue(allocator, input);
        defer freeValue(allocator, stream_val);
        try std.testing.expect(stream_val == .num);

        // Main parser result for the same input.
        var perr: json.ParseError = undefined;
        var doc = try json.parse(allocator, input, .{}, &perr);
        defer doc.deinit();
        try std.testing.expect(doc.root == .num);

        // The streaming and main parsers must now agree numerically. `Value.eql`
        // compares numbers via `number.compare` (sign/digits/exp10), proving the
        // streaming path builds the same canonical form the main parser does.
        try std.testing.expect(json.Value.eql(stream_val, doc.root));
        try std.testing.expectEqual(@as(i32, 0), number_mod.compare(stream_val.num, doc.root.num));
    }
}

test "readValue 1.5 is not mis-decoded as 0.1 (fractional digits bug)" {
    const allocator = std.testing.allocator;

    const onefive = try streamReadValue(allocator, "1.5");
    defer freeValue(allocator, onefive);
    try std.testing.expect(onefive == .num);

    // Correct normalization: digits "15", exp10 -1 -> 1.5.
    try std.testing.expectEqualStrings("15", onefive.num.digits);
    try std.testing.expectEqual(@as(i32, -1), onefive.num.exp10);

    // The specific bug: 1.5 must NOT equal 0.1. Build 0.1 the same way and
    // assert inequality so a regression to "integer part only" is caught.
    const onetenth = try streamReadValue(allocator, "0.1");
    defer freeValue(allocator, onetenth);
    try std.testing.expect(!json.Value.eql(onefive, onetenth));
}

test "readValue huge exponent does not crash (NASR-001)" {
    const allocator = std.testing.allocator;

    // Before the fix these panicked with "integer overflow" in Debug/ReleaseSafe.
    // Now the exponent saturates and parsing succeeds with a defined value.
    {
        const v = try streamReadValue(allocator, "1e99999999999");
        defer freeValue(allocator, v);
        try std.testing.expect(v == .num);
        // Lexeme is preserved verbatim for round-tripping.
        try std.testing.expectEqualStrings("1e99999999999", v.num.lexeme);
    }
    {
        const v = try streamReadValue(allocator, "1e-99999999999");
        defer freeValue(allocator, v);
        try std.testing.expect(v == .num);
        try std.testing.expectEqualStrings("1e-99999999999", v.num.lexeme);
    }
}

test "readValue number path frees owned digits/lexeme (no leak/double-free)" {
    // std.testing.allocator detects leaks AND double-frees. Exercise the number
    // path directly and inside a container so the recursive free is covered.
    const allocator = std.testing.allocator;

    const v = try streamReadValue(allocator, "123.456");
    defer freeValue(allocator, v);
    try std.testing.expect(v == .num);

    const arr = try streamReadValue(allocator, "[1.5, 2e3, -0.001]");
    defer freeValue(allocator, arr);
    try std.testing.expect(arr == .arr);
    try std.testing.expectEqual(@as(usize, 3), arr.arr.len);
}

// SONNY-2425: a Tokenizer keeps one scratch buffer for decoded strings across
// next(), peek() and readValue(), and only deinit() frees it.
// examples/08_streaming.zig never called deinit() on its three tokenizers, so
// each run leaked that buffer three times. Pin the contract: the example's
// three token/value sequences, each followed by deinit(), leave nothing behind
// under the leak-checking testing allocator.
test "SONNY-2425: deinit frees the string buffer that next, peek and readValue grow" {
    const allocator = std.testing.allocator;
    const doc = "{\"name\": \"Alice\", \"age\": 30, \"tags\": [\"dev\", \"zig\"]}";
    {
        var tokenizer = Tokenizer.init(allocator, doc, .{});
        defer tokenizer.deinit();
        var strings: usize = 0;
        while (true) {
            const token = try tokenizer.next();
            if (token.type == .eof) break;
            if (token.type == .string) strings += 1;
        }
        try std.testing.expectEqual(@as(usize, 6), strings);
    }
    {
        var tokenizer = Tokenizer.init(allocator, doc, .{});
        defer tokenizer.deinit();
        const value = try readValue(&tokenizer);
        defer freeValue(allocator, value);
        try std.testing.expect(value == .obj);
        try std.testing.expectEqual(@as(usize, 3), value.obj.len);
    }
    {
        var tokenizer = Tokenizer.init(allocator, "[{\"id\": 1, \"value\": \"first\"}, {\"id\": 2, \"value\": \"second\"}]", .{});
        defer tokenizer.deinit();
        try std.testing.expectEqual(TokenType.array_start, (try tokenizer.next()).type);
        var items: usize = 0;
        while ((try tokenizer.peek()).type != .array_end) {
            const item = try readValue(&tokenizer);
            defer freeValue(allocator, item);
            try std.testing.expect(item == .obj);
            items += 1;
            if ((try tokenizer.peek()).type == .comma) _ = try tokenizer.next();
        }
        try std.testing.expectEqual(@as(usize, 2), items);
    }
}

// ============================================================================
// Reader-based Streaming Tokenizer
// ============================================================================

/// Options for reader-based tokenizer
pub const ReaderTokenizerOptions = struct {
    /// Maximum nesting depth for skipValue
    max_depth: u16 = 256,
    /// Maximum string length to decode
    max_string_len: usize = 1024 * 1024,
    /// Buffer size for reading from the reader
    buffer_size: usize = 4096,
};

/// Reader tokenizer error codes
pub const ReaderTokenizerError = error{
    UnexpectedEof,
    UnexpectedToken,
    InvalidUtf8,
    InvalidString,
    InvalidEscape,
    InvalidSurrogate,
    InvalidNumber,
    /// Nesting depth exceeded options.max_depth
    DepthLimit,
    /// String length exceeded options.max_string_len
    StringTooLong,
    OutOfMemory,
    IoError,
    BufferOverflow,
};

/// A streaming JSON tokenizer that reads from any std.Io.Reader
/// Enables parsing JSON from files, sockets, or any other stream
/// without loading the entire input into memory.
pub fn ReaderTokenizer(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        /// Internal buffer for reading from the reader
        read_buffer: []u8,
        /// Current position in the buffer
        buf_pos: usize,
        /// Amount of valid data in the buffer
        buf_len: usize,
        /// The underlying reader
        reader: ReaderType,
        /// Current line number
        line: u32,
        /// Current column number
        col: u32,
        /// Total bytes read (for error reporting)
        total_read: usize,
        /// Options
        opts: ReaderTokenizerOptions,
        /// Allocator
        allocator: std.mem.Allocator,
        /// Buffer for strings
        string_buffer: std.ArrayList(u8),
        /// Buffer for number lexemes
        number_buffer: std.ArrayList(u8),
        /// Peeked token
        peeked: ?Token,
        /// End of stream reached
        eof_reached: bool,

        /// Initialize a new reader tokenizer
        pub fn init(allocator: std.mem.Allocator, reader: ReaderType, opts: ReaderTokenizerOptions) !Self {
            const buf = try allocator.alloc(u8, opts.buffer_size);
            return .{
                .read_buffer = buf,
                .buf_pos = 0,
                .buf_len = 0,
                .reader = reader,
                .line = 1,
                .col = 1,
                .total_read = 0,
                .opts = opts,
                .allocator = allocator,
                .string_buffer = .empty,
                .number_buffer = .empty,
                .peeked = null,
                .eof_reached = false,
            };
        }

        /// Clean up tokenizer resources
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.read_buffer);
            self.string_buffer.deinit(self.allocator);
            self.number_buffer.deinit(self.allocator);
        }

        /// Get the next token
        pub fn next(self: *Self) ReaderTokenizerError!Token {
            // Return peeked token if available
            if (self.peeked) |token| {
                self.peeked = null;
                return token;
            }

            self.skipWhitespace();

            const c = self.peekByte() catch {
                return Token{
                    .type = .eof,
                    .bytes = "",
                    .line = self.line,
                    .col = self.col,
                    .offset = self.total_read,
                };
            };

            const start_line = self.line;
            const start_col = self.col;
            const start_pos = self.total_read;

            return switch (c) {
                '{' => {
                    self.advance();
                    return Token{ .type = .object_start, .bytes = "{", .line = start_line, .col = start_col, .offset = start_pos };
                },
                '}' => {
                    self.advance();
                    return Token{ .type = .object_end, .bytes = "}", .line = start_line, .col = start_col, .offset = start_pos };
                },
                '[' => {
                    self.advance();
                    return Token{ .type = .array_start, .bytes = "[", .line = start_line, .col = start_col, .offset = start_pos };
                },
                ']' => {
                    self.advance();
                    return Token{ .type = .array_end, .bytes = "]", .line = start_line, .col = start_col, .offset = start_pos };
                },
                ':' => {
                    self.advance();
                    return Token{ .type = .colon, .bytes = ":", .line = start_line, .col = start_col, .offset = start_pos };
                },
                ',' => {
                    self.advance();
                    return Token{ .type = .comma, .bytes = ",", .line = start_line, .col = start_col, .offset = start_pos };
                },
                '"' => self.scanString(start_line, start_col, start_pos),
                't' => self.scanTrue(start_line, start_col, start_pos),
                'f' => self.scanFalse(start_line, start_col, start_pos),
                'n' => self.scanNull(start_line, start_col, start_pos),
                '-', '0'...'9' => self.scanNumber(start_line, start_col, start_pos),
                else => error.UnexpectedToken,
            };
        }

        /// Peek at the next token without consuming it
        pub fn peek(self: *Self) ReaderTokenizerError!Token {
            if (self.peeked) |token| {
                return token;
            }
            self.peeked = try self.next();
            return self.peeked.?;
        }

        /// Skip the current value
        pub fn skipValue(self: *Self) ReaderTokenizerError!void {
            const token = try self.next();

            switch (token.type) {
                .object_start, .array_start => {
                    // Track total nesting depth with a single iterative counter
                    // (no recursion) so deeply nested input cannot overflow the
                    // counter or the call stack. Enforce opts.max_depth.
                    var depth: usize = 1;
                    if (depth > self.opts.max_depth) return error.DepthLimit;
                    while (depth > 0) {
                        const t = try self.next();
                        switch (t.type) {
                            .object_start, .array_start => {
                                depth += 1;
                                if (depth > self.opts.max_depth) return error.DepthLimit;
                            },
                            .object_end, .array_end => depth -= 1,
                            .eof => return error.UnexpectedEof,
                            else => {},
                        }
                    }
                },
                .string, .number, .true_literal, .false_literal, .null_literal => {},
                .eof => return error.UnexpectedEof,
                else => return error.UnexpectedToken,
            }
        }

        // ========================================================================
        // Internal functions
        // ========================================================================

        /// Ensure we have at least one byte in the buffer
        fn ensureBuffer(self: *Self) !void {
            if (self.buf_pos >= self.buf_len) {
                if (self.eof_reached) return error.EndOfStream;
                const n = self.reader.readSliceShort(self.read_buffer) catch return error.IoError;
                if (n == 0) {
                    self.eof_reached = true;
                    return error.EndOfStream;
                }
                self.buf_pos = 0;
                self.buf_len = n;
            }
        }

        /// Peek at the current byte without consuming it
        fn peekByte(self: *Self) !u8 {
            try self.ensureBuffer();
            return self.read_buffer[self.buf_pos];
        }

        /// Consume the current byte and advance
        fn advance(self: *Self) void {
            if (self.buf_pos < self.buf_len) {
                const c = self.read_buffer[self.buf_pos];
                if (c == '\n') {
                    self.line += 1;
                    self.col = 1;
                } else {
                    self.col += 1;
                }
                self.buf_pos += 1;
                self.total_read += 1;
            }
        }

        /// Read and consume the next byte
        fn readByte(self: *Self) !u8 {
            try self.ensureBuffer();
            const c = self.read_buffer[self.buf_pos];
            self.advance();
            return c;
        }

        fn skipWhitespace(self: *Self) void {
            while (true) {
                const c = self.peekByte() catch return;
                switch (c) {
                    ' ', '\t', '\r', '\n' => self.advance(),
                    else => return,
                }
            }
        }

        fn scanString(self: *Self, start_line: u32, start_col: u32, start_pos: usize) ReaderTokenizerError!Token {
            self.advance(); // consume opening quote
            self.string_buffer.clearRetainingCapacity();

            while (true) {
                const c = self.readByte() catch return error.UnexpectedEof;

                if (c == '"') {
                    return Token{
                        .type = .string,
                        .bytes = self.string_buffer.items,
                        .line = start_line,
                        .col = start_col,
                        .offset = start_pos,
                    };
                }

                // Bound the decoded string length to prevent unbounded memory
                // use from a hostile, very long string.
                if (self.string_buffer.items.len > self.opts.max_string_len) {
                    return error.StringTooLong;
                }

                if (c == '\\') {
                    const escaped = self.readByte() catch return error.UnexpectedEof;
                    switch (escaped) {
                        '"' => self.string_buffer.append(self.allocator, '"') catch return error.OutOfMemory,
                        '\\' => self.string_buffer.append(self.allocator, '\\') catch return error.OutOfMemory,
                        '/' => self.string_buffer.append(self.allocator, '/') catch return error.OutOfMemory,
                        'b' => self.string_buffer.append(self.allocator, 0x08) catch return error.OutOfMemory,
                        'f' => self.string_buffer.append(self.allocator, 0x0C) catch return error.OutOfMemory,
                        'n' => self.string_buffer.append(self.allocator, '\n') catch return error.OutOfMemory,
                        'r' => self.string_buffer.append(self.allocator, '\r') catch return error.OutOfMemory,
                        't' => self.string_buffer.append(self.allocator, '\t') catch return error.OutOfMemory,
                        'u' => {
                            const cp = self.parseUnicodeEscape() catch return error.InvalidEscape;
                            self.appendCodepoint(cp) catch return error.OutOfMemory;
                        },
                        else => return error.InvalidEscape,
                    }
                } else if (c < 0x20) {
                    return error.InvalidString;
                } else if (c >= 0x80) {
                    // UTF-8 multi-byte - first byte already consumed. Assemble
                    // the full sequence and strictly validate it (rejecting
                    // malformed bytes, overlong encodings, and UTF-16 surrogate
                    // code points) before appending, matching the slice path so
                    // the streaming parser cannot be used to smuggle invalid
                    // UTF-8 past the slice parser's checks.
                    const seq_len = unicode.utf8SeqLen(c) catch return error.InvalidUtf8;
                    var seq: [4]u8 = undefined;
                    seq[0] = c;
                    var i: usize = 1;
                    while (i < seq_len) : (i += 1) {
                        seq[i] = self.readByte() catch return error.UnexpectedEof;
                    }
                    if (!unicode.isValidUtf8Seq(seq[0..seq_len])) return error.InvalidUtf8;
                    self.string_buffer.appendSlice(self.allocator, seq[0..seq_len]) catch return error.OutOfMemory;
                } else {
                    self.string_buffer.append(self.allocator, c) catch return error.OutOfMemory;
                }
            }
        }

        fn parseUnicodeEscape(self: *Self) !u21 {
            var hex: [4]u8 = undefined;
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                hex[i] = self.readByte() catch return error.InvalidEscape;
            }

            const cp1 = unicode.parseHex4(&hex) orelse return error.InvalidEscape;

            // Check for surrogate pair
            if (cp1 >= 0xD800 and cp1 <= 0xDBFF) {
                const b1 = self.readByte() catch return error.InvalidSurrogate;
                const b2 = self.readByte() catch return error.InvalidSurrogate;
                if (b1 != '\\' or b2 != 'u') return error.InvalidSurrogate;

                var hex2: [4]u8 = undefined;
                i = 0;
                while (i < 4) : (i += 1) {
                    hex2[i] = self.readByte() catch return error.InvalidSurrogate;
                }

                const cp2 = unicode.parseHex4(&hex2) orelse return error.InvalidEscape;
                if (cp2 < 0xDC00 or cp2 > 0xDFFF) return error.InvalidSurrogate;

                const high: u21 = cp1 - 0xD800;
                const low: u21 = cp2 - 0xDC00;
                return 0x10000 + (high << 10) + low;
            }

            if (cp1 >= 0xDC00 and cp1 <= 0xDFFF) return error.InvalidSurrogate;

            return cp1;
        }

        fn appendCodepoint(self: *Self, cp: u21) !void {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidUtf8;
            try self.string_buffer.appendSlice(self.allocator, buf[0..len]);
        }

        fn scanTrue(self: *Self, start_line: u32, start_col: u32, start_pos: usize) ReaderTokenizerError!Token {
            const expected = "true";
            var i: usize = 0;
            while (i < expected.len) : (i += 1) {
                const c = self.readByte() catch return error.UnexpectedEof;
                if (c != expected[i]) return error.UnexpectedToken;
            }
            return Token{
                .type = .true_literal,
                .bytes = "true",
                .line = start_line,
                .col = start_col,
                .offset = start_pos,
            };
        }

        fn scanFalse(self: *Self, start_line: u32, start_col: u32, start_pos: usize) ReaderTokenizerError!Token {
            const expected = "false";
            var i: usize = 0;
            while (i < expected.len) : (i += 1) {
                const c = self.readByte() catch return error.UnexpectedEof;
                if (c != expected[i]) return error.UnexpectedToken;
            }
            return Token{
                .type = .false_literal,
                .bytes = "false",
                .line = start_line,
                .col = start_col,
                .offset = start_pos,
            };
        }

        fn scanNull(self: *Self, start_line: u32, start_col: u32, start_pos: usize) ReaderTokenizerError!Token {
            const expected = "null";
            var i: usize = 0;
            while (i < expected.len) : (i += 1) {
                const c = self.readByte() catch return error.UnexpectedEof;
                if (c != expected[i]) return error.UnexpectedToken;
            }
            return Token{
                .type = .null_literal,
                .bytes = "null",
                .line = start_line,
                .col = start_col,
                .offset = start_pos,
            };
        }

        fn scanNumber(self: *Self, start_line: u32, start_col: u32, start_pos: usize) ReaderTokenizerError!Token {
            self.number_buffer.clearRetainingCapacity();

            // First character already peeked
            var c = self.peekByte() catch return error.UnexpectedEof;

            // Optional minus sign
            if (c == '-') {
                self.number_buffer.append(self.allocator, c) catch return error.OutOfMemory;
                self.advance();
                c = self.peekByte() catch return error.UnexpectedEof;
            }

            // Integer part
            if (c == '0') {
                self.number_buffer.append(self.allocator, c) catch return error.OutOfMemory;
                self.advance();
            } else if (c >= '1' and c <= '9') {
                while (true) {
                    self.number_buffer.append(self.allocator, c) catch return error.OutOfMemory;
                    self.advance();
                    c = self.peekByte() catch break;
                    if (c < '0' or c > '9') break;
                }
            } else {
                return error.InvalidNumber;
            }

            // Optional fractional part
            c = self.peekByte() catch {
                return Token{
                    .type = .number,
                    .bytes = self.number_buffer.items,
                    .line = start_line,
                    .col = start_col,
                    .offset = start_pos,
                };
            };

            if (c == '.') {
                self.number_buffer.append(self.allocator, '.') catch return error.OutOfMemory;
                self.advance();
                c = self.peekByte() catch return error.InvalidNumber;
                if (c < '0' or c > '9') return error.InvalidNumber;
                while (c >= '0' and c <= '9') {
                    self.number_buffer.append(self.allocator, c) catch return error.OutOfMemory;
                    self.advance();
                    c = self.peekByte() catch break;
                }
            }

            // Optional exponent part
            c = self.peekByte() catch {
                return Token{
                    .type = .number,
                    .bytes = self.number_buffer.items,
                    .line = start_line,
                    .col = start_col,
                    .offset = start_pos,
                };
            };

            if (c == 'e' or c == 'E') {
                self.number_buffer.append(self.allocator, c) catch return error.OutOfMemory;
                self.advance();
                c = self.peekByte() catch return error.InvalidNumber;
                if (c == '+' or c == '-') {
                    self.number_buffer.append(self.allocator, c) catch return error.OutOfMemory;
                    self.advance();
                    c = self.peekByte() catch return error.InvalidNumber;
                }
                if (c < '0' or c > '9') return error.InvalidNumber;
                while (c >= '0' and c <= '9') {
                    self.number_buffer.append(self.allocator, c) catch return error.OutOfMemory;
                    self.advance();
                    c = self.peekByte() catch break;
                }
            }

            return Token{
                .type = .number,
                .bytes = self.number_buffer.items,
                .line = start_line,
                .col = start_col,
                .offset = start_pos,
            };
        }
    };
}

/// Create a reader tokenizer from any reader type
pub fn readerTokenizer(allocator: std.mem.Allocator, reader: anytype, opts: ReaderTokenizerOptions) !ReaderTokenizer(@TypeOf(reader)) {
    return ReaderTokenizer(@TypeOf(reader)).init(allocator, reader, opts);
}

/// Read the next JSON value from a reader tokenizer
pub fn readValueFromReader(tokenizer: anytype) ReaderTokenizerError!json.Value {
    return readValueFromReaderDepth(tokenizer, 0);
}

/// Internal: read a value while tracking nesting depth so that recursion is
/// bounded by opts.max_depth.
fn readValueFromReaderDepth(tokenizer: anytype, depth: usize) ReaderTokenizerError!json.Value {
    const token = try tokenizer.next();

    return switch (token.type) {
        .null_literal => .null,
        .true_literal => .{ .bool = true },
        .false_literal => .{ .bool = false },
        .string => .{ .str = tokenizer.allocator.dupe(u8, token.bytes) catch return error.OutOfMemory },
        .number => .{ .num = try parseNumberToken(tokenizer.allocator, token.bytes) },
        .array_start => try readArrayFromReader(tokenizer, depth + 1),
        .object_start => try readObjectFromReader(tokenizer, depth + 1),
        .eof => error.UnexpectedEof,
        else => error.UnexpectedToken,
    };
}

fn readArrayFromReader(tokenizer: anytype, depth: usize) ReaderTokenizerError!json.Value {
    if (depth > tokenizer.opts.max_depth) return error.DepthLimit;

    var items: std.ArrayList(json.Value) = .empty;
    // Free the spine AND any already-parsed elements on a mid-parse error.
    errdefer {
        for (items.items) |item| freeValue(tokenizer.allocator, item);
        items.deinit(tokenizer.allocator);
    }

    while (true) {
        const peek_token = try tokenizer.peek();
        if (peek_token.type == .array_end) {
            _ = try tokenizer.next();
            break;
        }

        const item = try readValueFromReaderDepth(tokenizer, depth);
        items.append(tokenizer.allocator, item) catch {
            freeValue(tokenizer.allocator, item);
            return error.OutOfMemory;
        };

        const next_token = try tokenizer.peek();
        if (next_token.type == .comma) {
            _ = try tokenizer.next();
        } else if (next_token.type != .array_end) {
            return error.UnexpectedToken;
        }
    }

    const owned = items.toOwnedSlice(tokenizer.allocator) catch return error.OutOfMemory;
    return .{ .arr = owned };
}

fn readObjectFromReader(tokenizer: anytype, depth: usize) ReaderTokenizerError!json.Value {
    if (depth > tokenizer.opts.max_depth) return error.DepthLimit;

    var members: std.ArrayList(json.Member) = .empty;
    // Free the spine AND any already-parsed members (key + value) on error.
    errdefer {
        for (members.items) |m| {
            tokenizer.allocator.free(m.k);
            freeValue(tokenizer.allocator, m.v);
        }
        members.deinit(tokenizer.allocator);
    }

    while (true) {
        const peek_token = try tokenizer.peek();
        if (peek_token.type == .object_end) {
            _ = try tokenizer.next();
            break;
        }

        const key_token = try tokenizer.next();
        if (key_token.type != .string) return error.UnexpectedToken;

        // Free the duped key explicitly on each error path until ownership
        // transfers to members.append (avoids double-free with the
        // function-level errdefer above).
        const key = tokenizer.allocator.dupe(u8, key_token.bytes) catch return error.OutOfMemory;

        const colon_token = tokenizer.next() catch |err| {
            tokenizer.allocator.free(key);
            return err;
        };
        if (colon_token.type != .colon) {
            tokenizer.allocator.free(key);
            return error.UnexpectedToken;
        }

        const value = readValueFromReaderDepth(tokenizer, depth) catch |err| {
            tokenizer.allocator.free(key);
            return err;
        };

        members.append(tokenizer.allocator, .{ .k = key, .v = value }) catch {
            tokenizer.allocator.free(key);
            freeValue(tokenizer.allocator, value);
            return error.OutOfMemory;
        };

        const next_token = try tokenizer.peek();
        if (next_token.type == .comma) {
            _ = try tokenizer.next();
        } else if (next_token.type != .object_end) {
            return error.UnexpectedToken;
        }
    }

    const owned = members.toOwnedSlice(tokenizer.allocator) catch return error.OutOfMemory;
    return .{ .obj = owned };
}

// ============================================================================
// Reader Tokenizer Tests
// ============================================================================

test "ReaderTokenizer basic object" {
    const allocator = std.testing.allocator;
    const input = "{\"name\": \"Alice\", \"age\": 30}";
    var reader: std.Io.Reader = .fixed(input);

    var tokenizer = try readerTokenizer(allocator, &reader, .{});
    defer tokenizer.deinit();

    try std.testing.expectEqual(TokenType.object_start, (try tokenizer.next()).type);
    const key1 = try tokenizer.next();
    try std.testing.expectEqual(TokenType.string, key1.type);
    try std.testing.expectEqualStrings("name", key1.bytes);
    try std.testing.expectEqual(TokenType.colon, (try tokenizer.next()).type);
    const val1 = try tokenizer.next();
    try std.testing.expectEqual(TokenType.string, val1.type);
    try std.testing.expectEqualStrings("Alice", val1.bytes);
    try std.testing.expectEqual(TokenType.comma, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.string, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.colon, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.number, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.object_end, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.eof, (try tokenizer.next()).type);
}

test "ReaderTokenizer array" {
    const allocator = std.testing.allocator;
    const input = "[1, true, null, \"test\"]";
    var reader: std.Io.Reader = .fixed(input);

    var tokenizer = try readerTokenizer(allocator, &reader, .{});
    defer tokenizer.deinit();

    try std.testing.expectEqual(TokenType.array_start, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.number, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.comma, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.true_literal, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.comma, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.null_literal, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.comma, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.string, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.array_end, (try tokenizer.next()).type);
}

test "ReaderTokenizer unicode escape" {
    const allocator = std.testing.allocator;
    const input = "\"Hello \\u0048\\u0065\\u006C\\u006C\\u006F\"";
    var reader: std.Io.Reader = .fixed(input);

    var tokenizer = try readerTokenizer(allocator, &reader, .{});
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(TokenType.string, token.type);
    try std.testing.expectEqualStrings("Hello Hello", token.bytes);
}

test "ReaderTokenizer read value" {
    const allocator = std.testing.allocator;
    const input = "{\"items\": [1, 2, 3], \"active\": true}";
    var reader: std.Io.Reader = .fixed(input);

    var tokenizer = try readerTokenizer(allocator, &reader, .{});
    defer tokenizer.deinit();

    const value = try readValueFromReader(&tokenizer);
    defer freeValue(allocator, value);

    try std.testing.expect(value == .obj);
    try std.testing.expectEqual(@as(usize, 2), value.obj.len);
    try std.testing.expectEqualStrings("items", value.obj[0].k);
    try std.testing.expect(value.obj[0].v == .arr);
    try std.testing.expectEqual(@as(usize, 3), value.obj[0].v.arr.len);
}

test "ReaderTokenizer skip value" {
    const allocator = std.testing.allocator;
    const input = "{\"skip\": {\"nested\": [1,2,3]}} true";
    var reader: std.Io.Reader = .fixed(input);

    var tokenizer = try readerTokenizer(allocator, &reader, .{});
    defer tokenizer.deinit();

    try tokenizer.skipValue();
    const t = try tokenizer.next();
    try std.testing.expectEqual(TokenType.true_literal, t.type);
}

test "ReaderTokenizer number formats" {
    const allocator = std.testing.allocator;
    const input = "42 -17 3.14 1e10 -2.5e-3";
    var reader: std.Io.Reader = .fixed(input);

    var tokenizer = try readerTokenizer(allocator, &reader, .{});
    defer tokenizer.deinit();

    const t1 = try tokenizer.next();
    try std.testing.expectEqualStrings("42", t1.bytes);

    const t2 = try tokenizer.next();
    try std.testing.expectEqualStrings("-17", t2.bytes);

    const t3 = try tokenizer.next();
    try std.testing.expectEqualStrings("3.14", t3.bytes);

    const t4 = try tokenizer.next();
    try std.testing.expectEqualStrings("1e10", t4.bytes);

    const t5 = try tokenizer.next();
    try std.testing.expectEqualStrings("-2.5e-3", t5.bytes);
}

// ----------------------------------------------------------------------------
// Security / DoS regression tests (reader path)
// ----------------------------------------------------------------------------

test "ReaderTokenizer readValue rejects deeply nested arrays at max_depth" {
    const allocator = std.testing.allocator;
    const depth = 2000;
    const input = try allocator.alloc(u8, depth);
    defer allocator.free(input);
    @memset(input, '[');

    var reader: std.Io.Reader = .fixed(input);
    var tokenizer = try readerTokenizer(allocator, &reader, .{ .max_depth = 64 });
    defer tokenizer.deinit();

    try std.testing.expectError(error.DepthLimit, readValueFromReader(&tokenizer));
}

test "ReaderTokenizer readValue rejects deeply nested objects at max_depth" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const depth = 1000;
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        try buf.appendSlice(allocator, "{\"a\":");
    }
    try buf.append(allocator, '1');

    var reader: std.Io.Reader = .fixed(buf.items);
    var tokenizer = try readerTokenizer(allocator, &reader, .{ .max_depth = 32 });
    defer tokenizer.deinit();

    try std.testing.expectError(error.DepthLimit, readValueFromReader(&tokenizer));
}

test "ReaderTokenizer readValue accepts nesting within max_depth" {
    const allocator = std.testing.allocator;
    var reader: std.Io.Reader = .fixed("[[[[1]]]]");
    var tokenizer = try readerTokenizer(allocator, &reader, .{ .max_depth = 8 });
    defer tokenizer.deinit();

    const value = try readValueFromReader(&tokenizer);
    defer freeValue(allocator, value);
    try std.testing.expect(value == .arr);
}

test "ReaderTokenizer skipValue rejects deeply nested input at max_depth" {
    const allocator = std.testing.allocator;
    const depth = 2000;
    const input = try allocator.alloc(u8, depth);
    defer allocator.free(input);
    @memset(input, '[');

    var reader: std.Io.Reader = .fixed(input);
    var tokenizer = try readerTokenizer(allocator, &reader, .{ .max_depth = 64 });
    defer tokenizer.deinit();

    try std.testing.expectError(error.DepthLimit, tokenizer.skipValue());
}

test "ReaderTokenizer scanString rejects string longer than max_string_len" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '"');
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try buf.append(allocator, 'x');
    }
    try buf.append(allocator, '"');

    var reader: std.Io.Reader = .fixed(buf.items);
    var tokenizer = try readerTokenizer(allocator, &reader, .{ .max_string_len = 8 });
    defer tokenizer.deinit();

    try std.testing.expectError(error.StringTooLong, tokenizer.next());
}

test "ReaderTokenizer scanString accepts string within max_string_len" {
    const allocator = std.testing.allocator;
    var reader: std.Io.Reader = .fixed("\"short\"");
    var tokenizer = try readerTokenizer(allocator, &reader, .{ .max_string_len = 8 });
    defer tokenizer.deinit();

    const t = try tokenizer.next();
    try std.testing.expectEqual(TokenType.string, t.type);
    try std.testing.expectEqualStrings("short", t.bytes);
}

test "ReaderTokenizer scanString rejects surrogate and overlong UTF-8" {
    const allocator = std.testing.allocator;

    // UTF-16 surrogate U+D800 (ED A0 80) must be rejected just like the slice
    // path, preventing UTF-8 smuggling through the streaming parser.
    {
        var reader: std.Io.Reader = .fixed("\"\xED\xA0\x80\"");
        var tokenizer = try readerTokenizer(allocator, &reader, .{});
        defer tokenizer.deinit();
        try std.testing.expectError(error.InvalidUtf8, tokenizer.next());
    }

    // Overlong encoding (F0 80 80 80) must be rejected.
    {
        var reader: std.Io.Reader = .fixed("\"\xF0\x80\x80\x80\"");
        var tokenizer = try readerTokenizer(allocator, &reader, .{});
        defer tokenizer.deinit();
        try std.testing.expectError(error.InvalidUtf8, tokenizer.next());
    }
}

test "ReaderTokenizer scanString accepts valid multi-byte UTF-8" {
    const allocator = std.testing.allocator;
    // U+20AC EURO SIGN (E2 82 AC) and U+1F600 (F0 9F 98 80) must still parse.
    var reader: std.Io.Reader = .fixed("\"\xE2\x82\xAC\xF0\x9F\x98\x80\"");
    var tokenizer = try readerTokenizer(allocator, &reader, .{});
    defer tokenizer.deinit();

    const t = try tokenizer.next();
    try std.testing.expectEqual(TokenType.string, t.type);
    try std.testing.expectEqualStrings("\xE2\x82\xAC\xF0\x9F\x98\x80", t.bytes);
}

test "ReaderTokenizer readValue array malformed mid-parse does not leak" {
    // String elements allocate (dupe); trailing @ errors after they are built.
    const allocator = std.testing.allocator;
    var reader: std.Io.Reader = .fixed("[\"aa\", \"bb\", @]");
    var tokenizer = try readerTokenizer(allocator, &reader, .{});
    defer tokenizer.deinit();

    try std.testing.expectError(error.UnexpectedToken, readValueFromReader(&tokenizer));
}

test "ReaderTokenizer readValue nested array malformed mid-parse does not leak" {
    const allocator = std.testing.allocator;
    var reader: std.Io.Reader = .fixed("[[1, 2], @]");
    var tokenizer = try readerTokenizer(allocator, &reader, .{});
    defer tokenizer.deinit();

    try std.testing.expectError(error.UnexpectedToken, readValueFromReader(&tokenizer));
}

test "ReaderTokenizer readValue object malformed mid-parse does not leak" {
    // Member "a":"x" (duped key + value) and duped key "b" must all be freed.
    const allocator = std.testing.allocator;
    var reader: std.Io.Reader = .fixed("{\"a\":\"x\",\"b\" 2}");
    var tokenizer = try readerTokenizer(allocator, &reader, .{});
    defer tokenizer.deinit();

    try std.testing.expectError(error.UnexpectedToken, readValueFromReader(&tokenizer));
}

test "ReaderTokenizer readValue object malformed value does not leak duped key" {
    const allocator = std.testing.allocator;
    var reader: std.Io.Reader = .fixed("{\"a\":\"x\",\"b\":@}");
    var tokenizer = try readerTokenizer(allocator, &reader, .{});
    defer tokenizer.deinit();

    try std.testing.expectError(error.UnexpectedToken, readValueFromReader(&tokenizer));
}

// ----------------------------------------------------------------------------
// Reader-path number correctness + crash regression (NASR-001 / fractional bug)
//
// The reader path shared the same buggy `parseNumberToken`. It additionally had
// a latent dangling-pointer bug: the returned `Number` borrowed `number_buffer`,
// which is cleared on the next number and freed on deinit. Routing through
// `parseNumberToken` (which now dupes the lexeme + allocates `digits`) fixes the
// dangling pointer too. These tests run under `std.testing.allocator` so a leak
// or double-free is caught.
// ----------------------------------------------------------------------------

test "ReaderTokenizer number agrees with main parser (fractional + exponent)" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{ "1.5", "-3.25e1", "1e2", "0.001", "123.456" };
    for (cases) |input| {
        var reader: std.Io.Reader = .fixed(input);
        var tokenizer = try readerTokenizer(allocator, &reader, .{});
        defer tokenizer.deinit();

        const stream_val = try readValueFromReader(&tokenizer);
        defer freeValue(allocator, stream_val);
        try std.testing.expect(stream_val == .num);

        var perr: json.ParseError = undefined;
        var doc = try json.parse(allocator, input, .{}, &perr);
        defer doc.deinit();
        try std.testing.expect(doc.root == .num);

        try std.testing.expect(json.Value.eql(stream_val, doc.root));
    }
}

test "ReaderTokenizer 1.5 is not mis-decoded as 0.1 (fractional digits bug)" {
    const allocator = std.testing.allocator;
    var reader: std.Io.Reader = .fixed("1.5");
    var tokenizer = try readerTokenizer(allocator, &reader, .{});
    defer tokenizer.deinit();

    const v = try readValueFromReader(&tokenizer);
    defer freeValue(allocator, v);
    try std.testing.expect(v == .num);
    try std.testing.expectEqualStrings("15", v.num.digits);
    try std.testing.expectEqual(@as(i32, -1), v.num.exp10);
}

test "ReaderTokenizer huge exponent does not crash (NASR-001)" {
    const allocator = std.testing.allocator;
    var reader: std.Io.Reader = .fixed("1e99999999999");
    var tokenizer = try readerTokenizer(allocator, &reader, .{});
    defer tokenizer.deinit();

    const v = try readValueFromReader(&tokenizer);
    defer freeValue(allocator, v);
    try std.testing.expect(v == .num);
    try std.testing.expectEqualStrings("1e99999999999", v.num.lexeme);
}

// SONNY-2768: every \\u escape takes exactly four ASCII hex digits. Each bad
// byte is tried at every one of the four positions, in a lone escape and in
// the low half of a surrogate pair.
const sonny2768_bad_bytes = "+-_gGxXz .";

fn sonny2768BadInputs(comptime template: []const u8, comptime hex_at: usize) [sonny2768_bad_bytes.len * 4][template.len]u8 {
    var out: [sonny2768_bad_bytes.len * 4][template.len]u8 = undefined;
    for (sonny2768_bad_bytes, 0..) |b, bi| {
        for (0..4) |pos| {
            out[bi * 4 + pos] = template[0..template.len].*;
            out[bi * 4 + pos][hex_at + pos] = b;
        }
    }
    return out;
}

fn expectTokenizeInvalidEscape(input: []const u8) !void {
    {
        var t = Tokenizer.init(std.testing.allocator, input, .{});
        defer t.deinit();
        try std.testing.expectError(error.InvalidEscape, t.next());
    }
    {
        var reader: std.Io.Reader = .fixed(input);
        var t = try readerTokenizer(std.testing.allocator, &reader, .{});
        defer t.deinit();
        try std.testing.expectError(error.InvalidEscape, t.next());
    }
}

fn expectTokenizeString(input: []const u8, want: []const u8) !void {
    {
        var t = Tokenizer.init(std.testing.allocator, input, .{});
        defer t.deinit();
        const tok = try t.next();
        try std.testing.expectEqual(TokenType.string, tok.type);
        try std.testing.expectEqualStrings(want, tok.bytes);
    }
    {
        var reader: std.Io.Reader = .fixed(input);
        var t = try readerTokenizer(std.testing.allocator, &reader, .{});
        defer t.deinit();
        const tok = try t.next();
        try std.testing.expectEqual(TokenType.string, tok.type);
        try std.testing.expectEqualStrings(want, tok.bytes);
    }
}

test "SONNY-2768: tokenizers reject signed and underscored \\u escapes" {
    for ([_][]const u8{ "\"\\u+041\"", "\"\\u0_41\"", "\"\\u-000\"" }) |in| {
        try expectTokenizeInvalidEscape(in);
    }
}

test "SONNY-2768: tokenizers reject a non-hex byte at every \\u position" {
    const lone = comptime sonny2768BadInputs("\"\\u0041\"", 3);
    for (&lone) |*in| try expectTokenizeInvalidEscape(in);
    const pair = comptime sonny2768BadInputs("\"\\uD83D\\uDE00\"", 9);
    for (&pair) |*in| try expectTokenizeInvalidEscape(in);
}

test "SONNY-2768: tokenizers accept upper, lower and mixed case \\u hex" {
    try expectTokenizeString("\"\\u00e9\\u00E9\"", "\xC3\xA9\xC3\xA9");
    try expectTokenizeString("\"\\uABCD\\uabcd\\uAbCd\"", "\xEA\xAF\x8D" ** 3);
    try expectTokenizeString("\"\\ud83d\\ude00\\uD83D\\uDE00\\uD83d\\uDe00\"", "\xF0\x9F\x98\x80" ** 3);
}
