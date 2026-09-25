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
const simd = @import("simd.zig");

/// Below this member count an object dedups duplicate keys with a linear scan
/// over already-collected members instead of building a per-object hash map.
/// Linear scan avoids a hash-map allocation that would persist for the whole
/// document lifetime in the parse arena (arena deinit reclaims it only at the
/// end). See PERF-0003.
const LINEAR_DEDUP_THRESHOLD: usize = 32;

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

    /// Skip a run of plain JSON whitespace (space/tab/CR/LF) starting at the
    /// current position using the SIMD scanner, updating line/col to match a
    /// byte-at-a-time advance(). Returns true if at least one byte was skipped.
    /// Leaves self.pos at the first non-whitespace byte. (PERF-0001)
    fn skipPlainWhitespaceSIMD(self: *Parser) bool {
        const start = self.pos;
        const rel = simd.skipWhitespaceSIMD(self.input[start..]);
        if (rel == 0) return false;
        const end = start + rel;
        // Update line/col exactly as advance() would over the skipped span.
        var i = start;
        while (i < end) : (i += 1) {
            if (self.input[i] == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
        }
        self.pos = end;
        return true;
    }

    fn skipWhitespace(self: *Parser) void {
        while (true) {
            // Fast path: vectorized skip of a plain-whitespace run.
            _ = self.skipPlainWhitespaceSIMD();
            const c = self.peek() orelse return;
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                // skipPlainWhitespaceSIMD already consumed all of these; reaching
                // here only with leftover whitespace is impossible, but advance
                // defensively to guarantee forward progress.
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
        const byte = unicode.parseHex2(hex) orelse {
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

    /// Validate the span self.input[self.pos .. end] as JSON string content:
    /// reject unescaped control bytes (< 0x20) and invalid UTF-8 sequences,
    /// matching the byte-at-a-time semantics of the original parser. On success
    /// advances self.pos/line/col over the whole span and returns. On failure
    /// advances to the offending byte, sets the error, and returns error.JsonParse.
    /// `end` must be the position of a `"` or `\\` (i.e. neither appears inside).
    fn validateStringSpan(self: *Parser, end: usize) ParseValueError!void {
        while (self.pos < end) {
            const c = self.input[self.pos];
            if (c < 0x20) {
                self.setError(.InvalidString);
                return error.JsonParse;
            }
            // PERF-0011: ASCII fast-skip. For a byte in [0x20, 0x7F] (`c < 0x80`),
            // utf8SeqLen is always 1 and isValidUtf8Seq of the single byte always
            // succeeds, so col advances by exactly 1 — identical to the general
            // path below. Skipping the per-byte utf8SeqLen/isValidUtf8Seq calls is
            // behavior-preserving and only the multibyte case (c >= 0x80) falls
            // through to full UTF-8 validation (mirrors the tokenizer's c>=0x80
            // gate). Same accept/reject set, same col, same error positions.
            if (c < 0x80) {
                self.col += 1;
                self.pos += 1;
                continue;
            }
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
            // No newlines possible inside a JSON string span (control chars are
            // rejected above, and \n < 0x20), so col advances by the codepoint.
            self.col += 1;
            self.pos += seq_len;
        }
    }

    fn parseStringRaw(self: *Parser) ![]const u8 {
        if (self.peek() != '"') {
            self.setError(.UnexpectedToken);
            return error.JsonParse;
        }
        self.advance();

        const body_start = self.pos;

        // Fast path: scan for the closing quote / first escape with SIMD.
        // If the whole body has no escapes, return a single dupe of the span.
        // (PERF-0001 string scan, PERF-0002 no-escape fast path.)
        const first = simd.scanStringSIMD(self.input[self.pos..]);
        const first_rel = first.pos orelse {
            // No quote or backslash before end of input → unterminated. Validate
            // what we have so the error position/code matches the byte path
            // (control/UTF-8 errors take precedence over EOF).
            try self.validateStringSpan(self.input.len);
            self.setError(.UnexpectedEof);
            return error.JsonParse;
        };
        const first_abs = self.pos + first_rel;

        if (!first.is_escape) {
            // Closing quote with no escapes anywhere in the body.
            try self.validateStringSpan(first_abs); // advances pos to the quote
            // self.pos now == first_abs, pointing at the closing '"'.
            self.advance(); // consume '"'
            return try self.alloc().dupe(u8, self.input[body_start..first_abs]);
        }

        // Slow path: at least one escape present. Build incrementally, but
        // reserve up front to avoid realloc churn. (PERF-0002 slow-path reserve.)
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.alloc());
        // The decoded string is at most the remaining raw byte count; reserving
        // the distance to the first escape covers the common case in one alloc.
        try result.ensureTotalCapacity(self.alloc(), self.input.len - body_start);

        // Append the clean prefix before the first escape (validated), then fall
        // into the unified scan loop below starting at the escape.
        try self.validateStringSpan(first_abs);
        try result.appendSlice(self.alloc(), self.input[body_start..first_abs]);

        while (self.peek()) |c| {
            if (c == '\\') {
                self.advance();
                const escaped = try self.parseEscape();
                try result.appendSlice(self.alloc(), escaped);
            } else if (c == '"') {
                self.advance();
                return try result.toOwnedSlice(self.alloc());
            } else {
                // Scan the next clean run up to the following quote/escape.
                const scan = simd.scanStringSIMD(self.input[self.pos..]);
                const rel = scan.pos orelse {
                    try self.validateStringSpan(self.input.len);
                    self.setError(.UnexpectedEof);
                    return error.JsonParse;
                };
                const abs = self.pos + rel;
                const run_start = self.pos;
                try self.validateStringSpan(abs); // validates + advances to abs
                try result.appendSlice(self.alloc(), self.input[run_start..abs]);
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
        const cp1 = unicode.parseHex4(hex) orelse {
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
            const cp2 = unicode.parseHex4(hex2) orelse {
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
        var negative = false;
        if (self.peek() == '-') {
            self.advance();
            negative = true;
        } else if (self.opts.json5 and self.peek() == '+') {
            self.advance();
        }

        // JSON5: signed Infinity literal (GAP-0009). JSON5 §7 numbers are
        // `[+-]?(Infinity|NaN|...)`, so a leading sign may precede `Infinity`.
        // `Infinity`/`NaN` without a sign are handled in parseJson5Literal via
        // the `I`/`N` dispatch; this branch covers `-Infinity` / `+Infinity`,
        // which route through parseNumber because the sign is consumed here.
        // Strict JSON never reaches here with an `I` because parseValue only
        // dispatches `-`/`+` to parseNumber and a non-digit `I` then falls
        // through to error.InvalidNumber below — preserving strict rejection.
        if (self.opts.json5 and self.pos + 8 <= self.input.len and
            std.mem.eql(u8, self.input[self.pos..][0..8], "Infinity"))
        {
            self.pos += 8;
            self.col += 8;
            // Canonical signed-infinity Number: sign reflects the leading sign,
            // digits is the "Infinity" sentinel mantissa (mirrors cbor.zig
            // floatToNormalizedValue and the unsigned `Infinity` literal).
            const lexeme = try self.alloc().dupe(u8, self.input[start..self.pos]);
            return .{ .num = .{
                .lexeme = lexeme,
                .sign = if (negative) -1 else 1,
                .digits = "Infinity",
                .exp10 = 0,
            } };
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

        // Duplicate-key detection (PERF-0003): for small objects we scan the
        // already-collected members linearly (no allocation). Only once an
        // object grows past LINEAR_DEDUP_THRESHOLD do we build a hash map for
        // O(1) lookups. The map is only ever constructed when unique_keys is on
        // and the object is large, so the common case (small objects, default
        // options) allocates no per-object dedup table in the arena.
        var keys: ?std.StringHashMap(void) = null;
        defer if (keys) |*k| k.deinit();

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
                if (keys) |*k| {
                    // Large object: use the hash map.
                    if (k.contains(key)) {
                        self.setError(.DuplicateKey);
                        return error.JsonParse;
                    }
                    try k.put(key, {});
                } else {
                    // Small object: linear scan over already-collected keys.
                    for (members.items) |m| {
                        if (std.mem.eql(u8, m.k, key)) {
                            self.setError(.DuplicateKey);
                            return error.JsonParse;
                        }
                    }
                    // Promote to a hash map once we exceed the small-object size,
                    // seeding it with all keys collected so far.
                    if (members.items.len >= LINEAR_DEDUP_THRESHOLD) {
                        var map = std.StringHashMap(void).init(self.alloc());
                        try map.ensureTotalCapacity(@intCast(members.items.len + 1));
                        for (members.items) |m| map.putAssumeCapacity(m.k, {});
                        try map.put(key, {});
                        keys = map;
                    }
                }
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

/// Parse `input` into a `Document`.
///
/// The returned `Document` owns an arena holding the entire value tree; the
/// caller must call `Document.deinit()` to free it. On failure, `err` is
/// populated with the error `code`, line, column, and byte offset of the first
/// problem (so `err` is an out-parameter even on the error path).
///
/// Errors: `error.JsonLimit` when a configured limit in `opts` is exceeded
/// (size, depth, node count); `error.OutOfMemory` on allocation failure; and
/// the tokenizer/parse error set for malformed input.
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
// Hot-path correctness tests (PERF-0001/0002/0003 guards)
// ============================================================================

test "parse empty string" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "\"\"", .{}, &err);
    defer doc.deinit();
    try std.testing.expectEqualStrings("", doc.root.str);
}

test "parse long string with no escapes (SIMD span > vector width)" {
    var err = ParseError.init();
    // 100 'a' bytes — well past the 16-byte SIMD vector width, no escapes.
    const input = "\"" ++ ("a" ** 100) ++ "\"";
    var doc = try parse(std.testing.allocator, input, .{}, &err);
    defer doc.deinit();
    try std.testing.expectEqualStrings("a" ** 100, doc.root.str);
}

test "parse long string with escape after a long unescaped run" {
    var err = ParseError.init();
    // 40 unescaped bytes, then \n, then more bytes — forces fast-scan then escape fallback.
    const input = "\"" ++ ("x" ** 40) ++ "\\n" ++ ("y" ** 40) ++ "\"";
    var doc = try parse(std.testing.allocator, input, .{}, &err);
    defer doc.deinit();
    try std.testing.expectEqualStrings(("x" ** 40) ++ "\n" ++ ("y" ** 40), doc.root.str);
}

test "parse string with all simple escapes" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "\"a\\\"b\\\\c\\/d\\b\\f\\n\\r\\te\"", .{}, &err);
    defer doc.deinit();
    try std.testing.expectEqualStrings("a\"b\\c/d\x08\x0C\n\r\te", doc.root.str);
}

test "parse string with multibyte utf8 (no escapes)" {
    var err = ParseError.init();
    // Japanese + emoji, raw UTF-8 bytes, no escapes — must pass through byte-exact.
    var doc = try parse(std.testing.allocator, "\"\xE6\x97\xA5\xE6\x9C\xAC\xF0\x9F\x98\x80\"", .{}, &err);
    defer doc.deinit();
    try std.testing.expectEqualStrings("\xE6\x97\xA5\xE6\x9C\xAC\xF0\x9F\x98\x80", doc.root.str);
}

test "parse string with multibyte utf8 spanning vector boundary" {
    var err = ParseError.init();
    // 15 ASCII bytes (so a 3-byte char straddles the 16-byte SIMD chunk), then a 3-byte char.
    const input = "\"" ++ ("a" ** 15) ++ "\xE6\x97\xA5" ++ ("b" ** 20) ++ "\"";
    var doc = try parse(std.testing.allocator, input, .{}, &err);
    defer doc.deinit();
    try std.testing.expectEqualStrings(("a" ** 15) ++ "\xE6\x97\xA5" ++ ("b" ** 20), doc.root.str);
}

test "reject invalid utf8 in string (lone continuation)" {
    var err = ParseError.init();
    const result = parse(std.testing.allocator, "\"a\x80b\"", .{}, &err);
    try std.testing.expectError(error.JsonParse, result);
    try std.testing.expectEqual(ErrorCode.InvalidUtf8, err.code);
}

test "reject invalid utf8 in string (overlong)" {
    var err = ParseError.init();
    const result = parse(std.testing.allocator, "\"\xC0\x80\"", .{}, &err);
    try std.testing.expectError(error.JsonParse, result);
}

test "reject invalid utf8 in string (truncated multibyte at end)" {
    var err = ParseError.init();
    const result = parse(std.testing.allocator, "\"abc\xE6\x97\"", .{}, &err);
    try std.testing.expectError(error.JsonParse, result);
}

test "reject unescaped control char in string (co-located)" {
    var err = ParseError.init();
    const result = parse(std.testing.allocator, "\"a\tb\"", .{}, &err);
    try std.testing.expectError(error.JsonParse, result);
    try std.testing.expectEqual(ErrorCode.InvalidString, err.code);
}

test "reject unescaped control char after long run" {
    var err = ParseError.init();
    // Control byte appears after a >16-byte unescaped run, in the SIMD scan region.
    const input = "\"" ++ ("a" ** 30) ++ "\x01b\"";
    const result = parse(std.testing.allocator, input, .{}, &err);
    try std.testing.expectError(error.JsonParse, result);
    try std.testing.expectEqual(ErrorCode.InvalidString, err.code);
}

test "reject unterminated string" {
    var err = ParseError.init();
    const result = parse(std.testing.allocator, "\"abc", .{}, &err);
    try std.testing.expectError(error.JsonParse, result);
    try std.testing.expectEqual(ErrorCode.UnexpectedEof, err.code);
}

test "string line/col tracking with embedded escaped newline" {
    var err = ParseError.init();
    // After a string containing \n escape, trailing garbage error reports correct position.
    const result = parse(std.testing.allocator, "\"a\\nb\" x", .{}, &err);
    try std.testing.expectError(error.JsonParse, result);
    try std.testing.expectEqual(ErrorCode.TrailingGarbage, err.code);
}

test "whitespace skipping across vector boundary" {
    var err = ParseError.init();
    // >16 bytes of mixed whitespace before the value exercises the SIMD ws skip.
    const input = (" \t\n\r" ** 8) ++ "true";
    var doc = try parse(std.testing.allocator, input, .{}, &err);
    defer doc.deinit();
    try std.testing.expect(doc.root.bool == true);
}

test "small object duplicate key rejected" {
    var err = ParseError.init();
    const result = parse(std.testing.allocator, "{\"a\":1,\"b\":2,\"a\":3}", .{}, &err);
    try std.testing.expectError(error.JsonParse, result);
    try std.testing.expectEqual(ErrorCode.DuplicateKey, err.code);
}

test "large object (above linear-dedup threshold) accepts unique keys" {
    var err = ParseError.init();
    // 50 unique keys — above the small-object linear-scan threshold, exercises map path.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.append(std.testing.allocator, '{');
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        if (i != 0) try buf.append(std.testing.allocator, ',');
        const frag = try std.fmt.allocPrint(std.testing.allocator, "\"k{d}\":{d}", .{ i, i });
        defer std.testing.allocator.free(frag);
        try buf.appendSlice(std.testing.allocator, frag);
    }
    try buf.append(std.testing.allocator, '}');
    var doc = try parse(std.testing.allocator, buf.items, .{}, &err);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 50), doc.root.obj.len);
    try std.testing.expectEqualStrings("k0", doc.root.obj[0].k);
    try std.testing.expectEqualStrings("k49", doc.root.obj[49].k);
}

test "large object duplicate key (above threshold) rejected" {
    var err = ParseError.init();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.append(std.testing.allocator, '{');
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        if (i != 0) try buf.append(std.testing.allocator, ',');
        const frag = try std.fmt.allocPrint(std.testing.allocator, "\"k{d}\":{d}", .{ i, i });
        defer std.testing.allocator.free(frag);
        try buf.appendSlice(std.testing.allocator, frag);
    }
    // Duplicate the very first key after 40 unique ones.
    try buf.appendSlice(std.testing.allocator, ",\"k0\":99}");
    const result = parse(std.testing.allocator, buf.items, .{}, &err);
    try std.testing.expectError(error.JsonParse, result);
    try std.testing.expectEqual(ErrorCode.DuplicateKey, err.code);
}

test "object with unique_keys=false allows duplicates" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "{\"a\":1,\"a\":2}", .{ .unique_keys = false }, &err);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 2), doc.root.obj.len);
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

