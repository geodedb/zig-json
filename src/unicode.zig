// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! UTF-8 Encoding/Decoding Utilities
//!
//! Provides strict UTF-8 validation and encoding/decoding functions.

const std = @import("std");

/// Value of one ASCII hex digit (0-9, a-f, A-F), or null for any other byte.
pub fn hexDigitValue(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

/// Decodes the four hex digits of a `\uXXXX` escape. Every byte must be an
/// ASCII hex digit, as RFC 8259 requires. Unlike std.fmt.parseInt this rejects
/// a leading sign and `_` digit separators, so "+041", "0_41" and "-000" are
/// not accepted (SONNY-2768).
pub fn parseHex4(hex: *const [4]u8) ?u16 {
    var v: u16 = 0;
    for (hex) |c| v = (v << 4) | (hexDigitValue(c) orelse return null);
    return v;
}

/// Decodes exactly two ASCII hex digits (JSON5 `\xNN`, `%NN`). Same strictness
/// as parseHex4.
pub fn parseHex2(hex: *const [2]u8) ?u8 {
    var v: u8 = 0;
    for (hex) |c| v = (v << 4) | (hexDigitValue(c) orelse return null);
    return v;
}

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

    // NPERF-001: single decode pass. decodeUtf8 already range-checks every
    // continuation byte (0x80..0xBF), rejects a truncated sequence, and
    // computes the codepoint, so the previous separate continuation-byte
    // pre-scan was redundant. Apply the remaining UTF-8 validity rules
    // (surrogate, max, overlong) to the decoded codepoint -- decodeUtf8 does
    // NOT detect those, so they must stay here for correctness.
    const cp = decodeUtf8(seq) catch return false;

    // Reject surrogates
    if (cp >= 0xD800 and cp <= 0xDFFF) return false;
    if (cp > 0x10FFFF) return false;

    // Check for overlong encoding (minimum codepoint per sequence length).
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

test "parseHex4 accepts exactly four hex digits (SONNY-2768)" {
    try std.testing.expectEqual(@as(?u16, 0x0041), parseHex4("0041"));
    try std.testing.expectEqual(@as(?u16, 0xABCD), parseHex4("ABCD"));
    try std.testing.expectEqual(@as(?u16, 0xABCD), parseHex4("abcd"));
    try std.testing.expectEqual(@as(?u16, 0xABCD), parseHex4("aBcD"));
    try std.testing.expectEqual(@as(?u16, 0xFFFF), parseHex4("FFFF"));
    try std.testing.expectEqual(@as(?u16, 0), parseHex4("0000"));
    const bad = [_]*const [4]u8{
        "+041", "-000", "-041", "_041", "0_41", "00_1", "004_",
        "0+41", "004-", "004g", "G041", "0x41", " 041", "004 ",
    };
    for (bad) |h| try std.testing.expectEqual(@as(?u16, null), parseHex4(h));
}

test "parseHex2 accepts exactly two hex digits (SONNY-2768)" {
    try std.testing.expectEqual(@as(?u8, 0x4a), parseHex2("4a"));
    try std.testing.expectEqual(@as(?u8, 0x4a), parseHex2("4A"));
    const bad = [_]*const [2]u8{ "+1", "-0", "_1", "1_", "1g", "zz" };
    for (bad) |h| try std.testing.expectEqual(@as(?u8, null), parseHex2(h));
}
