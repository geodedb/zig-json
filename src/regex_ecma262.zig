// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! ECMA-262 Regular Expression Engine
//!
//! Implements a subset of ECMA-262 regex for JSON Schema pattern validation.
//! Uses NFA-based execution with configurable step limit.

const std = @import("std");

pub const Regex = struct {
    pattern: []const u8,
    compiled: CompiledRegex,

    pub fn compile(pattern: []const u8, a: std.mem.Allocator) !Regex {
        const pat = try a.dupe(u8, pattern);
        errdefer a.free(pat);
        return .{
            .pattern = pat,
            .compiled = try compilePattern(pattern, a),
        };
    }

    /// Match `input` against the compiled program. `a` is used only for the
    /// matcher's short-lived scratch buffers (all freed before returning); it
    /// need not be the allocator the pattern was compiled with. A live
    /// allocator is passed in here rather than stored on the compiled program
    /// because the latter is frequently an arena that is moved by value after
    /// compilation, leaving any captured allocator dangling (ASR-022 /
    /// PERF-003).
    pub fn match(self: *const Regex, a: std.mem.Allocator, input: []const u8, max_steps: u32) !bool {
        return try executeMatch(a, &self.compiled, input, max_steps);
    }

    pub fn deinit(self: *Regex, a: std.mem.Allocator) void {
        a.free(self.pattern);
        self.compiled.deinit(a);
    }
};

const OpCode = enum {
    literal,
    any_char,
    char_class,
    neg_char_class,
    anchor_start,
    anchor_end,
    split,
    jump,
    match_end,
};

const Instruction = struct {
    op: OpCode,
    c: u8 = 0,
    ranges: ?[]const [2]u8 = null,
    x: u32 = 0,
    y: u32 = 0,
};

/// Upper bound on the number of compiled instructions a single pattern may
/// produce. Without this, a bounded quantifier such as `a{1,5000000}` (which is
/// reachable via an untrusted JSON Schema `pattern`) would expand into millions
/// of instructions, allowing a trivial CPU/memory denial-of-service. When a
/// pattern would exceed this limit the compiler returns `error.PatternTooLarge`
/// instead of allocating.
const MAX_PROGRAM_SIZE: usize = 100_000;

/// Duplicate an instruction, deep-copying its owned `.ranges` slice (if any) so
/// the copy owns an independent allocation. This is required wherever a
/// char-class instruction is replicated (e.g. by `{n,m}` expansion); sharing the
/// `.ranges` pointer would otherwise cause a double-free in `CompiledRegex.deinit`.
fn dupeInst(a: std.mem.Allocator, inst: Instruction) !Instruction {
    var copy = inst;
    if (inst.ranges) |r| {
        copy.ranges = try a.dupe([2]u8, r);
    }
    return copy;
}

const CompiledRegex = struct {
    instructions: []Instruction,

    pub fn deinit(self: *CompiledRegex, a: std.mem.Allocator) void {
        for (self.instructions) |inst| {
            if (inst.ranges) |r| a.free(r);
        }
        a.free(self.instructions);
    }
};

