// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! JSONPath Query Language
//!
//! Implements JSONPath for querying JSON documents.
//! Syntax based on Stefan Goessner's JSONPath specification.
//!
//! Supported operators:
//! - `$` - Root element
//! - `.name` or `['name']` - Child element
//! - `..` - Recursive descent
//! - `*` - Wildcard (all children)
//! - `[n]` - Array index
//! - `[start:end]` or `[start:end:step]` - Array slice
//! - `[?(@.field == value)]` - Filter expression
//! - `[name1,name2]` - Union of names

const std = @import("std");
const json = @import("json.zig");

const Value = json.Value;
const Member = json.Member;

/// JSONPath query error
pub const PathError = error{
    InvalidPath,
    SyntaxError,
    OutOfMemory,
};

/// Result of a JSONPath query - a list of matched values
pub const QueryResult = struct {
    values: []const Value,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *QueryResult) void {
        self.allocator.free(self.values);
    }
};

/// Execute a JSONPath query on a JSON value
pub fn query(allocator: std.mem.Allocator, root: Value, path: []const u8) PathError!QueryResult {
    // Use an arena for internal parsing allocations (union indices/names)
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var results: std.ArrayList(Value) = .empty;
    errdefer results.deinit(allocator);

    // Parse and execute the path using arena for temporary allocations
    var parser = PathParser.init(path);
    try executeQuery(arena.allocator(), allocator, root, root, &parser, &results);

    return .{
        .values = try results.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Path segment types
const SegmentType = enum {
    root, // $
    child, // .name or ['name']
    recursive, // ..
    wildcard, // *
    index, // [n]
    slice, // [start:end:step]
    filter, // [?(...)]
    union_seg, // [a,b,c]
};

const Segment = struct {
    seg_type: SegmentType,
    name: ?[]const u8 = null,
    index: ?i64 = null,
    slice_start: ?i64 = null,
    slice_end: ?i64 = null,
    slice_step: ?i64 = null,
    filter_expr: ?[]const u8 = null,
    union_names: ?[]const []const u8 = null,
    union_indices: ?[]const i64 = null,
};

/// Parser for JSONPath expressions
const PathParser = struct {
    path: []const u8,
    pos: usize,

    fn init(path: []const u8) PathParser {
        return .{ .path = path, .pos = 0 };
    }

    fn peek(self: *PathParser) ?u8 {
        if (self.pos >= self.path.len) return null;
        return self.path[self.pos];
    }

    fn advance(self: *PathParser) ?u8 {
        if (self.pos >= self.path.len) return null;
        const c = self.path[self.pos];
        self.pos += 1;
        return c;
    }

    fn nextSegment(self: *PathParser, allocator: std.mem.Allocator) PathError!?Segment {
        const c = self.peek() orelse return null;

        if (c == '$') {
            _ = self.advance();
            return .{ .seg_type = .root };
        }

        if (c == '.') {
            _ = self.advance();
            // Check for recursive descent
            if (self.peek() == '.') {
                _ = self.advance();
                return .{ .seg_type = .recursive };
            }
            // Check for wildcard
            if (self.peek() == '*') {
                _ = self.advance();
                return .{ .seg_type = .wildcard };
            }
            // Regular child
            const name = self.readIdentifier();
            if (name.len == 0) return error.SyntaxError;
            return .{ .seg_type = .child, .name = name };
        }

        if (c == '[') {
            _ = self.advance();
            return self.parseBracket(allocator);
        }

        // Bare identifier (implicit child)
        const name = self.readIdentifier();
        if (name.len > 0) {
            return .{ .seg_type = .child, .name = name };
        }

        return error.SyntaxError;
    }

    fn parseBracket(self: *PathParser, allocator: std.mem.Allocator) PathError!?Segment {
        const start = self.pos;

        // Check for filter
        if (self.peek() == '?') {
            _ = self.advance();
            if (self.peek() != '(') return error.SyntaxError;
            _ = self.advance();

            // Find matching paren
            var depth: u32 = 1;
            const expr_start = self.pos;
            while (self.pos < self.path.len and depth > 0) {
                const ch = self.path[self.pos];
                if (ch == '(') depth += 1;
                if (ch == ')') depth -= 1;
                self.pos += 1;
            }
            if (depth != 0) return error.SyntaxError;

            const expr = self.path[expr_start .. self.pos - 1];

            if (self.peek() != ']') return error.SyntaxError;
            _ = self.advance();

            return .{ .seg_type = .filter, .filter_expr = expr };
        }

        // Check for wildcard
        if (self.peek() == '*') {
            _ = self.advance();
            if (self.peek() != ']') return error.SyntaxError;
            _ = self.advance();
            return .{ .seg_type = .wildcard };
        }

        // Read the entire content until ] (handling quoted strings properly)
        var content_end = self.pos;
        var in_quotes: ?u8 = null;
        while (content_end < self.path.len) {
            const ch = self.path[content_end];
            if (in_quotes) |quote| {
                if (ch == quote) {
                    in_quotes = null;
                }
            } else {
                if (ch == '\'' or ch == '"') {
                    in_quotes = ch;
                } else if (ch == ']') {
                    break;
                }
            }
            content_end += 1;
        }

        const content = self.path[start..content_end];
        self.pos = content_end;

        if (self.peek() != ']') return error.SyntaxError;
        _ = self.advance();

        // Check for slice (contains : outside quotes)
        if (containsOutsideQuotes(content, ':')) {
            return self.parseSlice(content);
        }

        // Check for union (contains , outside quotes)
        if (containsOutsideQuotes(content, ',')) {
            return self.parseUnion(allocator, content);
        }

        // Single quoted string
        const trimmed = std.mem.trim(u8, content, " \t");
        if (trimmed.len >= 2 and (trimmed[0] == '\'' or trimmed[0] == '"') and
            trimmed[trimmed.len - 1] == trimmed[0])
        {
            return .{ .seg_type = .child, .name = trimmed[1 .. trimmed.len - 1] };
        }

        // Simple index
        const idx = std.fmt.parseInt(i64, trimmed, 10) catch return error.SyntaxError;
        return .{ .seg_type = .index, .index = idx };
    }

    fn containsOutsideQuotes(content: []const u8, char: u8) bool {
        var in_quotes: ?u8 = null;
        for (content) |ch| {
            if (in_quotes) |quote| {
                if (ch == quote) {
                    in_quotes = null;
                }
            } else {
                if (ch == '\'' or ch == '"') {
                    in_quotes = ch;
                } else if (ch == char) {
                    return true;
                }
            }
        }
        return false;
    }

    fn parseSlice(self: *PathParser, content: []const u8) PathError!?Segment {
        _ = self;
        var seg = Segment{ .seg_type = .slice };

        var parts = std.mem.splitScalar(u8, content, ':');

        // Start
        if (parts.next()) |p| {
            if (p.len > 0) {
                seg.slice_start = std.fmt.parseInt(i64, p, 10) catch return error.SyntaxError;
            }
        }

        // End
        if (parts.next()) |p| {
            if (p.len > 0) {
                seg.slice_end = std.fmt.parseInt(i64, p, 10) catch return error.SyntaxError;
            }
        }

        // Step
        if (parts.next()) |p| {
            if (p.len > 0) {
                seg.slice_step = std.fmt.parseInt(i64, p, 10) catch return error.SyntaxError;
            }
        }

        return seg;
    }

    fn parseUnion(self: *PathParser, allocator: std.mem.Allocator, content: []const u8) PathError!?Segment {
        _ = self;
        var seg = Segment{ .seg_type = .union_seg };

        // Split by comma
        var parts = std.mem.splitScalar(u8, content, ',');

        // First pass: determine if all indices or all names
        var all_indices = true;
        var all_names = true;
        var count: usize = 0;

        var check_parts = std.mem.splitScalar(u8, content, ',');
        while (check_parts.next()) |p| {
            const trimmed = std.mem.trim(u8, p, " \t");
            if (trimmed.len == 0) continue;
            count += 1;

            // Check if it's a quoted string
            if ((trimmed[0] == '\'' or trimmed[0] == '"') and trimmed.len > 2 and
                trimmed[trimmed.len - 1] == trimmed[0])
            {
                all_indices = false;
            } else if (std.fmt.parseInt(i64, trimmed, 10)) |_| {
                all_names = false;
            } else |_| {
                // Unquoted string - treat as name
                all_indices = false;
            }
        }

        if (count == 0) return error.SyntaxError;

        // Parse based on type
        if (all_indices) {
            var indices = allocator.alloc(i64, count) catch return error.OutOfMemory;
            var i: usize = 0;
            while (parts.next()) |p| {
                const trimmed = std.mem.trim(u8, p, " \t");
                if (trimmed.len == 0) continue;
                indices[i] = std.fmt.parseInt(i64, trimmed, 10) catch {
                    allocator.free(indices);
                    return error.SyntaxError;
                };
                i += 1;
            }
            seg.union_indices = indices;
        } else {
            var names = allocator.alloc([]const u8, count) catch return error.OutOfMemory;
            var i: usize = 0;
            while (parts.next()) |p| {
                const trimmed = std.mem.trim(u8, p, " \t");
                if (trimmed.len == 0) continue;

                // Check for quoted string
                if ((trimmed[0] == '\'' or trimmed[0] == '"') and trimmed.len > 2 and
                    trimmed[trimmed.len - 1] == trimmed[0])
                {
                    names[i] = trimmed[1 .. trimmed.len - 1];
                } else {
                    // Unquoted - could be a name or an index
                    // If it's an index, treat as name anyway (mixed union)
                    names[i] = trimmed;
                }
                i += 1;
            }
            seg.union_names = names;
        }

        return seg;
    }

    fn readIdentifier(self: *PathParser) []const u8 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
                _ = self.advance();
            } else {
                break;
            }
        }
        return self.path[start..self.pos];
    }
};

