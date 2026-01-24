// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! RFC 6902 JSON Patch
//!
//! Implements JSON Patch operations for modifying JSON documents:
//! - add: Add a value at the target location
//! - remove: Remove the value at the target location
//! - replace: Replace the value at the target location
//! - move: Move a value from one location to another
//! - copy: Copy a value from one location to another
//! - test: Test that a value at the target location equals a specified value

const std = @import("std");
const json = @import("json.zig");
const pointer_mod = @import("pointer.zig");

const Value = json.Value;
const Member = json.Member;

/// Patch operation types
pub const OpType = enum {
    add,
    remove,
    replace,
    move,
    copy,
    @"test",
};

/// A single patch operation
pub const Operation = struct {
    op: OpType,
    path: []const u8,
    value: ?Value = null, // Required for add, replace, test
    from: ?[]const u8 = null, // Required for move, copy
};

/// Error types for patch operations
pub const PatchError = error{
    InvalidPatch,
    InvalidPath,
    PathNotFound,
    TestFailed,
    OutOfMemory,
};

/// Apply a JSON Patch document to a value
/// Returns a new modified document (does not modify original)
pub fn apply(allocator: std.mem.Allocator, doc: Value, patch: []const Operation) PatchError!Value {
    var current = try cloneValue(allocator, doc);
    errdefer freeValue(allocator, current);

    for (patch) |op| {
        const new_current = try applyOperation(allocator, current, op);
        freeValue(allocator, current);
        current = new_current;
    }

    return current;
}

/// Apply a single operation
fn applyOperation(allocator: std.mem.Allocator, doc: Value, op: Operation) PatchError!Value {
    switch (op.op) {
        .add => {
            const val = op.value orelse return error.InvalidPatch;
            return addValue(allocator, doc, op.path, val);
        },
        .remove => {
            return removeValue(allocator, doc, op.path);
        },
        .replace => {
            const val = op.value orelse return error.InvalidPatch;
            // Replace is remove + add
            const removed = try removeValue(allocator, doc, op.path);
            defer freeValue(allocator, removed);
            return addValue(allocator, removed, op.path, val);
        },
        .move => {
            const from = op.from orelse return error.InvalidPatch;
            // Get the value at 'from'
            const val = pointer_mod.evaluate(doc, from) orelse return error.PathNotFound;
            // Remove from source and add to destination
            const removed = try removeValue(allocator, doc, from);
            defer freeValue(allocator, removed);
            return addValue(allocator, removed, op.path, val);
        },
        .copy => {
            const from = op.from orelse return error.InvalidPatch;
            // Get the value at 'from'
            const val = pointer_mod.evaluate(doc, from) orelse return error.PathNotFound;
            // Clone and add to destination (addValue re-clones, so we need to free)
            const cloned = try cloneValue(allocator, val);
            defer freeValue(allocator, cloned);
            return addValue(allocator, doc, op.path, cloned);
        },
        .@"test" => {
            const expected = op.value orelse return error.InvalidPatch;
            const actual = pointer_mod.evaluate(doc, op.path) orelse return error.PathNotFound;
            if (!actual.eql(expected)) return error.TestFailed;
            // Clone for consistency - caller always frees the result
            return try cloneValue(allocator, doc);
        },
    }
}

/// Add a value at the specified path
fn addValue(allocator: std.mem.Allocator, doc: Value, path: []const u8, value: Value) PatchError!Value {
    if (path.len == 0) {
        // Replace entire document
        return try cloneValue(allocator, value);
    }

    if (path[0] != '/') return error.InvalidPath;

    // Find the parent path and the key/index to add
    const last_slash = std.mem.lastIndexOf(u8, path, "/") orelse return error.InvalidPath;
    const parent_path = path[0..last_slash];
    const key_escaped = path[last_slash + 1 ..];
    const key = unescape(allocator, key_escaped) catch return error.InvalidPath;
    defer allocator.free(key);

    return addValueAtPath(allocator, doc, if (parent_path.len == 0) "" else parent_path, key, value);
}

fn addValueAtPath(allocator: std.mem.Allocator, doc: Value, parent_path: []const u8, key: []const u8, value: Value) PatchError!Value {
    if (parent_path.len == 0) {
        // Add to root
        switch (doc) {
            .obj => |obj| {
                var members: std.ArrayList(Member) = .empty;
                errdefer members.deinit(allocator);
                for (obj) |m| {
                    try members.append(allocator, .{ .k = try allocator.dupe(u8, m.k), .v = try cloneValue(allocator, m.v) });
                }
                try members.append(allocator, .{ .k = try allocator.dupe(u8, key), .v = try cloneValue(allocator, value) });
                return .{ .obj = try members.toOwnedSlice(allocator) };
            },
            .arr => |arr| {
                var items: std.ArrayList(Value) = .empty;
                errdefer items.deinit(allocator);
                if (std.mem.eql(u8, key, "-")) {
                    // Append to end
                    for (arr) |item| {
                        try items.append(allocator, try cloneValue(allocator, item));
                    }
                    try items.append(allocator, try cloneValue(allocator, value));
                } else {
                    const idx = std.fmt.parseInt(usize, key, 10) catch return error.InvalidPath;
                    if (idx > arr.len) return error.PathNotFound;
                    for (arr, 0..) |item, i| {
                        if (i == idx) {
                            try items.append(allocator, try cloneValue(allocator, value));
                        }
                        try items.append(allocator, try cloneValue(allocator, item));
                    }
                    if (idx == arr.len) {
                        try items.append(allocator, try cloneValue(allocator, value));
                    }
                }
                return .{ .arr = try items.toOwnedSlice(allocator) };
            },
            else => return error.PathNotFound,
        }
    }

    // Navigate to parent and add there
    return modifyAtPath(allocator, doc, parent_path, key, value, .add);
}

