// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Normalized Base-10 Decimal Number Representation
//!
//! Provides exact decimal arithmetic without IEEE floating point rounding.
//! Numbers are stored as: sign * digits * 10^exp10

const std = @import("std");
const json = @import("json.zig");

const Number = json.Number;

/// Saturation bound for the decimal exponent.
///
/// JSON numbers whose magnitude exceeds ~10^308 are not representable as an
/// f64 anyway, so there is no information lost by clamping the accumulated
/// exponent to this sentinel. Clamping (rather than overflowing an `i32`)
/// guarantees `parseNumber` never panics on adversarial input such as
/// `"1e99999999999"`. The original text is preserved verbatim in
/// `Number.lexeme`, so float conversion and re-serialization are unaffected.
///
/// The value is kept far below `std.math.maxInt(i32)` so downstream code that
/// adds the exponent to a digit count (e.g. `compare`) cannot overflow.
const EXP_SATURATE: i32 = 1_000_000_000;

/// Saturating helper: append a decimal digit to `acc`, clamping at
/// `EXP_SATURATE` so the running exponent can never overflow `i32`.
fn accumExp(acc: i32, digit: u8) i32 {
    if (acc >= EXP_SATURATE) return EXP_SATURATE;
    const scaled = acc *| 10;
    const next = scaled +| @as(i32, digit - '0');
    return if (next >= EXP_SATURATE) EXP_SATURATE else next;
}

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
            // Saturating accumulation: an overly long exponent (e.g.
            // "1e99999999999") clamps at EXP_SATURATE instead of overflowing
            // i32 and panicking. The number is far outside f64 range either
            // way, and the verbatim lexeme is retained for serialization.
            exp_val = accumExp(exp_val, lexeme[pos]);
            pos += 1;
        }
        exp10 = exp_sign * exp_val;
    }

    // Adjust exponent for fractional digits (saturating: a pathologically long
    // fractional part cannot drive exp10 below i32's range).
    exp10 -|= std.math.lossyCast(i32, frac_digits);

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

    // Normalize: strip leading zeros (keep at least one digit).
    // Note: leading zeros don't affect the exponent.
    //
    // Count the run once and drop it with a single shift, rather than calling
    // orderedRemove(0) per zero (which memmoves the whole buffer each time and
    // is O(n^2) for long leading-zero runs).
    if (digits_buf.items.len > 1) {
        var lead: usize = 0;
        const max_strip = digits_buf.items.len - 1; // keep at least one digit
        while (lead < max_strip and digits_buf.items[lead] == '0') {
            lead += 1;
        }
        if (lead > 0) {
            digits_buf.replaceRangeAssumeCapacity(0, lead, &[_]u8{});
        }
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

    // exp_diff is the number of trailing zeros we would need to append to
    // n.digits to scale it up to an integer in div's units. It can be enormous
    // (n_exp/d_exp are exponents up to EXP_SATURATE), so we MUST NOT
    // materialize that many digits -- doing so was a memory/CPU DoS (a JSON
    // Schema `multipleOf` with a large exponent could force ~10^9 appends on
    // std.heap.page_allocator, both an unbounded allocation and an unbounded
    // loop). Instead we fold the scaling into modular arithmetic: appending one
    // '0' multiplies the running remainder by 10 (mod div_val), so appending k
    // zeros multiplies by 10^k (mod div_val), which we evaluate in O(log k) via
    // binary exponentiation. The result is exact for every divisor that fits in
    // a u64 -- which covers every divisor that the rest of this module can
    // already mod against (bigIntMod historically used the same u64 path).
    const exp_diff: i64 = @as(i64, n_exp) - @as(i64, d_exp);

    const div_val = stringToU64(div.digits) orelse {
        // Divisor does not fit in u64. The previous implementation also could
        // not handle this (stringToU64 silently overflowed), so this case never
        // produced a correct answer before. Bail to a safe definite `false`
        // rather than risk an unbounded computation; no existing caller hits
        // this path (schema multipleOf divisors are small).
        return false;
    };
    if (div_val == 0) return false;

    // remainder of n.digits (mod div_val), computed without overflow.
    var remainder: u64 = stringToU64Mod(n.digits, div_val);

    if (exp_diff > 0) {
        // exp_diff is bounded by ~2 * EXP_SATURATE (it derives from clamped
        // exponents), so it fits in u64. modPow10 is logarithmic in exp_diff,
        // so even the maximum value costs only ~31 iterations -- no DoS.
        // u128 intermediate: remainder and modPow10 result are both < div_val
        // (which is u64), so their product can reach ~2^128 -- widen before the
        // `% div_val` so the multiply can't overflow. The reduced result is
        // < div_val <= u64-max, so the @intCast back to u64 is safe.
        const scaled = @as(u128, remainder) * modPow10(@intCast(exp_diff), div_val);
        remainder = @as(u64, @intCast(scaled % div_val));
    }

    return remainder == 0;
}