/// Execute query recursively
/// arena_alloc: temporary allocator for parsing (e.g., union indices)
/// result_alloc: allocator for results list
fn executeQuery(
    arena_alloc: std.mem.Allocator,
    result_alloc: std.mem.Allocator,
    root: Value,
    current: Value,
    parser: *PathParser,
    results: *std.ArrayList(Value),
) PathError!void {
    const segment = try parser.nextSegment(arena_alloc) orelse {
        // No more segments - add current to results
        try results.append(result_alloc, current);
        return;
    };

    switch (segment.seg_type) {
        .root => {
            try executeQuery(arena_alloc, result_alloc, root, root, parser, results);
        },
        .child => {
            if (current == .obj) {
                for (current.obj) |m| {
                    if (std.mem.eql(u8, m.k, segment.name.?)) {
                        // Save parser state and recurse
                        const saved_pos = parser.pos;
                        try executeQuery(arena_alloc, result_alloc, root, m.v, parser, results);
                        parser.pos = saved_pos;
                    }
                }
            }
        },
        .wildcard => {
            if (current == .obj) {
                for (current.obj) |m| {
                    const saved_pos = parser.pos;
                    try executeQuery(arena_alloc, result_alloc, root, m.v, parser, results);
                    parser.pos = saved_pos;
                }
            } else if (current == .arr) {
                for (current.arr) |item| {
                    const saved_pos = parser.pos;
                    try executeQuery(arena_alloc, result_alloc, root, item, parser, results);
                    parser.pos = saved_pos;
                }
            }
        },
        .index => {
            if (current == .arr) {
                const arr = current.arr;
                var idx = segment.index.?;
                // Handle negative indices
                if (idx < 0) {
                    idx = @as(i64, @intCast(arr.len)) + idx;
                }
                if (idx >= 0 and idx < @as(i64, @intCast(arr.len))) {
                    const saved_pos = parser.pos;
                    try executeQuery(arena_alloc, result_alloc, root, arr[@intCast(idx)], parser, results);
                    parser.pos = saved_pos;
                }
            }
        },
        .slice => {
            if (current == .arr) {
                const arr = current.arr;
                const len: i64 = @intCast(arr.len);

                var start = segment.slice_start orelse 0;
                var end = segment.slice_end orelse len;
                const step = segment.slice_step orelse 1;

                // Handle negative indices
                if (start < 0) start = len + start;
                if (end < 0) end = len + end;

                // Clamp
                start = @max(0, @min(start, len));
                end = @max(0, @min(end, len));

                if (step > 0) {
                    var i = start;
                    while (i < end) : (i += step) {
                        const saved_pos = parser.pos;
                        try executeQuery(arena_alloc, result_alloc, root, arr[@intCast(i)], parser, results);
                        parser.pos = saved_pos;
                    }
                }
            }
        },
        .recursive => {
            // Get next segment to know what we're looking for
            const next_seg = try parser.nextSegment(arena_alloc);
            if (next_seg) |seg| {
                try recursiveDescend(arena_alloc, result_alloc, root, current, seg, parser, results);
            }
        },
        .filter => {
            if (current == .arr) {
                for (current.arr) |item| {
                    if (evaluateFilter(item, segment.filter_expr.?)) {
                        const saved_pos = parser.pos;
                        try executeQuery(arena_alloc, result_alloc, root, item, parser, results);
                        parser.pos = saved_pos;
                    }
                }
            }
        },
        .union_seg => {
            // Handle index-based unions
            if (segment.union_indices) |indices| {
                if (current == .arr) {
                    const arr = current.arr;
                    for (indices) |idx| {
                        const actual_idx: usize = if (idx < 0)
                            if (@as(usize, @intCast(-idx)) > arr.len) continue else arr.len - @as(usize, @intCast(-idx))
                        else
                            @intCast(idx);

                        if (actual_idx < arr.len) {
                            const saved_pos = parser.pos;
                            try executeQuery(arena_alloc, result_alloc, root, arr[actual_idx], parser, results);
                            parser.pos = saved_pos;
                        }
                    }
                }
            }
            // Handle name-based unions
            if (segment.union_names) |names| {
                if (current == .obj) {
                    for (names) |name| {
                        for (current.obj) |m| {
                            if (std.mem.eql(u8, m.k, name)) {
                                const saved_pos = parser.pos;
                                try executeQuery(arena_alloc, result_alloc, root, m.v, parser, results);
                                parser.pos = saved_pos;
                                break;
                            }
                        }
                    }
                } else if (current == .arr) {
                    // Try to parse names as indices for arrays
                    const arr = current.arr;
                    for (names) |name| {
                        if (std.fmt.parseInt(i64, name, 10)) |idx| {
                            const actual_idx: usize = if (idx < 0)
                                if (@as(usize, @intCast(-idx)) > arr.len) continue else arr.len - @as(usize, @intCast(-idx))
                            else
                                @intCast(idx);

                            if (actual_idx < arr.len) {
                                const saved_pos = parser.pos;
                                try executeQuery(arena_alloc, result_alloc, root, arr[actual_idx], parser, results);
                                parser.pos = saved_pos;
                            }
                        } else |_| {
                            // Not a valid index, skip
                        }
                    }
                }
            }
        },
    }
}

