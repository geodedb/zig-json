// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! RFC 8259 Strict JSON Parser
//!
//! Implements strict JSON parsing with:
//! - No comments
//! - No trailing commas
//! - No NaN/Infinity
//! - No leading zeros in numbers
//! - No unescaped control characters in strings
//! - Full surrogate pair handling

const std = @import("std");
const json = @import("json.zig");
const unicode = @import("unicode.zig");
const number_mod = @import("number.zig");

const ErrorCode = json.ErrorCode;
const ParseError = json.ParseError;
const ParseOptions = json.ParseOptions;
const Number = json.Number;
const Member = json.Member;
const Value = json.Value;
const Document = json.Document;

const Parser = struct {
    input: []const u8,
    pos: usize,
    line: u32,
    col: u32,
    opts: ParseOptions,
    arena: std.heap.ArenaAllocator,
    node_count: u32,
    depth: u16,
    err: *ParseError,

    fn init(a: std.mem.Allocator, input: []const u8, opts: ParseOptions, err: *ParseError) Parser {
        return .{
            .input = input,
            .pos = 0,
            .line = 1,
            .col = 1,
            .opts = opts,
            .arena = std.heap.ArenaAllocator.init(a),
            .node_count = 0,
            .depth = 0,
            .err = err,
        };
    }

    fn alloc(self: *Parser) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn setError(self: *Parser, code: ErrorCode) void {
        self.err.* = .{
            .code = code,
            .line = self.line,
            .col = self.col,
            .offset = @intCast(self.pos),
        };
    }

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    fn advance(self: *Parser) void {
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

    fn skipWhitespace(self: *Parser) void {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.advance();
            } else if (self.opts.json5 and c == '/') {
                // JSON5: Handle comments
                if (self.pos + 1 < self.input.len) {
                    const next = self.input[self.pos + 1];
                    if (next == '/') {
                        // Single-line comment
                        self.advance(); // skip /
                        self.advance(); // skip /
                        while (self.peek()) |cc| {
                            if (cc == '\n') {
                                self.advance();
                                break;
                            }
                            self.advance();
                        }
                    } else if (next == '*') {
                        // Multi-line comment
                        self.advance(); // skip /
                        self.advance(); // skip *
                        while (self.pos + 1 < self.input.len) {
                            if (self.input[self.pos] == '*' and self.input[self.pos + 1] == '/') {
                                self.advance(); // skip *
                                self.advance(); // skip /
                                break;
                            }
                            self.advance();
                        }
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            } else {
                break;
            }
        }
    }

    fn checkLimits(self: *Parser) !void {
        if (self.pos > self.opts.max_bytes) {
            self.setError(.ByteLimit);
            return error.JsonLimit;
        }
        if (self.node_count >= self.opts.max_nodes) {
            self.setError(.NodeLimit);
            return error.JsonLimit;
        }
        if (self.depth > self.opts.max_depth) {
            self.setError(.DepthLimit);
            return error.JsonLimit;
        }
    }

    const ParseValueError = error{ JsonParse, JsonLimit, OutOfMemory };

    fn parseValue(self: *Parser) ParseValueError!Value {
        try self.checkLimits();
        self.skipWhitespace();

        const c = self.peek() orelse {
            self.setError(.UnexpectedEof);
            return error.JsonParse;
        };

        self.node_count += 1;

        return switch (c) {
            'n' => self.parseNull(),
            't', 'f' => self.parseBool(),
            '"' => self.parseString(),
            '\'' => if (self.opts.json5) self.parseString5() else {
                self.setError(.UnexpectedToken);
                return error.JsonParse;
            },
            '[' => self.parseArray(),
            '{' => self.parseObject(),
            '-' => self.parseNumber(),
            '+' => if (self.opts.json5) self.parseNumber() else {
                self.setError(.UnexpectedToken);
                return error.JsonParse;
            },
            '.' => if (self.opts.json5) self.parseNumber() else {
                self.setError(.UnexpectedToken);
                return error.JsonParse;
            },
            '0'...'9' => self.parseNumber(),
            'I' => if (self.opts.json5) self.parseJson5Literal() else {
                self.setError(.UnexpectedToken);
                return error.JsonParse;
            },
            'N' => if (self.opts.json5) self.parseJson5Literal() else {
                self.setError(.UnexpectedToken);
                return error.JsonParse;
            },
            else => {
                self.setError(.UnexpectedToken);
                return error.JsonParse;
            },
        };
    }

    fn parseJson5Literal(self: *Parser) !Value {
        // Handle NaN, Infinity
        if (self.pos + 8 <= self.input.len and
            std.mem.eql(u8, self.input[self.pos..][0..8], "Infinity"))
        {
            self.pos += 8;
            self.col += 8;
            // Return as a number with Infinity lexeme
            const lexeme = try self.alloc().dupe(u8, "Infinity");
            return .{ .num = .{ .lexeme = lexeme, .sign = 1, .digits = "Infinity", .exp10 = 0 } };
        }
        if (self.pos + 3 <= self.input.len and
            std.mem.eql(u8, self.input[self.pos..][0..3], "NaN"))
        {
            self.pos += 3;
            self.col += 3;
            const lexeme = try self.alloc().dupe(u8, "NaN");
            return .{ .num = .{ .lexeme = lexeme, .sign = 1, .digits = "NaN", .exp10 = 0 } };
        }
        self.setError(.UnexpectedToken);
        return error.JsonParse;
    }

    fn parseString5(self: *Parser) !Value {
        // JSON5: Single-quoted strings
        const str = try self.parseStringRaw5();
        return .{ .str = str };
    }

    fn parseStringRaw5(self: *Parser) ![]const u8 {
        if (self.peek() != '\'') {
            self.setError(.UnexpectedToken);
            return error.JsonParse;
        }
        self.advance();

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.alloc());

        while (self.peek()) |c| {
            if (c == '\'') {
                self.advance();
                return result.toOwnedSlice(self.alloc());
            }

            if (c < 0x20 and c != '\n' and c != '\r' and c != '\t') {
                self.setError(.InvalidString);
                return error.JsonParse;
            }

            // JSON5: Allow newlines in strings with backslash continuation
            if (c == '\\') {
                self.advance();
                const next = self.peek() orelse {
                    self.setError(.UnexpectedEof);
                    return error.JsonParse;
                };
                if (next == '\n') {
                    self.advance();
                    continue;
                } else if (next == '\r') {
                    self.advance();
                    if (self.peek() == '\n') self.advance();
                    continue;
                }
                const escaped = try self.parseEscape5();
                try result.appendSlice(self.alloc(), escaped);
            } else {
                const seq_len = unicode.utf8SeqLen(c) catch {
                    self.setError(.InvalidUtf8);
                    return error.JsonParse;
                };
                if (self.pos + seq_len > self.input.len) {
                    self.setError(.InvalidUtf8);
                    return error.JsonParse;
                }
                const seq = self.input[self.pos..][0..seq_len];
                if (!unicode.isValidUtf8Seq(seq)) {
                    self.setError(.InvalidUtf8);
                    return error.JsonParse;
                }
                try result.appendSlice(self.alloc(), seq);
                for (0..seq_len) |_| self.advance();
            }
        }

        self.setError(.UnexpectedEof);
        return error.JsonParse;
    }

    fn parseEscape5(self: *Parser) ![]const u8 {
        const c = self.peek() orelse {
            self.setError(.UnexpectedEof);
            return error.JsonParse;
        };

        self.advance();

        return switch (c) {
            '"' => "\"",
            '\'' => "'",
            '\\' => "\\",
            '/' => "/",
            'b' => "\x08",
            'f' => "\x0C",
            'n' => "\n",
            'r' => "\r",
            't' => "\t",
            'v' => "\x0B", // JSON5: vertical tab
            '0' => "\x00", // JSON5: null character
            'u' => try self.parseUnicodeEscape(),
            'x' => try self.parseHexEscape(), // JSON5: \xNN escape
            else => {
                self.setError(.InvalidEscape);
                return error.JsonParse;
            },
        };
    }

    fn parseHexEscape(self: *Parser) ![]const u8 {
        if (self.pos + 2 > self.input.len) {
            self.setError(.InvalidEscape);
            return error.JsonParse;
        }

        const hex = self.input[self.pos..][0..2];
        const byte = std.fmt.parseInt(u8, hex, 16) catch {
            self.setError(.InvalidEscape);
            return error.JsonParse;
        };
        self.pos += 2;
        self.col += 2;

        const result = try self.alloc().alloc(u8, 1);
        result[0] = byte;
        return result;
    }

    fn parseNull(self: *Parser) !Value {
        if (self.pos + 4 <= self.input.len and
            std.mem.eql(u8, self.input[self.pos..][0..4], "null"))
        {
            self.pos += 4;
            self.col += 4;
            return .null;
        }
        self.setError(.UnexpectedToken);
        return error.JsonParse;
    }

    fn parseBool(self: *Parser) !Value {
        if (self.pos + 4 <= self.input.len and
            std.mem.eql(u8, self.input[self.pos..][0..4], "true"))
        {
            self.pos += 4;
            self.col += 4;
            return .{ .bool = true };
        }
        if (self.pos + 5 <= self.input.len and
            std.mem.eql(u8, self.input[self.pos..][0..5], "false"))
        {
            self.pos += 5;
            self.col += 5;
            return .{ .bool = false };
        }
        self.setError(.UnexpectedToken);
        return error.JsonParse;
    }

    fn parseString(self: *Parser) !Value {
        const str = try self.parseStringRaw();
        return .{ .str = str };
    }

    fn parseStringRaw(self: *Parser) ![]const u8 {
        if (self.peek() != '"') {
            self.setError(.UnexpectedToken);
            return error.JsonParse;
        }
        self.advance();

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.alloc());

        while (self.peek()) |c| {
            if (c == '"') {
                self.advance();
                return result.toOwnedSlice(self.alloc());
            }

            if (c < 0x20) {
                self.setError(.InvalidString);
                return error.JsonParse;
            }

            if (c == '\\') {
                self.advance();
                const escaped = try self.parseEscape();
                try result.appendSlice(self.alloc(), escaped);
            } else {
                const seq_len = unicode.utf8SeqLen(c) catch {
                    self.setError(.InvalidUtf8);
                    return error.JsonParse;
                };
                if (self.pos + seq_len > self.input.len) {
                    self.setError(.InvalidUtf8);
                    return error.JsonParse;
                }
                const seq = self.input[self.pos..][0..seq_len];
                if (!unicode.isValidUtf8Seq(seq)) {
                    self.setError(.InvalidUtf8);
                    return error.JsonParse;
                }
                try result.appendSlice(self.alloc(), seq);
                for (0..seq_len) |_| self.advance();
            }
        }

        self.setError(.UnexpectedEof);
        return error.JsonParse;
    }

    fn parseEscape(self: *Parser) ![]const u8 {
        const c = self.peek() orelse {
            self.setError(.UnexpectedEof);
            return error.JsonParse;
        };

        self.advance();

        return switch (c) {
            '"' => "\"",
            '\\' => "\\",
            '/' => "/",
            'b' => "\x08",
            'f' => "\x0C",
            'n' => "\n",
            'r' => "\r",
            't' => "\t",
            'u' => try self.parseUnicodeEscape(),
            else => {
                self.setError(.InvalidEscape);
                return error.JsonParse;
            },
        };
    }

    fn parseUnicodeEscape(self: *Parser) ![]const u8 {
        if (self.pos + 4 > self.input.len) {
            self.setError(.InvalidEscape);
            return error.JsonParse;
        }

        const hex = self.input[self.pos..][0..4];
        const cp1 = std.fmt.parseInt(u16, hex, 16) catch {
            self.setError(.InvalidEscape);
            return error.JsonParse;
        };
        self.pos += 4;
        self.col += 4;

        var codepoint: u21 = cp1;

        // Handle surrogate pairs
        if (cp1 >= 0xD800 and cp1 <= 0xDBFF) {
            // High surrogate - must be followed by low surrogate
            if (self.pos + 6 > self.input.len or
                self.input[self.pos] != '\\' or
                self.input[self.pos + 1] != 'u')
            {
                self.setError(.InvalidSurrogate);
                return error.JsonParse;
            }
            self.pos += 2;
            self.col += 2;

            const hex2 = self.input[self.pos..][0..4];
            const cp2 = std.fmt.parseInt(u16, hex2, 16) catch {
                self.setError(.InvalidEscape);
                return error.JsonParse;
            };

            if (cp2 < 0xDC00 or cp2 > 0xDFFF) {
                self.setError(.InvalidSurrogate);
                return error.JsonParse;
            }

            self.pos += 4;
            self.col += 4;

            codepoint = 0x10000 + (@as(u21, cp1 - 0xD800) << 10) + @as(u21, cp2 - 0xDC00);
        } else if (cp1 >= 0xDC00 and cp1 <= 0xDFFF) {
            // Lone low surrogate is invalid
            self.setError(.InvalidSurrogate);
            return error.JsonParse;
        }

        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch {
            self.setError(.InvalidSurrogate);
            return error.JsonParse;
        };

        const result = try self.alloc().alloc(u8, len);
        @memcpy(result, buf[0..len]);
        return result;
    }

    fn parseNumber(self: *Parser) !Value {
        const start = self.pos;

        // Optional sign (JSON5 allows +)
        if (self.peek() == '-') {
            self.advance();
        } else if (self.opts.json5 and self.peek() == '+') {
            self.advance();
        }

        // JSON5: Check for hex number 0x or 0X
        if (self.opts.json5 and self.peek() == '0' and self.pos + 1 < self.input.len) {
            const next = self.input[self.pos + 1];
            if (next == 'x' or next == 'X') {
                self.advance(); // skip 0
                self.advance(); // skip x
                var has_hex = false;
                while (self.peek()) |h| {
                    if ((h >= '0' and h <= '9') or (h >= 'a' and h <= 'f') or (h >= 'A' and h <= 'F')) {
                        self.advance();
                        has_hex = true;
                    } else break;
                }
                if (!has_hex) {
                    self.setError(.InvalidNumber);
                    return error.JsonParse;
                }
                const lexeme = self.input[start..self.pos];
                const lexeme_copy = try self.alloc().dupe(u8, lexeme);
                // For hex, parse to integer and create number
                const hex_start: usize = if (lexeme[0] == '-' or lexeme[0] == '+') 3 else 2;
                const hex_val = std.fmt.parseInt(i64, lexeme[hex_start..], 16) catch {
                    self.setError(.InvalidNumber);
                    return error.JsonParse;
                };
                const signed_val = if (lexeme[0] == '-') -hex_val else hex_val;
                var buf: [32]u8 = undefined;
                const decimal_str = std.fmt.bufPrint(&buf, "{d}", .{signed_val}) catch {
                    self.setError(.InvalidNumber);
                    return error.JsonParse;
                };
                const num = number_mod.parseNumber(try self.alloc().dupe(u8, decimal_str), self.alloc()) catch {
                    self.setError(.InvalidNumber);
                    return error.JsonParse;
                };
                return .{ .num = .{ .lexeme = lexeme_copy, .sign = num.sign, .digits = num.digits, .exp10 = num.exp10 } };
            }
        }

        // JSON5: Leading decimal point (.5)
        if (self.opts.json5 and self.peek() == '.') {
            self.advance();
            var has_frac = false;
            while (self.peek()) |d| {
                if (d >= '0' and d <= '9') {
                    self.advance();
                    has_frac = true;
                } else break;
            }
            if (!has_frac) {
                self.setError(.InvalidNumber);
                return error.JsonParse;
            }
            // Check for exponent
            if (self.peek()) |e| {
                if (e == 'e' or e == 'E') {
                    try self.parseExponent();
                }
            }
            const lexeme = self.input[start..self.pos];
            const lexeme_copy = try self.alloc().dupe(u8, lexeme);
            const num = number_mod.parseNumber(lexeme_copy, self.alloc()) catch {
                self.setError(.InvalidNumber);
                return error.JsonParse;
            };
            return .{ .num = num };
        }

        // Integer part
        const first = self.peek() orelse {
            self.setError(.InvalidNumber);
            return error.JsonParse;
        };

        if (first == '0') {
            self.advance();
            // Leading zeros not allowed (except for 0 itself) in strict JSON
            if (!self.opts.json5) {
                if (self.peek()) |n| {
                    if (n >= '0' and n <= '9') {
                        self.setError(.InvalidNumber);
                        return error.JsonParse;
                    }
                }
            }
        } else if (first >= '1' and first <= '9') {
            while (self.peek()) |d| {
                if (d >= '0' and d <= '9') self.advance() else break;
            }
        } else {
            self.setError(.InvalidNumber);
            return error.JsonParse;
        }

        // Fractional part
        if (self.peek() == '.') {
            self.advance();
            var has_frac = false;
            while (self.peek()) |d| {
                if (d >= '0' and d <= '9') {
                    self.advance();
                    has_frac = true;
                } else break;
            }
            // JSON5: Trailing decimal point allowed (5.)
            if (!has_frac and !self.opts.json5) {
                self.setError(.InvalidNumber);
                return error.JsonParse;
            }
        }

        // Exponent part
        if (self.peek()) |e| {
            if (e == 'e' or e == 'E') {
                try self.parseExponent();
            }
        }

        const lexeme = self.input[start..self.pos];
        const lexeme_copy = try self.alloc().dupe(u8, lexeme);

        const num = number_mod.parseNumber(lexeme_copy, self.alloc()) catch {
            self.setError(.InvalidNumber);
            return error.JsonParse;
        };

        return .{ .num = num };
    }

    fn parseExponent(self: *Parser) !void {
        self.advance(); // skip e/E
        if (self.peek()) |s| {
            if (s == '+' or s == '-') self.advance();
        }
        var has_exp = false;
        while (self.peek()) |d| {
            if (d >= '0' and d <= '9') {
                self.advance();
                has_exp = true;
            } else break;
        }
        if (!has_exp) {
            self.setError(.InvalidNumber);
            return error.JsonParse;
        }
    }

    fn parseArray(self: *Parser) !Value {
        if (self.peek() != '[') {
            self.setError(.UnexpectedToken);
            return error.JsonParse;
        }
        self.advance();
        self.depth += 1;
        defer self.depth -= 1;

        try self.checkLimits();

        var items: std.ArrayList(Value) = .empty;
        errdefer items.deinit(self.alloc());

        self.skipWhitespace();

        if (self.peek() == ']') {
            self.advance();
            return .{ .arr = try items.toOwnedSlice(self.alloc()) };
        }

        while (true) {
            const val = try self.parseValue();
            try items.append(self.alloc(), val);

            self.skipWhitespace();

            const c = self.peek() orelse {
                self.setError(.UnexpectedEof);
                return error.JsonParse;
            };

            if (c == ']') {
                self.advance();
                return .{ .arr = try items.toOwnedSlice(self.alloc()) };
            }

            if (c != ',') {
                self.setError(.UnexpectedToken);
                return error.JsonParse;
            }
            self.advance();
            self.skipWhitespace();

            // JSON5: Trailing commas allowed
            if (self.peek() == ']') {
                if (self.opts.json5) {
                    self.advance();
                    return .{ .arr = try items.toOwnedSlice(self.alloc()) };
                }
                self.setError(.UnexpectedToken);
                return error.JsonParse;
            }
        }
    }

    fn parseObject(self: *Parser) !Value {
        if (self.peek() != '{') {
            self.setError(.UnexpectedToken);
            return error.JsonParse;
        }
        self.advance();
        self.depth += 1;
        defer self.depth -= 1;

        try self.checkLimits();

        var members: std.ArrayList(Member) = .empty;
        errdefer members.deinit(self.alloc());

        var keys = std.StringHashMap(void).init(self.alloc());
        defer keys.deinit();

        self.skipWhitespace();

        if (self.peek() == '}') {
            self.advance();
            return .{ .obj = try members.toOwnedSlice(self.alloc()) };
        }

        while (true) {
            self.skipWhitespace();

            const key = blk: {
                const c = self.peek() orelse {
                    self.setError(.UnexpectedEof);
                    return error.JsonParse;
                };
                if (c == '"') {
                    break :blk try self.parseStringRaw();
                } else if (c == '\'' and self.opts.json5) {
                    break :blk try self.parseStringRaw5();
                } else if (self.opts.json5 and isIdentStart(c)) {
                    // JSON5: Unquoted key (ECMAScript identifier)
                    break :blk try self.parseIdentifier();
                } else {
                    self.setError(.UnexpectedToken);
                    return error.JsonParse;
                }
            };

            if (self.opts.unique_keys) {
                if (keys.contains(key)) {
                    self.setError(.DuplicateKey);
                    return error.JsonParse;
                }
                try keys.put(key, {});
            }

            self.skipWhitespace();

            if (self.peek() != ':') {
                self.setError(.UnexpectedToken);
                return error.JsonParse;
            }
            self.advance();

            const val = try self.parseValue();

            try members.append(self.alloc(), .{ .k = key, .v = val });

            self.skipWhitespace();

            const c = self.peek() orelse {
                self.setError(.UnexpectedEof);
                return error.JsonParse;
            };

            if (c == '}') {
                self.advance();
                return .{ .obj = try members.toOwnedSlice(self.alloc()) };
            }

            if (c != ',') {
                self.setError(.UnexpectedToken);
                return error.JsonParse;
            }
            self.advance();
            self.skipWhitespace();

            // JSON5: Trailing commas allowed
            if (self.peek() == '}') {
                if (self.opts.json5) {
                    self.advance();
                    return .{ .obj = try members.toOwnedSlice(self.alloc()) };
                }
                self.setError(.UnexpectedToken);
                return error.JsonParse;
            }
        }
    }

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
    }

    fn isIdentContinue(c: u8) bool {
        return isIdentStart(c) or (c >= '0' and c <= '9');
    }

    fn parseIdentifier(self: *Parser) ![]const u8 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (isIdentContinue(c)) {
                self.advance();
            } else {
                break;
            }
        }
        if (self.pos == start) {
            self.setError(.UnexpectedToken);
            return error.JsonParse;
        }
        return try self.alloc().dupe(u8, self.input[start..self.pos]);
    }
};