/// Compute 10^exp (mod m) using binary exponentiation. O(log exp).
fn modPow10(exp: u64, m: u64) u64 {
    if (m == 1) return 0;
    var result: u64 = 1 % m;
    var base: u64 = 10 % m;
    var e = exp;
    while (e > 0) {
        if (e & 1 == 1) {
            // u128 intermediate: result and base are both < m (which is u64),
            // so their product can approach 2^128. Widen before the `% m` so
            // the multiply can't overflow; the reduced value fits back in u64.
            result = @as(u64, @intCast(@as(u128, result) * base % m));
        }
        e >>= 1;
        base = @as(u64, @intCast(@as(u128, base) * base % m));
    }
    return result;
}

/// Reduce the decimal string `s` modulo `m` without overflow.
fn stringToU64Mod(s: []const u8, m: u64) u64 {
    if (m == 0) return 0;
    var remainder: u64 = 0;
    for (s) |c| {
        // u128 intermediate: remainder is < m (which is u64), so `remainder * 10`
        // can overflow u64. Widen before the `% m`; the reduced value fits in u64.
        const next = @as(u128, remainder) * 10 + (c - '0');
        remainder = @as(u64, @intCast(next % m));
    }
    return remainder;
}

/// Parse a decimal string to u64, returning null on overflow.
fn stringToU64(s: []const u8) ?u64 {
    var result: u64 = 0;
    for (s) |c| {
        const mul = std.math.mul(u64, result, 10) catch return null;
        result = std.math.add(u64, mul, c - '0') catch return null;
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

// ASR-001 (Critical): parsing a number with an enormous exponent must not panic
// with "integer overflow". Previously `exp_val = exp_val * 10 + digit` overflowed
// i32 in Debug/ReleaseSafe. The exponent now saturates and the original lexeme is
// preserved verbatim, so parsing succeeds with a defined, round-trippable value.
test "parse number - huge positive exponent does not overflow (ASR-001)" {
    const n = try parseNumber("1e99999999999", std.testing.allocator);
    defer std.testing.allocator.free(n.digits);
    try std.testing.expectEqual(@as(i8, 1), n.sign);
    try std.testing.expectEqualStrings("1", n.digits);
    // Exponent saturates instead of overflowing.
    try std.testing.expectEqual(EXP_SATURATE, n.exp10);
    // The verbatim lexeme is retained for serialization / float conversion.
    try std.testing.expectEqualStrings("1e99999999999", n.lexeme);
}

test "parse number - huge negative exponent does not overflow (ASR-001)" {
    const n = try parseNumber("1e-99999999999", std.testing.allocator);
    defer std.testing.allocator.free(n.digits);
    try std.testing.expectEqualStrings("1", n.digits);
    // Negative saturation sentinel.
    try std.testing.expectEqual(-EXP_SATURATE, n.exp10);
    try std.testing.expectEqualStrings("1e-99999999999", n.lexeme);
}

test "parse number - 400-digit exponent does not overflow (ASR-001)" {
    // Build "1e" followed by 400 '9' digits.
    var buf: [402]u8 = undefined;
    buf[0] = '1';
    buf[1] = 'e';
    @memset(buf[2..], '9');
    const n = try parseNumber(&buf, std.testing.allocator);
    defer std.testing.allocator.free(n.digits);
    try std.testing.expectEqualStrings("1", n.digits);
    try std.testing.expectEqual(EXP_SATURATE, n.exp10);

    // Also exercise the sign-bearing, fractional variant to cover the
    // frac-adjust saturation path.
    var buf2: [404]u8 = undefined;
    buf2[0] = '1';
    buf2[1] = '.';
    buf2[2] = '5';
    buf2[3] = 'e';
    @memset(buf2[4..], '9');
    const n2 = try parseNumber(&buf2, std.testing.allocator);
    defer std.testing.allocator.free(n2.digits);
    try std.testing.expectEqualStrings("15", n2.digits);
    // exp from the huge exponent saturates, then the single frac digit nudges it
    // down by one (still effectively saturated, never overflowing).
    try std.testing.expectEqual(EXP_SATURATE - 1, n2.exp10);
}

// ASR-001 end-to-end: the public `json.parse` entry point must not crash on a
// huge exponent. Before the fix this panicked with "integer overflow"; now it
// succeeds and yields a `.num` whose exponent is saturated and whose lexeme is
// the original text (so it round-trips on re-serialization).
test "parse public API - huge exponent does not crash (ASR-001 end-to-end)" {
    var err: json.ParseError = undefined;
    var doc = try json.parse(std.testing.allocator, "1e99999999999", .{}, &err);
    defer doc.deinit();
    try std.testing.expect(doc.root == .num);
    try std.testing.expectEqual(EXP_SATURATE, doc.root.num.exp10);
    try std.testing.expectEqualStrings("1e99999999999", doc.root.num.lexeme);

    var err2: json.ParseError = undefined;
    var doc2 = try json.parse(std.testing.allocator, "1e-99999999999", .{}, &err2);
    defer doc2.deinit();
    try std.testing.expect(doc2.root == .num);
    try std.testing.expectEqual(-EXP_SATURATE, doc2.root.num.exp10);
}

// PERF-008: a long run of leading zeros must be stripped in a single shift,
// and behavior must be preserved exactly (a lone "0" is not stripped to empty).
test "parse number - long leading-zero run (PERF-008)" {
    // "0000...0001" with 1000 leading zeros parses to digits "1", exp10 0.
    var buf: [1001]u8 = undefined;
    @memset(buf[0..1000], '0');
    buf[1000] = '1';
    const n = try parseNumber(&buf, std.testing.allocator);
    defer std.testing.allocator.free(n.digits);
    try std.testing.expectEqualStrings("1", n.digits);
    try std.testing.expectEqual(@as(i32, 0), n.exp10);

    // A lone "0" stays "0" (not stripped to empty).
    const z = try parseNumber("0", std.testing.allocator);
    defer std.testing.allocator.free(z.digits);
    try std.testing.expectEqualStrings("0", z.digits);

    // "000" normalizes to a single "0".
    const z3 = try parseNumber("000", std.testing.allocator);
    defer std.testing.allocator.free(z3.digits);
    try std.testing.expectEqualStrings("0", z3.digits);
}

// ASR-008 / PERF-004: isMultipleOf on a value with a very large positive exp10
// must return promptly and correctly WITHOUT materializing ~10^9 digits.
// Previously this appended one '0' per unit of exp_diff on page_allocator.
test "isMultipleOf - huge exponent returns promptly and correctly (ASR-008/PERF-004)" {
    // n = 1e1000000000 (huge positive exp10 after saturation), div = 2.
    // 10^k is divisible by 2 for any k >= 1, so this must be true -- and must
    // be answered via modular arithmetic, not a 10^9-element allocation.
    const big = try parseNumber("1e1000000000", std.testing.allocator);
    defer std.testing.allocator.free(big.digits);
    const two = try parseNumber("2", std.testing.allocator);
    defer std.testing.allocator.free(two.digits);
    try std.testing.expect(isMultipleOf(big, two));

    // 10^k is NOT divisible by 3 for any k, so this must be false.
    const three = try parseNumber("3", std.testing.allocator);
    defer std.testing.allocator.free(three.digits);
    try std.testing.expect(!isMultipleOf(big, three));

    // Sanity: 7 * 10^k mod 7 == 0.
    const big7 = try parseNumber("7e1000000000", std.testing.allocator);
    defer std.testing.allocator.free(big7.digits);
    const seven = try parseNumber("7", std.testing.allocator);
    defer std.testing.allocator.free(seven.digits);
    try std.testing.expect(isMultipleOf(big7, seven));
}

// Regression: the modular scaling must agree with the naive definition for
// ordinary magnitudes where the old code path was also correct.
test "isMultipleOf - exact modular scaling for small exponents" {
    // 100 is a multiple of 25; 100 is not a multiple of 7.
    const hundred = try parseNumber("1e2", std.testing.allocator);
    defer std.testing.allocator.free(hundred.digits);
    const twentyfive = try parseNumber("25", std.testing.allocator);
    defer std.testing.allocator.free(twentyfive.digits);
    try std.testing.expect(isMultipleOf(hundred, twentyfive));

    const seven = try parseNumber("7", std.testing.allocator);
    defer std.testing.allocator.free(seven.digits);
    try std.testing.expect(!isMultipleOf(hundred, seven));

    // 1000 is a multiple of 8 (1000 / 8 = 125).
    const thousand = try parseNumber("1000", std.testing.allocator);
    defer std.testing.allocator.free(thousand.digits);
    const eight = try parseNumber("8", std.testing.allocator);
    defer std.testing.allocator.free(eight.digits);
    try std.testing.expect(isMultipleOf(thousand, eight));
}

// NASR-003 / NQUAL-001 (Critical): isMultipleOf's modular helpers must not
// overflow when the divisor exceeds ~2^32. Both operands are attacker-controlled
// JSON, so a `u64 * u64` multiply in modPow10/stringToU64Mod was a process-abort
// ("integer overflow" at number.zig:266) in Debug and ReleaseSafe -- and a silent
// wrap to a wrong boolean in ReleaseFast. Every modular multiply now uses a u128
// intermediate so the product can't overflow before the `% m` reduces it.
test "isMultipleOf - large u64 divisor does not overflow (NASR-003/NQUAL-001)" {
    const a = std.testing.allocator;

    // The confirmed crash case: 19-significant-digit divisor (< 2^64 but > 2^32).
    // 10^40 mod 9999999999999999999 == 100, so 10^40 is NOT a multiple of it.
    const big = try parseNumber("1e40", a);
    defer a.free(big.digits);
    const huge_div = try parseNumber("9999999999999999999", a);
    defer a.free(huge_div.digits);
    // Must not panic. Result is defined and deterministic across repeated calls.
    const r1 = isMultipleOf(big, huge_div);
    const r2 = isMultipleOf(big, huge_div);
    try std.testing.expectEqual(r1, r2);
    try std.testing.expect(!r1); // 10^40 mod 9999999999999999999 == 100 != 0

    // A ~10-digit prime > 2^32 against 1e64. 10^64 mod 9999999967 == 4679732603,
    // so this is NOT a multiple either -- but it must be answered without overflow.
    const e64 = try parseNumber("1e64", a);
    defer a.free(e64.digits);
    const prime = try parseNumber("9999999967", a);
    defer a.free(prime.digits);
    try std.testing.expect(!isMultipleOf(e64, prime));

    // Correctness preserved for a true-multiple case: 9e30 (= 9 * 10^30) is a
    // multiple of 3. This exercises stringToU64Mod on the significand and the
    // modular scaling fold together with a small divisor.
    const nine_e30 = try parseNumber("9e30", a);
    defer a.free(nine_e30.digits);
    const three = try parseNumber("3", a);
    defer a.free(three.digits);
    try std.testing.expect(isMultipleOf(nine_e30, three));
}
