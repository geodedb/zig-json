// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! SIMD-optimized JSON parsing utilities
//!
//! Provides vectorized operations for common JSON parsing tasks:
//! - Whitespace scanning
//! - Structural character detection
//! - String boundary detection
//! - Escape sequence detection
//!
//! Uses Zig's @Vector types for portable SIMD across architectures.
//! Falls back to scalar operations on unsupported platforms.

const std = @import("std");
const builtin = @import("builtin");

/// Vector width for SIMD operations (16 bytes for SSE/NEON, 32 for AVX2)
pub const VECTOR_SIZE = 16;
pub const SimdVec = @Vector(VECTOR_SIZE, u8);

// =============================================================================
// SIMD Feature Detection
// =============================================================================

/// Detected SIMD capabilities
pub const SIMDFeatures = struct {
    /// Basic SIMD available (SSE2/NEON)
    has_simd: bool,
    /// SSE4.2 support (x86 only)
    has_sse42: bool,
    /// AVX2 support (256-bit vectors, x86 only)
    has_avx2: bool,
    /// AVX-512F support (512-bit vectors, x86 only)
    has_avx512f: bool,
    /// NEON support (ARM)
    has_neon: bool,
    /// Recommended vector width in bytes
    recommended_width: u8,

    /// Human-readable description of detected features
    pub fn describe(self: SIMDFeatures) []const u8 {
        if (self.has_avx512f) return "AVX-512 (512-bit)";
        if (self.has_avx2) return "AVX2 (256-bit)";
        if (self.has_sse42) return "SSE4.2 (128-bit)";
        if (self.has_neon) return "NEON (128-bit)";
        if (self.has_simd) return "SSE2 (128-bit)";
        return "scalar (no SIMD)";
    }
};

/// Detect SIMD features at runtime
/// Uses CPUID on x86 architectures, compile-time detection on ARM
pub fn detectFeatures() SIMDFeatures {
    var features = SIMDFeatures{
        .has_simd = false,
        .has_sse42 = false,
        .has_avx2 = false,
        .has_avx512f = false,
        .has_neon = false,
        .recommended_width = 1, // scalar fallback
    };

    if (builtin.cpu.arch.isX86()) {
        // x86/x86_64: Use CPUID for runtime detection
        features = detectX86Features();
    } else if (builtin.cpu.arch.isAARCH64()) {
        // AArch64: NEON/AdvSIMD is mandatory for all AArch64 processors
        features.has_neon = true;
        features.has_simd = true;
        features.recommended_width = 16;
    } else if (builtin.cpu.arch.isARM()) {
        // ARM32: NEON is optional, would need runtime detection with OS support
        // For now, conservatively assume no SIMD on ARM32
        features.has_neon = false;
        features.has_simd = false;
        features.recommended_width = 1;
    }

    return features;
}

/// Detect x86 SIMD features using CPUID
fn detectX86Features() SIMDFeatures {
    var features = SIMDFeatures{
        .has_simd = false,
        .has_sse42 = false,
        .has_avx2 = false,
        .has_avx512f = false,
        .has_neon = false,
        .recommended_width = 1,
    };

    // CPUID leaf 1: Basic features (SSE2, SSE4.2)
    const leaf1 = cpuid(1, 0);
    const ecx1 = leaf1[2]; // ECX from CPUID(1)
    const edx1 = leaf1[3]; // EDX from CPUID(1)

    // SSE2 is in EDX bit 26
    const sse2_bit: u32 = 1 << 26;
    features.has_simd = (edx1 & sse2_bit) != 0;

    // SSE4.2 is in ECX bit 20
    const sse42_bit: u32 = 1 << 20;
    features.has_sse42 = (ecx1 & sse42_bit) != 0;

    // Check for AVX support (requires OS support via XSAVE)
    // OSXSAVE bit in ECX (bit 27) indicates OS has enabled XSAVE
    const osxsave_bit: u32 = 1 << 27;
    const avx_bit: u32 = 1 << 28;
    const has_osxsave = (ecx1 & osxsave_bit) != 0;
    const has_avx = (ecx1 & avx_bit) != 0;

    if (has_osxsave and has_avx) {
        // Check XCR0 to verify OS has enabled AVX state saving
        const xcr0 = xgetbv(0);
        const xcr0_avx_enabled = (xcr0 & 0x6) == 0x6; // XMM and YMM state

        if (xcr0_avx_enabled) {
            // CPUID leaf 7: Extended features (AVX2, AVX-512)
            const leaf7 = cpuid(7, 0);
            const ebx7 = leaf7[1]; // EBX from CPUID(7,0)

            // AVX2 is in EBX bit 5
            const avx2_bit: u32 = 1 << 5;
            features.has_avx2 = (ebx7 & avx2_bit) != 0;

            // AVX-512F is in EBX bit 16
            const avx512f_bit: u32 = 1 << 16;
            const xcr0_avx512_enabled = (xcr0 & 0xE0) == 0xE0; // OPMASK, ZMM_Hi256, Hi16_ZMM
            features.has_avx512f = ((ebx7 & avx512f_bit) != 0) and xcr0_avx512_enabled;
        }
    }

    // Determine recommended width
    if (features.has_avx512f) {
        features.recommended_width = 64;
    } else if (features.has_avx2) {
        features.recommended_width = 32;
    } else if (features.has_simd) {
        features.recommended_width = 16;
    }

    return features;
}