pub fn parse(a: std.mem.Allocator, input: []const u8, opts: ParseOptions, err: *ParseError) !Document {
    if (input.len > opts.max_bytes) {
        err.* = .{ .code = .ByteLimit, .line = 1, .col = 1, .offset = 0 };
        return error.JsonLimit;
    }

    var p = Parser.init(a, input, opts, err);
    errdefer p.arena.deinit();

    // Handle optional BOM
    if (opts.allow_bom and input.len >= 3 and
        input[0] == 0xEF and input[1] == 0xBB and input[2] == 0xBF)
    {
        p.pos = 3;
        p.col = 4;
    }

    const root = try p.parseValue();

    p.skipWhitespace();
    if (p.pos < p.input.len) {
        p.setError(.TrailingGarbage);
        return error.JsonParse;
    }

    return .{
        .arena = p.arena,
        .root = root,
    };
}

test "parse null" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "null", .{}, &err);
    defer doc.deinit();
    try std.testing.expect(doc.root == .null);
}

test "parse bool" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "true", .{}, &err);
    defer doc.deinit();
    try std.testing.expect(doc.root.bool == true);
}

test "parse string" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "\"hello\"", .{}, &err);
    defer doc.deinit();
    try std.testing.expectEqualStrings("hello", doc.root.str);
}