test "json5: -Infinity parses to negative infinity (GAP-0009)" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "-Infinity", .{ .json5 = true }, &err);
    defer doc.deinit();
    // Canonical negative-infinity Number shape: lexeme "-Infinity", sign -1,
    // digits "Infinity" (matches cbor.zig floatToNormalizedValue).
    try std.testing.expectEqualStrings("-Infinity", doc.root.num.lexeme);
    try std.testing.expectEqual(@as(i8, -1), doc.root.num.sign);
    try std.testing.expectEqualStrings("Infinity", doc.root.num.digits);
}

test "json5: +Infinity parses to positive infinity (GAP-0009)" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "+Infinity", .{ .json5 = true }, &err);
    defer doc.deinit();
    try std.testing.expectEqualStrings("+Infinity", doc.root.num.lexeme);
    try std.testing.expectEqual(@as(i8, 1), doc.root.num.sign);
    try std.testing.expectEqualStrings("Infinity", doc.root.num.digits);
}

test "strict JSON rejects -Infinity / Infinity / NaN (GAP-0009)" {
    inline for (.{ "-Infinity", "Infinity", "NaN", "+Infinity", "-NaN" }) |lit| {
        var err = ParseError.init();
        const result = parse(std.testing.allocator, lit, .{}, &err);
        try std.testing.expectError(error.JsonParse, result);
    }
}

