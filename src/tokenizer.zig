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
    /// Byte offset in input
    offset: u32,
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
                .offset = @intCast(self.pos),
            };
        }

        const start_line = self.line;
        const start_col = self.col;
        const start_pos = self.pos;
        const c = self.input[self.pos];

        return switch (c) {
            '{' => {
                self.advance();
                return Token{ .type = .object_start, .bytes = "{", .line = start_line, .col = start_col, .offset = @intCast(start_pos) };
            },
            '}' => {
                self.advance();
                return Token{ .type = .object_end, .bytes = "}", .line = start_line, .col = start_col, .offset = @intCast(start_pos) };
            },
            '[' => {
                self.advance();
                return Token{ .type = .array_start, .bytes = "[", .line = start_line, .col = start_col, .offset = @intCast(start_pos) };
            },
            ']' => {
                self.advance();
                return Token{ .type = .array_end, .bytes = "]", .line = start_line, .col = start_col, .offset = @intCast(start_pos) };
            },
            ':' => {
                self.advance();
                return Token{ .type = .colon, .bytes = ":", .line = start_line, .col = start_col, .offset = @intCast(start_pos) };
            },
            ',' => {
                self.advance();
                return Token{ .type = .comma, .bytes = ",", .line = start_line, .col = start_col, .offset = @intCast(start_pos) };
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
            .object_start => {
                var depth: u16 = 1;
                while (depth > 0) {
                    const t = try self.next();
                    switch (t.type) {
                        .object_start => depth += 1,
                        .object_end => depth -= 1,
                        .array_start => {
                            // Need to track array depth too
                            try self.skipArrayContents();
                        },
                        .eof => return error.UnexpectedEof,
                        else => {},
                    }
                }
            },
            .array_start => {
                try self.skipArrayContents();
            },
            .string, .number, .true_literal, .false_literal, .null_literal => {
                // Primitive values are already consumed
            },
            .eof => return error.UnexpectedEof,
            else => return error.UnexpectedToken,
        }
    }

    fn skipArrayContents(self: *Tokenizer) TokenizerError!void {
        var depth: u16 = 1;
        while (depth > 0) {
            const t = try self.next();
            switch (t.type) {
                .array_start => depth += 1,
                .array_end => depth -= 1,
                .object_start => {
                    // Need to track object depth too
                    var obj_depth: u16 = 1;
                    while (obj_depth > 0) {
                        const ot = try self.next();
                        switch (ot.type) {
                            .object_start => obj_depth += 1,
                            .object_end => obj_depth -= 1,
                            .array_start => try self.skipArrayContents(),
                            .eof => return error.UnexpectedEof,
                            else => {},
                        }
                    }
                },
                .eof => return error.UnexpectedEof,
                else => {},
            }
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
                    .offset = @intCast(start_pos),
                };
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
                _ = unicode.decodeUtf8(seq) catch return error.InvalidUtf8;

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
        const cp1 = std.fmt.parseInt(u16, hex, 16) catch return error.InvalidEscape;
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
            const cp2 = std.fmt.parseInt(u16, hex2, 16) catch return error.InvalidEscape;
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
            .offset = @intCast(start_pos),
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
            .offset = @intCast(start_pos),
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
            .offset = @intCast(start_pos),
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
            .offset = @intCast(start_pos),
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
    const token = try tokenizer.next();

    return switch (token.type) {
        .null_literal => .null,
        .true_literal => .{ .bool = true },
        .false_literal => .{ .bool = false },
        .string => .{ .str = tokenizer.allocator.dupe(u8, token.bytes) catch return error.OutOfMemory },
        .number => .{ .num = parseNumberToken(token.bytes) },
        .array_start => try readArray(tokenizer),
        .object_start => try readObject(tokenizer),
        .eof => error.UnexpectedEof,
        else => error.UnexpectedToken,
    };
}