const ModifyOp = enum { add, remove };

fn modifyAtPath(allocator: std.mem.Allocator, doc: Value, path: []const u8, key: []const u8, value: ?Value, op: ModifyOp) PatchError!Value {
    if (path.len == 0 or path[0] != '/') {
        // At target
        return doModify(allocator, doc, key, value, op);
    }

    // Parse next token
    const rest = path[1..];
    const end = std.mem.indexOf(u8, rest, "/") orelse rest.len;
    const token_escaped = rest[0..end];
    const token = unescape(allocator, token_escaped) catch return error.InvalidPath;
    defer allocator.free(token);
    const remaining = if (end < rest.len) rest[end..] else "";

    switch (doc) {
        .obj => |obj| {
            var members: std.ArrayList(Member) = .empty;
            errdefer members.deinit(allocator);
            var found = false;
            for (obj) |m| {
                if (std.mem.eql(u8, m.k, token)) {
                    found = true;
                    const new_val = try modifyAtPath(allocator, m.v, remaining, key, value, op);
                    try members.append(allocator, .{ .k = try allocator.dupe(u8, m.k), .v = new_val });
                } else {
                    try members.append(allocator, .{ .k = try allocator.dupe(u8, m.k), .v = try cloneValue(allocator, m.v) });
                }
            }
            if (!found) return error.PathNotFound;
            return .{ .obj = try members.toOwnedSlice(allocator) };
        },
        .arr => |arr| {
            const idx = std.fmt.parseInt(usize, token, 10) catch return error.InvalidPath;
            if (idx >= arr.len) return error.PathNotFound;
            var items: std.ArrayList(Value) = .empty;
            errdefer items.deinit(allocator);
            for (arr, 0..) |item, i| {
                if (i == idx) {
                    const new_val = try modifyAtPath(allocator, item, remaining, key, value, op);
                    try items.append(allocator, new_val);
                } else {
                    try items.append(allocator, try cloneValue(allocator, item));
                }
            }
            return .{ .arr = try items.toOwnedSlice(allocator) };
        },
        else => return error.PathNotFound,
    }
}

fn doModify(allocator: std.mem.Allocator, doc: Value, key: []const u8, value: ?Value, op: ModifyOp) PatchError!Value {
    switch (doc) {
        .obj => |obj| {
            var members: std.ArrayList(Member) = .empty;
            errdefer members.deinit(allocator);
            var found = false;
            for (obj) |m| {
                if (std.mem.eql(u8, m.k, key)) {
                    found = true;
                    if (op == .add) {
                        // Replace existing
                        try members.append(allocator, .{ .k = try allocator.dupe(u8, m.k), .v = try cloneValue(allocator, value.?) });
                    }
                    // For remove, just skip this member
                } else {
                    try members.append(allocator, .{ .k = try allocator.dupe(u8, m.k), .v = try cloneValue(allocator, m.v) });
                }
            }
            if (!found) {
                if (op == .add) {
                    try members.append(allocator, .{ .k = try allocator.dupe(u8, key), .v = try cloneValue(allocator, value.?) });
                } else {
                    return error.PathNotFound;
                }
            }
            return .{ .obj = try members.toOwnedSlice(allocator) };
        },
        .arr => |arr| {
            var items: std.ArrayList(Value) = .empty;
            errdefer items.deinit(allocator);
            if (std.mem.eql(u8, key, "-")) {
                if (op == .add) {
                    for (arr) |item| {
                        try items.append(allocator, try cloneValue(allocator, item));
                    }
                    try items.append(allocator, try cloneValue(allocator, value.?));
                } else {
                    return error.InvalidPath;
                }
            } else {
                const idx = std.fmt.parseInt(usize, key, 10) catch return error.InvalidPath;
                if (op == .remove) {
                    if (idx >= arr.len) return error.PathNotFound;
                    for (arr, 0..) |item, i| {
                        if (i != idx) {
                            try items.append(allocator, try cloneValue(allocator, item));
                        }
                    }
                } else {
                    if (idx > arr.len) return error.PathNotFound;
                    for (arr, 0..) |item, i| {
                        if (i == idx) {
                            try items.append(allocator, try cloneValue(allocator, value.?));
                        }
                        try items.append(allocator, try cloneValue(allocator, item));
                    }
                    if (idx == arr.len) {
                        try items.append(allocator, try cloneValue(allocator, value.?));
                    }
                }
            }
            return .{ .arr = try items.toOwnedSlice(allocator) };
        },
        else => return error.PathNotFound,
    }
}