/// Execute CPUID instruction
fn cpuid(leaf: u32, subleaf: u32) [4]u32 {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );

    return .{ eax, ebx, ecx, edx };
}

/// Execute XGETBV instruction to read XCR register
fn xgetbv(xcr: u32) u64 {
    var eax: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("xgetbv"
        : [eax] "={eax}" (eax),
          [edx] "={edx}" (edx),
        : [xcr] "{ecx}" (xcr),
    );

    return (@as(u64, edx) << 32) | eax;
}

/// Cached features (computed once on first access)
var cached_features: ?SIMDFeatures = null;

/// Get cached SIMD features (thread-safe via atomic compare-exchange)
pub fn getFeatures() SIMDFeatures {
    if (cached_features) |f| return f;

    const features = detectFeatures();
    cached_features = features;
    return features;
}

/// Check if SIMD is available on this platform
pub fn simdAvailable() bool {
    return getFeatures().has_simd;
}

/// Result of a SIMD scan operation
pub const ScanResult = struct {
    /// Position of the found character (relative to input start)
    position: ?usize,
    /// Number of bytes scanned
    bytes_scanned: usize,
};

// =============================================================================
// Whitespace Scanning
// =============================================================================

/// Find the first non-whitespace character using SIMD
/// Returns the index of the first non-whitespace character, or input.len if all whitespace
pub fn skipWhitespaceSIMD(input: []const u8) usize {
    if (input.len == 0) return 0;

    var pos: usize = 0;

    // Process full vectors
    while (pos + VECTOR_SIZE <= input.len) {
        const chunk = loadVector(input[pos..][0..VECTOR_SIZE]);
        const mask = getWhitespaceMask(chunk);

        // Find first non-whitespace
        const non_ws_pos = findFirstZero(mask);
        if (non_ws_pos < VECTOR_SIZE) {
            return pos + non_ws_pos;
        }
        pos += VECTOR_SIZE;
    }

    // Handle remaining bytes scalar
    while (pos < input.len) {
        const c = input[pos];
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') {
            return pos;
        }
        pos += 1;
    }

    return input.len;
}

/// Check if a byte is whitespace
inline fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Create a bitmask where 0xFF = whitespace, 0x00 = not whitespace
fn getWhitespaceMask(vec: SimdVec) SimdVec {
    const space: SimdVec = @splat(' ');
    const tab: SimdVec = @splat('\t');
    const newline: SimdVec = @splat('\n');
    const cr: SimdVec = @splat('\r');

    const is_space = vec == space;
    const is_tab = vec == tab;
    const is_newline = vec == newline;
    const is_cr = vec == cr;

    // Combine all whitespace checks
    const ws_mask = @select(u8, is_space, @as(SimdVec, @splat(0xFF)), @as(SimdVec, @splat(0)));
    const tab_mask = @select(u8, is_tab, @as(SimdVec, @splat(0xFF)), @as(SimdVec, @splat(0)));
    const nl_mask = @select(u8, is_newline, @as(SimdVec, @splat(0xFF)), @as(SimdVec, @splat(0)));
    const cr_mask = @select(u8, is_cr, @as(SimdVec, @splat(0xFF)), @as(SimdVec, @splat(0)));

    return ws_mask | tab_mask | nl_mask | cr_mask;
}

