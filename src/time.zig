// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Time and Duration Types for JSON
//!
//! Provides wrapper types for common time representations in JSON:
//! - Timestamp: RFC 3339 formatted strings
//! - UnixTimestamp: Unix seconds as numbers
//! - UnixTimestampMs: Unix milliseconds as numbers
//! - Duration: ISO 8601 duration strings
//!
//! All types implement custom jsonMarshal and jsonUnmarshal methods.

const std = @import("std");
const json = @import("json.zig");

const Value = json.Value;

/// RFC 3339 timestamp
/// Marshals to/from ISO 8601 / RFC 3339 strings like "2024-01-15T10:30:00Z"
pub const Timestamp = struct {
    /// Nanoseconds since Unix epoch (1970-01-01T00:00:00Z)
    nanos: i128,

    /// Create from Unix seconds
    pub fn fromUnix(seconds: i64) Timestamp {
        return .{ .nanos = @as(i128, seconds) * std.time.ns_per_s };
    }

    /// Create from Unix milliseconds
    pub fn fromUnixMs(ms: i64) Timestamp {
        return .{ .nanos = @as(i128, ms) * std.time.ns_per_ms };
    }

    /// Create from Unix nanoseconds
    pub fn fromUnixNs(nanos: i128) Timestamp {
        return .{ .nanos = nanos };
    }

    /// Get Unix seconds
    pub fn toUnix(self: Timestamp) i64 {
        return @intCast(@divFloor(self.nanos, std.time.ns_per_s));
    }

    /// Get Unix milliseconds
    pub fn toUnixMs(self: Timestamp) i64 {
        return @intCast(@divFloor(self.nanos, std.time.ns_per_ms));
    }

    /// Parse from RFC 3339 string
    pub fn fromRfc3339(s: []const u8) !Timestamp {
        // Minimal RFC 3339 parsing: YYYY-MM-DDTHH:MM:SSZ or with offset
        if (s.len < 20) return error.InvalidFormat;

        const year = std.fmt.parseInt(i32, s[0..4], 10) catch return error.InvalidFormat;
        if (s[4] != '-') return error.InvalidFormat;
        const month = std.fmt.parseInt(u8, s[5..7], 10) catch return error.InvalidFormat;
        if (s[7] != '-') return error.InvalidFormat;
        const day = std.fmt.parseInt(u8, s[8..10], 10) catch return error.InvalidFormat;
        if (s[10] != 'T' and s[10] != 't' and s[10] != ' ') return error.InvalidFormat;
        const hour = std.fmt.parseInt(u8, s[11..13], 10) catch return error.InvalidFormat;
        if (s[13] != ':') return error.InvalidFormat;
        const minute = std.fmt.parseInt(u8, s[14..16], 10) catch return error.InvalidFormat;
        if (s[16] != ':') return error.InvalidFormat;
        const second = std.fmt.parseInt(u8, s[17..19], 10) catch return error.InvalidFormat;

        // Validate ranges
        if (month < 1 or month > 12) return error.InvalidFormat;
        if (day < 1 or day > 31) return error.InvalidFormat;
        if (hour > 23) return error.InvalidFormat;
        if (minute > 59) return error.InvalidFormat;
        if (second > 60) return error.InvalidFormat; // Allow leap second

        // Calculate days since epoch
        const days = daysFromEpoch(year, month, day);
        const secs_of_day: i64 = @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
        var total_secs: i64 = days * 86400 + secs_of_day;

        // Handle fractional seconds
        var frac_nanos: i64 = 0;
        var pos: usize = 19;
        if (pos < s.len and s[pos] == '.') {
            pos += 1;
            var frac: i64 = 0;
            var frac_digits: u8 = 0;
            while (pos < s.len and s[pos] >= '0' and s[pos] <= '9') {
                if (frac_digits < 9) {
                    frac = frac * 10 + (s[pos] - '0');
                    frac_digits += 1;
                }
                pos += 1;
            }
            // Pad to nanoseconds
            while (frac_digits < 9) {
                frac *= 10;
                frac_digits += 1;
            }
            frac_nanos = frac;
        }

        // Handle timezone
        if (pos < s.len) {
            const tz_char = s[pos];
            if (tz_char == 'Z' or tz_char == 'z') {
                // UTC, no adjustment needed
            } else if (tz_char == '+' or tz_char == '-') {
                if (pos + 6 > s.len) return error.InvalidFormat;
                const tz_hour = std.fmt.parseInt(i32, s[pos + 1 .. pos + 3], 10) catch return error.InvalidFormat;
                if (s[pos + 3] != ':') return error.InvalidFormat;
                const tz_min = std.fmt.parseInt(i32, s[pos + 4 .. pos + 6], 10) catch return error.InvalidFormat;
                const offset_secs: i64 = (@as(i64, tz_hour) * 60 + @as(i64, tz_min)) * 60;
                if (tz_char == '+') {
                    total_secs -= offset_secs;
                } else {
                    total_secs += offset_secs;
                }
            }
        }

        return .{ .nanos = @as(i128, total_secs) * std.time.ns_per_s + frac_nanos };
    }

    /// Format as RFC 3339 string
    pub fn toRfc3339(self: Timestamp, allocator: std.mem.Allocator) ![]u8 {
        const secs = self.toUnix();
        const abs_ns: i128 = if (self.nanos < 0) -self.nanos else self.nanos;
        const nanos: u32 = @intCast(@mod(abs_ns, std.time.ns_per_s));

        // Convert to calendar date
        const days_since_epoch: i64 = @divFloor(secs, 86400);
        const secs_of_day: u32 = @intCast(@mod(secs, 86400));

        const date = daysToDate(days_since_epoch);
        const hour = secs_of_day / 3600;
        const minute = (secs_of_day % 3600) / 60;
        const second = secs_of_day % 60;

        if (nanos == 0) {
            // Cast year to unsigned for proper formatting (no sign prefix)
            const year_u: u32 = @intCast(date.year);
            return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
                year_u, date.month, date.day, hour, minute, second,
            });
        } else {
            // Include fractional seconds, trimming trailing zeros
            var frac = nanos;
            var digits: u8 = 9;
            while (digits > 1 and frac % 10 == 0) {
                frac /= 10;
                digits -= 1;
            }
            // Format with fixed precision based on remaining digits
            var buf: [32]u8 = undefined;
            const frac_str = std.fmt.bufPrint(&buf, "{d}", .{frac}) catch unreachable;
            // Pad with leading zeros if necessary
            var padded: [9]u8 = [_]u8{'0'} ** 9;
            const start = 9 - frac_str.len;
            @memcpy(padded[start..], frac_str);
            // Trim trailing zeros
            var end: usize = 9;
            while (end > 1 and padded[end - 1] == '0') {
                end -= 1;
            }
            const year_u: u32 = @intCast(date.year);
            return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{s}Z", .{
                year_u, date.month, date.day, hour, minute, second, padded[0..end],
            });
        }
    }

    /// Custom JSON marshaler - outputs RFC 3339 string
    pub fn jsonMarshal(self: Timestamp, allocator: std.mem.Allocator) !Value {
        const s = try self.toRfc3339(allocator);
        return .{ .str = s };
    }

    /// Custom JSON unmarshaler - parses RFC 3339 string or Unix timestamp
    pub fn jsonUnmarshal(allocator: std.mem.Allocator, value: Value) !Timestamp {
        _ = allocator;
        if (value == .str) {
            return Timestamp.fromRfc3339(value.str);
        } else if (value == .num) {
            // Support numeric Unix timestamps
            const secs = std.fmt.parseInt(i64, value.num.lexeme, 10) catch return error.InvalidFormat;
            return Timestamp.fromUnix(secs);
        }
        return error.TypeMismatch;
    }
};