/// Remove a value at the specified path
fn removeValue(allocator: std.mem.Allocator, doc: Value, path: []const u8) PatchError!Value {
    if (path.len == 0) return error.InvalidPath; // Can't remove root
    if (path[0] != '/') return error.InvalidPath;

    const last_slash = std.mem.lastIndexOf(u8, path, "/") orelse return error.InvalidPath;
    const parent_path = path[0..last_slash];
    const key_escaped = path[last_slash + 1 ..];
    const key = unescape(allocator, key_escaped) catch return error.InvalidPath;
    defer allocator.free(key);

    if (parent_path.len == 0) {
        return doModify(allocator, doc, key, null, .remove);
    }
    return modifyAtPath(allocator, doc, parent_path, key, null, .remove);
}

/// Unescape a JSON Pointer token
fn unescape(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < token.len) {
        if (token[i] == '~') {
            if (i + 1 >= token.len) return error.InvalidPath;
            if (token[i + 1] == '0') {
                try result.append(allocator, '~');
                i += 2;
            } else if (token[i + 1] == '1') {
                try result.append(allocator, '/');
                i += 2;
            } else {
                return error.InvalidPath;
            }
        } else {
            try result.append(allocator, token[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Deep clone a Value
fn cloneValue(allocator: std.mem.Allocator, value: Value) PatchError!Value {
    switch (value) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .num => |n| return .{ .num = .{
            .lexeme = try allocator.dupe(u8, n.lexeme),
            .sign = n.sign,
            .digits = try allocator.dupe(u8, n.digits),
            .exp10 = n.exp10,
        } },
        .str => |s| return .{ .str = try allocator.dupe(u8, s) },
        .arr => |arr| {
            var items: std.ArrayList(Value) = .empty;
            errdefer items.deinit(allocator);
            for (arr) |item| {
                try items.append(allocator, try cloneValue(allocator, item));
            }
            return .{ .arr = try items.toOwnedSlice(allocator) };
        },
        .obj => |obj| {
            var members: std.ArrayList(Member) = .empty;
            errdefer members.deinit(allocator);
            for (obj) |m| {
                try members.append(allocator, .{
                    .k = try allocator.dupe(u8, m.k),
                    .v = try cloneValue(allocator, m.v),
                });
            }
            return .{ .obj = try members.toOwnedSlice(allocator) };
        },
    }
}

/// Free a cloned Value
pub fn freeValue(allocator: std.mem.Allocator, value: Value) void {
    switch (value) {
        .null, .bool => {},
        .num => |n| {
            allocator.free(n.lexeme);
            if (n.digits.ptr != n.lexeme.ptr) {
                allocator.free(n.digits);
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

/// Parse a patch document from JSON
pub fn parsePatch(allocator: std.mem.Allocator, patch_doc: Value) PatchError![]Operation {
    if (patch_doc != .arr) return error.InvalidPatch;

    var ops: std.ArrayList(Operation) = .empty;
    errdefer ops.deinit(allocator);

    for (patch_doc.arr) |op_value| {
        if (op_value != .obj) return error.InvalidPatch;

        var op_type: ?OpType = null;
        var path: ?[]const u8 = null;
        var value: ?Value = null;
        var from: ?[]const u8 = null;

        for (op_value.obj) |m| {
            if (std.mem.eql(u8, m.k, "op")) {
                if (m.v != .str) return error.InvalidPatch;
                if (std.mem.eql(u8, m.v.str, "add")) op_type = .add else if (std.mem.eql(u8, m.v.str, "remove")) op_type = .remove else if (std.mem.eql(u8, m.v.str, "replace")) op_type = .replace else if (std.mem.eql(u8, m.v.str, "move")) op_type = .move else if (std.mem.eql(u8, m.v.str, "copy")) op_type = .copy else if (std.mem.eql(u8, m.v.str, "test")) op_type = .@"test" else return error.InvalidPatch;
            } else if (std.mem.eql(u8, m.k, "path")) {
                if (m.v != .str) return error.InvalidPatch;
                path = m.v.str;
            } else if (std.mem.eql(u8, m.k, "value")) {
                value = m.v;
            } else if (std.mem.eql(u8, m.k, "from")) {
                if (m.v != .str) return error.InvalidPatch;
                from = m.v.str;
            }
        }

        if (op_type == null or path == null) return error.InvalidPatch;

        try ops.append(allocator, .{
            .op = op_type.?,
            .path = path.?,
            .value = value,
            .from = from,
        });
    }

    return ops.toOwnedSlice(allocator);
}

// ============================================================================
// JSON Diff (RFC 6902 Patch Generation)
// ============================================================================

/// Generate a JSON Patch document that transforms 'from' into 'to'
/// Caller must free the returned operations and their string allocations
pub fn diff(allocator: std.mem.Allocator, from: Value, to: Value) PatchError![]Operation {
    var ops: std.ArrayList(Operation) = .empty;
    errdefer {
        for (ops.items) |op| freeOperation(allocator, op);
        ops.deinit(allocator);
    }

    try diffValues(allocator, &ops, "", from, to);

    return ops.toOwnedSlice(allocator);
}

/// Free operations returned by diff
pub fn freeDiffOperations(allocator: std.mem.Allocator, ops: []Operation) void {
    for (ops) |op| {
        freeOperation(allocator, op);
    }
    allocator.free(ops);
}

fn freeOperation(allocator: std.mem.Allocator, op: Operation) void {
    allocator.free(op.path);
    if (op.from) |from| allocator.free(from);
    if (op.value) |val| freeValue(allocator, val);
}

fn diffValues(allocator: std.mem.Allocator, ops: *std.ArrayList(Operation), path: []const u8, from: Value, to: Value) PatchError!void {
    // If types differ or both are primitives, check for difference
    if (@intFromEnum(from) != @intFromEnum(to)) {
        try ops.append(allocator, .{
            .op = .replace,
            .path = try allocator.dupe(u8, path),
            .value = try cloneValue(allocator, to),
        });
        return;
    }

    switch (from) {
        .null => {
            // Both are null, no change
        },
        .bool => |b| {
            if (b != to.bool) {
                try ops.append(allocator, .{
                    .op = .replace,
                    .path = try allocator.dupe(u8, path),
                    .value = .{ .bool = to.bool },
                });
            }
        },
        .num => {
            if (!valuesEqual(from, to)) {
                try ops.append(allocator, .{
                    .op = .replace,
                    .path = try allocator.dupe(u8, path),
                    .value = try cloneValue(allocator, to),
                });
            }
        },
        .str => |s| {
            if (!std.mem.eql(u8, s, to.str)) {
                try ops.append(allocator, .{
                    .op = .replace,
                    .path = try allocator.dupe(u8, path),
                    .value = .{ .str = try allocator.dupe(u8, to.str) },
                });
            }
        },
        .arr => |from_arr| {
            try diffArrays(allocator, ops, path, from_arr, to.arr);
        },
        .obj => |from_obj| {
            try diffObjects(allocator, ops, path, from_obj, to.obj);
        },
    }
}

fn diffArrays(allocator: std.mem.Allocator, ops: *std.ArrayList(Operation), path: []const u8, from: []Value, to: []Value) PatchError!void {
    // Use a simple algorithm: compute common prefix, then generate ops for differences
    // For optimal patches, a more sophisticated algorithm like LCS could be used

    const min_len = @min(from.len, to.len);

    // Diff elements that exist in both arrays
    for (0..min_len) |i| {
        const elem_path = try buildArrayPath(allocator, path, i);
        defer allocator.free(elem_path);
        try diffValues(allocator, ops, elem_path, from[i], to[i]);
    }

    // Handle extra elements in 'to' array - add them
    if (to.len > from.len) {
        for (from.len..to.len) |i| {
            const elem_path = try buildArrayPath(allocator, path, i);
            try ops.append(allocator, .{
                .op = .add,
                .path = elem_path,
                .value = try cloneValue(allocator, to[i]),
            });
        }
    }

    // Handle extra elements in 'from' array - remove them (in reverse order)
    if (from.len > to.len) {
        var i = from.len;
        while (i > to.len) {
            i -= 1;
            const elem_path = try buildArrayPath(allocator, path, i);
            try ops.append(allocator, .{
                .op = .remove,
                .path = elem_path,
            });
        }
    }
}

fn diffObjects(allocator: std.mem.Allocator, ops: *std.ArrayList(Operation), path: []const u8, from: []Member, to: []Member) PatchError!void {
    // Track which keys in 'to' we've processed
    var processed = std.StringHashMap(bool).init(allocator);
    defer processed.deinit();

    // Process keys in 'from'
    for (from) |fm| {
        const to_val = findMember(to, fm.k);
        if (to_val) |tv| {
            // Key exists in both - diff the values
            const member_path = try buildObjectPath(allocator, path, fm.k);
            defer allocator.free(member_path);
            try diffValues(allocator, ops, member_path, fm.v, tv.v);
            processed.put(fm.k, true) catch return error.OutOfMemory;
        } else {
            // Key removed
            const member_path = try buildObjectPath(allocator, path, fm.k);
            try ops.append(allocator, .{
                .op = .remove,
                .path = member_path,
            });
        }
    }

    // Process keys in 'to' that weren't in 'from'
    for (to) |tm| {
        if (processed.get(tm.k) == null and findMember(from, tm.k) == null) {
            // New key
            const member_path = try buildObjectPath(allocator, path, tm.k);
            try ops.append(allocator, .{
                .op = .add,
                .path = member_path,
                .value = try cloneValue(allocator, tm.v),
            });
        }
    }
}

fn buildArrayPath(allocator: std.mem.Allocator, base: []const u8, index: usize) ![]u8 {
    var buf: [32]u8 = undefined;
    const idx_str = std.fmt.bufPrint(&buf, "{d}", .{index}) catch unreachable;

    if (base.len == 0) {
        return std.fmt.allocPrint(allocator, "/{s}", .{idx_str});
    } else {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, idx_str });
    }
}

fn buildObjectPath(allocator: std.mem.Allocator, base: []const u8, key: []const u8) ![]u8 {
    // Escape key for JSON Pointer (~ becomes ~0, / becomes ~1)
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(allocator);

    for (key) |c| {
        if (c == '~') {
            escaped.appendSlice(allocator, "~0") catch return error.OutOfMemory;
        } else if (c == '/') {
            escaped.appendSlice(allocator, "~1") catch return error.OutOfMemory;
        } else {
            escaped.append(allocator, c) catch return error.OutOfMemory;
        }
    }

    const escaped_key = escaped.items;
    if (base.len == 0) {
        return std.fmt.allocPrint(allocator, "/{s}", .{escaped_key});
    } else {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, escaped_key });
    }
}

fn valuesEqual(a: Value, b: Value) bool {
    if (@intFromEnum(a) != @intFromEnum(b)) return false;

    switch (a) {
        .null => return true,
        .bool => |av| return av == b.bool,
        .num => |an| {
            // Compare number values properly
            const bn = b.num;
            if (an.sign != bn.sign) return false;
            // Simple lexeme comparison for now
            return std.mem.eql(u8, an.lexeme, bn.lexeme);
        },
        .str => |as| return std.mem.eql(u8, as, b.str),
        .arr => |aa| {
            const ba = b.arr;
            if (aa.len != ba.len) return false;
            for (aa, ba) |ai, bi| {
                if (!valuesEqual(ai, bi)) return false;
            }
            return true;
        },
        .obj => |ao| {
            const bo = b.obj;
            if (ao.len != bo.len) return false;
            for (ao) |am| {
                const found = findMember(bo, am.k);
                if (found) |f| {
                    if (!valuesEqual(am.v, f.v)) return false;
                } else {
                    return false;
                }
            }
            return true;
        },
    }
}

/// Serialize patch operations to a JSON Value for output
pub fn patchToValue(allocator: std.mem.Allocator, ops: []const Operation) PatchError!Value {
    var arr: std.ArrayList(Value) = .empty;
    errdefer {
        for (arr.items) |item| freeValue(allocator, item);
        arr.deinit(allocator);
    }

    for (ops) |op| {
        var members: std.ArrayList(Member) = .empty;
        errdefer members.deinit(allocator);

        // op field
        const op_str = switch (op.op) {
            .add => "add",
            .remove => "remove",
            .replace => "replace",
            .move => "move",
            .copy => "copy",
            .@"test" => "test",
        };
        try members.append(allocator, .{
            .k = try allocator.dupe(u8, "op"),
            .v = .{ .str = try allocator.dupe(u8, op_str) },
        });

        // path field
        try members.append(allocator, .{
            .k = try allocator.dupe(u8, "path"),
            .v = .{ .str = try allocator.dupe(u8, op.path) },
        });

        // value field (for add, replace, test)
        if (op.value) |val| {
            try members.append(allocator, .{
                .k = try allocator.dupe(u8, "value"),
                .v = try cloneValue(allocator, val),
            });
        }

        // from field (for move, copy)
        if (op.from) |from| {
            try members.append(allocator, .{
                .k = try allocator.dupe(u8, "from"),
                .v = .{ .str = try allocator.dupe(u8, from) },
            });
        }

        try arr.append(allocator, .{ .obj = try members.toOwnedSlice(allocator) });
    }

    return .{ .arr = try arr.toOwnedSlice(allocator) };
}

// ============================================================================
// RFC 7396 JSON Merge Patch
// ============================================================================

/// Apply a JSON Merge Patch (RFC 7396) to a document
/// Returns a new modified document (does not modify original)
pub fn mergePatch(allocator: std.mem.Allocator, target: Value, patch: Value) PatchError!Value {
    // If patch is not an object, it replaces the target entirely
    if (patch != .obj) {
        return try cloneValue(allocator, patch);
    }

    // Start with target (clone if object, otherwise start with empty object)
    var result: Value = if (target == .obj)
        try cloneValue(allocator, target)
    else
        .{ .obj = &.{} };
    errdefer freeValue(allocator, result);

    // Apply each patch member
    for (patch.obj) |patch_member| {
        if (patch_member.v == .null) {
            // Remove the key
            result = try removeKey(allocator, result, patch_member.k);
        } else {
            // Recursively merge
            const existing = findMember(result.obj, patch_member.k);
            const merged = if (existing) |e|
                try mergePatch(allocator, e.v, patch_member.v)
            else
                try cloneValue(allocator, patch_member.v);
            errdefer freeValue(allocator, merged);

            result = try setKey(allocator, result, patch_member.k, merged);
        }
    }

    return result;
}

/// Find a member by key
fn findMember(obj: []const Member, key: []const u8) ?*const Member {
    for (obj) |*m| {
        if (std.mem.eql(u8, m.k, key)) return m;
    }
    return null;
}

/// Remove a key from an object, returning a new object
fn removeKey(allocator: std.mem.Allocator, obj: Value, key: []const u8) PatchError!Value {
    if (obj != .obj) return try cloneValue(allocator, obj);

    var members: std.ArrayList(Member) = .empty;
    errdefer members.deinit(allocator);

    for (obj.obj) |m| {
        if (!std.mem.eql(u8, m.k, key)) {
            try members.append(allocator, .{
                .k = try allocator.dupe(u8, m.k),
                .v = try cloneValue(allocator, m.v),
            });
        }
    }

    // Free the old object
    freeValue(allocator, obj);

    return .{ .obj = try members.toOwnedSlice(allocator) };
}

/// Set a key in an object, returning a new object
fn setKey(allocator: std.mem.Allocator, obj: Value, key: []const u8, value: Value) PatchError!Value {
    if (obj != .obj) {
        // Create new object with just this key
        var members: std.ArrayList(Member) = .empty;
        errdefer members.deinit(allocator);
        try members.append(allocator, .{
            .k = try allocator.dupe(u8, key),
            .v = value, // Take ownership of value
        });
        return .{ .obj = try members.toOwnedSlice(allocator) };
    }

    var members: std.ArrayList(Member) = .empty;
    errdefer members.deinit(allocator);

    var found = false;
    for (obj.obj) |m| {
        if (std.mem.eql(u8, m.k, key)) {
            found = true;
            try members.append(allocator, .{
                .k = try allocator.dupe(u8, m.k),
                .v = value, // Take ownership of new value
            });
        } else {
            try members.append(allocator, .{
                .k = try allocator.dupe(u8, m.k),
                .v = try cloneValue(allocator, m.v),
            });
        }
    }

    if (!found) {
        try members.append(allocator, .{
            .k = try allocator.dupe(u8, key),
            .v = value, // Take ownership of value
        });
    }

    // Free the old object
    freeValue(allocator, obj);

    return .{ .obj = try members.toOwnedSlice(allocator) };
}

// ============================================================================
// Tests
// ============================================================================

test "patch add to object" {
    const allocator = std.testing.allocator;

    var members = [_]Member{
        .{ .k = "a", .v = .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } } },
    };
    const doc: Value = .{ .obj = &members };

    const ops = [_]Operation{
        .{ .op = .add, .path = "/b", .value = .{ .num = .{ .lexeme = "2", .sign = 1, .digits = "2", .exp10 = 0 } } },
    };

    const result = try apply(allocator, doc, &ops);
    defer freeValue(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.obj.len);
}

test "patch remove from object" {
    const allocator = std.testing.allocator;

    var members = [_]Member{
        .{ .k = "a", .v = .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } } },
        .{ .k = "b", .v = .{ .num = .{ .lexeme = "2", .sign = 1, .digits = "2", .exp10 = 0 } } },
    };
    const doc: Value = .{ .obj = &members };

    const ops = [_]Operation{
        .{ .op = .remove, .path = "/a" },
    };

    const result = try apply(allocator, doc, &ops);
    defer freeValue(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.obj.len);
    try std.testing.expectEqualStrings("b", result.obj[0].k);
}