// =============================================================================
// Structural Character Detection
// =============================================================================

/// Structural characters in JSON
pub const StructuralChar = enum {
    object_start, // {
    object_end, // }
    array_start, // [
    array_end, // ]
    colon, // :
    comma, // ,
    quote, // "
    none,
};

/// Find the next structural character using SIMD
/// Returns the position and type of the next structural character
pub fn findStructuralSIMD(input: []const u8) struct { pos: ?usize, char: StructuralChar } {
    if (input.len == 0) return .{ .pos = null, .char = .none };

    var pos: usize = 0;

    // Process full vectors
    while (pos + VECTOR_SIZE <= input.len) {
        const chunk = loadVector(input[pos..][0..VECTOR_SIZE]);
        const mask = getStructuralMask(chunk);

        const first_structural = findFirstNonZero(mask);
        if (first_structural < VECTOR_SIZE) {
            const idx = pos + first_structural;
            return .{
                .pos = idx,
                .char = charToStructural(input[idx]),
            };
        }
        pos += VECTOR_SIZE;
    }

    // Handle remaining bytes scalar
    while (pos < input.len) {
        const structural = charToStructural(input[pos]);
        if (structural != .none) {
            return .{ .pos = pos, .char = structural };
        }
        pos += 1;
    }

    return .{ .pos = null, .char = .none };
}

/// Convert a byte to its structural character type
inline fn charToStructural(c: u8) StructuralChar {
    return switch (c) {
        '{' => .object_start,
        '}' => .object_end,
        '[' => .array_start,
        ']' => .array_end,
        ':' => .colon,
        ',' => .comma,
        '"' => .quote,
        else => .none,
    };
}

/// Create a bitmask where non-zero = structural character
fn getStructuralMask(vec: SimdVec) SimdVec {
    const lbrace: SimdVec = @splat('{');
    const rbrace: SimdVec = @splat('}');
    const lbracket: SimdVec = @splat('[');
    const rbracket: SimdVec = @splat(']');
    const colon: SimdVec = @splat(':');
    const comma: SimdVec = @splat(',');
    const quote: SimdVec = @splat('"');

    const is_lbrace = vec == lbrace;
    const is_rbrace = vec == rbrace;
    const is_lbracket = vec == lbracket;
    const is_rbracket = vec == rbracket;
    const is_colon = vec == colon;
    const is_comma = vec == comma;
    const is_quote = vec == quote;

    var result: SimdVec = @splat(0);
    result = @select(u8, is_lbrace, @as(SimdVec, @splat(1)), result);
    result = @select(u8, is_rbrace, @as(SimdVec, @splat(2)), result);
    result = @select(u8, is_lbracket, @as(SimdVec, @splat(3)), result);
    result = @select(u8, is_rbracket, @as(SimdVec, @splat(4)), result);
    result = @select(u8, is_colon, @as(SimdVec, @splat(5)), result);
    result = @select(u8, is_comma, @as(SimdVec, @splat(6)), result);
    result = @select(u8, is_quote, @as(SimdVec, @splat(7)), result);

    return result;
}

// =============================================================================
// String Scanning
// =============================================================================

