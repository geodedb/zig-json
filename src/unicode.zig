// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! UTF-8 Encoding/Decoding Utilities
//!
//! Provides strict UTF-8 validation and encoding/decoding functions.

const std = @import("std");

/// Get the expected length of a UTF-8 sequence from its first byte
pub fn utf8SeqLen(first: u8) !usize {
    if (first < 0x80) return 1;
    if (first >= 0xC2 and first <= 0xDF) return 2;
    if (first >= 0xE0 and first <= 0xEF) return 3;
    if (first >= 0xF0 and first <= 0xF4) return 4;
    return error.InvalidUtf8;
}

/// Validate a UTF-8 byte sequence
pub fn isValidUtf8Seq(seq: []const u8) bool {
    if (seq.len == 0) return false;

    const len = utf8SeqLen(seq[0]) catch return false;
    if (seq.len != len) return false;

    // Check continuation bytes
    for (seq[1..]) |b| {
        if (b < 0x80 or b > 0xBF) return false;
    }

    // Decode and validate codepoint
    const cp = decodeUtf8(seq) catch return false;

    // Reject surrogates
    if (cp >= 0xD800 and cp <= 0xDFFF) return false;
    if (cp > 0x10FFFF) return false;

    // Check for overlong encoding
    const min_cp: u21 = switch (len) {
        1 => 0,
        2 => 0x80,
        3 => 0x800,
        4 => 0x10000,
        else => return false,
    };
    if (cp < min_cp) return false;

    return true;
}

/// Decode a UTF-8 sequence to a codepoint
pub fn decodeUtf8(seq: []const u8) !u21 {
    if (seq.len == 0) return error.InvalidUtf8;

    const len = try utf8SeqLen(seq[0]);
    if (seq.len != len) return error.InvalidUtf8;

    var cp: u21 = switch (len) {
        1 => seq[0],
        2 => @as(u21, seq[0] & 0x1F) << 6,
        3 => @as(u21, seq[0] & 0x0F) << 12,
        4 => @as(u21, seq[0] & 0x07) << 18,
        else => return error.InvalidUtf8,
    };

    for (seq[1..], 0..) |b, i| {
        if (b < 0x80 or b > 0xBF) return error.InvalidUtf8;
        cp |= @as(u21, b & 0x3F) << @intCast(6 * (len - 2 - i));
    }

    return cp;
}

/// Encode a codepoint to UTF-8
pub fn encodeUtf8(cp: u21, buf: *[4]u8) !usize {
    if (cp < 0x80) {
        buf[0] = @intCast(cp);
        return 1;
    }
    if (cp < 0x800) {
        buf[0] = @intCast(0xC0 | (cp >> 6));
        buf[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        buf[0] = @intCast(0xE0 | (cp >> 12));
        buf[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    }
    if (cp <= 0x10FFFF) {
        buf[0] = @intCast(0xF0 | (cp >> 18));
        buf[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
        buf[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        buf[3] = @intCast(0x80 | (cp & 0x3F));
        return 4;
    }
    return error.InvalidCodepoint;
}

/// Count UTF-8 codepoints in a string
pub fn countCodepoints(s: []const u8) !usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = try utf8SeqLen(s[i]);
        if (i + len > s.len) return error.InvalidUtf8;
        count += 1;
        i += len;
    }
    return count;
}

test "utf8 sequence length" {
    try std.testing.expectEqual(@as(usize, 1), try utf8SeqLen('a'));
    try std.testing.expectEqual(@as(usize, 2), try utf8SeqLen(0xC2));
    try std.testing.expectEqual(@as(usize, 3), try utf8SeqLen(0xE0));
    try std.testing.expectEqual(@as(usize, 4), try utf8SeqLen(0xF0));
}

test "valid utf8" {
    try std.testing.expect(isValidUtf8Seq("a"));
    try std.testing.expect(isValidUtf8Seq("\xC2\x80"));
    try std.testing.expect(isValidUtf8Seq("\xE0\xA0\x80"));
    try std.testing.expect(isValidUtf8Seq("\xF0\x90\x80\x80"));
}

test "invalid utf8 - overlong" {
    try std.testing.expect(!isValidUtf8Seq("\xC0\x80")); // Overlong NUL
}

test "invalid utf8 - surrogate" {
    try std.testing.expect(!isValidUtf8Seq("\xED\xA0\x80")); // U+D800
}

test "decode utf8" {
    try std.testing.expectEqual(@as(u21, 'A'), try decodeUtf8("A"));
    try std.testing.expectEqual(@as(u21, 0x80), try decodeUtf8("\xC2\x80"));
    try std.testing.expectEqual(@as(u21, 0x800), try decodeUtf8("\xE0\xA0\x80"));
    try std.testing.expectEqual(@as(u21, 0x10000), try decodeUtf8("\xF0\x90\x80\x80"));
}

test "encode utf8" {
    var buf: [4]u8 = undefined;

    const len1 = try encodeUtf8('A', &buf);
    try std.testing.expectEqual(@as(usize, 1), len1);
    try std.testing.expectEqualStrings("A", buf[0..len1]);

    const len2 = try encodeUtf8(0x80, &buf);
    try std.testing.expectEqual(@as(usize, 2), len2);
    try std.testing.expectEqualStrings("\xC2\x80", buf[0..len2]);
}

test "count codepoints" {
    try std.testing.expectEqual(@as(usize, 5), try countCodepoints("hello"));
    try std.testing.expectEqual(@as(usize, 1), try countCodepoints("\xF0\x9F\x98\x80")); // emoji
}
