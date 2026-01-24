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
        return .{
            .pattern = try a.dupe(u8, pattern),
            .compiled = try compilePattern(pattern, a),
        };
    }

    pub fn match(self: *const Regex, input: []const u8, max_steps: u32) !bool {
        return try executeMatch(&self.compiled, input, max_steps);
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
                    's' => try instructions.append(a, .{
                        .op = .char_class,
                        .ranges = try a.dupe([2]u8, &[_][2]u8{ .{ ' ', ' ' }, .{ '\t', '\t' }, .{ '\n', '\n' }, .{ '\r', '\r' } }),
                    }),
                    'S' => try instructions.append(a, .{
                        .op = .neg_char_class,
                        .ranges = try a.dupe([2]u8, &[_][2]u8{ .{ ' ', ' ' }, .{ '\t', '\t' }, .{ '\n', '\n' }, .{ '\r', '\r' } }),
                    }),
                    'n' => try instructions.append(a, .{ .op = .literal, .c = '\n' }),
                    'r' => try instructions.append(a, .{ .op = .literal, .c = '\r' }),
                    't' => try instructions.append(a, .{ .op = .literal, .c = '\t' }),
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
                // Bounded repetition {n} or {n,m}
                if (instructions.items.len == 0) return error.InvalidPattern;

                i += 1;
                var min: usize = 0;
                var max: usize = 0;

                // Parse min
                while (i < pattern.len and pattern[i] >= '0' and pattern[i] <= '9') {
                    min = min * 10 + (pattern[i] - '0');
                    i += 1;
                }

                if (i < pattern.len and pattern[i] == ',') {
                    i += 1;
                    // Parse max (if present)
                    if (i < pattern.len and pattern[i] >= '0' and pattern[i] <= '9') {
                        while (i < pattern.len and pattern[i] >= '0' and pattern[i] <= '9') {
                            max = max * 10 + (pattern[i] - '0');
                            i += 1;
                        }
                    } else {
                        max = 1000; // Treat {n,} as {n,1000}
                    }
                } else {
                    max = min; // {n} means exactly n
                }

                if (i < pattern.len and pattern[i] == '}') {
                    i += 1;
                }

                // Apply quantifier: repeat last instruction min to max times
                const last_inst = instructions.items[instructions.items.len - 1];
                _ = instructions.pop();

                // Add min required copies
                for (0..min) |_| {
                    try instructions.append(a, last_inst);
                }

                // Add optional copies for (max - min)
                const optional_count = max -| min;
                for (0..optional_count) |_| {
                    const split_idx: u32 = @intCast(instructions.items.len);
                    try instructions.append(a, .{ .op = .split, .x = split_idx + 1, .y = split_idx + 2 });
                    try instructions.append(a, last_inst);
                }

                // Handle non-greedy modifier
                if (i < pattern.len and pattern[i] == '?') i += 1;
            },
            '|' => {
                // Alternation - simplified handling
                i += 1;
            },
            '(', ')' => {
                // Groups - simplified handling
                i += 1;
            },
            else => {
                try instructions.append(a, .{ .op = .literal, .c = c });
                i += 1;
            },
        }
    }

    try instructions.append(a, .{ .op = .match_end });

    return .{ .instructions = try instructions.toOwnedSlice(a) };
}

fn executeMatch(compiled: *const CompiledRegex, input: []const u8, max_steps: u32) !bool {
    // Try matching at each position
    for (0..input.len + 1) |start| {
        if (try runNFA(compiled, input, start, max_steps)) return true;
    }
    return false;
}