/// Find the end of a JSON string (closing quote or backslash)
/// Returns the position of the quote or backslash, or null if not found
pub fn scanStringSIMD(input: []const u8) struct { pos: ?usize, is_escape: bool } {
    if (input.len == 0) return .{ .pos = null, .is_escape = false };

    var pos: usize = 0;

    // Process full vectors
    while (pos + VECTOR_SIZE <= input.len) {
        const chunk = loadVector(input[pos..][0..VECTOR_SIZE]);

        const quote: SimdVec = @splat('"');
        const backslash: SimdVec = @splat('\\');

        const is_quote = chunk == quote;
        const is_backslash = chunk == backslash;

        const quote_mask = @select(u8, is_quote, @as(SimdVec, @splat(1)), @as(SimdVec, @splat(0)));
        const backslash_mask = @select(u8, is_backslash, @as(SimdVec, @splat(2)), @as(SimdVec, @splat(0)));

        const combined = quote_mask | backslash_mask;
        const first_match = findFirstNonZero(combined);

        if (first_match < VECTOR_SIZE) {
            const idx = pos + first_match;
            return .{
                .pos = idx,
                .is_escape = input[idx] == '\\',
            };
        }
        pos += VECTOR_SIZE;
    }

    // Handle remaining bytes scalar
    while (pos < input.len) {
        const c = input[pos];
        if (c == '"') {
            return .{ .pos = pos, .is_escape = false };
        }
        if (c == '\\') {
            return .{ .pos = pos, .is_escape = true };
        }
        pos += 1;
    }

    return .{ .pos = null, .is_escape = false };
}

/// Validate that a string contains no unescaped control characters
/// Returns true if valid, false if invalid control character found
pub fn validateStringCharsSIMD(input: []const u8) bool {
    if (input.len == 0) return true;

    var pos: usize = 0;

    // Process full vectors
    while (pos + VECTOR_SIZE <= input.len) {
        const chunk = loadVector(input[pos..][0..VECTOR_SIZE]);

        // Check for control characters (< 0x20)
        const control_threshold: SimdVec = @splat(0x20);
        const is_control = chunk < control_threshold;

        // If any control character found, fail
        if (@reduce(.Or, is_control)) {
            return false;
        }
        pos += VECTOR_SIZE;
    }

    // Handle remaining bytes scalar
    while (pos < input.len) {
        if (input[pos] < 0x20) {
            return false;
        }
        pos += 1;
    }

    return true;
}

// =============================================================================
// Number Scanning
// =============================================================================

/// Find the end of a JSON number
/// Returns the position after the last digit
pub fn scanNumberSIMD(input: []const u8) usize {
    if (input.len == 0) return 0;

    var pos: usize = 0;

    // Process full vectors
    while (pos + VECTOR_SIZE <= input.len) {
        const chunk = loadVector(input[pos..][0..VECTOR_SIZE]);
        const mask = getNumberCharMask(chunk);

        const first_non_num = findFirstZero(mask);
        if (first_non_num < VECTOR_SIZE) {
            return pos + first_non_num;
        }
        pos += VECTOR_SIZE;
    }

    // Handle remaining bytes scalar
    while (pos < input.len) {
        const c = input[pos];
        if (!isNumberChar(c)) {
            return pos;
        }
        pos += 1;
    }

    return input.len;
}

/// Check if a byte is part of a JSON number
inline fn isNumberChar(c: u8) bool {
    return (c >= '0' and c <= '9') or c == '-' or c == '+' or c == '.' or c == 'e' or c == 'E';
}

/// Create a bitmask for number characters
fn getNumberCharMask(vec: SimdVec) SimdVec {
    const zero: SimdVec = @splat('0');
    const nine: SimdVec = @splat('9');
    const minus: SimdVec = @splat('-');
    const plus: SimdVec = @splat('+');
    const dot: SimdVec = @splat('.');
    const e_lower: SimdVec = @splat('e');
    const e_upper: SimdVec = @splat('E');

    // Check digit range - use @select to AND two bool vectors
    const ge_zero: @Vector(VECTOR_SIZE, bool) = vec >= zero;
    const le_nine: @Vector(VECTOR_SIZE, bool) = vec <= nine;
    const is_digit = @select(bool, ge_zero, le_nine, @as(@Vector(VECTOR_SIZE, bool), @splat(false)));

    // Check special number characters
    const is_minus = vec == minus;
    const is_plus = vec == plus;
    const is_dot = vec == dot;
    const is_e_lower = vec == e_lower;
    const is_e_upper = vec == e_upper;

    // Combine all
    var result: SimdVec = @splat(0);
    result = @select(u8, is_digit, @as(SimdVec, @splat(0xFF)), result);
    result = @select(u8, is_minus, @as(SimdVec, @splat(0xFF)), result);
    result = @select(u8, is_plus, @as(SimdVec, @splat(0xFF)), result);
    result = @select(u8, is_dot, @as(SimdVec, @splat(0xFF)), result);
    result = @select(u8, is_e_lower, @as(SimdVec, @splat(0xFF)), result);
    result = @select(u8, is_e_upper, @as(SimdVec, @splat(0xFF)), result);

    return result;
}