test "patch replace in object" {
    const allocator = std.testing.allocator;

    var members = [_]Member{
        .{ .k = "a", .v = .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } } },
    };
    const doc: Value = .{ .obj = &members };

    const ops = [_]Operation{
        .{ .op = .replace, .path = "/a", .value = .{ .num = .{ .lexeme = "99", .sign = 1, .digits = "99", .exp10 = 0 } } },
    };

    const result = try apply(allocator, doc, &ops);
    defer freeValue(allocator, result);

    try std.testing.expectEqualStrings("99", result.obj[0].v.num.lexeme);
}

test "patch test operation success" {
    const allocator = std.testing.allocator;

    var members = [_]Member{
        .{ .k = "a", .v = .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } } },
    };
    const doc: Value = .{ .obj = &members };

    const ops = [_]Operation{
        .{ .op = .@"test", .path = "/a", .value = .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } } },
    };

    const result = try apply(allocator, doc, &ops);
    defer freeValue(allocator, result);
    // Test doesn't modify, but should succeed
    try std.testing.expectEqual(@as(usize, 1), result.obj.len);
}

test "patch test operation failure" {
    const allocator = std.testing.allocator;

    var members = [_]Member{
        .{ .k = "a", .v = .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } } },
    };
    const doc: Value = .{ .obj = &members };

    const ops = [_]Operation{
        .{ .op = .@"test", .path = "/a", .value = .{ .num = .{ .lexeme = "2", .sign = 1, .digits = "2", .exp10 = 0 } } },
    };

    try std.testing.expectError(error.TestFailed, apply(allocator, doc, &ops));
}