/// Recursive descent - search all descendants
fn recursiveDescend(
    arena_alloc: std.mem.Allocator,
    result_alloc: std.mem.Allocator,
    root: Value,
    current: Value,
    target: Segment,
    parser: *PathParser,
    results: *std.ArrayList(Value),
) PathError!void {
    // Check current level
    switch (target.seg_type) {
        .child => {
            if (current == .obj) {
                for (current.obj) |m| {
                    if (std.mem.eql(u8, m.k, target.name.?)) {
                        const saved_pos = parser.pos;
                        try executeQuery(arena_alloc, result_alloc, root, m.v, parser, results);
                        parser.pos = saved_pos;
                    }
                }
            }
        },
        .wildcard => {
            if (current == .obj) {
                for (current.obj) |m| {
                    const saved_pos = parser.pos;
                    try executeQuery(arena_alloc, result_alloc, root, m.v, parser, results);
                    parser.pos = saved_pos;
                }
            } else if (current == .arr) {
                for (current.arr) |item| {
                    const saved_pos = parser.pos;
                    try executeQuery(arena_alloc, result_alloc, root, item, parser, results);
                    parser.pos = saved_pos;
                }
            }
        },
        else => {},
    }

    // Recurse into children
    if (current == .obj) {
        for (current.obj) |m| {
            try recursiveDescend(arena_alloc, result_alloc, root, m.v, target, parser, results);
        }
    } else if (current == .arr) {
        for (current.arr) |item| {
            try recursiveDescend(arena_alloc, result_alloc, root, item, target, parser, results);
        }
    }
}