fn compilePattern(pattern: []const u8, a: std.mem.Allocator) !CompiledRegex {
    var instructions: std.ArrayList(Instruction) = .empty;
    errdefer {
        for (instructions.items) |inst| {
            if (inst.ranges) |r| a.free(r);
        }
        instructions.deinit(a);
    }

    var i: usize = 0;

    while (i < pattern.len) {
        const c = pattern[i];

        switch (c) {
            '^' => {
                try instructions.append(a, .{ .op = .anchor_start });
                i += 1;
            },
            '$' => {
                try instructions.append(a, .{ .op = .anchor_end });
                i += 1;
            },
            '.' => {
                try instructions.append(a, .{ .op = .any_char });
                i += 1;
            },
            '[' => {
                i += 1;
                var negated = false;
                if (i < pattern.len and pattern[i] == '^') {
                    negated = true;
                    i += 1;
                }

                var ranges: std.ArrayList([2]u8) = .empty;
                errdefer ranges.deinit(a);

                while (i < pattern.len and pattern[i] != ']') {
                    const start = pattern[i];
                    i += 1;

                    if (i + 1 < pattern.len and pattern[i] == '-' and pattern[i + 1] != ']') {
                        i += 1;
                        const end = pattern[i];
                        i += 1;
                        try ranges.append(a, .{ start, end });
                    } else {
                        try ranges.append(a, .{ start, start });
                    }
                }

                if (i < pattern.len) i += 1; // Skip ']'

                try instructions.append(a, .{
                    .op = if (negated) .neg_char_class else .char_class,
                    .ranges = try ranges.toOwnedSlice(a),
                });
            },
            '\\' => {
                i += 1;
                if (i >= pattern.len) return error.InvalidPattern;

                const escaped = pattern[i];
                i += 1;

                switch (escaped) {
                    'd' => try instructions.append(a, .{
                        .op = .char_class,
                        .ranges = try a.dupe([2]u8, &[_][2]u8{.{ '0', '9' }}),
                    }),
                    'D' => try instructions.append(a, .{
                        .op = .neg_char_class,
                        .ranges = try a.dupe([2]u8, &[_][2]u8{.{ '0', '9' }}),
                    }),
                    'w' => try instructions.append(a, .{
                        .op = .char_class,
                        .ranges = try a.dupe([2]u8, &[_][2]u8{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '0', '9' }, .{ '_', '_' } }),
                    }),
                    'W' => try instructions.append(a, .{
                        .op = .neg_char_class,
                        .ranges = try a.dupe([2]u8, &[_][2]u8{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '0', '9' }, .{ '_', '_' } }),
                    }),
                    // ECMA-262 §22.2.2.9 WhiteSpace/LineTerminator (ASCII set):
                    // space, tab, line feed, carriage return, form feed (\f, 0x0C)
                    // and vertical tab (\v, 0x0B). The \t..\r contiguous run
                    // 0x09..0x0D covers tab, LF, VT, FF and CR in one range.
                    's' => try instructions.append(a, .{
                        .op = .char_class,
                        .ranges = try a.dupe([2]u8, &[_][2]u8{ .{ ' ', ' ' }, .{ 0x09, 0x0D } }),
                    }),
                    'S' => try instructions.append(a, .{
                        .op = .neg_char_class,
                        .ranges = try a.dupe([2]u8, &[_][2]u8{ .{ ' ', ' ' }, .{ 0x09, 0x0D } }),
                    }),
                    'n' => try instructions.append(a, .{ .op = .literal, .c = '\n' }),
                    'r' => try instructions.append(a, .{ .op = .literal, .c = '\r' }),
                    't' => try instructions.append(a, .{ .op = .literal, .c = '\t' }),
                    'f' => try instructions.append(a, .{ .op = .literal, .c = 0x0C }),
                    'v' => try instructions.append(a, .{ .op = .literal, .c = 0x0B }),
                    else => try instructions.append(a, .{ .op = .literal, .c = escaped }),
                }
            },
            '*', '+', '?' => {
                if (instructions.items.len == 0) return error.InvalidPattern;

                const last_idx = instructions.items.len - 1;

                if (c == '*') {
                    // a* -> split(L1, L3); L1: a; jump(L0); L3: ...
                    const split_idx: u32 = @intCast(last_idx);
                    const after_idx: u32 = @intCast(instructions.items.len + 1);

                    var new_insts: std.ArrayList(Instruction) = .empty;
                    errdefer new_insts.deinit(a);

                    for (instructions.items[0..last_idx]) |inst| {
                        try new_insts.append(a, inst);
                    }

                    try new_insts.append(a, .{ .op = .split, .x = split_idx + 1, .y = after_idx + 1 });
                    try new_insts.append(a, instructions.items[last_idx]);
                    try new_insts.append(a, .{ .op = .jump, .x = split_idx });

                    instructions.deinit(a);
                    instructions = new_insts;
                } else if (c == '+') {
                    // a+ -> L1: a; split(L1, L2); L2: ...
                    const start_idx: u32 = @intCast(instructions.items.len);
                    try instructions.append(a, .{ .op = .split, .x = @intCast(last_idx), .y = start_idx + 1 });
                } else if (c == '?') {
                    // a? -> split(L1, L2); L1: a; L2: ...
                    const split_idx: u32 = @intCast(last_idx);
                    const after_idx: u32 = @intCast(instructions.items.len);

                    var new_insts: std.ArrayList(Instruction) = .empty;
                    errdefer new_insts.deinit(a);

                    for (instructions.items[0..last_idx]) |inst| {
                        try new_insts.append(a, inst);
                    }

                    try new_insts.append(a, .{ .op = .split, .x = split_idx + 1, .y = after_idx + 1 });
                    try new_insts.append(a, instructions.items[last_idx]);

                    instructions.deinit(a);
                    instructions = new_insts;
                }

                i += 1;
                // Handle non-greedy modifier
                if (i < pattern.len and pattern[i] == '?') i += 1;
            },
            '{' => {
                // Bounded repetition {n}, {n,} or {n,m}.
                if (instructions.items.len == 0) return error.InvalidPattern;

                i += 1;
                const min_start = i;
                while (i < pattern.len and pattern[i] >= '0' and pattern[i] <= '9') {
                    i += 1;
                }
                // A `{` with no leading digits is not a quantifier; treat it as a
                // literal brace (ECMA-262 allows `{` as an ordinary character).
                if (i == min_start) {
                    try instructions.append(a, .{ .op = .literal, .c = '{' });
                    i = min_start;
                    continue;
                }
                // Parse the lower bound with overflow detection (ASR-019).
                const min = std.fmt.parseInt(usize, pattern[min_start..i], 10) catch
                    return error.PatternTooLarge;

                var max: usize = min; // {n} means exactly n.
                var unbounded = false;

                if (i < pattern.len and pattern[i] == ',') {
                    i += 1;
                    const max_start = i;
                    while (i < pattern.len and pattern[i] >= '0' and pattern[i] <= '9') {
                        i += 1;
                    }
                    if (i == max_start) {
                        unbounded = true; // {n,} repeats n or more times.
                    } else {
                        max = std.fmt.parseInt(usize, pattern[max_start..i], 10) catch
                            return error.PatternTooLarge;
                    }
                }

                if (i < pattern.len and pattern[i] == '}') {
                    i += 1;
                } else {
                    return error.InvalidPattern;
                }

                if (!unbounded and max < min) return error.InvalidPattern;

                // The quantifier applies to the single preceding instruction. We
                // detach the template, deep-copying its owned `.ranges` so each
                // emitted copy owns an independent allocation (ASR-003), and use
                // split/jump loops rather than physical duplication so the upper
                // bound cannot trigger a compile-time explosion (ASR-002).
                const template = instructions.pop().?;
                errdefer if (template.ranges) |r| a.free(r);

                // Project the final instruction count and reject up front if it
                // would exceed the program-size cap, before allocating anything.
                // Required copies cost 1 each; bounded optional copies cost 2 each
                // (a split + the body); an unbounded tail costs 2 (split + jump).
                const optional: usize = if (unbounded) 0 else max -| min;
                const projected = instructions.items.len + min + optional * 2 +
                    (if (unbounded) @as(usize, 2) else 0) + 1; // +1 for match_end
                if (projected > MAX_PROGRAM_SIZE or min > MAX_PROGRAM_SIZE) {
                    return error.PatternTooLarge;
                }

                // Emit the `min` mandatory copies.
                var n: usize = 0;
                while (n < min) : (n += 1) {
                    try instructions.append(a, try dupeInst(a, template));
                }

                if (unbounded) {
                    // {n,} -> star loop on the body:
                    //   split(body, after); body: X; jump(split); after: ...
                    const split_idx: u32 = @intCast(instructions.items.len);
                    try instructions.append(a, .{
                        .op = .split,
                        .x = split_idx + 1,
                        .y = split_idx + 3,
                    });
                    try instructions.append(a, try dupeInst(a, template));
                    try instructions.append(a, .{ .op = .jump, .x = split_idx });
                } else {
                    // {n,m} -> (m-n) optional copies, each guarded by a split that
                    // can skip the remaining tail:
                    //   split(next, after); X; split(next, after); X; ...
                    var opt: usize = 0;
                    while (opt < optional) : (opt += 1) {
                        const split_idx: u32 = @intCast(instructions.items.len);
                        // y jumps past all remaining (split, X) pairs to `after`.
                        const remaining = optional - opt;
                        const after: u32 = @intCast(instructions.items.len + remaining * 2);
                        try instructions.append(a, .{
                            .op = .split,
                            .x = split_idx + 1,
                            .y = after,
                        });
                        try instructions.append(a, try dupeInst(a, template));
                    }
                }

                // The template was consumed via dupes above; free its allocation.
                if (template.ranges) |r| a.free(r);

                // Handle non-greedy modifier (treated identically here).
                if (i < pattern.len and pattern[i] == '?') i += 1;
            },
            // Grouping and alternation are not supported by this flat NFA
            // compiler. Silently dropping them (the previous behaviour) made
            // `(foo|bar)` compile to `fobar` and `^(admin|user)$` accept
            // arbitrary input, a validation-bypass when a schema `pattern` is
            // used as an input control. Reject such patterns with a hard error
            // so callers fail closed rather than matching incorrectly (ASR-020).
            '|', '(', ')' => return error.UnsupportedPattern,
            else => {
                try instructions.append(a, .{ .op = .literal, .c = c });
                i += 1;
            },
        }
    }

    try instructions.append(a, .{ .op = .match_end });

    return .{ .instructions = try instructions.toOwnedSlice(a) };
}

