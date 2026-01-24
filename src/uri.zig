// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! RFC 3986 URI Resolution
//!
//! Provides URI parsing and reference resolution for JSON Schema $ref handling.

const std = @import("std");

/// Parsed URI components
pub const Uri = struct {
    scheme: ?[]const u8,
    authority: ?[]const u8,
    path: []const u8,
    query: ?[]const u8,
    fragment: ?[]const u8,
};

/// Parse a URI string into components
pub fn parseUri(s: []const u8) Uri {
    var uri = Uri{
        .scheme = null,
        .authority = null,
        .path = "",
        .query = null,
        .fragment = null,
    };

    var rest = s;

    // Extract fragment
    if (std.mem.indexOf(u8, rest, "#")) |frag_pos| {
        uri.fragment = rest[frag_pos + 1 ..];
        rest = rest[0..frag_pos];
    }

    // Extract query
    if (std.mem.indexOf(u8, rest, "?")) |query_pos| {
        uri.query = rest[query_pos + 1 ..];
        rest = rest[0..query_pos];
    }

    // Extract scheme
    if (std.mem.indexOf(u8, rest, ":")) |colon_pos| {
        const potential_scheme = rest[0..colon_pos];
        var valid = true;
        for (potential_scheme, 0..) |c, i| {
            if (i == 0) {
                if (!std.ascii.isAlphabetic(c)) valid = false;
            } else {
                if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') valid = false;
            }
        }
        if (valid and potential_scheme.len > 0) {
            uri.scheme = potential_scheme;
            rest = rest[colon_pos + 1 ..];
        }
    }

    // Extract authority
    if (rest.len >= 2 and rest[0] == '/' and rest[1] == '/') {
        rest = rest[2..];
        if (std.mem.indexOf(u8, rest, "/")) |path_start| {
            uri.authority = rest[0..path_start];
            uri.path = rest[path_start..];
        } else {
            uri.authority = rest;
            uri.path = "";
        }
    } else {
        uri.path = rest;
    }

    return uri;
}

/// Resolve a reference URI against a base URI (RFC 3986 Section 5)
pub fn resolve(base: []const u8, ref: []const u8, a: std.mem.Allocator) ![]u8 {
    const r = parseUri(ref);

    // If reference has scheme, it's absolute
    if (r.scheme != null) {
        return try a.dupe(u8, ref);
    }

    const b = parseUri(base);

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);

    // Use base scheme
    if (b.scheme) |scheme| {
        try result.appendSlice(a, scheme);
        try result.append(a, ':');
    }

    if (r.authority != null) {
        // Reference has authority
        try result.appendSlice(a, "//");
        try result.appendSlice(a, r.authority.?);
        const cleaned = try removeDotSegments(r.path, a);
        defer a.free(cleaned);
        try result.appendSlice(a, cleaned);
    } else {
        // Use base authority
        if (b.authority) |auth| {
            try result.appendSlice(a, "//");
            try result.appendSlice(a, auth);
        }

        if (r.path.len == 0) {
            try result.appendSlice(a, b.path);
            if (r.query) |q| {
                try result.append(a, '?');
                try result.appendSlice(a, q);
            } else if (b.query) |q| {
                try result.append(a, '?');
                try result.appendSlice(a, q);
            }
        } else {
            if (r.path.len > 0 and r.path[0] == '/') {
                const cleaned = try removeDotSegments(r.path, a);
                defer a.free(cleaned);
                try result.appendSlice(a, cleaned);
            } else {
                const merged = try mergePaths(b, r.path, a);
                defer a.free(merged);
                const cleaned = try removeDotSegments(merged, a);
                defer a.free(cleaned);
                try result.appendSlice(a, cleaned);
            }
            if (r.query) |q| {
                try result.append(a, '?');
                try result.appendSlice(a, q);
            }
        }
    }

    // Keep reference fragment
    if (r.fragment) |frag| {
        try result.append(a, '#');
        try result.appendSlice(a, frag);
    }

    return result.toOwnedSlice(a);
}

fn mergePaths(base: Uri, ref_path: []const u8, a: std.mem.Allocator) ![]u8 {
    if (base.authority != null and base.path.len == 0) {
        var result: std.ArrayList(u8) = .empty;
        try result.append(a, '/');
        try result.appendSlice(a, ref_path);
        return result.toOwnedSlice(a);
    }

    if (std.mem.lastIndexOf(u8, base.path, "/")) |last_slash| {
        var result: std.ArrayList(u8) = .empty;
        try result.appendSlice(a, base.path[0 .. last_slash + 1]);
        try result.appendSlice(a, ref_path);
        return result.toOwnedSlice(a);
    }

    return a.dupe(u8, ref_path);
}

fn removeDotSegments(path: []const u8, a: std.mem.Allocator) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(a);

    var input = path;

    while (input.len > 0) {
        if (std.mem.startsWith(u8, input, "../")) {
            input = input[3..];
        } else if (std.mem.startsWith(u8, input, "./")) {
            input = input[2..];
        } else if (std.mem.startsWith(u8, input, "/./")) {
            input = input[2..];
        } else if (std.mem.eql(u8, input, "/.")) {
            input = "/";
        } else if (std.mem.startsWith(u8, input, "/../")) {
            input = input[3..];
            removeLastSegment(&output);
        } else if (std.mem.eql(u8, input, "/..")) {
            input = "/";
            removeLastSegment(&output);
        } else if (std.mem.eql(u8, input, ".") or std.mem.eql(u8, input, "..")) {
            input = "";
        } else {
            if (input[0] == '/') {
                try output.append(a, '/');
                input = input[1..];
            }
            if (std.mem.indexOf(u8, input, "/")) |next_slash| {
                try output.appendSlice(a, input[0..next_slash]);
                input = input[next_slash..];
            } else {
                try output.appendSlice(a, input);
                input = "";
            }
        }
    }

    return output.toOwnedSlice(a);
}

fn removeLastSegment(output: *std.ArrayList(u8)) void {
    while (output.items.len > 0) {
        const c = output.pop();
        if (c == '/') break;
    }
}

test "parse uri - full" {
    const u = parseUri("https://example.com/path?query#frag");
    try std.testing.expectEqualStrings("https", u.scheme.?);
    try std.testing.expectEqualStrings("example.com", u.authority.?);
    try std.testing.expectEqualStrings("/path", u.path);
    try std.testing.expectEqualStrings("query", u.query.?);
    try std.testing.expectEqualStrings("frag", u.fragment.?);
}

test "parse uri - path only" {
    const u = parseUri("/a/b/c");
    try std.testing.expect(u.scheme == null);
    try std.testing.expect(u.authority == null);
    try std.testing.expectEqualStrings("/a/b/c", u.path);
}

test "parse uri - fragment only" {
    const u = parseUri("#foo");
    try std.testing.expect(u.scheme == null);
    try std.testing.expectEqualStrings("", u.path);
    try std.testing.expectEqualStrings("foo", u.fragment.?);
}

test "resolve - relative path" {
    const result = try resolve("https://ex.com/a/b", "../c", std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("https://ex.com/c", result);
}

test "resolve - fragment only" {
    const result = try resolve("https://ex.com/schema", "#/$defs/foo", std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("https://ex.com/schema#/$defs/foo", result);
}

test "resolve - absolute reference" {
    const result = try resolve("https://ex.com/a", "https://other.com/b", std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("https://other.com/b", result);
}