test "patch add to array" {
    const allocator = std.testing.allocator;

    var items = [_]Value{
        .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } },
        .{ .num = .{ .lexeme = "2", .sign = 1, .digits = "2", .exp10 = 0 } },
    };
    const doc: Value = .{ .arr = &items };

    const ops = [_]Operation{
        .{ .op = .add, .path = "/-", .value = .{ .num = .{ .lexeme = "3", .sign = 1, .digits = "3", .exp10 = 0 } } },
    };

    const result = try apply(allocator, doc, &ops);
    defer freeValue(allocator, result);

    try std.testing.expectEqual(@as(usize, 3), result.arr.len);
}

// ============================================================================
// Merge Patch Tests
// ============================================================================

test "merge patch add new key" {
    const allocator = std.testing.allocator;

    var target_members = [_]Member{
        .{ .k = "a", .v = .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } } },
    };
    const target: Value = .{ .obj = &target_members };

    var patch_members = [_]Member{
        .{ .k = "b", .v = .{ .num = .{ .lexeme = "2", .sign = 1, .digits = "2", .exp10 = 0 } } },
    };
    const patch: Value = .{ .obj = &patch_members };

    const result = try mergePatch(allocator, target, patch);
    defer freeValue(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.obj.len);
}

test "merge patch replace existing key" {
    const allocator = std.testing.allocator;

    var target_members = [_]Member{
        .{ .k = "a", .v = .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } } },
    };
    const target: Value = .{ .obj = &target_members };

    var patch_members = [_]Member{
        .{ .k = "a", .v = .{ .num = .{ .lexeme = "99", .sign = 1, .digits = "99", .exp10 = 0 } } },
    };
    const patch: Value = .{ .obj = &patch_members };

    const result = try mergePatch(allocator, target, patch);
    defer freeValue(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.obj.len);
    try std.testing.expectEqualStrings("99", result.obj[0].v.num.lexeme);
}