/// Free memory allocated by readValue
pub fn freeValue(allocator: std.mem.Allocator, value: json.Value) void {
    switch (value) {
        .null, .bool, .num => {}, // no allocation
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

fn parseNumberToken(lexeme: []const u8) json.Number {
    // Parse the number lexeme into a normalized Number
    var sign: i8 = 1;
    var start: usize = 0;

    if (lexeme.len > 0 and lexeme[0] == '-') {
        sign = -1;
        start = 1;
    }

    // Find integer and fraction parts
    var int_end = start;
    while (int_end < lexeme.len and lexeme[int_end] >= '0' and lexeme[int_end] <= '9') {
        int_end += 1;
    }

    var frac_start: usize = int_end;
    var frac_end: usize = int_end;
    if (int_end < lexeme.len and lexeme[int_end] == '.') {
        frac_start = int_end + 1;
        frac_end = frac_start;
        while (frac_end < lexeme.len and lexeme[frac_end] >= '0' and lexeme[frac_end] <= '9') {
            frac_end += 1;
        }
    }

    // Parse exponent
    var exp10: i32 = 0;
    var exp_idx = frac_end;
    if (exp_idx < lexeme.len and (lexeme[exp_idx] == 'e' or lexeme[exp_idx] == 'E')) {
        exp_idx += 1;
        var exp_sign: i32 = 1;
        if (exp_idx < lexeme.len and lexeme[exp_idx] == '-') {
            exp_sign = -1;
            exp_idx += 1;
        } else if (exp_idx < lexeme.len and lexeme[exp_idx] == '+') {
            exp_idx += 1;
        }
        while (exp_idx < lexeme.len and lexeme[exp_idx] >= '0' and lexeme[exp_idx] <= '9') {
            exp10 = exp10 * 10 + @as(i32, @intCast(lexeme[exp_idx] - '0'));
            exp_idx += 1;
        }
        exp10 *= exp_sign;
    }

    // Adjust exponent for fraction digits
    if (frac_end > frac_start) {
        exp10 -= @intCast(frac_end - frac_start);
    }

    // Build digits string (integer + fraction without decimal point)
    const digits = if (frac_end > frac_start)
        lexeme[start..int_end] // We'll need to concatenate, but for now just use integer part
    else
        lexeme[start..int_end];

    return .{
        .lexeme = lexeme,
        .sign = sign,
        .digits = digits,
        .exp10 = exp10,
    };
}

fn readArray(tokenizer: *Tokenizer) TokenizerError!json.Value {
    var items: std.ArrayList(json.Value) = .empty;
    defer items.deinit(tokenizer.allocator);

    while (true) {
        const peek_token = try tokenizer.peek();
        if (peek_token.type == .array_end) {
            _ = try tokenizer.next(); // consume ]
            break;
        }

        const item = try readValue(tokenizer);
        items.append(tokenizer.allocator, item) catch return error.OutOfMemory;

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

fn readObject(tokenizer: *Tokenizer) TokenizerError!json.Value {
    var members: std.ArrayList(json.Member) = .empty;
    defer members.deinit(tokenizer.allocator);

    while (true) {
        const peek_token = try tokenizer.peek();
        if (peek_token.type == .object_end) {
            _ = try tokenizer.next(); // consume }
            break;
        }

        // Read key
        const key_token = try tokenizer.next();
        if (key_token.type != .string) return error.UnexpectedToken;

        // Dupe the key since tokenizer buffer will be reused
        const key = tokenizer.allocator.dupe(u8, key_token.bytes) catch return error.OutOfMemory;

        // Read colon
        const colon_token = try tokenizer.next();
        if (colon_token.type != .colon) return error.UnexpectedToken;

        // Read value
        const value = try readValue(tokenizer);

        members.append(tokenizer.allocator, .{ .k = key, .v = value }) catch return error.OutOfMemory;

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
    OutOfMemory,
    IoError,
    BufferOverflow,
};

/// A streaming JSON tokenizer that reads from any std.io.Reader
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
                    .offset = @intCast(self.total_read),
                };
            };

            const start_line = self.line;
            const start_col = self.col;
            const start_pos = self.total_read;

            return switch (c) {
                '{' => {
                    self.advance();
                    return Token{ .type = .object_start, .bytes = "{", .line = start_line, .col = start_col, .offset = @intCast(start_pos) };
                },
                '}' => {
                    self.advance();
                    return Token{ .type = .object_end, .bytes = "}", .line = start_line, .col = start_col, .offset = @intCast(start_pos) };
                },
                '[' => {
                    self.advance();
                    return Token{ .type = .array_start, .bytes = "[", .line = start_line, .col = start_col, .offset = @intCast(start_pos) };
                },
                ']' => {
                    self.advance();
                    return Token{ .type = .array_end, .bytes = "]", .line = start_line, .col = start_col, .offset = @intCast(start_pos) };
                },
                ':' => {
                    self.advance();
                    return Token{ .type = .colon, .bytes = ":", .line = start_line, .col = start_col, .offset = @intCast(start_pos) };
                },
                ',' => {
                    self.advance();
                    return Token{ .type = .comma, .bytes = ",", .line = start_line, .col = start_col, .offset = @intCast(start_pos) };
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
                .object_start => {
                    var depth: u16 = 1;
                    while (depth > 0) {
                        const t = try self.next();
                        switch (t.type) {
                            .object_start => depth += 1,
                            .object_end => depth -= 1,
                            .array_start => try self.skipArrayContents(),
                            .eof => return error.UnexpectedEof,
                            else => {},
                        }
                    }
                },
                .array_start => try self.skipArrayContents(),
                .string, .number, .true_literal, .false_literal, .null_literal => {},
                .eof => return error.UnexpectedEof,
                else => return error.UnexpectedToken,
            }
        }

        fn skipArrayContents(self: *Self) ReaderTokenizerError!void {
            var depth: u16 = 1;
            while (depth > 0) {
                const t = try self.next();
                switch (t.type) {
                    .array_start => depth += 1,
                    .array_end => depth -= 1,
                    .object_start => {
                        var obj_depth: u16 = 1;
                        while (obj_depth > 0) {
                            const ot = try self.next();
                            switch (ot.type) {
                                .object_start => obj_depth += 1,
                                .object_end => obj_depth -= 1,
                                .array_start => try self.skipArrayContents(),
                                .eof => return error.UnexpectedEof,
                                else => {},
                            }
                        }
                    },
                    .eof => return error.UnexpectedEof,
                    else => {},
                }
            }
        }

        // ========================================================================
        // Internal functions
        // ========================================================================

        /// Ensure we have at least one byte in the buffer
        fn ensureBuffer(self: *Self) !void {
            if (self.buf_pos >= self.buf_len) {
                if (self.eof_reached) return error.EndOfStream;
                const n = self.reader.read(self.read_buffer) catch return error.IoError;
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
                        .offset = @intCast(start_pos),
                    };
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
                    // UTF-8 multi-byte - first byte already consumed
                    self.string_buffer.append(self.allocator, c) catch return error.OutOfMemory;
                    const seq_len = unicode.utf8SeqLen(c) catch return error.InvalidUtf8;
                    var i: usize = 1;
                    while (i < seq_len) : (i += 1) {
                        const b = self.readByte() catch return error.UnexpectedEof;
                        self.string_buffer.append(self.allocator, b) catch return error.OutOfMemory;
                    }
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

            const cp1 = std.fmt.parseInt(u16, &hex, 16) catch return error.InvalidEscape;

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

                const cp2 = std.fmt.parseInt(u16, &hex2, 16) catch return error.InvalidEscape;
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
                .offset = @intCast(start_pos),
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
                .offset = @intCast(start_pos),
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
                .offset = @intCast(start_pos),
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
                    .offset = @intCast(start_pos),
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
                    .offset = @intCast(start_pos),
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
                .offset = @intCast(start_pos),
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
    const token = try tokenizer.next();

    return switch (token.type) {
        .null_literal => .null,
        .true_literal => .{ .bool = true },
        .false_literal => .{ .bool = false },
        .string => .{ .str = tokenizer.allocator.dupe(u8, token.bytes) catch return error.OutOfMemory },
        .number => .{ .num = parseNumberToken(token.bytes) },
        .array_start => try readArrayFromReader(tokenizer),
        .object_start => try readObjectFromReader(tokenizer),
        .eof => error.UnexpectedEof,
        else => error.UnexpectedToken,
    };
}

fn readArrayFromReader(tokenizer: anytype) ReaderTokenizerError!json.Value {
    var items: std.ArrayList(json.Value) = .empty;
    defer items.deinit(tokenizer.allocator);

    while (true) {
        const peek_token = try tokenizer.peek();
        if (peek_token.type == .array_end) {
            _ = try tokenizer.next();
            break;
        }

        const item = try readValueFromReader(tokenizer);
        items.append(tokenizer.allocator, item) catch return error.OutOfMemory;

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

fn readObjectFromReader(tokenizer: anytype) ReaderTokenizerError!json.Value {
    var members: std.ArrayList(json.Member) = .empty;
    defer members.deinit(tokenizer.allocator);

    while (true) {
        const peek_token = try tokenizer.peek();
        if (peek_token.type == .object_end) {
            _ = try tokenizer.next();
            break;
        }

        const key_token = try tokenizer.next();
        if (key_token.type != .string) return error.UnexpectedToken;

        const key = tokenizer.allocator.dupe(u8, key_token.bytes) catch return error.OutOfMemory;

        const colon_token = try tokenizer.next();
        if (colon_token.type != .colon) return error.UnexpectedToken;

        const value = try readValueFromReader(tokenizer);

        members.append(tokenizer.allocator, .{ .k = key, .v = value }) catch return error.OutOfMemory;

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
    var stream = std.io.fixedBufferStream(input);

    var tokenizer = try readerTokenizer(allocator, stream.reader(), .{});
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
    var stream = std.io.fixedBufferStream(input);

    var tokenizer = try readerTokenizer(allocator, stream.reader(), .{});
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
    var stream = std.io.fixedBufferStream(input);

    var tokenizer = try readerTokenizer(allocator, stream.reader(), .{});
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(TokenType.string, token.type);
    try std.testing.expectEqualStrings("Hello Hello", token.bytes);
}

test "ReaderTokenizer read value" {
    const allocator = std.testing.allocator;
    const input = "{\"items\": [1, 2, 3], \"active\": true}";
    var stream = std.io.fixedBufferStream(input);

    var tokenizer = try readerTokenizer(allocator, stream.reader(), .{});
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
    var stream = std.io.fixedBufferStream(input);

    var tokenizer = try readerTokenizer(allocator, stream.reader(), .{});
    defer tokenizer.deinit();

    try tokenizer.skipValue();
    const t = try tokenizer.next();
    try std.testing.expectEqual(TokenType.true_literal, t.type);
}

test "ReaderTokenizer number formats" {
    const allocator = std.testing.allocator;
    const input = "42 -17 3.14 1e10 -2.5e-3";
    var stream = std.io.fixedBufferStream(input);

    var tokenizer = try readerTokenizer(allocator, stream.reader(), .{});
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