test "json5 still parses Infinity and NaN (GAP-0009 regression)" {
    {
        var err = ParseError.init();
        var doc = try parse(std.testing.allocator, "Infinity", .{ .json5 = true }, &err);
        defer doc.deinit();
        try std.testing.expectEqualStrings("Infinity", doc.root.num.lexeme);
        try std.testing.expectEqual(@as(i8, 1), doc.root.num.sign);
    }
    {
        var err = ParseError.init();
        var doc = try parse(std.testing.allocator, "NaN", .{ .json5 = true }, &err);
        defer doc.deinit();
        try std.testing.expectEqualStrings("NaN", doc.root.num.lexeme);
    }
}

test "json5: -Infinity inside array/object (GAP-0009)" {
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "{a: -Infinity, b: [Infinity, -Infinity]}", .{ .json5 = true }, &err);
    defer doc.deinit();
    const members = doc.root.obj;
    try std.testing.expectEqualStrings("a", members[0].k);
    try std.testing.expectEqualStrings("-Infinity", members[0].v.num.lexeme);
    try std.testing.expectEqual(@as(i8, -1), members[0].v.num.sign);
    const arr = members[1].v.arr;
    try std.testing.expectEqualStrings("Infinity", arr[0].num.lexeme);
    try std.testing.expectEqualStrings("-Infinity", arr[1].num.lexeme);
}