test "parse array" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "[1, 2, 3]", .{}, &err);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 3), doc.root.arr.len);
}

test "parse object" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "{\"a\": 1}", .{}, &err);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.root.obj.len);
}

test "reject trailing comma in array" {
    var err = ParseError.init();
    const result = parse(std.testing.allocator, "[1,]", .{}, &err);
    try std.testing.expectError(error.JsonParse, result);
}

test "reject trailing comma in object" {
    var err = ParseError.init();
    const result = parse(std.testing.allocator, "{\"a\":1,}", .{}, &err);
    try std.testing.expectError(error.JsonParse, result);
}

test "reject leading zero" {
    var err = ParseError.init();
    const result = parse(std.testing.allocator, "01", .{}, &err);
    try std.testing.expectError(error.JsonParse, result);
}

test "parse BOM" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "\xEF\xBB\xBFnull", .{}, &err);
    defer doc.deinit();
    try std.testing.expect(doc.root == .null);
}

test "parse unicode escape" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "\"\\u0041\"", .{}, &err);
    defer doc.deinit();
    try std.testing.expectEqualStrings("A", doc.root.str);
}

test "parse surrogate pair" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "\"\\uD83D\\uDE00\"", .{}, &err);
    defer doc.deinit();
    // U+1F600 = grinning face emoji
    try std.testing.expectEqualStrings("\xF0\x9F\x98\x80", doc.root.str);
}