fn runNFA(compiled: *const CompiledRegex, input: []const u8, start: usize, max_steps: u32) !bool {
    const a = std.heap.page_allocator;

    // Use a work list for processing epsilon transitions
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(a);

    // Track which PCs are in current/next set to avoid duplicates
    var in_current = try a.alloc(bool, compiled.instructions.len);
    defer a.free(in_current);
    var in_next = try a.alloc(bool, compiled.instructions.len);
    defer a.free(in_next);

    var current: std.ArrayList(u32) = .empty;
    defer current.deinit(a);
    var next: std.ArrayList(u32) = .empty;
    defer next.deinit(a);

    var steps: u32 = 0;
    var sp: usize = start;

    // Initialize with epsilon closure from state 0
    @memset(in_current, false);
    @memset(in_next, false);
    try addState(compiled, &current, in_current, &work, 0, sp, input.len);

    while (current.items.len > 0) {
        if (steps >= max_steps) return error.RegexLimit;
        steps += 1;

        // Check for match in current states
        for (current.items) |pc| {
            if (compiled.instructions[pc].op == .match_end) return true;
        }

        // If at end of input, check for match one more time (already done above)
        if (sp >= input.len) {
            break;
        }

        // Process character transitions
        next.clearRetainingCapacity();
        @memset(in_next, false);

        const c = input[sp];
        for (current.items) |pc| {
            const inst = compiled.instructions[pc];
            switch (inst.op) {
                .literal => {
                    if (c == inst.c) {
                        try addState(compiled, &next, in_next, &work, pc + 1, sp + 1, input.len);
                    }
                },
                .any_char => {
                    if (c != '\n') {
                        try addState(compiled, &next, in_next, &work, pc + 1, sp + 1, input.len);
                    }
                },
                .char_class => {
                    if (matchCharClass(c, inst.ranges.?)) {
                        try addState(compiled, &next, in_next, &work, pc + 1, sp + 1, input.len);
                    }
                },
                .neg_char_class => {
                    if (!matchCharClass(c, inst.ranges.?)) {
                        try addState(compiled, &next, in_next, &work, pc + 1, sp + 1, input.len);
                    }
                },
                else => {},
            }
        }

        // Swap current and next
        const tmp_list = current;
        current = next;
        next = tmp_list;
        const tmp_set = in_current;
        in_current = in_next;
        in_next = tmp_set;

        sp += 1;
    }

    return false;
}

fn addState(
    compiled: *const CompiledRegex,
    list: *std.ArrayList(u32),
    in_list: []bool,
    work: *std.ArrayList(u32),
    pc: u32,
    sp: usize,
    input_len: usize,
) !void {
    const a = std.heap.page_allocator;

    work.clearRetainingCapacity();
    try work.append(a, pc);

    while (work.items.len > 0) {
        const cur_pc = work.items[work.items.len - 1];
        work.items.len -= 1;
        if (cur_pc >= compiled.instructions.len) continue;
        if (in_list[cur_pc]) continue;
        in_list[cur_pc] = true;

        const inst = compiled.instructions[cur_pc];
        switch (inst.op) {
            .split => {
                try work.append(a, inst.x);
                try work.append(a, inst.y);
            },
            .jump => {
                try work.append(a, inst.x);
            },
            .anchor_start => {
                if (sp == 0) {
                    try work.append(a, cur_pc + 1);
                }
            },
            .anchor_end => {
                if (sp == input_len) {
                    try work.append(a, cur_pc + 1);
                }
            },
            else => {
                try list.append(a, cur_pc);
            },
        }
    }
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
    try std.testing.expect(try re.match("abc", 10000));
    try std.testing.expect(try re.match("xabcy", 10000));
    try std.testing.expect(!try re.match("ab", 10000));
}

test "regex anchor" {
    var re = try Regex.compile("^abc$", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match("abc", 10000));
    try std.testing.expect(!try re.match("xabc", 10000));
    try std.testing.expect(!try re.match("abcx", 10000));
}

test "regex char class" {
    var re = try Regex.compile("[a-z]+", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match("abc", 10000));
    try std.testing.expect(!try re.match("123", 10000));
}

test "regex negated class" {
    var re = try Regex.compile("[^0-9]+", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match("abc", 10000));
}

test "regex quantifier star" {
    var re = try Regex.compile("a*", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match("", 10000));
    try std.testing.expect(try re.match("a", 10000));
    try std.testing.expect(try re.match("aaa", 10000));
}

test "regex quantifier plus" {
    var re = try Regex.compile("a+", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(!try re.match("", 10000));
    try std.testing.expect(try re.match("a", 10000));
    try std.testing.expect(try re.match("aaa", 10000));
}

test "regex quantifier question" {
    var re = try Regex.compile("a?b", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match("b", 10000));
    try std.testing.expect(try re.match("ab", 10000));
}

test "regex digit class" {
    var re = try Regex.compile("\\d+", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match("123", 10000));
    try std.testing.expect(!try re.match("abc", 10000));
}

test "regex email pattern" {
    var re = try Regex.compile("^[a-zA-Z0-9]+@[a-zA-Z0-9]+\\.[a-zA-Z]+$", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match("test@example.com", 10000));
    try std.testing.expect(!try re.match("invalid", 10000));
}
