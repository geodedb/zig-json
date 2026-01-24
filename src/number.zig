// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Normalized Base-10 Decimal Number Representation
//!
//! Provides exact decimal arithmetic without IEEE floating point rounding.
//! Numbers are stored as: sign * digits * 10^exp10

const std = @import("std");
const json = @import("json.zig");

const Number = json.Number;

/// Parse a number lexeme into normalized form
pub fn parseNumber(lexeme: []const u8, a: std.mem.Allocator) !Number {
    var sign: i8 = 1;
    var pos: usize = 0;

    // Handle sign
    if (lexeme.len > 0 and lexeme[0] == '-') {
        sign = -1;
        pos = 1;
    }

    // Parse integer part
    const int_start = pos;
    var int_end = pos;
    while (int_end < lexeme.len and lexeme[int_end] >= '0' and lexeme[int_end] <= '9') {
        int_end += 1;
    }

    // Parse fractional part
    var frac_digits: usize = 0;
    if (int_end < lexeme.len and lexeme[int_end] == '.') {
        pos = int_end + 1;
        while (pos < lexeme.len and lexeme[pos] >= '0' and lexeme[pos] <= '9') {
            pos += 1;
            frac_digits += 1;
        }
    } else {
        pos = int_end;
    }

    // Parse exponent
    var exp10: i32 = 0;
    if (pos < lexeme.len and (lexeme[pos] == 'e' or lexeme[pos] == 'E')) {
        pos += 1;
        var exp_sign: i32 = 1;
        if (pos < lexeme.len and lexeme[pos] == '+') {
            pos += 1;
        } else if (pos < lexeme.len and lexeme[pos] == '-') {
            exp_sign = -1;
            pos += 1;
        }

        var exp_val: i32 = 0;
        while (pos < lexeme.len and lexeme[pos] >= '0' and lexeme[pos] <= '9') {
            exp_val = exp_val * 10 + @as(i32, lexeme[pos] - '0');
            pos += 1;
        }
        exp10 = exp_sign * exp_val;
    }

    // Adjust exponent for fractional digits
    exp10 -= @intCast(frac_digits);

    // Build digit string (integer + fractional parts)
    var digits_buf: std.ArrayList(u8) = .empty;
    errdefer digits_buf.deinit(a);

    for (lexeme[int_start..int_end]) |c| {
        try digits_buf.append(a, c);
    }

    if (int_end < lexeme.len and lexeme[int_end] == '.') {
        for (lexeme[int_end + 1 ..][0..frac_digits]) |c| {
            try digits_buf.append(a, c);
        }
    }

    // Normalize: strip leading zeros (keep at least one digit)
    // Note: leading zeros don't affect the exponent
    while (digits_buf.items.len > 1 and digits_buf.items[0] == '0') {
        _ = digits_buf.orderedRemove(0);
    }

    // Normalize: strip trailing zeros
    while (digits_buf.items.len > 1 and digits_buf.items[digits_buf.items.len - 1] == '0') {
        _ = digits_buf.pop();
        exp10 += 1;
    }

    // Special case: zero
    if (digits_buf.items.len == 1 and digits_buf.items[0] == '0') {
        sign = 1;
        exp10 = 0;
    }

    return .{
        .lexeme = lexeme,
        .sign = sign,
        .digits = try digits_buf.toOwnedSlice(a),
        .exp10 = exp10,
    };
}

/// Check if a number represents an integer (no fractional part)
pub fn isInteger(n: Number) bool {
    if (n.exp10 >= 0) return true;

    const neg_exp: usize = @intCast(-n.exp10);
    if (neg_exp > n.digits.len) return false;

    // Check that trailing digits (fractional part) are all zeros
    return allZeros(n.digits[n.digits.len - neg_exp ..]);
}

fn allZeros(s: []const u8) bool {
    for (s) |c| {
        if (c != '0') return false;
    }
    return true;
}

/// Compare two numbers: returns -1 if a < b, 0 if a == b, 1 if a > b
pub fn compare(a: Number, b: Number) i32 {
    // Handle zeros
    const a_zero = a.digits.len == 1 and a.digits[0] == '0';
    const b_zero = b.digits.len == 1 and b.digits[0] == '0';

    if (a_zero and b_zero) return 0;
    if (a_zero) return if (b.sign == -1) 1 else -1;
    if (b_zero) return if (a.sign == -1) -1 else 1;

    // Different signs
    if (a.sign != b.sign) {
        return if (a.sign > b.sign) 1 else -1;
    }

    const sign_mult: i32 = a.sign;

    // Compare magnitudes (number of digits before decimal point)
    const a_mag: i64 = @as(i64, @intCast(a.digits.len)) + a.exp10;
    const b_mag: i64 = @as(i64, @intCast(b.digits.len)) + b.exp10;

    if (a_mag != b_mag) {
        return if (a_mag > b_mag) sign_mult else -sign_mult;
    }

    // Compare digit by digit
    const min_len = @min(a.digits.len, b.digits.len);
    for (a.digits[0..min_len], b.digits[0..min_len]) |ad, bd| {
        if (ad != bd) {
            return if (ad > bd) sign_mult else -sign_mult;
        }
    }

    // Longer number wins
    if (a.digits.len != b.digits.len) {
        return if (a.digits.len > b.digits.len) sign_mult else -sign_mult;
    }

    return 0;
}