/// Evaluate a filter expression
fn evaluateFilter(item: Value, expr: []const u8) bool {
    // Simple filter parser for common patterns:
    // @.field == value
    // @.field != value
    // @.field > value
    // @.field < value
    // @.field >= value
    // @.field <= value

    var e = expr;

    // Skip leading whitespace
    while (e.len > 0 and e[0] == ' ') e = e[1..];

    // Must start with @
    if (e.len == 0 or e[0] != '@') return true; // Unknown filter passes
    e = e[1..];

    // Must have .field
    if (e.len == 0 or e[0] != '.') return true;
    e = e[1..];

    // Read field name
    var field_end: usize = 0;
    while (field_end < e.len and (std.ascii.isAlphanumeric(e[field_end]) or e[field_end] == '_')) {
        field_end += 1;
    }
    const field_name = e[0..field_end];
    e = e[field_end..];

    // Skip whitespace
    while (e.len > 0 and e[0] == ' ') e = e[1..];

    // Get operator
    var op: []const u8 = "";
    if (e.len >= 2) {
        if (std.mem.eql(u8, e[0..2], "==")) {
            op = "==";
            e = e[2..];
        } else if (std.mem.eql(u8, e[0..2], "!=")) {
            op = "!=";
            e = e[2..];
        } else if (std.mem.eql(u8, e[0..2], ">=")) {
            op = ">=";
            e = e[2..];
        } else if (std.mem.eql(u8, e[0..2], "<=")) {
            op = "<=";
            e = e[2..];
        } else if (e[0] == '>') {
            op = ">";
            e = e[1..];
        } else if (e[0] == '<') {
            op = "<";
            e = e[1..];
        }
    }

    if (op.len == 0) return true;

    // Skip whitespace
    while (e.len > 0 and e[0] == ' ') e = e[1..];

    // Get value to compare
    const compare_value = std.mem.trim(u8, e, " ");

    // Get field value from item
    if (item != .obj) return false;

    var field_value: ?Value = null;
    for (item.obj) |m| {
        if (std.mem.eql(u8, m.k, field_name)) {
            field_value = m.v;
            break;
        }
    }

    if (field_value == null) return false;

    // Compare based on operator
    return compareValues(field_value.?, compare_value, op);
}