/// Unix timestamp (seconds) wrapper
/// Marshals to/from numbers representing seconds since Unix epoch
pub const UnixTimestamp = struct {
    seconds: i64,

    /// Create from Timestamp
    pub fn fromTimestamp(ts: Timestamp) UnixTimestamp {
        return .{ .seconds = ts.toUnix() };
    }

    /// Convert to Timestamp
    pub fn toTimestamp(self: UnixTimestamp) Timestamp {
        return Timestamp.fromUnix(self.seconds);
    }

    /// Custom JSON marshaler - outputs number
    pub fn jsonMarshal(self: UnixTimestamp, allocator: std.mem.Allocator) !Value {
        var buf: [32]u8 = undefined;
        const lexeme = std.fmt.bufPrint(&buf, "{d}", .{self.seconds}) catch unreachable;
        const lexeme_copy = try allocator.dupe(u8, lexeme);
        return .{ .num = .{
            .lexeme = lexeme_copy,
            .sign = if (self.seconds < 0) -1 else 1,
            .digits = lexeme_copy,
            .exp10 = 0,
        } };
    }

    /// Custom JSON unmarshaler - parses number
    pub fn jsonUnmarshal(allocator: std.mem.Allocator, value: Value) !UnixTimestamp {
        _ = allocator;
        if (value != .num) return error.TypeMismatch;
        const secs = std.fmt.parseInt(i64, value.num.lexeme, 10) catch return error.InvalidFormat;
        return .{ .seconds = secs };
    }
};

