// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! RFC 6901 JSON Pointer
//!
//! Implements JSON Pointer evaluation and construction for schema navigation.

const std = @import("std");
const json = @import("json.zig");

const Value = json.Value;

/// Evaluate a JSON Pointer against a value tree
pub fn evaluate(root: Value, ptr: []const u8) ?Value {
    if (ptr.len == 0) return root;
    if (ptr[0] != '/') return null;

    var current = root;
    var rest = ptr[1..];

    while (rest.len > 0) {
        const end = std.mem.indexOf(u8, rest, "/") orelse rest.len;
        const token = unescape(rest[0..end], std.heap.page_allocator) catch return null;
        defer std.heap.page_allocator.free(token);

        switch (current) {
            .obj => |obj| {
                var found = false;
                for (obj) |m| {
                    if (std.mem.eql(u8, m.k, token)) {
                        current = m.v;
                        found = true;
                        break;
                    }
                }
                if (!found) return null;
            },
            .arr => |arr| {
                if (std.mem.eql(u8, token, "-")) return null; // "-" means append, not valid for read
                const idx = std.fmt.parseInt(usize, token, 10) catch return null;
                if (idx >= arr.len) return null;
                current = arr[idx];
            },
            else => return null,
        }

        if (end < rest.len) {
            rest = rest[end + 1 ..];
        } else {
            break;
        }
    }

    return current;
}

/// Unescape a JSON Pointer token (~0 -> ~, ~1 -> /)
fn unescape(token: []const u8, a: std.mem.Allocator) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);

    var i: usize = 0;
    while (i < token.len) {
        if (token[i] == '~') {
            if (i + 1 >= token.len) return error.InvalidPointer;
            if (token[i + 1] == '0') {
                try result.append(a, '~');
                i += 2;
            } else if (token[i + 1] == '1') {
                try result.append(a, '/');
                i += 2;
            } else {
                return error.InvalidPointer;
            }
        } else {
            try result.append(a, token[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(a);
}

/// Escape a key for use in a JSON Pointer (~ -> ~0, / -> ~1)
pub fn escape(key: []const u8, a: std.mem.Allocator) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);

    for (key) |c| {
        if (c == '~') {
            try result.appendSlice(a, "~0");
        } else if (c == '/') {
            try result.appendSlice(a, "~1");
        } else {
            try result.append(a, c);
        }
    }

    return result.toOwnedSlice(a);
}

/// Append a key to a JSON Pointer path
pub fn append(base: []const u8, token: []const u8, a: std.mem.Allocator) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);

    try result.appendSlice(a, base);
    try result.append(a, '/');

    const escaped = try escape(token, a);
    defer a.free(escaped);
    try result.appendSlice(a, escaped);

    return result.toOwnedSlice(a);
}

/// Append an array index to a JSON Pointer path
pub fn appendIndex(base: []const u8, idx: usize, a: std.mem.Allocator) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);

    try result.appendSlice(a, base);
    try result.append(a, '/');

    var buf: [20]u8 = undefined;
    const num_str = std.fmt.bufPrint(&buf, "{d}", .{idx}) catch return error.OutOfMemory;
    try result.appendSlice(a, num_str);

    return result.toOwnedSlice(a);
}

test "evaluate pointer - root" {
    const val = evaluate(Value{ .bool = true }, "");
    try std.testing.expect(val.?.bool == true);
}

test "evaluate pointer - object" {
    var members = [_]json.Member{
        .{ .k = "a", .v = .{ .bool = true } },
    };
    const val = evaluate(Value{ .obj = &members }, "/a");
    try std.testing.expect(val.?.bool == true);
}

test "evaluate pointer - nested" {
    var inner = [_]json.Member{
        .{ .k = "b", .v = .{ .bool = true } },
    };
    var outer = [_]json.Member{
        .{ .k = "a", .v = .{ .obj = &inner } },
    };
    const val = evaluate(Value{ .obj = &outer }, "/a/b");
    try std.testing.expect(val.?.bool == true);
}

test "evaluate pointer - array" {
    var items = [_]Value{ .{ .bool = true }, .{ .bool = false } };
    const val = evaluate(Value{ .arr = &items }, "/0");
    try std.testing.expect(val.?.bool == true);
}

test "evaluate pointer - not found" {
    var members = [_]json.Member{
        .{ .k = "a", .v = .{ .bool = true } },
    };
    const val = evaluate(Value{ .obj = &members }, "/b");
    try std.testing.expect(val == null);
}

test "escape key" {
    const escaped = try escape("a/b~c", std.testing.allocator);
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("a~1b~0c", escaped);
}

test "append path" {
    const result = try append("/a", "b", std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/a/b", result);
}

test "append index" {
    const result = try appendIndex("/arr", 42, std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/arr/42", result);
}