test "whitespace SIMD skip preserves line/col (PERF-0011 correctness)" {
    var err = ParseError.init();
    // >16 bytes of newline-bearing whitespace before invalid garbage: the error
    // position must match a byte-at-a-time advance (line 6, after 5 newlines).
    const input = "\n\n\n\n\n" ++ (" " ** 20) ++ "@";
    const result = parse(std.testing.allocator, input, .{}, &err);
    try std.testing.expectError(error.JsonParse, result);
    try std.testing.expectEqual(@as(usize, 6), err.line);
    try std.testing.expectEqual(@as(usize, 21), err.col);
}

// ============================================================================
// Parse-throughput micro-bench (PERF-0001/0002/0003)
//
// Normally a no-op: the `RUN_PARSE_BENCH` compile-time flag is false, so the
// bench test skips immediately and does not affect `zig build test` timing.
// To measure locally, flip the flag to `true` and run a ReleaseFast test:
//   zig test -OReleaseFast --dep ... src/json.zig   (or temporarily set it true
//   and `zig build test` — Debug numbers are noisier but directional).
// ============================================================================

const RUN_PARSE_BENCH = false;

fn monoNanos() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn benchCorpus(a: std.mem.Allocator, comptime label: []const u8, input: []const u8, iters: usize) !void {
    // Warmup + correctness sanity (the bench input must actually parse).
    {
        var err = ParseError.init();
        var doc = try parse(a, input, .{}, &err);
        doc.deinit();
    }
    const t0 = monoNanos();
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        var err = ParseError.init();
        var doc = parse(a, input, .{}, &err) catch unreachable;
        doc.deinit();
    }
    const ns = monoNanos() - t0;
    const total_bytes = input.len * iters;
    const mbps = (@as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0)) /
        (@as(f64, @floatFromInt(ns)) / 1_000_000_000.0);
    std.debug.print(
        "  parse-throughput[{s}]: {d} iters, {d} bytes/iter, {d:.2} ms, {d:.1} MB/s\n",
        .{ label, iters, input.len, @as(f64, @floatFromInt(ns)) / 1_000_000.0, mbps },
    );
}