// =============================================================================
// UTF-8 Validation
// =============================================================================

/// Validate UTF-8 sequences using SIMD
/// Returns true if valid UTF-8, false otherwise
pub fn validateUtf8SIMD(input: []const u8) bool {
    if (input.len == 0) return true;

    var pos: usize = 0;

    // Process full vectors for ASCII fast path
    while (pos + VECTOR_SIZE <= input.len) {
        const chunk = loadVector(input[pos..][0..VECTOR_SIZE]);

        // Fast path: all ASCII (high bit clear)
        const high_bit: SimdVec = @splat(0x80);
        const has_high_bit = (chunk & high_bit) != @as(SimdVec, @splat(0));

        if (!@reduce(.Or, has_high_bit)) {
            // All ASCII, continue
            pos += VECTOR_SIZE;
            continue;
        }

        // Contains multi-byte sequences, fall back to scalar validation
        break;
    }

    // Scalar validation for remaining bytes or multi-byte sequences
    while (pos < input.len) {
        const c = input[pos];

        if (c < 0x80) {
            // ASCII
            pos += 1;
        } else if ((c & 0xE0) == 0xC0) {
            // 2-byte sequence
            if (pos + 2 > input.len) return false;
            if ((input[pos + 1] & 0xC0) != 0x80) return false;
            // Check for overlong
            if (c < 0xC2) return false;
            pos += 2;
        } else if ((c & 0xF0) == 0xE0) {
            // 3-byte sequence
            if (pos + 3 > input.len) return false;
            if ((input[pos + 1] & 0xC0) != 0x80) return false;
            if ((input[pos + 2] & 0xC0) != 0x80) return false;
            // Check for overlong and surrogate
            const cp = (@as(u21, c & 0x0F) << 12) |
                (@as(u21, input[pos + 1] & 0x3F) << 6) |
                @as(u21, input[pos + 2] & 0x3F);
            if (cp < 0x800 or (cp >= 0xD800 and cp <= 0xDFFF)) return false;
            pos += 3;
        } else if ((c & 0xF8) == 0xF0) {
            // 4-byte sequence
            if (pos + 4 > input.len) return false;
            if ((input[pos + 1] & 0xC0) != 0x80) return false;
            if ((input[pos + 2] & 0xC0) != 0x80) return false;
            if ((input[pos + 3] & 0xC0) != 0x80) return false;
            // Check for overlong and out of range
            const cp = (@as(u21, c & 0x07) << 18) |
                (@as(u21, input[pos + 1] & 0x3F) << 12) |
                (@as(u21, input[pos + 2] & 0x3F) << 6) |
                @as(u21, input[pos + 3] & 0x3F);
            if (cp < 0x10000 or cp > 0x10FFFF) return false;
            pos += 4;
        } else {
            // Invalid UTF-8 start byte
            return false;
        }
    }

    return true;
}

// =============================================================================
// Helper Functions
// =============================================================================

/// Load a vector from memory
inline fn loadVector(ptr: *const [VECTOR_SIZE]u8) SimdVec {
    return ptr.*;
}

/// Find the index of the first zero byte in the vector
/// Returns VECTOR_SIZE if no zero found
fn findFirstZero(vec: SimdVec) usize {
    const arr: [VECTOR_SIZE]u8 = vec;
    for (arr, 0..) |b, i| {
        if (b == 0) return i;
    }
    return VECTOR_SIZE;
}

/// Find the index of the first non-zero byte in the vector
/// Returns VECTOR_SIZE if all zero
fn findFirstNonZero(vec: SimdVec) usize {
    const arr: [VECTOR_SIZE]u8 = vec;
    for (arr, 0..) |b, i| {
        if (b != 0) return i;
    }
    return VECTOR_SIZE;
}