/// Reusable scratch state for the NFA simulation. The work buffers are sized to
/// the instruction count and allocated once per `executeMatch`, then reused for
/// every start position via `clearRetainingCapacity`/`@memset` instead of being
/// reallocated per start position (ASR-022 / PERF-003). All allocations are made
/// through the caller-supplied allocator rather than `page_allocator`.
const Matcher = struct {
    a: std.mem.Allocator,
    compiled: *const CompiledRegex,
    work: std.ArrayList(u32),
    current: std.ArrayList(u32),
    next: std.ArrayList(u32),
    in_current: []bool,
    in_next: []bool,

    fn init(a: std.mem.Allocator, compiled: *const CompiledRegex) !Matcher {
        const n = compiled.instructions.len;

        const in_current = try a.alloc(bool, n);
        errdefer a.free(in_current);
        const in_next = try a.alloc(bool, n);
        errdefer a.free(in_next);

        var work: std.ArrayList(u32) = .empty;
        errdefer work.deinit(a);
        try work.ensureTotalCapacity(a, n);

        var current: std.ArrayList(u32) = .empty;
        errdefer current.deinit(a);
        try current.ensureTotalCapacity(a, n);

        var next: std.ArrayList(u32) = .empty;
        errdefer next.deinit(a);
        try next.ensureTotalCapacity(a, n);

        return .{
            .a = a,
            .compiled = compiled,
            .work = work,
            .current = current,
            .next = next,
            .in_current = in_current,
            .in_next = in_next,
        };
    }

    fn deinit(self: *Matcher) void {
        self.work.deinit(self.a);
        self.current.deinit(self.a);
        self.next.deinit(self.a);
        self.a.free(self.in_current);
        self.a.free(self.in_next);
    }

    fn run(self: *Matcher, input: []const u8, start: usize, max_steps: u32) !bool {
        const compiled = self.compiled;

        // Reset reusable buffers for this start position.
        self.current.clearRetainingCapacity();
        self.next.clearRetainingCapacity();
        @memset(self.in_current, false);
        @memset(self.in_next, false);

        var steps: u32 = 0;
        var sp: usize = start;

        try self.addState(&self.current, self.in_current, 0, sp, input.len);

        while (self.current.items.len > 0) {
            if (steps >= max_steps) return error.RegexLimit;
            steps += 1;

            // Check for match in current states.
            for (self.current.items) |pc| {
                if (compiled.instructions[pc].op == .match_end) return true;
            }

            if (sp >= input.len) break;

            // Process character transitions.
            self.next.clearRetainingCapacity();
            @memset(self.in_next, false);

            const c = input[sp];
            for (self.current.items) |pc| {
                const inst = compiled.instructions[pc];
                switch (inst.op) {
                    .literal => {
                        if (c == inst.c) {
                            try self.addState(&self.next, self.in_next, pc + 1, sp + 1, input.len);
                        }
                    },
                    .any_char => {
                        if (c != '\n') {
                            try self.addState(&self.next, self.in_next, pc + 1, sp + 1, input.len);
                        }
                    },
                    .char_class => {
                        if (matchCharClass(c, inst.ranges.?)) {
                            try self.addState(&self.next, self.in_next, pc + 1, sp + 1, input.len);
                        }
                    },
                    .neg_char_class => {
                        if (!matchCharClass(c, inst.ranges.?)) {
                            try self.addState(&self.next, self.in_next, pc + 1, sp + 1, input.len);
                        }
                    },
                    else => {},
                }
            }

            // Swap current and next.
            const tmp_list = self.current;
            self.current = self.next;
            self.next = tmp_list;
            const tmp_set = self.in_current;
            self.in_current = self.in_next;
            self.in_next = tmp_set;

            sp += 1;
        }

        return false;
    }

    fn addState(
        self: *Matcher,
        list: *std.ArrayList(u32),
        in_list: []bool,
        pc: u32,
        sp: usize,
        input_len: usize,
    ) !void {
        const compiled = self.compiled;
        self.work.clearRetainingCapacity();
        try self.work.append(self.a, pc);

        while (self.work.items.len > 0) {
            const cur_pc = self.work.items[self.work.items.len - 1];
            self.work.items.len -= 1;
            if (cur_pc >= compiled.instructions.len) continue;
            if (in_list[cur_pc]) continue;
            in_list[cur_pc] = true;

            const inst = compiled.instructions[cur_pc];
            switch (inst.op) {
                .split => {
                    try self.work.append(self.a, inst.x);
                    try self.work.append(self.a, inst.y);
                },
                .jump => {
                    try self.work.append(self.a, inst.x);
                },
                .anchor_start => {
                    if (sp == 0) {
                        try self.work.append(self.a, cur_pc + 1);
                    }
                },
                .anchor_end => {
                    if (sp == input_len) {
                        try self.work.append(self.a, cur_pc + 1);
                    }
                },
                else => {
                    try list.append(self.a, cur_pc);
                },
            }
        }
    }
};

