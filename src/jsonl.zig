// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! JSON Lines (JSONL) Support
//!
//! Parses newline-delimited JSON (NDJSON/JSON Lines) format where
//! each line contains a valid JSON value.
//!
//! Features:
//! - Parse entire JSONL document into array of values
//! - Streaming iterator for memory-efficient parsing
//! - Optional empty line handling
//! - Line number tracking for error reporting

const std = @import("std");
const json = @import("json.zig");
const parser = @import("parser.zig");

const Value = json.Value;
const ParseOptions = json.ParseOptions;
const ParseError = json.ParseError;

/// Options for JSONL parsing
pub const JsonlOptions = struct {
    /// Base parse options for each JSON value
    parse_options: ParseOptions = .{},
    /// Skip empty lines (default: true)
    skip_empty_lines: bool = true,
    /// Allow trailing newline (default: true)
    allow_trailing_newline: bool = true,
};

/// Error during JSONL parsing
pub const JsonlError = struct {
    line_number: usize,
    parse_error: ParseError,
};

/// Parse entire JSONL document into array of values
/// Each value is allocated on the arena; caller manages Document lifetime
pub fn parseAll(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: JsonlOptions,
    err_out: *JsonlError,
) !json.Document {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const alloc = arena.allocator();
    var values: std.ArrayList(Value) = .empty;

    var line_number: usize = 1;
    var start: usize = 0;

    for (input, 0..) |c, i| {
        if (c == '\n') {
            const line = input[start..i];
            start = i + 1;

            if (line.len == 0 or (line.len == 1 and line[0] == '\r')) {
                if (options.skip_empty_lines) {
                    line_number += 1;
                    continue;
                }
            }

            // Parse the line
            var parse_err = ParseError.init();
            const doc = parser.parse(alloc, line, options.parse_options, &parse_err) catch {
                err_out.line_number = line_number;
                err_out.parse_error = parse_err;
                return error.ParseError;
            };
            try values.append(alloc, doc.root);

            line_number += 1;
        }
    }

    // Handle last line without trailing newline
    if (start < input.len) {
        const line = input[start..];
        if (line.len > 0 and !(line.len == 1 and line[0] == '\r')) {
            var parse_err = ParseError.init();
            const doc = parser.parse(alloc, line, options.parse_options, &parse_err) catch {
                err_out.line_number = line_number;
                err_out.parse_error = parse_err;
                return error.ParseError;
            };
            try values.append(alloc, doc.root);
        }
    }

    return .{
        .arena = arena,
        .root = .{ .arr = try values.toOwnedSlice(alloc) },
    };
}

/// Streaming iterator for JSONL parsing
pub const Iterator = struct {
    input: []const u8,
    pos: usize,
    line_number: usize,
    options: JsonlOptions,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, input: []const u8, options: JsonlOptions) Iterator {
        return .{
            .input = input,
            .pos = 0,
            .line_number = 1,
            .options = options,
            .allocator = allocator,
        };
    }

    /// Get the next value, or null if end of input
    /// Returns owned Document that caller must deinit
    pub fn next(self: *Iterator, err_out: *JsonlError) !?json.Document {
        while (self.pos < self.input.len) {
            // Find end of line
            const line_start = self.pos;
            var line_end = self.pos;
            while (line_end < self.input.len and self.input[line_end] != '\n') {
                line_end += 1;
            }

            // Extract line (handle \r\n)
            var line = self.input[line_start..line_end];
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }

            // Advance position
            self.pos = if (line_end < self.input.len) line_end + 1 else line_end;
            const current_line = self.line_number;
            self.line_number += 1;

            // Skip empty lines if configured
            if (line.len == 0) {
                if (self.options.skip_empty_lines) {
                    continue;
                }
            }

            // Parse the line
            var parse_err = ParseError.init();
            const doc = parser.parse(self.allocator, line, self.options.parse_options, &parse_err) catch {
                err_out.line_number = current_line;
                err_out.parse_error = parse_err;
                return error.ParseError;
            };
            return doc;
        }

        return null;
    }

    /// Reset iterator to beginning
    pub fn reset(self: *Iterator) void {
        self.pos = 0;
        self.line_number = 1;
    }
};

/// Create a streaming JSONL iterator
pub fn iterator(allocator: std.mem.Allocator, input: []const u8, options: JsonlOptions) Iterator {
    return Iterator.init(allocator, input, options);
}

// ============================================================================
// Tests
// ============================================================================

test "jsonl parse single line" {
    const allocator = std.testing.allocator;
    var err: JsonlError = undefined;

    var doc = try parseAll(allocator, "{\"a\":1}\n", .{}, &err);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.root.arr.len);
    try std.testing.expect(doc.root.arr[0] == .obj);
}

test "jsonl parse multiple lines" {
    const allocator = std.testing.allocator;
    var err: JsonlError = undefined;

    var doc = try parseAll(allocator, "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n", .{}, &err);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 3), doc.root.arr.len);
}

test "jsonl skip empty lines" {
    const allocator = std.testing.allocator;
    var err: JsonlError = undefined;

    var doc = try parseAll(allocator, "{\"a\":1}\n\n{\"b\":2}\n", .{}, &err);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.root.arr.len);
}

test "jsonl no trailing newline" {
    const allocator = std.testing.allocator;
    var err: JsonlError = undefined;

    var doc = try parseAll(allocator, "{\"a\":1}\n{\"b\":2}", .{}, &err);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.root.arr.len);
}

test "jsonl iterator" {
    const allocator = std.testing.allocator;
    var err: JsonlError = undefined;

    var iter = iterator(allocator, "{\"a\":1}\n{\"b\":2}\n", .{});
    var count: usize = 0;

    while (try iter.next(&err)) |*doc| {
        var d = doc.*;
        defer d.deinit();
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 2), count);
}

test "jsonl with CRLF" {
    const allocator = std.testing.allocator;
    var err: JsonlError = undefined;

    var doc = try parseAll(allocator, "{\"a\":1}\r\n{\"b\":2}\r\n", .{}, &err);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.root.arr.len);
}