test "parse-throughput micro-bench (flag-gated)" {
    if (!RUN_PARSE_BENCH) return error.SkipZigTest;
    const a = std.testing.allocator;

    // 1) Whitespace-heavy: lots of inter-token whitespace (scan-bound).
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        try buf.append(a, '[');
        var i: usize = 0;
        while (i < 2000) : (i += 1) {
            if (i != 0) try buf.appendSlice(a, ",");
            try buf.appendSlice(a, "        \n\t  1");
        }
        try buf.append(a, ']');
        try benchCorpus(a, "whitespace", buf.items, 2000);
    }

    // 2) Long-string-heavy: array of 64-byte unescaped strings (string-scan-bound).
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        try buf.append(a, '[');
        var i: usize = 0;
        while (i < 2000) : (i += 1) {
            if (i != 0) try buf.append(a, ',');
            try buf.append(a, '"');
            try buf.appendSlice(a, "abcdefghABCDEFGH0123456789abcdefghABCDEFGH0123456789abcdefgh01234");
            try buf.append(a, '"');
        }
        try buf.append(a, ']');
        try benchCorpus(a, "long-strings", buf.items, 2000);
    }

    // 3) Small-object-heavy: array of small objects (object-dedup-bound).
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        try buf.append(a, '[');
        var i: usize = 0;
        while (i < 2000) : (i += 1) {
            if (i != 0) try buf.append(a, ',');
            try buf.appendSlice(a, "{\"id\":1,\"name\":\"abc\",\"ok\":true,\"v\":3.14}");
        }
        try buf.append(a, ']');
        try benchCorpus(a, "small-objects", buf.items, 2000);
    }
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