fn executeMatch(a: std.mem.Allocator, compiled: *const CompiledRegex, input: []const u8, max_steps: u32) !bool {
    var matcher = try Matcher.init(a, compiled);
    defer matcher.deinit();

    // Try matching at each position, reusing the matcher's scratch buffers.
    for (0..input.len + 1) |start| {
        if (try matcher.run(input, start, max_steps)) return true;
    }
    return false;
}

fn matchCharClass(c: u8, ranges: []const [2]u8) bool {
    for (ranges) |range| {
        if (c >= range[0] and c <= range[1]) return true;
    }
    return false;
}

test "regex literal" {
    var re = try Regex.compile("abc", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match(std.testing.allocator, "abc", 10000));
    try std.testing.expect(try re.match(std.testing.allocator, "xabcy", 10000));
    try std.testing.expect(!try re.match(std.testing.allocator, "ab", 10000));
}

test "regex anchor" {
    var re = try Regex.compile("^abc$", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match(std.testing.allocator, "abc", 10000));
    try std.testing.expect(!try re.match(std.testing.allocator, "xabc", 10000));
    try std.testing.expect(!try re.match(std.testing.allocator, "abcx", 10000));
}

test "regex char class" {
    var re = try Regex.compile("[a-z]+", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match(std.testing.allocator, "abc", 10000));
    try std.testing.expect(!try re.match(std.testing.allocator, "123", 10000));
}