test "reject lone high surrogate" {
    var err = ParseError.init();
    const result = parse(std.testing.allocator, "\"\\uD83D\"", .{}, &err);
    try std.testing.expectError(error.JsonParse, result);
    try std.testing.expectEqual(ErrorCode.InvalidSurrogate, err.code);
}

test "reject lone low surrogate" {
    var err = ParseError.init();
    const result = parse(std.testing.allocator, "\"\\uDE00\"", .{}, &err);
    try std.testing.expectError(error.JsonParse, result);
    try std.testing.expectEqual(ErrorCode.InvalidSurrogate, err.code);
}

// ============================================================================
// JSON5 Tests
// ============================================================================

test "json5: single-line comment" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "// comment\n42", .{ .json5 = true }, &err);
    defer doc.deinit();
    try std.testing.expectEqualStrings("42", doc.root.num.lexeme);
}

test "json5: multi-line comment" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "/* comment */ 42", .{ .json5 = true }, &err);
    defer doc.deinit();
    try std.testing.expectEqualStrings("42", doc.root.num.lexeme);
}

test "json5: trailing comma in array" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "[1, 2, 3,]", .{ .json5 = true }, &err);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 3), doc.root.arr.len);
}

test "json5: trailing comma in object" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "{\"a\": 1,}", .{ .json5 = true }, &err);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.root.obj.len);
}