/// Check if n is a multiple of div (n mod div == 0)
pub fn isMultipleOf(n: Number, div: Number) bool {
    // Division by zero
    if (div.digits.len == 1 and div.digits[0] == '0') return false;

    // Zero is multiple of everything
    if (n.digits.len == 1 and n.digits[0] == '0') return true;

    const n_exp = n.exp10;
    const d_exp = div.exp10;

    // If n has fewer fractional digits than div, it can't be a multiple
    if (n_exp < d_exp) return false;

    const exp_diff = n_exp - d_exp;

    // Scale n by the exponent difference
    var n_int: std.ArrayList(u8) = .empty;
    defer n_int.deinit(std.heap.page_allocator);
    n_int.appendSlice(std.heap.page_allocator, n.digits) catch return false;
    for (0..@intCast(exp_diff)) |_| {
        n_int.append(std.heap.page_allocator, '0') catch return false;
    }

    // Check if n_int is divisible by div.digits
    return bigIntMod(n_int.items, div.digits);
}

fn bigIntMod(dividend: []const u8, divisor: []const u8) bool {
    const div_val = stringToU64(divisor);
    if (div_val == 0) return false;

    var remainder: u64 = 0;
    for (dividend) |d| {
        remainder = (remainder * 10 + (d - '0')) % div_val;
    }
    return remainder == 0;
}

fn stringToU64(s: []const u8) u64 {
    var result: u64 = 0;
    for (s) |c| {
        result = result * 10 + (c - '0');
    }
    return result;
}

test "parse number - integer" {
    const n = try parseNumber("123", std.testing.allocator);
    defer std.testing.allocator.free(n.digits);
    try std.testing.expectEqual(@as(i8, 1), n.sign);
    try std.testing.expectEqualStrings("123", n.digits);
    try std.testing.expectEqual(@as(i32, 0), n.exp10);
}

test "parse number - negative" {
    const n = try parseNumber("-42", std.testing.allocator);
    defer std.testing.allocator.free(n.digits);
    try std.testing.expectEqual(@as(i8, -1), n.sign);
    try std.testing.expectEqualStrings("42", n.digits);
}

test "parse number - decimal" {
    const n = try parseNumber("3.14", std.testing.allocator);
    defer std.testing.allocator.free(n.digits);
    try std.testing.expectEqualStrings("314", n.digits);
    try std.testing.expectEqual(@as(i32, -2), n.exp10);
}

test "parse number - exponent" {
    const n = try parseNumber("1e10", std.testing.allocator);
    defer std.testing.allocator.free(n.digits);
    try std.testing.expectEqualStrings("1", n.digits);
    try std.testing.expectEqual(@as(i32, 10), n.exp10);
}

test "parse number - zero" {
    const n = try parseNumber("0", std.testing.allocator);
    defer std.testing.allocator.free(n.digits);
    try std.testing.expectEqual(@as(i8, 1), n.sign); // Normalized to positive
    try std.testing.expectEqualStrings("0", n.digits);
    try std.testing.expectEqual(@as(i32, 0), n.exp10);
}

test "isInteger" {
    const int_num = try parseNumber("42", std.testing.allocator);
    defer std.testing.allocator.free(int_num.digits);
    try std.testing.expect(isInteger(int_num));

    const float_num = try parseNumber("3.14", std.testing.allocator);
    defer std.testing.allocator.free(float_num.digits);
    try std.testing.expect(!isInteger(float_num));

    const whole_float = try parseNumber("3.0", std.testing.allocator);
    defer std.testing.allocator.free(whole_float.digits);
    try std.testing.expect(isInteger(whole_float));
}

test "compare numbers" {
    const a = try parseNumber("100", std.testing.allocator);
    defer std.testing.allocator.free(a.digits);
    const b = try parseNumber("99", std.testing.allocator);
    defer std.testing.allocator.free(b.digits);
    try std.testing.expect(compare(a, b) > 0);

    const c = try parseNumber("-5", std.testing.allocator);
    defer std.testing.allocator.free(c.digits);
    const d = try parseNumber("5", std.testing.allocator);
    defer std.testing.allocator.free(d.digits);
    try std.testing.expect(compare(c, d) < 0);
}

test "isMultipleOf" {
    const n = try parseNumber("10", std.testing.allocator);
    defer std.testing.allocator.free(n.digits);
    const div = try parseNumber("5", std.testing.allocator);
    defer std.testing.allocator.free(div.digits);
    try std.testing.expect(isMultipleOf(n, div));

    const n2 = try parseNumber("10", std.testing.allocator);
    defer std.testing.allocator.free(n2.digits);
    const div2 = try parseNumber("3", std.testing.allocator);
    defer std.testing.allocator.free(div2.digits);
    try std.testing.expect(!isMultipleOf(n2, div2));
}
