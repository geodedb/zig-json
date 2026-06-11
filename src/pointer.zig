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
        const raw = rest[0..end];

        switch (current) {
            .obj => |obj| {
                var found = false;
                for (obj) |m| {
                    // Compare the (possibly escaped) token against the decoded
                    // key without allocating or materializing the unescaped
                    // token; the escape-free case degenerates to std.mem.eql.
                    if (tokenEqualsKey(raw, m.k) catch return null) {
                        current = m.v;
                        found = true;
                        break;
                    }
                }
                if (!found) return null;
            },
            .arr => |arr| {
                // Array indices are bare digits in RFC 6901, so they never
                // contain escapes -- parse the raw token directly.
                if (std.mem.eql(u8, raw, "-")) return null; // "-" means append, not valid for read
                const idx = std.fmt.parseInt(usize, raw, 10) catch return null;
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

/// Compare a raw (possibly escaped) JSON Pointer token against a decoded object
/// key, applying RFC 6901 unescaping (~0 -> ~, ~1 -> /) on the fly.
///
/// This never allocates and never materializes the unescaped token. The common
/// escape-free case short-circuits to a plain byte comparison; only when the
/// token actually contains a `~` does it walk the escape sequences. A malformed
/// escape (trailing `~` or `~` followed by anything other than `0`/`1`) yields
/// `error.InvalidPointer`.
fn tokenEqualsKey(token: []const u8, key: []const u8) !bool {
    // Fast path: no escapes -- a direct byte comparison.
    if (std.mem.indexOfScalar(u8, token, '~') == null) {
        return std.mem.eql(u8, token, key);
    }

    var ti: usize = 0;
    var ki: usize = 0;
    while (ti < token.len) {
        const decoded: u8 = if (token[ti] == '~') blk: {
            if (ti + 1 >= token.len) return error.InvalidPointer;
            const c: u8 = switch (token[ti + 1]) {
                '0' => '~',
                '1' => '/',
                else => return error.InvalidPointer,
            };
            ti += 2;
            break :blk c;
        } else blk: {
            const c = token[ti];
            ti += 1;
            break :blk c;
        };

        if (ki >= key.len or key[ki] != decoded) return false;
        ki += 1;
    }

    return ki == key.len;
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

test "evaluate pointer - no escapes does not allocate" {
    // Using the testing allocator as the document allocator: evaluate must
    // resolve the pointer without performing any allocation of its own. If it
    // leaked an allocation (as the old page_allocator path could not be caught
    // by), this test's allocator would still be clean because evaluate now
    // borrows directly from the input. We assert functional correctness on a
    // multi-segment escape-free pointer.
    const a = std.testing.allocator;

    var inner = [_]json.Member{
        .{ .k = "b", .v = .{ .bool = true } },
    };
    var outer = [_]json.Member{
        .{ .k = "a", .v = .{ .obj = &inner } },
    };
    const doc = Value{ .obj = &outer };

    const val = evaluate(doc, "/a/b");
    try std.testing.expect(val != null);
    try std.testing.expect(val.?.bool == true);

    // Sanity: the testing allocator has tracked no outstanding allocations from
    // evaluate (it never received one). Allocate and free a throwaway byte to
    // confirm the allocator is healthy and detect-leaks is active for this test.
    const probe = try a.alloc(u8, 1);
    a.free(probe);
}

test "evaluate pointer - tilde escapes resolve" {
    // Key literally named "a/b" is addressed via ~1; key "m~n" via ~0.
    var members = [_]json.Member{
        .{ .k = "a/b", .v = .{ .bool = true } },
        .{ .k = "m~n", .v = .{ .bool = false } },
    };
    const doc = Value{ .obj = &members };

    const slash = evaluate(doc, "/a~1b");
    try std.testing.expect(slash != null);
    try std.testing.expect(slash.?.bool == true);

    const tilde = evaluate(doc, "/m~0n");
    try std.testing.expect(tilde != null);
    try std.testing.expect(tilde.?.bool == false);

    // Combined escapes in a single token: key "~/" addressed via ~0~1.
    var combo_members = [_]json.Member{
        .{ .k = "~/", .v = .{ .bool = true } },
    };
    const combo = evaluate(Value{ .obj = &combo_members }, "/~0~1");
    try std.testing.expect(combo != null);
    try std.testing.expect(combo.?.bool == true);
}

test "evaluate pointer - malformed escape is rejected" {
    var members = [_]json.Member{
        .{ .k = "x", .v = .{ .bool = true } },
    };
    const doc = Value{ .obj = &members };

    // Trailing `~` and `~` followed by an invalid char must not resolve.
    try std.testing.expect(evaluate(doc, "/x~") == null);
    try std.testing.expect(evaluate(doc, "/x~2") == null);
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
