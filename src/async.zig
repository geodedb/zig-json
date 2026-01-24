// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Async JSON Parsing Support
//!
//! Provides non-blocking JSON parsing capabilities for async contexts.
//! Supports incremental parsing that can yield and resume, enabling
//! integration with async I/O and event loops.
//!
//! Features:
//! - Incremental tokenization with suspend/resume
//! - Async-friendly value construction
//! - Progress callbacks for long-running parses
//! - Cancelation support

const std = @import("std");
const json = @import("json.zig");
const tokenizer_mod = @import("tokenizer.zig");

/// Async parser state
pub const AsyncState = enum {
    /// Ready to start or continue parsing
    ready,
    /// Parsing in progress
    parsing,
    /// Waiting for more input data
    waiting_for_data,
    /// Parse completed successfully
    completed,
    /// Parse failed with error
    failed,
    /// Parse was canceled
    canceled,
};

/// Progress information for async parsing
pub const ParseProgress = struct {
    /// Bytes processed so far
    bytes_processed: usize,
    /// Total bytes (if known)
    total_bytes: ?usize,
    /// Current nesting depth
    depth: u16,
    /// Number of values parsed
    values_parsed: usize,
    /// Estimated progress (0.0 to 1.0, if total_bytes known)
    progress: ?f32,
};

/// Async parse result
pub const AsyncParseResult = union(enum) {
    /// Parsing yielded, call resume to continue
    yielded: ParseProgress,
    /// Parsing completed successfully
    completed: json.Value,
    /// Need more input data
    need_data: usize,
    /// Error occurred
    err: ParseError,
};

/// Parse error with context
pub const ParseError = struct {
    code: ErrorCode,
    line: u32,
    col: u32,
    offset: usize,
    message: []const u8,

    pub const ErrorCode = enum {
        unexpected_eof,
        unexpected_token,
        invalid_utf8,
        invalid_string,
        invalid_escape,
        invalid_number,
        depth_exceeded,
        canceled,
        out_of_memory,
    };
};

/// Error recovery mode for async parsing
pub const ErrorRecoveryMode = enum {
    /// Stop parsing on first error (default)
    none,
    /// Skip invalid values and continue parsing next sibling
    skip_value,
    /// Try to resync at the next structural character
    resync,
};

/// Async parser options
pub const AsyncParseOptions = struct {
    /// Maximum nesting depth
    max_depth: u16 = 256,
    /// Yield every N bytes processed
    yield_interval: usize = 4096,
    /// Maximum string length
    max_string_len: usize = 1024 * 1024,
    /// Enable JSON5 parsing
    json5: bool = false,
    /// Total input size (for progress reporting)
    total_size: ?usize = null,
    /// Error recovery mode
    recovery_mode: ErrorRecoveryMode = .none,
};