fn compareValues(field: Value, compare_str: []const u8, op: []const u8) bool {
    // String comparison
    if (compare_str.len >= 2 and (compare_str[0] == '\'' or compare_str[0] == '"')) {
        const str_val = compare_str[1 .. compare_str.len - 1];
        if (field != .str) return false;

        if (std.mem.eql(u8, op, "==")) return std.mem.eql(u8, field.str, str_val);
        if (std.mem.eql(u8, op, "!=")) return !std.mem.eql(u8, field.str, str_val);
        return false;
    }

    // Numeric comparison
    const num = std.fmt.parseFloat(f64, compare_str) catch return false;
    if (field != .num) return false;

    const field_num = std.fmt.parseFloat(f64, field.num.lexeme) catch return false;

    if (std.mem.eql(u8, op, "==")) return field_num == num;
    if (std.mem.eql(u8, op, "!=")) return field_num != num;
    if (std.mem.eql(u8, op, ">")) return field_num > num;
    if (std.mem.eql(u8, op, "<")) return field_num < num;
    if (std.mem.eql(u8, op, ">=")) return field_num >= num;
    if (std.mem.eql(u8, op, "<=")) return field_num <= num;

    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "jsonpath root" {
    const allocator = std.testing.allocator;

    const input = "{\"a\":1}";
    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    var result = try query(allocator, doc.root, "$");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.values.len);
    try std.testing.expect(result.values[0] == .obj);
}