/// Unix timestamp (milliseconds) wrapper
/// Marshals to/from numbers representing milliseconds since Unix epoch
pub const UnixTimestampMs = struct {
    milliseconds: i64,

    /// Create from Timestamp
    pub fn fromTimestamp(ts: Timestamp) UnixTimestampMs {
        return .{ .milliseconds = ts.toUnixMs() };
    }

    /// Convert to Timestamp
    pub fn toTimestamp(self: UnixTimestampMs) Timestamp {
        return Timestamp.fromUnixMs(self.milliseconds);
    }

    /// Custom JSON marshaler - outputs number
    pub fn jsonMarshal(self: UnixTimestampMs, allocator: std.mem.Allocator) !Value {
        var buf: [32]u8 = undefined;
        const lexeme = std.fmt.bufPrint(&buf, "{d}", .{self.milliseconds}) catch unreachable;
        const lexeme_copy = try allocator.dupe(u8, lexeme);
        return .{ .num = .{
            .lexeme = lexeme_copy,
            .sign = if (self.milliseconds < 0) -1 else 1,
            .digits = lexeme_copy,
            .exp10 = 0,
        } };
    }

    /// Custom JSON unmarshaler - parses number
    pub fn jsonUnmarshal(allocator: std.mem.Allocator, value: Value) !UnixTimestampMs {
        _ = allocator;
        if (value != .num) return error.TypeMismatch;
        const ms = std.fmt.parseInt(i64, value.num.lexeme, 10) catch return error.InvalidFormat;
        return .{ .milliseconds = ms };
    }
};

/// ISO 8601 duration
/// Marshals to/from strings like "PT2H30M" (2 hours 30 minutes)
pub const Duration = struct {
    /// Duration in nanoseconds
    nanos: i128,

    /// Create from nanoseconds
    pub fn fromNanos(nanos: i128) Duration {
        return .{ .nanos = nanos };
    }

    /// Create from seconds
    pub fn fromSeconds(seconds: i64) Duration {
        return .{ .nanos = @as(i128, seconds) * std.time.ns_per_s };
    }

    /// Create from milliseconds
    pub fn fromMs(ms: i64) Duration {
        return .{ .nanos = @as(i128, ms) * std.time.ns_per_ms };
    }

    /// Get total seconds
    pub fn toSeconds(self: Duration) i64 {
        return @intCast(@divFloor(self.nanos, std.time.ns_per_s));
    }

    /// Get total milliseconds
    pub fn toMs(self: Duration) i64 {
        return @intCast(@divFloor(self.nanos, std.time.ns_per_ms));
    }

    /// Parse from ISO 8601 duration string (e.g., "P1DT2H30M15S")
    pub fn fromIso8601(s: []const u8) !Duration {
        if (s.len == 0 or s[0] != 'P') return error.InvalidFormat;

        var total_nanos: i128 = 0;
        var pos: usize = 1;
        var in_time_part = false;

        while (pos < s.len) {
            if (s[pos] == 'T') {
                in_time_part = true;
                pos += 1;
                continue;
            }

            // Parse number
            const num_start = pos;
            var has_fraction = false;
            while (pos < s.len and ((s[pos] >= '0' and s[pos] <= '9') or s[pos] == '.')) {
                if (s[pos] == '.') has_fraction = true;
                pos += 1;
            }

            if (pos == num_start or pos >= s.len) return error.InvalidFormat;

            const designator = s[pos];
            pos += 1;

            const value: f64 = std.fmt.parseFloat(f64, s[num_start .. pos - 1]) catch return error.InvalidFormat;

            const multiplier: i128 = switch (designator) {
                'Y' => 365 * 24 * 60 * 60 * std.time.ns_per_s, // Approximate year
                'M' => if (in_time_part) 60 * std.time.ns_per_s else 30 * 24 * 60 * 60 * std.time.ns_per_s, // Minutes or months
                'W' => 7 * 24 * 60 * 60 * std.time.ns_per_s,
                'D' => 24 * 60 * 60 * std.time.ns_per_s,
                'H' => 60 * 60 * std.time.ns_per_s,
                'S' => std.time.ns_per_s,
                else => return error.InvalidFormat,
            };

            total_nanos += @intFromFloat(@as(f64, @floatFromInt(multiplier)) * value);
        }

        return .{ .nanos = total_nanos };
    }

    /// Format as ISO 8601 duration string
    pub fn toIso8601(self: Duration, allocator: std.mem.Allocator) ![]u8 {
        const abs_nanos = if (self.nanos < 0) -self.nanos else self.nanos;
        const neg = self.nanos < 0;

        const total_secs: u64 = @intCast(@divFloor(abs_nanos, std.time.ns_per_s));
        const rem_nanos: u32 = @intCast(@mod(abs_nanos, std.time.ns_per_s));

        const days = total_secs / 86400;
        const hours = (total_secs % 86400) / 3600;
        const minutes = (total_secs % 3600) / 60;
        const seconds = total_secs % 60;

        var buf: [64]u8 = undefined;
        var len: usize = 0;

        if (neg) {
            buf[len] = '-';
            len += 1;
        }
        buf[len] = 'P';
        len += 1;

        if (days > 0) {
            const written = std.fmt.bufPrint(buf[len..], "{d}D", .{days}) catch unreachable;
            len += written.len;
        }

        if (hours > 0 or minutes > 0 or seconds > 0 or rem_nanos > 0) {
            buf[len] = 'T';
            len += 1;

            if (hours > 0) {
                const written = std.fmt.bufPrint(buf[len..], "{d}H", .{hours}) catch unreachable;
                len += written.len;
            }
            if (minutes > 0) {
                const written = std.fmt.bufPrint(buf[len..], "{d}M", .{minutes}) catch unreachable;
                len += written.len;
            }
            if (seconds > 0 or rem_nanos > 0) {
                if (rem_nanos > 0) {
                    const written = std.fmt.bufPrint(buf[len..], "{d}.{d:0>9}S", .{ seconds, rem_nanos }) catch unreachable;
                    // Trim trailing zeros
                    var end = len + written.len - 1;
                    while (end > len and buf[end - 1] == '0') {
                        end -= 1;
                    }
                    buf[end] = 'S';
                    len = end + 1;
                } else {
                    const written = std.fmt.bufPrint(buf[len..], "{d}S", .{seconds}) catch unreachable;
                    len += written.len;
                }
            }
        }

        if (len == 1 or (len == 2 and neg)) {
            // Empty duration - output PT0S
            buf[len] = 'T';
            buf[len + 1] = '0';
            buf[len + 2] = 'S';
            len += 3;
        }

        return allocator.dupe(u8, buf[0..len]);
    }

    /// Custom JSON marshaler - outputs ISO 8601 string
    pub fn jsonMarshal(self: Duration, allocator: std.mem.Allocator) !Value {
        const s = try self.toIso8601(allocator);
        return .{ .str = s };
    }

    /// Custom JSON unmarshaler - parses ISO 8601 string or number (seconds)
    pub fn jsonUnmarshal(allocator: std.mem.Allocator, value: Value) !Duration {
        _ = allocator;
        if (value == .str) {
            return Duration.fromIso8601(value.str);
        } else if (value == .num) {
            // Support numeric seconds
            const secs = std.fmt.parseInt(i64, value.num.lexeme, 10) catch return error.InvalidFormat;
            return Duration.fromSeconds(secs);
        }
        return error.TypeMismatch;
    }
};