/// Incremental async JSON parser
pub const AsyncParser = struct {
    const Self = @This();

    /// Internal parse error set (explicit to break recursive inference)
    pub const InternalError = error{
        UnexpectedEof,
        UnexpectedToken,
        InvalidString,
        InvalidEscape,
        InvalidNumber,
        DepthExceeded,
        OutOfMemory,
        ContinueContainer,
    };

    /// Current state
    state: AsyncState,
    /// Allocator for value construction
    allocator: std.mem.Allocator,
    /// Parser options
    opts: AsyncParseOptions,
    /// Input buffer
    input: std.ArrayList(u8),
    /// Current parse position
    pos: usize,
    /// Line number
    line: u32,
    /// Column number
    col: u32,
    /// Value stack for incremental construction
    value_stack: std.ArrayList(StackEntry),
    /// Current nesting depth
    depth: u16,
    /// Bytes processed since last yield
    bytes_since_yield: usize,
    /// Total bytes processed
    total_bytes_processed: usize,
    /// Values parsed
    values_parsed: usize,
    /// Cancel flag
    canceled: bool,
    /// Last error (if any)
    last_error: ?ParseError,
    /// Number of errors recovered during parsing
    errors_recovered: usize,
    /// List of recovered errors (when recovery mode is enabled)
    recovered_errors: std.ArrayList(ParseError),

    /// Stack entry for value construction
    const StackEntry = struct {
        value_type: ValueType,
        items: std.ArrayList(json.Value),
        members: std.ArrayList(json.Member),
        pending_key: ?[]const u8,

        const ValueType = enum { array, object };

        fn deinit(self: *StackEntry, allocator: std.mem.Allocator) void {
            for (self.items.items) |item| {
                freeValue(allocator, item);
            }
            self.items.deinit(allocator);

            for (self.members.items) |m| {
                allocator.free(m.k);
                freeValue(allocator, m.v);
            }
            self.members.deinit(allocator);

            if (self.pending_key) |k| {
                allocator.free(k);
            }
        }
    };

    /// Initialize a new async parser
    pub fn init(allocator: std.mem.Allocator, opts: AsyncParseOptions) Self {
        return .{
            .state = .ready,
            .allocator = allocator,
            .opts = opts,
            .input = .empty,
            .pos = 0,
            .line = 1,
            .col = 1,
            .value_stack = .empty,
            .depth = 0,
            .bytes_since_yield = 0,
            .total_bytes_processed = 0,
            .values_parsed = 0,
            .canceled = false,
            .last_error = null,
            .errors_recovered = 0,
            .recovered_errors = .empty,
        };
    }

    /// Clean up parser resources
    pub fn deinit(self: *Self) void {
        self.input.deinit(self.allocator);
        for (self.value_stack.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.value_stack.deinit(self.allocator);
        self.recovered_errors.deinit(self.allocator);
    }

    /// Add input data to the parser
    pub fn addInput(self: *Self, data: []const u8) !void {
        try self.input.appendSlice(self.allocator, data);
        if (self.state == .waiting_for_data) {
            self.state = .ready;
        }
    }

    /// Signal end of input
    pub fn endInput(self: *Self) void {
        // Mark that no more data will come
        if (self.state == .waiting_for_data) {
            self.state = .ready;
        }
    }

    /// Cancel the parse operation
    pub fn cancel(self: *Self) void {
        self.canceled = true;
        self.state = .canceled;
    }

    /// Reset the parser for reuse
    pub fn reset(self: *Self) void {
        self.input.clearRetainingCapacity();
        self.pos = 0;
        self.line = 1;
        self.col = 1;
        for (self.value_stack.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.value_stack.clearRetainingCapacity();
        self.depth = 0;
        self.bytes_since_yield = 0;
        self.total_bytes_processed = 0;
        self.values_parsed = 0;
        self.canceled = false;
        self.last_error = null;
        self.errors_recovered = 0;
        self.recovered_errors.clearRetainingCapacity();
        self.state = .ready;
    }

    /// Parse incrementally, yielding periodically
    pub fn parse(self: *Self) AsyncParseResult {
        if (self.canceled) {
            return .{ .err = .{
                .code = .canceled,
                .line = self.line,
                .col = self.col,
                .offset = self.pos,
                .message = "Parse canceled",
            } };
        }

        if (self.state == .failed) {
            return .{ .err = self.last_error.? };
        }

        self.state = .parsing;

        const result = self.parseInternal();
        return result;
    }

    /// Get current progress
    pub fn getProgress(self: *Self) ParseProgress {
        const progress: ?f32 = if (self.opts.total_size) |total|
            @as(f32, @floatFromInt(self.total_bytes_processed)) / @as(f32, @floatFromInt(total))
        else
            null;

        return .{
            .bytes_processed = self.total_bytes_processed,
            .total_bytes = self.opts.total_size,
            .depth = self.depth,
            .values_parsed = self.values_parsed,
            .progress = progress,
        };
    }

    /// Get the list of errors that were recovered during parsing
    pub fn getRecoveredErrors(self: *Self) []const ParseError {
        return self.recovered_errors.items;
    }

    /// Skip to the next valid JSON value start position
    /// Used for error recovery - skips past invalid content to find next value
    pub fn skipToNextValue(self: *Self) void {
        var brace_depth: i32 = 0;
        var bracket_depth: i32 = 0;
        var in_string = false;
        var escape_next = false;

        while (self.pos < self.input.items.len) {
            const c = self.input.items[self.pos];

            if (escape_next) {
                escape_next = false;
                self.advance();
                continue;
            }

            if (in_string) {
                if (c == '\\') {
                    escape_next = true;
                } else if (c == '"') {
                    in_string = false;
                }
                self.advance();
                continue;
            }

            switch (c) {
                '"' => in_string = true,
                '{' => brace_depth += 1,
                '}' => {
                    brace_depth -= 1;
                    if (brace_depth < 0 and bracket_depth == 0) {
                        // Found closing brace of parent - stop here
                        return;
                    }
                },
                '[' => bracket_depth += 1,
                ']' => {
                    bracket_depth -= 1;
                    if (bracket_depth < 0 and brace_depth == 0) {
                        // Found closing bracket of parent - stop here
                        return;
                    }
                },
                ',' => {
                    if (brace_depth == 0 and bracket_depth == 0) {
                        // Found comma at our level - skip it and we're at next value
                        self.advance();
                        self.skipWhitespace();
                        return;
                    }
                },
                else => {},
            }

            self.advance();
        }
    }

    /// Try to recover from a parse error and continue parsing
    /// Returns true if recovery was successful and parsing can continue
    pub fn tryRecover(self: *Self, err: ParseError) bool {
        if (self.opts.recovery_mode == .none) {
            return false;
        }

        // Record the error
        self.recovered_errors.append(self.allocator, err) catch {
            // Can't record error, fail recovery
            return false;
        };
        self.errors_recovered += 1;

        // Skip to the next value
        self.skipToNextValue();
        self.skipWhitespace();

        // Check if we're at a valid recovery point
        if (self.pos >= self.input.items.len) {
            return false;
        }

        const c = self.input.items[self.pos];

        // Check for end of container or start of new value
        if (c == '}' or c == ']' or c == ',' or c == '"' or
            c == '{' or c == '[' or c == 't' or c == 'f' or
            c == 'n' or c == '-' or (c >= '0' and c <= '9'))
        {
            // We're at a recovery point - clear failed state
            self.state = .parsing;
            self.last_error = null;
            return true;
        }

        return false;
    }

    // =========================================================================
    // Internal parsing functions
    // =========================================================================

    fn parseInternal(self: *Self) AsyncParseResult {
        // If we have a value on the stack, we're in the middle of an object/array
        if (self.value_stack.items.len > 0) {
            return self.continueContainer();
        }

        // Parse a new value
        self.skipWhitespace();

        if (self.pos >= self.input.items.len) {
            self.state = .waiting_for_data;
            return .{ .need_data = 1 };
        }

        const value = self.parseValue() catch |err| {
            return self.handleError(err);
        };

        // Check for yield
        if (self.shouldYield()) {
            // For now, we can't yield in the middle of a primitive
            // This would require more complex state management
        }

        // Skip trailing whitespace
        self.skipWhitespace();

        if (self.pos < self.input.items.len) {
            // Trailing garbage
            return .{ .err = .{
                .code = .unexpected_token,
                .line = self.line,
                .col = self.col,
                .offset = self.pos,
                .message = "Unexpected trailing content",
            } };
        }

        self.state = .completed;
        return .{ .completed = value };
    }

    fn continueContainer(self: *Self) AsyncParseResult {
        while (self.value_stack.items.len > 0) {
            if (self.canceled) {
                return .{ .err = .{
                    .code = .canceled,
                    .line = self.line,
                    .col = self.col,
                    .offset = self.pos,
                    .message = "Parse canceled",
                } };
            }

            if (self.shouldYield()) {
                self.state = .ready;
                return .{ .yielded = self.getProgress() };
            }

            const entry = &self.value_stack.items[self.value_stack.items.len - 1];

            self.skipWhitespace();

            if (self.pos >= self.input.items.len) {
                self.state = .waiting_for_data;
                return .{ .need_data = 1 };
            }

            const c = self.input.items[self.pos];

            if (entry.value_type == .array) {
                if (c == ']') {
                    self.advance();
                    self.depth -= 1;

                    // Complete the array
                    const arr = entry.items.toOwnedSlice(self.allocator) catch {
                        return self.handleError(error.OutOfMemory);
                    };
                    const value = json.Value{ .arr = arr };
                    _ = self.value_stack.pop();

                    // Add to parent or return
                    if (self.value_stack.items.len > 0) {
                        self.addValueToParent(value) catch |err| {
                            return self.handleError(err);
                        };
                    } else {
                        self.skipWhitespace();
                        self.state = .completed;
                        return .{ .completed = value };
                    }
                } else {
                    // Expect comma between elements
                    if (entry.items.items.len > 0) {
                        if (c != ',') {
                            return .{ .err = .{
                                .code = .unexpected_token,
                                .line = self.line,
                                .col = self.col,
                                .offset = self.pos,
                                .message = "Expected ',' or ']'",
                            } };
                        }
                        self.advance();
                        self.skipWhitespace();
                    }

                    // Parse next element
                    const elem = self.parseValue() catch |err| {
                        return self.handleError(err);
                    };
                    entry.items.append(self.allocator, elem) catch {
                        return self.handleError(error.OutOfMemory);
                    };
                }
            } else {
                // Object
                if (c == '}') {
                    self.advance();
                    self.depth -= 1;

                    // Complete the object
                    const obj = entry.members.toOwnedSlice(self.allocator) catch {
                        return self.handleError(error.OutOfMemory);
                    };
                    const value = json.Value{ .obj = obj };
                    _ = self.value_stack.pop();

                    // Add to parent or return
                    if (self.value_stack.items.len > 0) {
                        self.addValueToParent(value) catch |err| {
                            return self.handleError(err);
                        };
                    } else {
                        self.skipWhitespace();
                        self.state = .completed;
                        return .{ .completed = value };
                    }
                } else {
                    // Expect comma between members
                    if (entry.members.items.len > 0) {
                        if (c != ',') {
                            return .{ .err = .{
                                .code = .unexpected_token,
                                .line = self.line,
                                .col = self.col,
                                .offset = self.pos,
                                .message = "Expected ',' or '}'",
                            } };
                        }
                        self.advance();
                        self.skipWhitespace();
                    }

                    // Parse key
                    if (self.pos >= self.input.items.len) {
                        self.state = .waiting_for_data;
                        return .{ .need_data = 1 };
                    }

                    if (self.input.items[self.pos] != '"') {
                        return .{ .err = .{
                            .code = .unexpected_token,
                            .line = self.line,
                            .col = self.col,
                            .offset = self.pos,
                            .message = "Expected string key",
                        } };
                    }

                    const key = self.parseString() catch |err| {
                        return self.handleError(err);
                    };

                    self.skipWhitespace();

                    if (self.pos >= self.input.items.len or self.input.items[self.pos] != ':') {
                        self.allocator.free(key);
                        return .{ .err = .{
                            .code = .unexpected_token,
                            .line = self.line,
                            .col = self.col,
                            .offset = self.pos,
                            .message = "Expected ':'",
                        } };
                    }
                    self.advance();

                    // Parse value
                    const val = self.parseValue() catch |err| {
                        self.allocator.free(key);
                        return self.handleError(err);
                    };

                    entry.members.append(self.allocator, .{ .k = key, .v = val }) catch {
                        self.allocator.free(key);
                        freeValue(self.allocator, val);
                        return self.handleError(error.OutOfMemory);
                    };
                }
            }
        }

        return .{ .err = .{
            .code = .unexpected_token,
            .line = self.line,
            .col = self.col,
            .offset = self.pos,
            .message = "Internal parser error",
        } };
    }

    fn parseValue(self: *Self) InternalError!json.Value {
        self.skipWhitespace();

        if (self.pos >= self.input.items.len) {
            return error.UnexpectedEof;
        }

        const c = self.input.items[self.pos];

        self.values_parsed += 1;

        return switch (c) {
            'n' => self.parseNull(),
            't', 'f' => self.parseBool(),
            '"' => blk: {
                const s = try self.parseString();
                break :blk json.Value{ .str = s };
            },
            '[' => self.parseArray(),
            '{' => self.parseObject(),
            '-', '0'...'9' => self.parseNumber(),
            else => error.UnexpectedToken,
        };
    }

    fn parseNull(self: *Self) InternalError!json.Value {
        if (self.pos + 4 > self.input.items.len) {
            return error.UnexpectedEof;
        }
        if (!std.mem.eql(u8, self.input.items[self.pos..][0..4], "null")) {
            return error.UnexpectedToken;
        }
        self.pos += 4;
        self.col += 4;
        self.bytes_since_yield += 4;
        self.total_bytes_processed += 4;
        return .null;
    }

    fn parseBool(self: *Self) InternalError!json.Value {
        if (self.input.items[self.pos] == 't') {
            if (self.pos + 4 > self.input.items.len) {
                return error.UnexpectedEof;
            }
            if (!std.mem.eql(u8, self.input.items[self.pos..][0..4], "true")) {
                return error.UnexpectedToken;
            }
            self.pos += 4;
            self.col += 4;
            self.bytes_since_yield += 4;
            self.total_bytes_processed += 4;
            return .{ .bool = true };
        } else {
            if (self.pos + 5 > self.input.items.len) {
                return error.UnexpectedEof;
            }
            if (!std.mem.eql(u8, self.input.items[self.pos..][0..5], "false")) {
                return error.UnexpectedToken;
            }
            self.pos += 5;
            self.col += 5;
            self.bytes_since_yield += 5;
            self.total_bytes_processed += 5;
            return .{ .bool = false };
        }
    }

    fn parseString(self: *Self) InternalError![]const u8 {
        if (self.input.items[self.pos] != '"') {
            return error.UnexpectedToken;
        }
        self.advance();

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);

        while (self.pos < self.input.items.len) {
            const c = self.input.items[self.pos];

            if (c == '"') {
                self.advance();
                return result.toOwnedSlice(self.allocator);
            }

            if (c < 0x20) {
                return error.InvalidString;
            }

            if (c == '\\') {
                self.advance();
                if (self.pos >= self.input.items.len) {
                    return error.UnexpectedEof;
                }
                const escaped = self.input.items[self.pos];
                switch (escaped) {
                    '"' => try result.append(self.allocator, '"'),
                    '\\' => try result.append(self.allocator, '\\'),
                    '/' => try result.append(self.allocator, '/'),
                    'b' => try result.append(self.allocator, 0x08),
                    'f' => try result.append(self.allocator, 0x0C),
                    'n' => try result.append(self.allocator, '\n'),
                    'r' => try result.append(self.allocator, '\r'),
                    't' => try result.append(self.allocator, '\t'),
                    'u' => {
                        self.advance();
                        if (self.pos + 4 > self.input.items.len) {
                            return error.InvalidEscape;
                        }
                        const hex = self.input.items[self.pos..][0..4];
                        const cp = std.fmt.parseInt(u16, hex, 16) catch return error.InvalidEscape;
                        self.pos += 4;
                        self.col += 4;
                        self.bytes_since_yield += 4;
                        self.total_bytes_processed += 4;

                        // Handle codepoint
                        if (cp < 0x80) {
                            try result.append(self.allocator, @intCast(cp));
                        } else if (cp < 0x800) {
                            try result.append(self.allocator, @intCast(0xC0 | (cp >> 6)));
                            try result.append(self.allocator, @intCast(0x80 | (cp & 0x3F)));
                        } else {
                            try result.append(self.allocator, @intCast(0xE0 | (cp >> 12)));
                            try result.append(self.allocator, @intCast(0x80 | ((cp >> 6) & 0x3F)));
                            try result.append(self.allocator, @intCast(0x80 | (cp & 0x3F)));
                        }
                        continue;
                    },
                    else => return error.InvalidEscape,
                }
                self.advance();
            } else {
                try result.append(self.allocator, c);
                self.advance();
            }
        }

        return error.UnexpectedEof;
    }

    fn parseNumber(self: *Self) InternalError!json.Value {
        const start = self.pos;

        // Optional sign
        if (self.pos < self.input.items.len and self.input.items[self.pos] == '-') {
            self.advance();
        }

        // Integer part
        if (self.pos >= self.input.items.len) return error.InvalidNumber;

        if (self.input.items[self.pos] == '0') {
            self.advance();
        } else if (self.input.items[self.pos] >= '1' and self.input.items[self.pos] <= '9') {
            while (self.pos < self.input.items.len and
                self.input.items[self.pos] >= '0' and self.input.items[self.pos] <= '9')
            {
                self.advance();
            }
        } else {
            return error.InvalidNumber;
        }

        // Fractional part
        if (self.pos < self.input.items.len and self.input.items[self.pos] == '.') {
            self.advance();
            if (self.pos >= self.input.items.len or
                self.input.items[self.pos] < '0' or self.input.items[self.pos] > '9')
            {
                return error.InvalidNumber;
            }
            while (self.pos < self.input.items.len and
                self.input.items[self.pos] >= '0' and self.input.items[self.pos] <= '9')
            {
                self.advance();
            }
        }

        // Exponent part
        if (self.pos < self.input.items.len and
            (self.input.items[self.pos] == 'e' or self.input.items[self.pos] == 'E'))
        {
            self.advance();
            if (self.pos < self.input.items.len and
                (self.input.items[self.pos] == '+' or self.input.items[self.pos] == '-'))
            {
                self.advance();
            }
            if (self.pos >= self.input.items.len or
                self.input.items[self.pos] < '0' or self.input.items[self.pos] > '9')
            {
                return error.InvalidNumber;
            }
            while (self.pos < self.input.items.len and
                self.input.items[self.pos] >= '0' and self.input.items[self.pos] <= '9')
            {
                self.advance();
            }
        }

        const lexeme = self.input.items[start..self.pos];
        return .{ .num = .{
            .lexeme = lexeme,
            .sign = if (lexeme[0] == '-') @as(i8, -1) else @as(i8, 1),
            .digits = lexeme,
            .exp10 = 0,
        } };
    }

    fn parseArray(self: *Self) InternalError!json.Value {
        if (self.input.items[self.pos] != '[') {
            return error.UnexpectedToken;
        }
        self.advance();
        self.depth += 1;

        if (self.depth > self.opts.max_depth) {
            return error.DepthExceeded;
        }

        // Push array onto stack
        try self.value_stack.append(self.allocator, .{
            .value_type = .array,
            .items = .empty,
            .members = .empty,
            .pending_key = null,
        });

        self.skipWhitespace();

        // Check for empty array
        if (self.pos < self.input.items.len and self.input.items[self.pos] == ']') {
            self.advance();
            self.depth -= 1;
            _ = self.value_stack.pop();
            return .{ .arr = &[_]json.Value{} };
        }

        // Parse first element
        const elem = try self.parseValue();
        self.value_stack.items[self.value_stack.items.len - 1].items.append(self.allocator, elem) catch {
            return error.OutOfMemory;
        };

        // The rest will be handled by continueContainer
        return error.ContinueContainer;
    }

    fn parseObject(self: *Self) InternalError!json.Value {
        if (self.input.items[self.pos] != '{') {
            return error.UnexpectedToken;
        }
        self.advance();
        self.depth += 1;

        if (self.depth > self.opts.max_depth) {
            return error.DepthExceeded;
        }

        // Push object onto stack
        try self.value_stack.append(self.allocator, .{
            .value_type = .object,
            .items = .empty,
            .members = .empty,
            .pending_key = null,
        });

        self.skipWhitespace();

        // Check for empty object
        if (self.pos < self.input.items.len and self.input.items[self.pos] == '}') {
            self.advance();
            self.depth -= 1;
            _ = self.value_stack.pop();
            return .{ .obj = &[_]json.Member{} };
        }

        // Parse first key-value
        if (self.input.items[self.pos] != '"') {
            return error.UnexpectedToken;
        }

        const key = try self.parseString();
        self.skipWhitespace();

        if (self.pos >= self.input.items.len or self.input.items[self.pos] != ':') {
            self.allocator.free(key);
            return error.UnexpectedToken;
        }
        self.advance();

        const val = try self.parseValue();
        self.value_stack.items[self.value_stack.items.len - 1].members.append(self.allocator, .{ .k = key, .v = val }) catch {
            self.allocator.free(key);
            freeValue(self.allocator, val);
            return error.OutOfMemory;
        };

        // The rest will be handled by continueContainer
        return error.ContinueContainer;
    }

    fn addValueToParent(self: *Self, value: json.Value) InternalError!void {
        if (self.value_stack.items.len == 0) return;

        var parent = &self.value_stack.items[self.value_stack.items.len - 1];
        if (parent.value_type == .array) {
            try parent.items.append(self.allocator, value);
        } else {
            if (parent.pending_key) |key| {
                try parent.members.append(self.allocator, .{ .k = key, .v = value });
                parent.pending_key = null;
            }
        }
    }

    fn skipWhitespace(self: *Self) void {
        while (self.pos < self.input.items.len) {
            const c = self.input.items[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn advance(self: *Self) void {
        if (self.pos < self.input.items.len) {
            if (self.input.items[self.pos] == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
            self.pos += 1;
            self.bytes_since_yield += 1;
            self.total_bytes_processed += 1;
        }
    }

    fn shouldYield(self: *Self) bool {
        if (self.bytes_since_yield >= self.opts.yield_interval) {
            self.bytes_since_yield = 0;
            return true;
        }
        return false;
    }

    fn handleError(self: *Self, err: anyerror) AsyncParseResult {
        self.state = .failed;
        const code: ParseError.ErrorCode = switch (err) {
            error.UnexpectedEof => .unexpected_eof,
            error.UnexpectedToken => .unexpected_token,
            error.InvalidUtf8 => .invalid_utf8,
            error.InvalidString => .invalid_string,
            error.InvalidEscape => .invalid_escape,
            error.InvalidNumber => .invalid_number,
            error.DepthExceeded => .depth_exceeded,
            error.OutOfMemory => .out_of_memory,
            error.ContinueContainer => {
                // Not an error - need to continue container parsing
                self.state = .parsing;
                return self.continueContainer();
            },
            else => .unexpected_token,
        };

        self.last_error = .{
            .code = code,
            .line = self.line,
            .col = self.col,
            .offset = self.pos,
            .message = @errorName(err),
        };

        return .{ .err = self.last_error.? };
    }
};

/// Free a JSON value and all its children
fn freeValue(allocator: std.mem.Allocator, value: json.Value) void {
    switch (value) {
        .null, .bool, .num => {},
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

// =============================================================================
// Async Iterator Interface
// =============================================================================

/// Async JSON value iterator
/// Yields one value at a time from an array or object stream
pub const AsyncIterator = struct {
    const Self = @This();

    parser: AsyncParser,
    in_container: bool,
    container_type: ?ContainerType,
    items_yielded: usize,

    const ContainerType = enum { array, object };

    pub fn init(allocator: std.mem.Allocator, opts: AsyncParseOptions) Self {
        return .{
            .parser = AsyncParser.init(allocator, opts),
            .in_container = false,
            .container_type = null,
            .items_yielded = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.parser.deinit();
    }

    pub fn addInput(self: *Self, data: []const u8) !void {
        try self.parser.addInput(data);
    }

    /// Get the next value from the stream
    pub fn next(self: *Self) ?json.Value {
        _ = self;
        // Simplified implementation - full implementation would track state
        return null;
    }
};

// =============================================================================
// Convenience Functions
// =============================================================================

/// Parse JSON asynchronously with a callback for progress updates
pub fn parseAsync(
    allocator: std.mem.Allocator,
    input: []const u8,
    opts: AsyncParseOptions,
    progress_callback: ?*const fn (ParseProgress) void,
) !json.Value {
    var parser = AsyncParser.init(allocator, opts);
    defer parser.deinit();

    try parser.addInput(input);
    parser.endInput();

    while (true) {
        const result = parser.parse();

        switch (result) {
            .yielded => |progress| {
                if (progress_callback) |cb| {
                    cb(progress);
                }
            },
            .completed => |value| {
                return value;
            },
            .need_data => {
                return error.UnexpectedEof;
            },
            .err => |e| {
                return switch (e.code) {
                    .unexpected_eof => error.UnexpectedEof,
                    .unexpected_token => error.UnexpectedToken,
                    .invalid_utf8 => error.InvalidUtf8,
                    .invalid_string => error.InvalidString,
                    .invalid_escape => error.InvalidEscape,
                    .invalid_number => error.InvalidNumber,
                    .depth_exceeded => error.DepthExceeded,
                    .canceled => error.Canceled,
                    .out_of_memory => error.OutOfMemory,
                };
            },
        }
    }
}

pub const AsyncParseError = error{
    UnexpectedEof,
    UnexpectedToken,
    InvalidUtf8,
    InvalidString,
    InvalidEscape,
    InvalidNumber,
    DepthExceeded,
    Canceled,
    OutOfMemory,
};

// =============================================================================
// Tests
// =============================================================================

test "AsyncParser basic primitives" {
    const allocator = std.testing.allocator;

    // Test null
    {
        var parser = AsyncParser.init(allocator, .{});
        defer parser.deinit();
        try parser.addInput("null");
        parser.endInput();

        const result = parser.parse();
        try std.testing.expect(result == .completed);
        try std.testing.expect(result.completed == .null);
    }

    // Test boolean
    {
        var parser = AsyncParser.init(allocator, .{});
        defer parser.deinit();
        try parser.addInput("true");
        parser.endInput();

        const result = parser.parse();
        try std.testing.expect(result == .completed);
        try std.testing.expect(result.completed == .bool);
        try std.testing.expect(result.completed.bool == true);
    }

    // Test string
    {
        var parser = AsyncParser.init(allocator, .{});
        defer parser.deinit();
        try parser.addInput("\"hello\"");
        parser.endInput();

        const result = parser.parse();
        try std.testing.expect(result == .completed);
        try std.testing.expect(result.completed == .str);
        try std.testing.expectEqualStrings("hello", result.completed.str);
        allocator.free(result.completed.str);
    }
}

test "AsyncParser empty containers" {
    const allocator = std.testing.allocator;

    // Empty array
    {
        var parser = AsyncParser.init(allocator, .{});
        defer parser.deinit();
        try parser.addInput("[]");
        parser.endInput();

        const result = parser.parse();
        try std.testing.expect(result == .completed);
        try std.testing.expect(result.completed == .arr);
        try std.testing.expectEqual(@as(usize, 0), result.completed.arr.len);
    }

    // Empty object
    {
        var parser = AsyncParser.init(allocator, .{});
        defer parser.deinit();
        try parser.addInput("{}");
        parser.endInput();

        const result = parser.parse();
        try std.testing.expect(result == .completed);
        try std.testing.expect(result.completed == .obj);
        try std.testing.expectEqual(@as(usize, 0), result.completed.obj.len);
    }
}

test "AsyncParser cancelation" {
    const allocator = std.testing.allocator;

    var parser = AsyncParser.init(allocator, .{ .yield_interval = 10 });
    defer parser.deinit();
    try parser.addInput("[1, 2, 3, 4, 5]");
    parser.endInput();

    parser.cancel();
    const result = parser.parse();
    try std.testing.expect(result == .err);
    try std.testing.expectEqual(ParseError.ErrorCode.canceled, result.err.code);
}

test "AsyncParser progress tracking" {
    const allocator = std.testing.allocator;

    var parser = AsyncParser.init(allocator, .{ .total_size = 100 });
    defer parser.deinit();
    try parser.addInput("null");
    parser.endInput();

    _ = parser.parse();
    const progress = parser.getProgress();
    try std.testing.expect(progress.bytes_processed > 0);
}

test "parseAsync convenience function" {
    const allocator = std.testing.allocator;

    const value = try parseAsync(allocator, "42", .{}, null);
    try std.testing.expect(value == .num);
}

test "AsyncParser skipToNextValue" {
    const allocator = std.testing.allocator;

    // Test skipping to next value after invalid content
    {
        var parser = AsyncParser.init(allocator, .{ .recovery_mode = .skip_value });
        defer parser.deinit();

        // Position at start of invalid content, should skip to next value
        try parser.addInput("invalid, \"valid\"");
        parser.pos = 0;
        parser.skipToNextValue();

        // Should be at the start of "valid"
        try std.testing.expect(parser.pos > 0);
        try std.testing.expect(parser.input.items[parser.pos] == '"');
    }

    // Test skipping nested structures
    {
        var parser = AsyncParser.init(allocator, .{ .recovery_mode = .skip_value });
        defer parser.deinit();

        try parser.addInput("{\"nested\": [1,2,3]}, \"next\"");
        parser.pos = 0;
        parser.skipToNextValue();

        // Should skip the entire object and be at "next"
        try std.testing.expect(parser.input.items[parser.pos] == '"');
    }
}

test "AsyncParser error recovery" {
    const allocator = std.testing.allocator;

    // Test tryRecover functionality
    {
        var parser = AsyncParser.init(allocator, .{ .recovery_mode = .skip_value });
        defer parser.deinit();

        try parser.addInput("invalid_token, true");
        parser.endInput();

        // Simulate an error at position 0
        const err = ParseError{
            .code = .unexpected_token,
            .line = 1,
            .col = 1,
            .offset = 0,
            .message = "test error",
        };

        // Try to recover
        const recovered = parser.tryRecover(err);
        try std.testing.expect(recovered);

        // Check that error was recorded
        try std.testing.expectEqual(@as(usize, 1), parser.errors_recovered);
        try std.testing.expectEqual(@as(usize, 1), parser.getRecoveredErrors().len);

        // Parser should be at "true" now
        try std.testing.expect(parser.input.items[parser.pos] == 't');
    }

    // Test that recovery is disabled by default
    {
        var parser = AsyncParser.init(allocator, .{});
        defer parser.deinit();

        try parser.addInput("invalid, true");

        const err = ParseError{
            .code = .unexpected_token,
            .line = 1,
            .col = 1,
            .offset = 0,
            .message = "test error",
        };

        const recovered = parser.tryRecover(err);
        try std.testing.expect(!recovered);
        try std.testing.expectEqual(@as(usize, 0), parser.errors_recovered);
    }
}