test "jsonpath child" {
    const allocator = std.testing.allocator;

    const input = "{\"name\":\"Alice\",\"age\":30}";
    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    var result = try query(allocator, doc.root, "$.name");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.values.len);
    try std.testing.expectEqualStrings("Alice", result.values[0].str);
}

test "jsonpath array index" {
    const allocator = std.testing.allocator;

    const input = "[1,2,3,4,5]";
    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    var result = try query(allocator, doc.root, "$[2]");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.values.len);
    try std.testing.expectEqualStrings("3", result.values[0].num.lexeme);
}

test "jsonpath negative index" {
    const allocator = std.testing.allocator;

    const input = "[1,2,3,4,5]";
    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    var result = try query(allocator, doc.root, "$[-1]");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.values.len);
    try std.testing.expectEqualStrings("5", result.values[0].num.lexeme);
}

test "jsonpath wildcard" {
    const allocator = std.testing.allocator;

    const input = "{\"a\":1,\"b\":2,\"c\":3}";
    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    var result = try query(allocator, doc.root, "$.*");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.values.len);
}

test "jsonpath slice" {
    const allocator = std.testing.allocator;

    const input = "[0,1,2,3,4,5]";
    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    var result = try query(allocator, doc.root, "$[1:4]");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.values.len);
}

test "jsonpath nested" {
    const allocator = std.testing.allocator;

    const input =
        \\{"store":{"book":[{"title":"A"},{"title":"B"}]}}
    ;
    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    var result = try query(allocator, doc.root, "$.store.book[0].title");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.values.len);
    try std.testing.expectEqualStrings("A", result.values[0].str);
}

test "jsonpath recursive descent" {
    const allocator = std.testing.allocator;

    const input =
        \\{"a":{"b":{"name":"deep"}},"name":"shallow"}
    ;
    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    var result = try query(allocator, doc.root, "$..name");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.values.len);
}

test "jsonpath filter" {
    const allocator = std.testing.allocator;

    const input =
        \\[{"name":"Alice","age":30},{"name":"Bob","age":25}]
    ;
    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    var result = try query(allocator, doc.root, "$[?(@.age > 27)]");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.values.len);
}

test "jsonpath bracket notation" {
    const allocator = std.testing.allocator;

    const input = "{\"first-name\":\"John\"}";
    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    var result = try query(allocator, doc.root, "$['first-name']");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.values.len);
    try std.testing.expectEqualStrings("John", result.values[0].str);
}

test "jsonpath union index" {
    const allocator = std.testing.allocator;

    const input = "[1, 2, 3, 4, 5]";
    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    var result = try query(allocator, doc.root, "$[0,2,4]");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.values.len);
    try std.testing.expectEqualStrings("1", result.values[0].num.lexeme);
    try std.testing.expectEqualStrings("3", result.values[1].num.lexeme);
    try std.testing.expectEqualStrings("5", result.values[2].num.lexeme);
}

test "jsonpath union names" {
    const allocator = std.testing.allocator;

    const input = "{\"a\":1,\"b\":2,\"c\":3}";
    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    var result = try query(allocator, doc.root, "$['a','c']");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.values.len);
    try std.testing.expectEqualStrings("1", result.values[0].num.lexeme);
    try std.testing.expectEqualStrings("3", result.values[1].num.lexeme);
}

test "jsonpath union negative index" {
    const allocator = std.testing.allocator;

    const input = "[1, 2, 3, 4, 5]";
    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    var result = try query(allocator, doc.root, "$[0,-1]");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.values.len);
    try std.testing.expectEqualStrings("1", result.values[0].num.lexeme);
    try std.testing.expectEqualStrings("5", result.values[1].num.lexeme);
}