// =============================================================================
// SIMD-Accelerated Parser
// =============================================================================

/// SIMD-accelerated JSON parser options
pub const SimdParseOptions = struct {
    /// Maximum nesting depth
    max_depth: u16 = 256,
    /// Maximum string length
    max_string_len: usize = 1024 * 1024,
    /// Validate UTF-8 (disable for trusted input)
    validate_utf8: bool = true,
};

/// Parse state for SIMD parser
pub const SimdParser = struct {
    input: []const u8,
    pos: usize,
    line: u32,
    col: u32,
    opts: SimdParseOptions,

    const Self = @This();

    pub fn init(input: []const u8, opts: SimdParseOptions) Self {
        return .{
            .input = input,
            .pos = 0,
            .line = 1,
            .col = 1,
            .opts = opts,
        };
    }

    /// Skip whitespace using SIMD
    pub fn skipWhitespace(self: *Self) void {
        if (self.pos >= self.input.len) return;

        const remaining = self.input[self.pos..];
        const skip_count = skipWhitespaceSIMD(remaining);

        // Update line/col for skipped characters
        for (self.input[self.pos..][0..skip_count]) |c| {
            if (c == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
        }
        self.pos += skip_count;
    }

    /// Find next structural character using SIMD
    pub fn findNextStructural(self: *Self) ?struct { pos: usize, char: StructuralChar } {
        if (self.pos >= self.input.len) return null;

        const remaining = self.input[self.pos..];
        const result = findStructuralSIMD(remaining);

        if (result.pos) |rel_pos| {
            return .{
                .pos = self.pos + rel_pos,
                .char = result.char,
            };
        }
        return null;
    }

    /// Scan a string using SIMD
    /// Returns the content between quotes (excluding quotes)
    pub fn scanString(self: *Self) ![]const u8 {
        if (self.pos >= self.input.len or self.input[self.pos] != '"') {
            return error.InvalidString;
        }

        self.pos += 1; // skip opening quote
        self.col += 1;
        const start = self.pos;

        while (self.pos < self.input.len) {
            const remaining = self.input[self.pos..];
            const scan_result = scanStringSIMD(remaining);

            if (scan_result.pos) |rel_pos| {
                const abs_pos = self.pos + rel_pos;

                // Update position tracking for skipped content
                for (self.input[self.pos..abs_pos]) |c| {
                    if (c == '\n') {
                        self.line += 1;
                        self.col = 1;
                    } else {
                        self.col += 1;
                    }
                }

                if (scan_result.is_escape) {
                    // Found backslash - need to handle escape
                    self.pos = abs_pos + 2; // skip backslash and escaped char
                    self.col += 2;

                    // Handle \u escape specially (4 more hex chars)
                    if (abs_pos + 1 < self.input.len and self.input[abs_pos + 1] == 'u') {
                        self.pos += 4;
                        self.col += 4;
                    }
                } else {
                    // Found closing quote
                    self.pos = abs_pos + 1;
                    self.col += 1;
                    return self.input[start..abs_pos];
                }
            } else {
                // No quote or backslash found
                return error.UnterminatedString;
            }
        }

        return error.UnterminatedString;
    }

    /// Scan a number using SIMD
    pub fn scanNumber(self: *Self) []const u8 {
        const start = self.pos;
        const remaining = self.input[self.pos..];
        const end_offset = scanNumberSIMD(remaining);

        self.pos += end_offset;
        self.col += @intCast(end_offset);

        return self.input[start .. start + end_offset];
    }

    /// Validate UTF-8 in the remaining input
    pub fn validateUtf8(self: *Self) bool {
        return validateUtf8SIMD(self.input[self.pos..]);
    }

    const ParseError = error{
        InvalidString,
        UnterminatedString,
    };
};

// =============================================================================
// Batch Processing
// =============================================================================

/// Process multiple JSON values in a batch using SIMD
pub const BatchProcessor = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Find all string boundaries in the input
    /// Returns array of (start, end) positions for each string
    pub fn findAllStrings(self: *Self, input: []const u8) ![]struct { start: usize, end: usize } {
        var results = std.ArrayList(struct { start: usize, end: usize }).init(self.allocator);
        errdefer results.deinit();

        var pos: usize = 0;
        var in_string = false;
        var string_start: usize = 0;

        while (pos < input.len) {
            const remaining = input[pos..];
            const scan_result = scanStringSIMD(remaining);

            if (scan_result.pos) |rel_pos| {
                const abs_pos = pos + rel_pos;

                if (scan_result.is_escape) {
                    // Skip escape sequence
                    pos = abs_pos + 2;
                    if (abs_pos + 1 < input.len and input[abs_pos + 1] == 'u') {
                        pos += 4;
                    }
                } else {
                    // Found quote
                    if (in_string) {
                        try results.append(.{ .start = string_start, .end = abs_pos });
                        in_string = false;
                    } else {
                        string_start = abs_pos + 1;
                        in_string = true;
                    }
                    pos = abs_pos + 1;
                }
            } else {
                break;
            }
        }

        return results.toOwnedSlice();
    }

    /// Structural character counts
    pub const StructuralCounts = struct {
        objects: usize = 0,
        arrays: usize = 0,
        strings: usize = 0,
        colons: usize = 0,
        commas: usize = 0,
    };

    /// Count structural characters in the input
    pub fn countStructurals(self: *Self, input: []const u8) StructuralCounts {
        _ = self;
        var counts = StructuralCounts{};

        var pos: usize = 0;

        while (pos + VECTOR_SIZE <= input.len) {
            const chunk = loadVector(input[pos..][0..VECTOR_SIZE]);

            const lbrace: SimdVec = @splat('{');
            const lbracket: SimdVec = @splat('[');
            const quote: SimdVec = @splat('"');
            const colon: SimdVec = @splat(':');
            const comma: SimdVec = @splat(',');

            // Use @reduce to sum up boolean matches (converted to u8 to avoid overflow)
            counts.objects += @reduce(.Add, @as(@Vector(VECTOR_SIZE, u8), @intFromBool(chunk == lbrace)));
            counts.arrays += @reduce(.Add, @as(@Vector(VECTOR_SIZE, u8), @intFromBool(chunk == lbracket)));
            counts.strings += @reduce(.Add, @as(@Vector(VECTOR_SIZE, u8), @intFromBool(chunk == quote)));
            counts.colons += @reduce(.Add, @as(@Vector(VECTOR_SIZE, u8), @intFromBool(chunk == colon)));
            counts.commas += @reduce(.Add, @as(@Vector(VECTOR_SIZE, u8), @intFromBool(chunk == comma)));

            pos += VECTOR_SIZE;
        }

        // Handle remaining bytes
        while (pos < input.len) {
            switch (input[pos]) {
                '{' => counts.objects += 1,
                '[' => counts.arrays += 1,
                '"' => counts.strings += 1,
                ':' => counts.colons += 1,
                ',' => counts.commas += 1,
                else => {},
            }
            pos += 1;
        }

        // Divide string count by 2 (start and end quotes)
        counts.strings /= 2;

        return counts;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "skipWhitespaceSIMD" {
    try std.testing.expectEqual(@as(usize, 0), skipWhitespaceSIMD("hello"));
    try std.testing.expectEqual(@as(usize, 3), skipWhitespaceSIMD("   hello"));
    try std.testing.expectEqual(@as(usize, 4), skipWhitespaceSIMD("\t\n\r world"));
    try std.testing.expectEqual(@as(usize, 5), skipWhitespaceSIMD("     "));
    try std.testing.expectEqual(@as(usize, 0), skipWhitespaceSIMD(""));

    // Test long whitespace
    const long_ws = " " ** 100 ++ "x";
    try std.testing.expectEqual(@as(usize, 100), skipWhitespaceSIMD(long_ws));
}

test "findStructuralSIMD" {
    {
        const result = findStructuralSIMD("{\"key\": 1}");
        try std.testing.expectEqual(@as(usize, 0), result.pos.?);
        try std.testing.expectEqual(StructuralChar.object_start, result.char);
    }
    {
        const result = findStructuralSIMD("   [1, 2]");
        try std.testing.expectEqual(@as(usize, 3), result.pos.?);
        try std.testing.expectEqual(StructuralChar.array_start, result.char);
    }
    {
        const result = findStructuralSIMD("hello world");
        try std.testing.expect(result.pos == null);
    }
}

test "scanStringSIMD" {
    {
        const result = scanStringSIMD("hello world\"");
        try std.testing.expectEqual(@as(usize, 11), result.pos.?);
        try std.testing.expect(!result.is_escape);
    }
    {
        const result = scanStringSIMD("hello\\nworld\"");
        try std.testing.expectEqual(@as(usize, 5), result.pos.?);
        try std.testing.expect(result.is_escape);
    }
    {
        const result = scanStringSIMD("no quote here");
        try std.testing.expect(result.pos == null);
    }
}

test "validateStringCharsSIMD" {
    try std.testing.expect(validateStringCharsSIMD("hello world"));
    try std.testing.expect(validateStringCharsSIMD(""));
    try std.testing.expect(!validateStringCharsSIMD("hello\x00world"));
    try std.testing.expect(!validateStringCharsSIMD("hello\nworld")); // newline is < 0x20
}

test "scanNumberSIMD" {
    try std.testing.expectEqual(@as(usize, 3), scanNumberSIMD("123 "));
    try std.testing.expectEqual(@as(usize, 4), scanNumberSIMD("-123abc"));
    try std.testing.expectEqual(@as(usize, 8), scanNumberSIMD("1.23e+10 "));
    try std.testing.expectEqual(@as(usize, 0), scanNumberSIMD("abc"));
}

test "validateUtf8SIMD" {
    try std.testing.expect(validateUtf8SIMD("hello world"));
    try std.testing.expect(validateUtf8SIMD(""));
    try std.testing.expect(validateUtf8SIMD("日本語")); // Japanese
    try std.testing.expect(validateUtf8SIMD("🎉")); // Emoji
    try std.testing.expect(!validateUtf8SIMD("\x80")); // Invalid start byte
    try std.testing.expect(!validateUtf8SIMD("\xC0\x80")); // Overlong encoding
}

test "SimdParser basic" {
    var parser = SimdParser.init("  {\"key\": 123}", .{});

    parser.skipWhitespace();
    try std.testing.expectEqual(@as(usize, 2), parser.pos);

    const structural = parser.findNextStructural();
    try std.testing.expect(structural != null);
    try std.testing.expectEqual(StructuralChar.object_start, structural.?.char);
}

test "BatchProcessor countStructurals" {
    var processor = BatchProcessor.init(std.testing.allocator);

    // Input: {"a": [1, 2], "b": {"c": 3}}
    // Commas: after [1,2] and inside [1,2] = 2 commas
    const counts = processor.countStructurals("{\"a\": [1, 2], \"b\": {\"c\": 3}}");
    try std.testing.expectEqual(@as(usize, 2), counts.objects);
    try std.testing.expectEqual(@as(usize, 1), counts.arrays);
    try std.testing.expectEqual(@as(usize, 3), counts.strings);
    try std.testing.expectEqual(@as(usize, 3), counts.colons);
    try std.testing.expectEqual(@as(usize, 2), counts.commas);
}

test "detectFeatures" {
    const features = detectFeatures();

    // Basic sanity checks
    try std.testing.expect(features.recommended_width >= 1);
    try std.testing.expect(features.recommended_width <= 64);

    // If we have advanced features, we should also have basic SIMD
    if (features.has_avx512f) {
        try std.testing.expect(features.has_avx2);
        try std.testing.expect(features.has_sse42);
        try std.testing.expect(features.has_simd);
    }
    if (features.has_avx2) {
        try std.testing.expect(features.has_simd);
    }

    // Check describe returns non-empty string
    const desc = features.describe();
    try std.testing.expect(desc.len > 0);

    // Test getFeatures caching
    const features2 = getFeatures();
    try std.testing.expectEqual(features.has_simd, features2.has_simd);
    try std.testing.expectEqual(features.has_avx2, features2.has_avx2);

    // simdAvailable should be consistent with has_simd
    try std.testing.expectEqual(features.has_simd, simdAvailable());
}