test "merge patch remove key with null" {
    const allocator = std.testing.allocator;

    var target_members = [_]Member{
        .{ .k = "a", .v = .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } } },
        .{ .k = "b", .v = .{ .num = .{ .lexeme = "2", .sign = 1, .digits = "2", .exp10 = 0 } } },
    };
    const target: Value = .{ .obj = &target_members };

    var patch_members = [_]Member{
        .{ .k = "a", .v = .null },
    };
    const patch: Value = .{ .obj = &patch_members };

    const result = try mergePatch(allocator, target, patch);
    defer freeValue(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.obj.len);
    try std.testing.expectEqualStrings("b", result.obj[0].k);
}

test "merge patch non-object replaces target" {
    const allocator = std.testing.allocator;

    var target_members = [_]Member{
        .{ .k = "a", .v = .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } } },
    };
    const target: Value = .{ .obj = &target_members };
    const patch: Value = .{ .str = "hello" };

    const result = try mergePatch(allocator, target, patch);
    defer freeValue(allocator, result);

    try std.testing.expectEqualStrings("hello", result.str);
}

// ============================================================================
// Diff Tests
// ============================================================================

test "diff identical objects" {
    const allocator = std.testing.allocator;

    var members = [_]Member{
        .{ .k = "a", .v = .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } } },
    };
    const from: Value = .{ .obj = &members };
    const to: Value = .{ .obj = &members };

    const ops = try diff(allocator, from, to);
    defer freeDiffOperations(allocator, ops);

    try std.testing.expectEqual(@as(usize, 0), ops.len);
}