test "regex negated class" {
    var re = try Regex.compile("[^0-9]+", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match(std.testing.allocator, "abc", 10000));
}

test "regex quantifier star" {
    var re = try Regex.compile("a*", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match(std.testing.allocator, "", 10000));
    try std.testing.expect(try re.match(std.testing.allocator, "a", 10000));
    try std.testing.expect(try re.match(std.testing.allocator, "aaa", 10000));
}

test "regex quantifier plus" {
    var re = try Regex.compile("a+", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(!try re.match(std.testing.allocator, "", 10000));
    try std.testing.expect(try re.match(std.testing.allocator, "a", 10000));
    try std.testing.expect(try re.match(std.testing.allocator, "aaa", 10000));
}

test "regex quantifier question" {
    var re = try Regex.compile("a?b", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match(std.testing.allocator, "b", 10000));
    try std.testing.expect(try re.match(std.testing.allocator, "ab", 10000));
}

test "regex digit class" {
    var re = try Regex.compile("\\d+", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match(std.testing.allocator, "123", 10000));
    try std.testing.expect(!try re.match(std.testing.allocator, "abc", 10000));
}

test "regex email pattern" {
    var re = try Regex.compile("^[a-zA-Z0-9]+@[a-zA-Z0-9]+\\.[a-zA-Z]+$", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match(std.testing.allocator, "test@example.com", 10000));
    try std.testing.expect(!try re.match(std.testing.allocator, "invalid", 10000));
}

// ASR-002: a large bounded quantifier must be rejected promptly with a compile
// error instead of expanding into ~10M instructions and exhausting memory/CPU.
test "ASR-002: bounded quantifier upper bound is capped" {
    try std.testing.expectError(error.PatternTooLarge, Regex.compile("a{1,5000000}", std.testing.allocator));
    // Even larger bounds (previously tens of GB) must also fail fast.
    try std.testing.expectError(error.PatternTooLarge, Regex.compile("a{1,500000000}", std.testing.allocator));
    // A char-class body is just as dangerous; it must be rejected too.
    try std.testing.expectError(error.PatternTooLarge, Regex.compile("[a-z]{1,5000000}", std.testing.allocator));
}

// ASR-003: a quantified char class must not double-free its `.ranges` slice.
// std.testing.allocator detects leaks and double-frees, so a clean deinit here
// proves each replicated instruction owns an independent allocation.
test "ASR-003: quantified char class compiles, matches and deinits cleanly" {
    {
        var re = try Regex.compile("[a-z]{3}", std.testing.allocator);
        defer re.deinit(std.testing.allocator);
        try std.testing.expect(try re.match(std.testing.allocator, "abc", 10000));
        try std.testing.expect(!try re.match(std.testing.allocator, "ab", 10000));
        try std.testing.expect(try re.match(std.testing.allocator, "xabcy", 10000));
    }
    {
        var re = try Regex.compile("\\d{4}", std.testing.allocator);
        defer re.deinit(std.testing.allocator);
        try std.testing.expect(try re.match(std.testing.allocator, "1234", 10000));
        try std.testing.expect(!try re.match(std.testing.allocator, "123", 10000));
    }
    {
        // Ranged quantifier on a char class also replicates the slice.
        var re = try Regex.compile("[0-9]{2,4}", std.testing.allocator);
        defer re.deinit(std.testing.allocator);
        try std.testing.expect(!try re.match(std.testing.allocator, "1", 10000));
        try std.testing.expect(try re.match(std.testing.allocator, "12", 10000));
        try std.testing.expect(try re.match(std.testing.allocator, "1234", 10000));
    }
    {
        // Unbounded {n,} on a char class uses the star-loop path.
        var re = try Regex.compile("^[a-z]{2,}$", std.testing.allocator);
        defer re.deinit(std.testing.allocator);
        try std.testing.expect(!try re.match(std.testing.allocator, "a", 10000));
        try std.testing.expect(try re.match(std.testing.allocator, "ab", 10000));
        try std.testing.expect(try re.match(std.testing.allocator, "abcdef", 10000));
    }
}

// Anchored exact-count quantifier on a char class (mirrors tests/accept.zig).
test "ASR-003: anchored exact count char class" {
    var re = try Regex.compile("^[A-Z]{3}$", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match(std.testing.allocator, "ABC", 10000));
    try std.testing.expect(!try re.match(std.testing.allocator, "ab", 10000));
    try std.testing.expect(!try re.match(std.testing.allocator, "ABCD", 10000));
}

// ASR-019: enormous numeric bounds must not overflow usize arithmetic; they are
// rejected as too large rather than wrapping to a small value.
test "ASR-019: bounded quantifier bound overflow is rejected" {
    try std.testing.expectError(error.PatternTooLarge, Regex.compile("a{999999999999999999999}", std.testing.allocator));
    try std.testing.expectError(error.PatternTooLarge, Regex.compile("a{1,999999999999999999999}", std.testing.allocator));
}

// ASR-020 / GAP-001 / QUAL-026: grouping and alternation must NOT silently
// compile to the wrong program. The previous behaviour turned `(foo|bar)` into
// `fobar` and `^(admin|user)$` into an allow-anything matcher. They must now
// fail closed with a hard compile error.
test "ASR-020: groups and alternation are rejected, not silently dropped" {
    try std.testing.expectError(error.UnsupportedPattern, Regex.compile("(foo|bar)", std.testing.allocator));
    try std.testing.expectError(error.UnsupportedPattern, Regex.compile("a|b", std.testing.allocator));
    try std.testing.expectError(error.UnsupportedPattern, Regex.compile("^(admin|user)$", std.testing.allocator));
    try std.testing.expectError(error.UnsupportedPattern, Regex.compile("(abc)", std.testing.allocator));
}

// GAP-004: \s must include form feed (\f, 0x0C) and vertical tab (\v, 0x0B) in
// addition to space, tab, LF and CR; \S is its complement.
test "GAP-004: whitespace class includes form feed and vertical tab" {
    var re = try Regex.compile("^\\s$", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match(std.testing.allocator, " ", 10000));
    try std.testing.expect(try re.match(std.testing.allocator, "\t", 10000));
    try std.testing.expect(try re.match(std.testing.allocator, "\n", 10000));
    try std.testing.expect(try re.match(std.testing.allocator, "\r", 10000));
    try std.testing.expect(try re.match(std.testing.allocator, "\x0C", 10000)); // form feed
    try std.testing.expect(try re.match(std.testing.allocator, "\x0B", 10000)); // vertical tab
    try std.testing.expect(!try re.match(std.testing.allocator, "a", 10000));

    var neg = try Regex.compile("^\\S$", std.testing.allocator);
    defer neg.deinit(std.testing.allocator);
    try std.testing.expect(try neg.match(std.testing.allocator, "a", 10000));
    try std.testing.expect(!try neg.match(std.testing.allocator, " ", 10000));
    try std.testing.expect(!try neg.match(std.testing.allocator, "\x0C", 10000));
    try std.testing.expect(!try neg.match(std.testing.allocator, "\x0B", 10000));
}

// \f and \v escapes map to form feed / vertical tab literals.
test "GAP-004: form-feed and vertical-tab escapes" {
    var re = try Regex.compile("a\\fb\\vc", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match(std.testing.allocator, "a\x0Cb\x0Bc", 10000));
    try std.testing.expect(!try re.match(std.testing.allocator, "afbvc", 10000));
}

// Exercise the bounded-quantifier loop semantics end-to-end with the literal
// path (no char-class allocation) so the split/jump wiring is validated too.
test "bounded quantifier loop semantics on literals" {
    {
        var re = try Regex.compile("^a{2,4}$", std.testing.allocator);
        defer re.deinit(std.testing.allocator);
        try std.testing.expect(!try re.match(std.testing.allocator, "a", 10000));
        try std.testing.expect(try re.match(std.testing.allocator, "aa", 10000));
        try std.testing.expect(try re.match(std.testing.allocator, "aaa", 10000));
        try std.testing.expect(try re.match(std.testing.allocator, "aaaa", 10000));
        try std.testing.expect(!try re.match(std.testing.allocator, "aaaaa", 10000));
    }
    {
        var re = try Regex.compile("^a{3}$", std.testing.allocator);
        defer re.deinit(std.testing.allocator);
        try std.testing.expect(!try re.match(std.testing.allocator, "aa", 10000));
        try std.testing.expect(try re.match(std.testing.allocator, "aaa", 10000));
        try std.testing.expect(!try re.match(std.testing.allocator, "aaaa", 10000));
    }
    {
        var re = try Regex.compile("^a{0,2}$", std.testing.allocator);
        defer re.deinit(std.testing.allocator);
        try std.testing.expect(try re.match(std.testing.allocator, "", 10000));
        try std.testing.expect(try re.match(std.testing.allocator, "a", 10000));
        try std.testing.expect(try re.match(std.testing.allocator, "aa", 10000));
        try std.testing.expect(!try re.match(std.testing.allocator, "aaa", 10000));
    }
}

// PERF-003 / ASR-022: matching against a long input (which drives the
// O(N) start-position loop) must still produce correct results with the
// reused scratch buffers and no per-position reallocation regressions.
test "PERF-003: matcher reuses scratch buffers across start positions" {
    var re = try Regex.compile("abc", std.testing.allocator);
    defer re.deinit(std.testing.allocator);

    var buf: [1024]u8 = undefined;
    @memset(&buf, 'x');
    // No "abc" anywhere -> no match, exercising every start position.
    try std.testing.expect(!try re.match(std.testing.allocator, &buf, 1_000_000));
    // Place "abc" near the end so the unanchored scan must reach it.
    buf[1000] = 'a';
    buf[1001] = 'b';
    buf[1002] = 'c';
    try std.testing.expect(try re.match(std.testing.allocator, &buf, 1_000_000));
}