fn expectParseInvalidEscape(input: []const u8, opts: ParseOptions) !void {
    var err = ParseError.init();
    const result = parse(std.testing.allocator, input, opts, &err);
    if (result) |doc_const| {
        var doc = doc_const;
        doc.deinit();
        std.debug.print("accepted invalid escape: {s}\n", .{input});
        return error.TestUnexpectedResult;
    } else |e| {
        try std.testing.expectEqual(error.JsonParse, e);
        try std.testing.expectEqual(ErrorCode.InvalidEscape, err.code);
    }
    // JSON5 single-quoted strings decode escapes on their own path.
    if (opts.json5 and input.len <= 64 and input[0] == '"') {
        var single: [64]u8 = undefined;
        @memcpy(single[0..input.len], input);
        single[0] = '\'';
        single[input.len - 1] = '\'';
        try expectParseInvalidEscape(single[0..input.len], opts);
    }
}

test "SONNY-2768: parser rejects signed and underscored \\u escapes" {
    for ([_][]const u8{ "\"\\u+041\"", "\"\\u0_41\"", "\"\\u-000\"" }) |in| {
        try expectParseInvalidEscape(in, .{});
        try expectParseInvalidEscape(in, .{ .json5 = true });
    }
}

test "SONNY-2768: parser rejects a non-hex byte at every \\u position" {
    const lone = comptime sonny2768BadInputs("\"\\u0041\"", 3);
    for (&lone) |*in| {
        try expectParseInvalidEscape(in, .{});
        try expectParseInvalidEscape(in, .{ .json5 = true });
    }
    const pair = comptime sonny2768BadInputs("\"\\uD83D\\uDE00\"", 9);
    for (&pair) |*in| {
        try expectParseInvalidEscape(in, .{});
        try expectParseInvalidEscape(in, .{ .json5 = true });
    }
}

test "SONNY-2768: JSON5 \\x escape takes exactly two hex digits" {
    for ([_][]const u8{ "'\\x+1'", "'\\x-0'", "'\\x_1'", "'\\x1_'", "'\\x1g'" }) |in| {
        try expectParseInvalidEscape(in, .{ .json5 = true });
    }
    var err = ParseError.init();
    var doc = try parse(std.testing.allocator, "'\\x4a\\x4A'", .{ .json5 = true }, &err);
    defer doc.deinit();
    try std.testing.expectEqualStrings("JJ", doc.root.str);
}

test "SONNY-2768: parser accepts upper, lower and mixed case \\u hex" {
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "\"\\u00e9\\u00E9\"", .want = "\xC3\xA9\xC3\xA9" },
        .{ .in = "\"\\uABCD\\uabcd\\uAbCd\"", .want = "\xEA\xAF\x8D\xEA\xAF\x8D\xEA\xAF\x8D" },
        .{ .in = "\"\\ud83d\\ude00\\uD83D\\uDE00\\uD83d\\uDe00\"", .want = "\xF0\x9F\x98\x80" ** 3 },
    };
    for (cases) |c| {
        for ([_]ParseOptions{ .{}, .{ .json5 = true } }) |opts| {
            var err = ParseError.init();
            var doc = try parse(std.testing.allocator, c.in, opts, &err);
            defer doc.deinit();
            try std.testing.expectEqualStrings(c.want, doc.root.str);
        }
        var single: [64]u8 = undefined;
        @memcpy(single[0..c.in.len], c.in);
        single[0] = '\'';
        single[c.in.len - 1] = '\'';
        var err = ParseError.init();
        var doc = try parse(std.testing.allocator, single[0..c.in.len], .{ .json5 = true }, &err);
        defer doc.deinit();
        try std.testing.expectEqualStrings(c.want, doc.root.str);
    }
}