test "diff object add key" {
    const allocator = std.testing.allocator;

    var from_members = [_]Member{
        .{ .k = "a", .v = .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } } },
    };
    const from: Value = .{ .obj = &from_members };

    var to_members = [_]Member{
        .{ .k = "a", .v = .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } } },
        .{ .k = "b", .v = .{ .num = .{ .lexeme = "2", .sign = 1, .digits = "2", .exp10 = 0 } } },
    };
    const to: Value = .{ .obj = &to_members };

    const ops = try diff(allocator, from, to);
    defer freeDiffOperations(allocator, ops);

    try std.testing.expectEqual(@as(usize, 1), ops.len);
    try std.testing.expectEqual(OpType.add, ops[0].op);
    try std.testing.expectEqualStrings("/b", ops[0].path);
}

test "diff object remove key" {
    const allocator = std.testing.allocator;

    var from_members = [_]Member{
        .{ .k = "a", .v = .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } } },
        .{ .k = "b", .v = .{ .num = .{ .lexeme = "2", .sign = 1, .digits = "2", .exp10 = 0 } } },
    };
    const from: Value = .{ .obj = &from_members };

    var to_members = [_]Member{
        .{ .k = "a", .v = .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } } },
    };
    const to: Value = .{ .obj = &to_members };

    const ops = try diff(allocator, from, to);
    defer freeDiffOperations(allocator, ops);

    try std.testing.expectEqual(@as(usize, 1), ops.len);
    try std.testing.expectEqual(OpType.remove, ops[0].op);
    try std.testing.expectEqualStrings("/b", ops[0].path);
}