// ============================================================================
// Date calculation helpers
// ============================================================================

const DateComponents = struct {
    year: i32,
    month: u8,
    day: u8,
};

fn isLeapYear(year: i32) bool {
    const y = if (year >= 0) @as(u32, @intCast(year)) else @as(u32, @intCast(-year));
    return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0;
}

fn daysInMonth(year: i32, month: u8) u8 {
    const days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month == 2 and isLeapYear(year)) return 29;
    return days[month - 1];
}

fn daysFromEpoch(year: i32, month: u8, day: u8) i64 {
    // Calculate days from 1970-01-01 using a simple counting approach
    var total_days: i64 = 0;

    // Add days for years since 1970
    if (year >= 1970) {
        var y: i32 = 1970;
        while (y < year) : (y += 1) {
            total_days += if (isLeapYear(y)) 366 else 365;
        }
    } else {
        var y: i32 = 1969;
        while (y >= year) : (y -= 1) {
            total_days -= if (isLeapYear(y)) 366 else 365;
        }
    }

    // Add days for months in current year
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        total_days += daysInMonth(year, m);
    }

    // Add days
    total_days += day - 1;

    return total_days;
}

fn daysToDate(days_since_epoch: i64) DateComponents {
    var remaining_days = days_since_epoch;
    var year: i32 = 1970;

    // Find the year
    if (remaining_days >= 0) {
        while (true) {
            const days_in_year: i64 = if (isLeapYear(year)) 366 else 365;
            if (remaining_days < days_in_year) break;
            remaining_days -= days_in_year;
            year += 1;
        }
    } else {
        while (remaining_days < 0) {
            year -= 1;
            remaining_days += if (isLeapYear(year)) 366 else 365;
        }
    }

    // Find the month
    var month: u8 = 1;
    while (month <= 12) {
        const days_in_month: i64 = daysInMonth(year, month);
        if (remaining_days < days_in_month) break;
        remaining_days -= days_in_month;
        month += 1;
    }

    return .{
        .year = year,
        .month = month,
        .day = @intCast(remaining_days + 1),
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Timestamp from/to Unix" {
    const ts = Timestamp.fromUnix(1705318200);
    try std.testing.expectEqual(@as(i64, 1705318200), ts.toUnix());
}

test "Timestamp from/to UnixMs" {
    const ts = Timestamp.fromUnixMs(1705318200123);
    try std.testing.expectEqual(@as(i64, 1705318200123), ts.toUnixMs());
}

test "Timestamp parse RFC 3339" {
    const ts = try Timestamp.fromRfc3339("2024-01-15T10:30:00Z");
    // 19737 days * 86400 + 10*3600 + 30*60 = 1705314600
    try std.testing.expectEqual(@as(i64, 1705314600), ts.toUnix());
}

test "Timestamp parse RFC 3339 with offset" {
    const ts = try Timestamp.fromRfc3339("2024-01-15T10:30:00+01:00");
    // Should be 1 hour earlier in UTC: 1705314600 - 3600 = 1705311000
    try std.testing.expectEqual(@as(i64, 1705311000), ts.toUnix());
}

test "Timestamp format RFC 3339" {
    const ts = Timestamp.fromUnix(1705314600);
    const s = try ts.toRfc3339(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("2024-01-15T10:30:00Z", s);
}

test "Duration parse ISO 8601" {
    const d1 = try Duration.fromIso8601("PT2H30M");
    try std.testing.expectEqual(@as(i64, 2 * 3600 + 30 * 60), d1.toSeconds());

    const d2 = try Duration.fromIso8601("P1D");
    try std.testing.expectEqual(@as(i64, 86400), d2.toSeconds());

    const d3 = try Duration.fromIso8601("PT15S");
    try std.testing.expectEqual(@as(i64, 15), d3.toSeconds());
}

test "Duration format ISO 8601" {
    const d = Duration.fromSeconds(2 * 3600 + 30 * 60 + 15);
    const s = try d.toIso8601(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("PT2H30M15S", s);
}

test "UnixTimestamp marshal" {
    const ts = UnixTimestamp{ .seconds = 1705318200 };
    const v = try ts.jsonMarshal(std.testing.allocator);
    defer std.testing.allocator.free(v.num.lexeme);
    try std.testing.expectEqualStrings("1705318200", v.num.lexeme);
}

// ============================================================================
// Custom Format Timestamps
// ============================================================================

/// Format specifiers for custom timestamp formatting
/// Supports strftime-like format codes:
/// - %Y: 4-digit year (e.g., 2024)
/// - %y: 2-digit year (e.g., 24)
/// - %m: 2-digit month (01-12)
/// - %d: 2-digit day (01-31)
/// - %H: 2-digit hour 24h (00-23)
/// - %I: 2-digit hour 12h (01-12)
/// - %M: 2-digit minute (00-59)
/// - %S: 2-digit second (00-59)
/// - %f: 6-digit microseconds (000000-999999)
/// - %p: AM/PM
/// - %z: Timezone offset (+0000)
/// - %Z: Timezone name (UTC)
/// - %%: Literal percent
pub const TimeFormat = struct {
    pattern: []const u8,

    pub const rfc3339 = TimeFormat{ .pattern = "%Y-%m-%dT%H:%M:%SZ" };
    pub const rfc3339_ms = TimeFormat{ .pattern = "%Y-%m-%dT%H:%M:%S.%fZ" };
    pub const iso8601_date = TimeFormat{ .pattern = "%Y-%m-%d" };
    pub const iso8601_time = TimeFormat{ .pattern = "%H:%M:%S" };
    pub const us_date = TimeFormat{ .pattern = "%m/%d/%Y" };
    pub const eu_date = TimeFormat{ .pattern = "%d/%m/%Y" };
    pub const us_datetime = TimeFormat{ .pattern = "%m/%d/%Y %I:%M:%S %p" };
    pub const sql_datetime = TimeFormat{ .pattern = "%Y-%m-%d %H:%M:%S" };
};

/// Custom formatted timestamp
/// Wraps a Timestamp with a custom format pattern for JSON serialization
pub fn FormattedTimestamp(comptime fmt: TimeFormat) type {
    return struct {
        const Self = @This();

        /// The underlying timestamp
        timestamp: Timestamp,

        /// Create from a Timestamp
        pub fn fromTimestamp(ts: Timestamp) Self {
            return .{ .timestamp = ts };
        }

        /// Create from Unix seconds
        pub fn fromUnix(seconds: i64) Self {
            return .{ .timestamp = Timestamp.fromUnix(seconds) };
        }

        /// Create from Unix milliseconds
        pub fn fromUnixMs(ms: i64) Self {
            return .{ .timestamp = Timestamp.fromUnixMs(ms) };
        }

        /// Get Unix seconds
        pub fn toUnix(self: Self) i64 {
            return self.timestamp.toUnix();
        }

        /// Get Unix milliseconds
        pub fn toUnixMs(self: Self) i64 {
            return self.timestamp.toUnixMs();
        }

        /// Format to string using the pattern
        pub fn format(self: Self, allocator: std.mem.Allocator) ![]u8 {
            return formatTimestamp(self.timestamp, fmt.pattern, allocator);
        }

        /// Parse from string using the pattern
        pub fn parse(s: []const u8) !Self {
            const ts = try parseTimestamp(s, fmt.pattern);
            return .{ .timestamp = ts };
        }

        /// Custom JSON marshaler
        pub fn jsonMarshal(self: Self, allocator: std.mem.Allocator) !Value {
            const s = try self.format(allocator);
            return .{ .str = s };
        }

        /// Custom JSON unmarshaler
        pub fn jsonUnmarshal(allocator: std.mem.Allocator, value: Value) !Self {
            _ = allocator;
            if (value != .str) return error.TypeMismatch;
            return Self.parse(value.str);
        }
    };
}

/// Format a timestamp using a format pattern
pub fn formatTimestamp(ts: Timestamp, pattern: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const secs = ts.toUnix();
    const abs_ns: i128 = if (ts.nanos < 0) -ts.nanos else ts.nanos;
    const micros: u32 = @intCast(@mod(@divFloor(abs_ns, std.time.ns_per_us), 1_000_000));

    // Convert to calendar date
    const days_since_epoch: i64 = @divFloor(secs, 86400);
    const secs_of_day: u32 = @intCast(@mod(secs, 86400));

    const date = daysToDate(days_since_epoch);
    const hour24 = secs_of_day / 3600;
    const minute = (secs_of_day % 3600) / 60;
    const second = secs_of_day % 60;
    const hour12 = if (hour24 == 0) 12 else if (hour24 > 12) hour24 - 12 else hour24;
    const am_pm: []const u8 = if (hour24 < 12) "AM" else "PM";

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < pattern.len) {
        if (pattern[i] == '%' and i + 1 < pattern.len) {
            const spec = pattern[i + 1];
            switch (spec) {
                'Y' => {
                    // 4-digit year
                    var buf: [5]u8 = undefined;
                    const year_u: u32 = @intCast(if (date.year < 0) -date.year else date.year);
                    const s = std.fmt.bufPrint(&buf, "{d:0>4}", .{year_u}) catch unreachable;
                    try result.appendSlice(allocator, s);
                },
                'y' => {
                    // 2-digit year
                    var buf: [3]u8 = undefined;
                    const year_u: u32 = @intCast(@mod(if (date.year < 0) -date.year else date.year, 100));
                    const s = std.fmt.bufPrint(&buf, "{d:0>2}", .{year_u}) catch unreachable;
                    try result.appendSlice(allocator, s);
                },
                'm' => {
                    // 2-digit month
                    var buf: [3]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{d:0>2}", .{date.month}) catch unreachable;
                    try result.appendSlice(allocator, s);
                },
                'd' => {
                    // 2-digit day
                    var buf: [3]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{d:0>2}", .{date.day}) catch unreachable;
                    try result.appendSlice(allocator, s);
                },
                'H' => {
                    // 2-digit hour 24h
                    var buf: [3]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{d:0>2}", .{hour24}) catch unreachable;
                    try result.appendSlice(allocator, s);
                },
                'I' => {
                    // 2-digit hour 12h
                    var buf: [3]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{d:0>2}", .{hour12}) catch unreachable;
                    try result.appendSlice(allocator, s);
                },
                'M' => {
                    // 2-digit minute
                    var buf: [3]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{d:0>2}", .{minute}) catch unreachable;
                    try result.appendSlice(allocator, s);
                },
                'S' => {
                    // 2-digit second
                    var buf: [3]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{d:0>2}", .{second}) catch unreachable;
                    try result.appendSlice(allocator, s);
                },
                'f' => {
                    // 6-digit microseconds
                    var buf: [7]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{d:0>6}", .{micros}) catch unreachable;
                    try result.appendSlice(allocator, s);
                },
                'p' => {
                    // AM/PM
                    try result.appendSlice(allocator, am_pm);
                },
                'z' => {
                    // Timezone offset (always UTC)
                    try result.appendSlice(allocator, "+0000");
                },
                'Z' => {
                    // Timezone name
                    try result.appendSlice(allocator, "UTC");
                },
                '%' => {
                    // Literal percent
                    try result.append(allocator, '%');
                },
                else => {
                    // Unknown specifier, output as-is
                    try result.append(allocator, '%');
                    try result.append(allocator, spec);
                },
            }
            i += 2;
        } else {
            try result.append(allocator, pattern[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Parse a timestamp from a string using a format pattern
pub fn parseTimestamp(s: []const u8, pattern: []const u8) !Timestamp {
    var year: i32 = 1970;
    var month: u8 = 1;
    var day: u8 = 1;
    var hour: u8 = 0;
    var minute: u8 = 0;
    var second: u8 = 0;
    var micros: u32 = 0;
    var is_pm = false;
    var is_12h = false;
    var tz_offset_secs: i64 = 0;

    var si: usize = 0; // string index
    var pi: usize = 0; // pattern index

    while (pi < pattern.len and si < s.len) {
        if (pattern[pi] == '%' and pi + 1 < pattern.len) {
            const spec = pattern[pi + 1];
            switch (spec) {
                'Y' => {
                    // 4-digit year
                    if (si + 4 > s.len) return error.InvalidFormat;
                    year = std.fmt.parseInt(i32, s[si .. si + 4], 10) catch return error.InvalidFormat;
                    si += 4;
                },
                'y' => {
                    // 2-digit year (assume 2000s)
                    if (si + 2 > s.len) return error.InvalidFormat;
                    const y2 = std.fmt.parseInt(i32, s[si .. si + 2], 10) catch return error.InvalidFormat;
                    year = if (y2 >= 70) 1900 + y2 else 2000 + y2;
                    si += 2;
                },
                'm' => {
                    // 2-digit month
                    if (si + 2 > s.len) return error.InvalidFormat;
                    month = std.fmt.parseInt(u8, s[si .. si + 2], 10) catch return error.InvalidFormat;
                    if (month < 1 or month > 12) return error.InvalidFormat;
                    si += 2;
                },
                'd' => {
                    // 2-digit day
                    if (si + 2 > s.len) return error.InvalidFormat;
                    day = std.fmt.parseInt(u8, s[si .. si + 2], 10) catch return error.InvalidFormat;
                    if (day < 1 or day > 31) return error.InvalidFormat;
                    si += 2;
                },
                'H' => {
                    // 2-digit hour 24h
                    if (si + 2 > s.len) return error.InvalidFormat;
                    hour = std.fmt.parseInt(u8, s[si .. si + 2], 10) catch return error.InvalidFormat;
                    if (hour > 23) return error.InvalidFormat;
                    si += 2;
                },
                'I' => {
                    // 2-digit hour 12h
                    if (si + 2 > s.len) return error.InvalidFormat;
                    hour = std.fmt.parseInt(u8, s[si .. si + 2], 10) catch return error.InvalidFormat;
                    if (hour < 1 or hour > 12) return error.InvalidFormat;
                    is_12h = true;
                    si += 2;
                },
                'M' => {
                    // 2-digit minute
                    if (si + 2 > s.len) return error.InvalidFormat;
                    minute = std.fmt.parseInt(u8, s[si .. si + 2], 10) catch return error.InvalidFormat;
                    if (minute > 59) return error.InvalidFormat;
                    si += 2;
                },
                'S' => {
                    // 2-digit second
                    if (si + 2 > s.len) return error.InvalidFormat;
                    second = std.fmt.parseInt(u8, s[si .. si + 2], 10) catch return error.InvalidFormat;
                    if (second > 60) return error.InvalidFormat; // Allow leap second
                    si += 2;
                },
                'f' => {
                    // 6-digit microseconds
                    if (si + 6 > s.len) return error.InvalidFormat;
                    micros = std.fmt.parseInt(u32, s[si .. si + 6], 10) catch return error.InvalidFormat;
                    si += 6;
                },
                'p' => {
                    // AM/PM
                    if (si + 2 > s.len) return error.InvalidFormat;
                    const ap = s[si .. si + 2];
                    if (std.mem.eql(u8, ap, "PM") or std.mem.eql(u8, ap, "pm")) {
                        is_pm = true;
                    } else if (std.mem.eql(u8, ap, "AM") or std.mem.eql(u8, ap, "am")) {
                        is_pm = false;
                    } else {
                        return error.InvalidFormat;
                    }
                    si += 2;
                },
                'z' => {
                    // Timezone offset (+0000 or +00:00)
                    if (si >= s.len) return error.InvalidFormat;
                    if (s[si] == 'Z' or s[si] == 'z') {
                        si += 1;
                    } else if (s[si] == '+' or s[si] == '-') {
                        const sign: i64 = if (s[si] == '-') -1 else 1;
                        si += 1;
                        if (si + 2 > s.len) return error.InvalidFormat;
                        const tz_hour = std.fmt.parseInt(i32, s[si .. si + 2], 10) catch return error.InvalidFormat;
                        si += 2;
                        // Skip optional colon
                        if (si < s.len and s[si] == ':') si += 1;
                        var tz_min: i32 = 0;
                        if (si + 2 <= s.len) {
                            tz_min = std.fmt.parseInt(i32, s[si .. si + 2], 10) catch 0;
                            if (tz_min != 0) si += 2;
                        }
                        tz_offset_secs = sign * (@as(i64, tz_hour) * 3600 + @as(i64, tz_min) * 60);
                    }
                },
                'Z' => {
                    // Timezone name - just skip "UTC" for now
                    if (si + 3 <= s.len and std.mem.eql(u8, s[si .. si + 3], "UTC")) {
                        si += 3;
                    }
                },
                '%' => {
                    // Literal percent
                    if (s[si] != '%') return error.InvalidFormat;
                    si += 1;
                },
                else => {
                    // Unknown specifier, skip 2 chars in pattern
                },
            }
            pi += 2;
        } else {
            // Literal character must match
            if (s[si] != pattern[pi]) return error.InvalidFormat;
            si += 1;
            pi += 1;
        }
    }

    // Convert 12h to 24h if needed
    if (is_12h) {
        if (is_pm and hour < 12) {
            hour += 12;
        } else if (!is_pm and hour == 12) {
            hour = 0;
        }
    }

    // Calculate timestamp
    const days = daysFromEpoch(year, month, day);
    const secs_of_day: i64 = @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
    const total_secs: i64 = days * 86400 + secs_of_day - tz_offset_secs;
    const nanos: i128 = @as(i128, total_secs) * std.time.ns_per_s + @as(i128, micros) * std.time.ns_per_us;

    return .{ .nanos = nanos };
}

// ============================================================================
// FormattedTimestamp Tests
// ============================================================================

test "formatTimestamp basic" {
    const allocator = std.testing.allocator;
    const ts = Timestamp.fromUnix(1705314600); // 2024-01-15T10:30:00Z

    const s1 = try formatTimestamp(ts, "%Y-%m-%d", allocator);
    defer allocator.free(s1);
    try std.testing.expectEqualStrings("2024-01-15", s1);

    const s2 = try formatTimestamp(ts, "%H:%M:%S", allocator);
    defer allocator.free(s2);
    try std.testing.expectEqualStrings("10:30:00", s2);

    const s3 = try formatTimestamp(ts, "%Y/%m/%d %H:%M", allocator);
    defer allocator.free(s3);
    try std.testing.expectEqualStrings("2024/01/15 10:30", s3);
}

test "formatTimestamp 12h clock" {
    const allocator = std.testing.allocator;
    const ts = Timestamp.fromUnix(1705314600); // 2024-01-15T10:30:00Z (10 AM)

    const s = try formatTimestamp(ts, "%I:%M %p", allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("10:30 AM", s);

    const ts_pm = Timestamp.fromUnix(1705314600 + 12 * 3600); // 10 PM
    const s_pm = try formatTimestamp(ts_pm, "%I:%M %p", allocator);
    defer allocator.free(s_pm);
    try std.testing.expectEqualStrings("10:30 PM", s_pm);
}

test "formatTimestamp microseconds" {
    const allocator = std.testing.allocator;
    const ts = Timestamp.fromUnixMs(1705314600123); // with .123 seconds

    const s = try formatTimestamp(ts, "%Y-%m-%d %H:%M:%S.%f", allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("2024-01-15 10:30:00.123000", s);
}

test "parseTimestamp basic" {
    const ts1 = try parseTimestamp("2024-01-15", "%Y-%m-%d");
    try std.testing.expectEqual(@as(i64, 1705276800), ts1.toUnix()); // Midnight 2024-01-15

    const ts2 = try parseTimestamp("2024-01-15 10:30:00", "%Y-%m-%d %H:%M:%S");
    try std.testing.expectEqual(@as(i64, 1705314600), ts2.toUnix());
}

test "parseTimestamp 12h clock" {
    const ts1 = try parseTimestamp("01/15/2024 10:30:00 AM", "%m/%d/%Y %I:%M:%S %p");
    try std.testing.expectEqual(@as(i64, 1705314600), ts1.toUnix());

    const ts2 = try parseTimestamp("01/15/2024 10:30:00 PM", "%m/%d/%Y %I:%M:%S %p");
    try std.testing.expectEqual(@as(i64, 1705314600 + 12 * 3600), ts2.toUnix());
}

test "parseTimestamp with timezone" {
    const ts1 = try parseTimestamp("2024-01-15T10:30:00Z", "%Y-%m-%dT%H:%M:%S%z");
    try std.testing.expectEqual(@as(i64, 1705314600), ts1.toUnix());

    const ts2 = try parseTimestamp("2024-01-15T11:30:00+01:00", "%Y-%m-%dT%H:%M:%S%z");
    try std.testing.expectEqual(@as(i64, 1705314600), ts2.toUnix()); // Same UTC time
}

test "FormattedTimestamp type" {
    const allocator = std.testing.allocator;
    const SqlTimestamp = FormattedTimestamp(TimeFormat.sql_datetime);

    const ts = SqlTimestamp.fromUnix(1705314600);
    const s = try ts.format(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("2024-01-15 10:30:00", s);

    const parsed = try SqlTimestamp.parse("2024-01-15 10:30:00");
    try std.testing.expectEqual(@as(i64, 1705314600), parsed.toUnix());
}

test "FormattedTimestamp US date" {
    const allocator = std.testing.allocator;
    const UsDate = FormattedTimestamp(TimeFormat.us_date);

    const ts = UsDate.fromUnix(1705276800); // 2024-01-15 midnight
    const s = try ts.format(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("01/15/2024", s);

    const parsed = try UsDate.parse("01/15/2024");
    try std.testing.expectEqual(@as(i64, 1705276800), parsed.toUnix());
}

test "FormattedTimestamp EU date" {
    const allocator = std.testing.allocator;
    const EuDate = FormattedTimestamp(TimeFormat.eu_date);

    const ts = EuDate.fromUnix(1705276800); // 2024-01-15 midnight
    const s = try ts.format(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("15/01/2024", s);

    const parsed = try EuDate.parse("15/01/2024");
    try std.testing.expectEqual(@as(i64, 1705276800), parsed.toUnix());
}

test "FormattedTimestamp JSON marshal/unmarshal" {
    const allocator = std.testing.allocator;
    const SqlTimestamp = FormattedTimestamp(TimeFormat.sql_datetime);

    const ts = SqlTimestamp.fromUnix(1705314600);
    const v = try ts.jsonMarshal(allocator);
    defer allocator.free(v.str);
    try std.testing.expectEqualStrings("2024-01-15 10:30:00", v.str);

    const parsed = try SqlTimestamp.jsonUnmarshal(allocator, v);
    try std.testing.expectEqual(@as(i64, 1705314600), parsed.toUnix());
}