test "json5: unquoted keys" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "{foo: 1, bar: 2}", .{ .json5 = true }, &err);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 2), doc.root.obj.len);
    try std.testing.expectEqualStrings("foo", doc.root.obj[0].k);
    try std.testing.expectEqualStrings("bar", doc.root.obj[1].k);
}

test "json5: single-quoted strings" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "'hello'", .{ .json5 = true }, &err);
    defer doc.deinit();
    try std.testing.expectEqualStrings("hello", doc.root.str);
}

test "json5: hex numbers" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "0xFF", .{ .json5 = true }, &err);
    defer doc.deinit();
    try std.testing.expectEqualStrings("0xFF", doc.root.num.lexeme);
}

test "json5: positive sign" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "+42", .{ .json5 = true }, &err);
    defer doc.deinit();
    try std.testing.expectEqualStrings("+42", doc.root.num.lexeme);
}

test "json5: leading decimal point" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, ".5", .{ .json5 = true }, &err);
    defer doc.deinit();
    try std.testing.expectEqualStrings(".5", doc.root.num.lexeme);
}

test "json5: trailing decimal point" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "5.", .{ .json5 = true }, &err);
    defer doc.deinit();
    try std.testing.expectEqualStrings("5.", doc.root.num.lexeme);
}

test "json5: Infinity" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "Infinity", .{ .json5 = true }, &err);
    defer doc.deinit();
    try std.testing.expectEqualStrings("Infinity", doc.root.num.lexeme);
}

test "json5: NaN" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "NaN", .{ .json5 = true }, &err);
    defer doc.deinit();
    try std.testing.expectEqualStrings("NaN", doc.root.num.lexeme);
}