test "diff object replace value" {
    const allocator = std.testing.allocator;

    var from_members = [_]Member{
        .{ .k = "a", .v = .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } } },
    };
    const from: Value = .{ .obj = &from_members };

    var to_members = [_]Member{
        .{ .k = "a", .v = .{ .num = .{ .lexeme = "2", .sign = 1, .digits = "2", .exp10 = 0 } } },
    };
    const to: Value = .{ .obj = &to_members };

    const ops = try diff(allocator, from, to);
    defer freeDiffOperations(allocator, ops);

    try std.testing.expectEqual(@as(usize, 1), ops.len);
    try std.testing.expectEqual(OpType.replace, ops[0].op);
    try std.testing.expectEqualStrings("/a", ops[0].path);
}

test "diff array add element" {
    const allocator = std.testing.allocator;

    var from_items = [_]Value{
        .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } },
    };
    const from: Value = .{ .arr = &from_items };

    var to_items = [_]Value{
        .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } },
        .{ .num = .{ .lexeme = "2", .sign = 1, .digits = "2", .exp10 = 0 } },
    };
    const to: Value = .{ .arr = &to_items };

    const ops = try diff(allocator, from, to);
    defer freeDiffOperations(allocator, ops);

    try std.testing.expectEqual(@as(usize, 1), ops.len);
    try std.testing.expectEqual(OpType.add, ops[0].op);
    try std.testing.expectEqualStrings("/1", ops[0].path);
}

test "diff array remove element" {
    const allocator = std.testing.allocator;

    var from_items = [_]Value{
        .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } },
        .{ .num = .{ .lexeme = "2", .sign = 1, .digits = "2", .exp10 = 0 } },
    };
    const from: Value = .{ .arr = &from_items };

    var to_items = [_]Value{
        .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } },
    };
    const to: Value = .{ .arr = &to_items };

    const ops = try diff(allocator, from, to);
    defer freeDiffOperations(allocator, ops);

    try std.testing.expectEqual(@as(usize, 1), ops.len);
    try std.testing.expectEqual(OpType.remove, ops[0].op);
    try std.testing.expectEqualStrings("/1", ops[0].path);
}

test "diff round trip" {
    const allocator = std.testing.allocator;

    var from_members = [_]Member{
        .{ .k = "name", .v = .{ .str = "Alice" } },
        .{ .k = "age", .v = .{ .num = .{ .lexeme = "30", .sign = 1, .digits = "30", .exp10 = 0 } } },
    };
    const from: Value = .{ .obj = &from_members };

    var to_members = [_]Member{
        .{ .k = "name", .v = .{ .str = "Bob" } },
        .{ .k = "age", .v = .{ .num = .{ .lexeme = "25", .sign = 1, .digits = "25", .exp10 = 0 } } },
        .{ .k = "city", .v = .{ .str = "NYC" } },
    };
    const to: Value = .{ .obj = &to_members };

    // Generate diff
    const ops = try diff(allocator, from, to);
    defer freeDiffOperations(allocator, ops);

    // Apply patch
    const patched = try apply(allocator, from, ops);
    defer freeValue(allocator, patched);

    // Verify result matches 'to'
    try std.testing.expectEqual(@as(usize, 3), patched.obj.len);

    // Check specific values
    var found_name = false;
    var found_city = false;
    for (patched.obj) |m| {
        if (std.mem.eql(u8, m.k, "name")) {
            try std.testing.expectEqualStrings("Bob", m.v.str);
            found_name = true;
        }
        if (std.mem.eql(u8, m.k, "city")) {
            try std.testing.expectEqualStrings("NYC", m.v.str);
            found_city = true;
        }
    }
    try std.testing.expect(found_name);
    try std.testing.expect(found_city);
}

test "diff to JSON value" {
    const allocator = std.testing.allocator;

    var from_members = [_]Member{
        .{ .k = "a", .v = .{ .num = .{ .lexeme = "1", .sign = 1, .digits = "1", .exp10 = 0 } } },
    };
    const from: Value = .{ .obj = &from_members };

    var to_members = [_]Member{
        .{ .k = "a", .v = .{ .num = .{ .lexeme = "2", .sign = 1, .digits = "2", .exp10 = 0 } } },
    };
    const to: Value = .{ .obj = &to_members };

    const ops = try diff(allocator, from, to);
    defer freeDiffOperations(allocator, ops);

    const patch_value = try patchToValue(allocator, ops);
    defer freeValue(allocator, patch_value);

    try std.testing.expect(patch_value == .arr);
    try std.testing.expectEqual(@as(usize, 1), patch_value.arr.len);
    try std.testing.expect(patch_value.arr[0] == .obj);
}
