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
        const pattern_copy = try a.dupe(u8, pattern);
        errdefer a.free(pattern_copy);
        return .{
            .pattern = pattern_copy,
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

/// Upper bound on bounded-repetition expansion (`{n}`, `{n,m}`, `{n,}`).
///
/// Without this cap a pattern such as `"a{1000000000}"` would expand to ~10^9
/// `Instruction` structs (~40 GB) at compile time — a trivial OOM/DoS vector
/// whenever a pattern is attacker-supplied (SEC-0005). Repetitions exceeding
/// this bound are rejected with `error.InvalidPattern`. The value matches the
/// pre-existing implicit `{n,}` ceiling so behavior is backwards-compatible.
const max_repeat: usize = 1000;

/// Hard ceiling on the total number of compiled `Instruction`s in a program
/// (SEC-0025). `max_repeat` caps each individual `{n}` quantifier, but nested
/// bounded quantifiers (and the group support added in the cycle-1 rewrite)
/// multiply at *compile* time: `((a{1000}){1000}){1000}` (~25 bytes) would
/// otherwise expand to ~10^9 instructions (~40 GB) before any match runs. This
/// ceiling is enforced *during* expansion (in `Frag.concat`, which every
/// fragment merge funnels through, plus a final guard in `compilePattern`) so
/// the multiplication is caught early — after at most ~2x this bound of
/// transient allocation — and rejected with `error.InvalidPattern`. The value
/// is generous enough for any realistic schema `pattern` while making the DoS
/// vector cheap to reject.
const max_program_insts: usize = 100_000;

/// Maximum recursion depth of the recursive-descent parser, counted in nested
/// groups (SEC-0027). `parseAtom` recurses into `parseAlternation` for each
/// `(`; without a bound a pattern such as `"(" ** 100000` overflows the native
/// stack at compile time. Patterns nesting groups beyond this depth are
/// rejected with `error.InvalidPattern`. Mirrors the parser's structural
/// `max_depth` convention.
const max_parse_depth: usize = 256;

/// A fragment of compiled instructions whose `split`/`jump` targets are
/// expressed as absolute indices *within the fragment itself* (0-based). When
/// fragments are concatenated, jump targets are rebased by the destination
/// offset so the final program uses absolute program counters — exactly the
/// layout `executeMatch`/`addState` already expect.
const Frag = struct {
    items: std.ArrayList(Instruction) = .empty,

    fn deinit(self: *Frag, a: std.mem.Allocator) void {
        for (self.items.items) |inst| {
            if (inst.ranges) |r| a.free(r);
        }
        self.items.deinit(a);
    }

    /// Number of instructions in the fragment as a `u32` (the width of jump and
    /// split targets). QUAL-0040: a checked conversion instead of a bare
    /// `@intCast`, so an over-wide fragment returns `error.InvalidPattern`
    /// rather than panicking. In practice the `max_program_insts` ceiling
    /// rejects long before `u32` could overflow, so the error path is defensive.
    fn len(self: *const Frag) ParseError!u32 {
        return std.math.cast(u32, self.items.items.len) orelse error.InvalidPattern;
    }

    /// Append a copy of `inst`. Caller retains ownership of any `ranges` — this
    /// is only used for jump/split/anchor/match instructions which never own
    /// allocations.
    fn append(self: *Frag, a: std.mem.Allocator, inst: Instruction) !void {
        try self.items.append(a, inst);
    }

    /// Append `other`'s instructions, rebasing its internal jump targets by the
    /// current length of `self`. `other` is consumed (its backing storage is
    /// freed) but the per-instruction `ranges` allocations are transferred, not
    /// freed, so ownership moves into `self`.
    ///
    /// Exception-safety (QUAL-0035): the `ranges` pointer of each instruction is
    /// nulled in `other` as soon as ownership is handed to `self`, and an
    /// `errdefer` reclaims whatever remains in `other` on any failure — so a
    /// mid-append OOM neither leaks the untransferred fragment nor double-frees
    /// the transferred `ranges`. `other` is always left empty once consumed.
    ///
    /// SEC-0025: every fragment merge funnels through here, so this is also the
    /// choke point where the global program-size ceiling is enforced — caught
    /// after each merge before nested bounded quantifiers can multiply away.
    fn concat(self: *Frag, a: std.mem.Allocator, other: *Frag) ParseError!void {
        errdefer {
            other.deinit(a);
            other.* = .{};
        }
        const base: u32 = try self.len();
        var i: usize = 0;
        while (i < other.items.items.len) : (i += 1) {
            var copy = other.items.items[i];
            switch (copy.op) {
                .split => {
                    copy.x += base;
                    copy.y += base;
                },
                .jump => copy.x += base,
                else => {},
            }
            try self.items.append(a, copy);
            // Ownership of any `ranges` now belongs to `self`; clear it in
            // `other` so the errdefer cannot double-free it.
            other.items.items[i].ranges = null;
        }
        other.items.deinit(a);
        other.* = .{};
        if (self.items.items.len > max_program_insts) return error.InvalidPattern;
    }
};

/// Explicit error set for the recursive-descent parser. An explicit set is
/// required because `parseAtom` -> `parseAlternation` -> ... -> `parseAtom`
/// form a recursion cycle, and inferred error sets cannot resolve a cycle.
const ParseError = error{ InvalidPattern, OutOfMemory };

const Parser = struct {
    pattern: []const u8,
    pos: usize = 0,
    a: std.mem.Allocator,
    /// Current group-nesting recursion depth (SEC-0027). Incremented for each
    /// `(` entered in `parseAtom`; bounded by `max_parse_depth`.
    depth: usize = 0,

    fn peek(self: *const Parser) ?u8 {
        if (self.pos >= self.pattern.len) return null;
        return self.pattern[self.pos];
    }

    /// alternation := concat ( '|' concat )*
    ///
    /// `a|b` compiles to:
    ///   split(L_a, L_b)
    ///   L_a: <a>; jump(End)
    ///   L_b: <b>
    ///   End:
    fn parseAlternation(self: *Parser) ParseError!Frag {
        var first = try self.parseConcat();
        errdefer first.deinit(self.a);

        if (self.peek() != '|') return first;

        // Collect all branches left-to-right.
        var branches: std.ArrayList(Frag) = .empty;
        errdefer {
            for (branches.items) |*b| b.deinit(self.a);
            branches.deinit(self.a);
        }
        try branches.append(self.a, first);
        first = .{}; // ownership moved into branches

        while (self.peek() == '|') {
            self.pos += 1; // consume '|'
            var branch = try self.parseConcat();
            errdefer branch.deinit(self.a);
            try branches.append(self.a, branch);
        }

        // Build right-to-left so the "End" target of each branch's jump is
        // known (it is one past the end of the fragment being assembled).
        //
        // Final layout for branches b0..b(N-1):
        //   split(1, acc_start)      ; try b0, else fall through to b1..
        //   b0 ...
        //   jump(End)
        //   <acc>                    ; recursively-built split chain for b1..
        //   ...
        //   b(N-1) ...               ; last branch needs no split/jump
        //   End:
        var acc: Frag = branches.items[branches.items.len - 1];
        branches.items[branches.items.len - 1] = .{};
        // QUAL-0035: `acc` is moved out of `branches` (its slot zeroed), so the
        // `branches` errdefer no longer covers it; guard it explicitly. Once a
        // `concat` consumes `acc` it is left empty, making this a safe no-op.
        errdefer acc.deinit(self.a);

        var idx: usize = branches.items.len - 1;
        while (idx > 0) {
            idx -= 1;
            var branch = branches.items[idx];
            branches.items[idx] = .{};
            // QUAL-0035: same reasoning as `acc` — `branch` is moved out and
            // must be reclaimed if any `combined` append/concat below OOMs.
            errdefer branch.deinit(self.a);

            var combined: Frag = .{};
            errdefer combined.deinit(self.a);

            const branch_len = try branch.len();
            // After split(1) + branch(branch_len) + jump(1) comes `acc`.
            const acc_start: u32 = 1 + branch_len + 1;
            try combined.append(self.a, .{ .op = .split, .x = 1, .y = acc_start });
            try combined.concat(self.a, &branch);
            const jump_idx = try combined.len();
            try combined.append(self.a, .{ .op = .jump, .x = 0 }); // patched below
            try combined.concat(self.a, &acc);
            // End == one past the end of the fully assembled fragment.
            combined.items.items[jump_idx].x = try combined.len();
            acc = combined;
        }

        branches.deinit(self.a);
        return acc;
    }

    /// concat := ( quantified )*
    fn parseConcat(self: *Parser) ParseError!Frag {
        var frag: Frag = .{};
        errdefer frag.deinit(self.a);

        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            var atom = try self.parseQuantified();
            errdefer atom.deinit(self.a);
            try frag.concat(self.a, &atom);
        }
        return frag;
    }

    /// quantified := atom ( '*' | '+' | '?' | '{' n[,m] '}' )? '?'?
    fn parseQuantified(self: *Parser) ParseError!Frag {
        var atom = try self.parseAtom();
        errdefer atom.deinit(self.a);

        const q = self.peek() orelse return atom;
        switch (q) {
            '*' => {
                self.pos += 1;
                self.skipNonGreedy();
                return try self.applyStar(&atom);
            },
            '+' => {
                self.pos += 1;
                self.skipNonGreedy();
                return try self.applyPlus(&atom);
            },
            '?' => {
                self.pos += 1;
                self.skipNonGreedy();
                return try self.applyOptional(&atom);
            },
            '{' => return try self.applyBounded(&atom),
            else => return atom,
        }
    }

    fn skipNonGreedy(self: *Parser) void {
        // Non-greedy modifier is accepted but treated as greedy (the NFA reports
        // match/no-match, not leftmost-longest captures), preserving prior
        // behavior.
        if (self.peek() == '?') self.pos += 1;
    }

    /// a* -> split(1, end); a ; jump(0)
    fn applyStar(self: *Parser, atom: *Frag) !Frag {
        var out: Frag = .{};
        errdefer out.deinit(self.a);
        const atom_len = try atom.len();
        try out.append(self.a, .{ .op = .split, .x = 1, .y = 1 + atom_len + 1 });
        try out.concat(self.a, atom);
        try out.append(self.a, .{ .op = .jump, .x = 0 });
        return out;
    }

    /// a+ -> a ; split(0, end)
    fn applyPlus(self: *Parser, atom: *Frag) !Frag {
        var out: Frag = .{};
        errdefer out.deinit(self.a);
        try out.concat(self.a, atom);
        const split_idx = try out.len();
        try out.append(self.a, .{ .op = .split, .x = 0, .y = split_idx + 1 });
        return out;
    }

    /// a? -> split(1, end); a
    fn applyOptional(self: *Parser, atom: *Frag) !Frag {
        var out: Frag = .{};
        errdefer out.deinit(self.a);
        const atom_len = try atom.len();
        try out.append(self.a, .{ .op = .split, .x = 1, .y = 1 + atom_len });
        try out.concat(self.a, atom);
        return out;
    }

    /// a{n} / a{n,m} / a{n,} with a hard cap on n and m (SEC-0005).
    fn applyBounded(self: *Parser, atom: *Frag) !Frag {
        // self.pos is at '{'
        self.pos += 1;
        var min: usize = 0;
        var have_min = false;
        while (self.peek()) |d| {
            if (d < '0' or d > '9') break;
            have_min = true;
            min = std.math.mul(usize, min, 10) catch return error.InvalidPattern;
            min = std.math.add(usize, min, d - '0') catch return error.InvalidPattern;
            if (min > max_repeat) return error.InvalidPattern;
            self.pos += 1;
        }

        var max: usize = min;
        if (self.peek() == ',') {
            self.pos += 1;
            if (self.peek()) |d0| {
                if (d0 >= '0' and d0 <= '9') {
                    max = 0;
                    while (self.peek()) |d| {
                        if (d < '0' or d > '9') break;
                        max = std.math.mul(usize, max, 10) catch return error.InvalidPattern;
                        max = std.math.add(usize, max, d - '0') catch return error.InvalidPattern;
                        if (max > max_repeat) return error.InvalidPattern;
                        self.pos += 1;
                    }
                } else {
                    max = max_repeat; // {n,} -> {n, max_repeat}
                }
            } else {
                max = max_repeat;
            }
        }

        if (self.peek() == '}') {
            self.pos += 1;
        } else {
            return error.InvalidPattern;
        }
        if (!have_min) return error.InvalidPattern;
        if (max < min) return error.InvalidPattern;
        self.skipNonGreedy();

        var out: Frag = .{};
        errdefer out.deinit(self.a);

        // `min` mandatory copies.
        for (0..min) |_| {
            var copy = try self.cloneFrag(atom);
            errdefer copy.deinit(self.a);
            try out.concat(self.a, &copy);
        }

        // `max - min` optional copies: each is split(1, end); <atom>.
        const optional = max - min;
        for (0..optional) |_| {
            var copy = try self.cloneFrag(atom);
            errdefer copy.deinit(self.a);
            var opt = try self.applyOptional(&copy);
            errdefer opt.deinit(self.a);
            try out.concat(self.a, &opt);
        }

        atom.deinit(self.a);
        return out;
    }

    /// Deep-copy a fragment, duplicating any owned `ranges` slices so each copy
    /// can be freed independently.
    fn cloneFrag(self: *Parser, src: *const Frag) !Frag {
        var out: Frag = .{};
        errdefer out.deinit(self.a);
        for (src.items.items) |inst| {
            var copy = inst;
            if (inst.ranges) |r| copy.ranges = try self.a.dupe([2]u8, r);
            try out.items.append(self.a, copy);
        }
        return out;
    }

    /// atom := '(' alternation ')' | '[' class ']' | '\' escape | '.' | '^'
    ///       | '$' | literal
    fn parseAtom(self: *Parser) ParseError!Frag {
        const c = self.peek() orelse return error.InvalidPattern;
        switch (c) {
            '(' => {
                self.pos += 1;
                // SEC-0027: bound group-nesting recursion so a deeply nested
                // `(((…)))` pattern cannot overflow the native stack at compile
                // time. Checked *before* recursing into `parseAlternation`.
                if (self.depth >= max_parse_depth) return error.InvalidPattern;
                self.depth += 1;
                defer self.depth -= 1;
                // Support (?:...) non-capturing prefix; capture groups are
                // treated as non-capturing (no capture extraction) which is all
                // `pattern`/`patternProperties` validation needs.
                if (self.peek() == '?') {
                    self.pos += 1;
                    if (self.peek() == ':') {
                        self.pos += 1;
                    } else {
                        // Unsupported group flag (lookahead/named); reject.
                        return error.InvalidPattern;
                    }
                }
                var inner = try self.parseAlternation();
                errdefer inner.deinit(self.a);
                if (self.peek() != ')') return error.InvalidPattern;
                self.pos += 1;
                return inner;
            },
            ')' => return error.InvalidPattern,
            '^' => {
                self.pos += 1;
                var f: Frag = .{};
                errdefer f.deinit(self.a);
                try f.append(self.a, .{ .op = .anchor_start });
                return f;
            },
            '$' => {
                self.pos += 1;
                var f: Frag = .{};
                errdefer f.deinit(self.a);
                try f.append(self.a, .{ .op = .anchor_end });
                return f;
            },
            '.' => {
                self.pos += 1;
                var f: Frag = .{};
                errdefer f.deinit(self.a);
                try f.append(self.a, .{ .op = .any_char });
                return f;
            },
            '[' => return try self.parseCharClass(),
            '\\' => return try self.parseEscape(),
            '*', '+', '?' => return error.InvalidPattern, // quantifier with no atom
            '{' => {
                // A '{' that does not follow an atom is a literal brace.
                self.pos += 1;
                var f: Frag = .{};
                errdefer f.deinit(self.a);
                try f.append(self.a, .{ .op = .literal, .c = '{' });
                return f;
            },
            else => {
                self.pos += 1;
                var f: Frag = .{};
                errdefer f.deinit(self.a);
                try f.append(self.a, .{ .op = .literal, .c = c });
                return f;
            },
        }
    }

    fn parseCharClass(self: *Parser) !Frag {
        self.pos += 1; // consume '['
        var negated = false;
        if (self.peek() == '^') {
            negated = true;
            self.pos += 1;
        }

        var ranges: std.ArrayList([2]u8) = .empty;
        errdefer ranges.deinit(self.a);

        while (self.peek()) |ch| {
            if (ch == ']') break;
            const start = ch;
            self.pos += 1;

            if (self.pos + 1 < self.pattern.len and self.pattern[self.pos] == '-' and self.pattern[self.pos + 1] != ']') {
                self.pos += 1;
                const end = self.pattern[self.pos];
                self.pos += 1;
                try ranges.append(self.a, .{ start, end });
            } else {
                try ranges.append(self.a, .{ start, start });
            }
        }

        if (self.peek() == ']') self.pos += 1;

        var f: Frag = .{};
        errdefer f.deinit(self.a);
        try f.items.append(self.a, .{
            .op = if (negated) .neg_char_class else .char_class,
            .ranges = try ranges.toOwnedSlice(self.a),
        });
        return f;
    }

    fn parseEscape(self: *Parser) !Frag {
        self.pos += 1; // consume '\'
        const escaped = self.peek() orelse return error.InvalidPattern;
        self.pos += 1;

        var f: Frag = .{};
        errdefer f.deinit(self.a);

        switch (escaped) {
            'd' => try f.items.append(self.a, .{
                .op = .char_class,
                .ranges = try self.a.dupe([2]u8, &[_][2]u8{.{ '0', '9' }}),
            }),
            'D' => try f.items.append(self.a, .{
                .op = .neg_char_class,
                .ranges = try self.a.dupe([2]u8, &[_][2]u8{.{ '0', '9' }}),
            }),
            'w' => try f.items.append(self.a, .{
                .op = .char_class,
                .ranges = try self.a.dupe([2]u8, &[_][2]u8{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '0', '9' }, .{ '_', '_' } }),
            }),
            'W' => try f.items.append(self.a, .{
                .op = .neg_char_class,
                .ranges = try self.a.dupe([2]u8, &[_][2]u8{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '0', '9' }, .{ '_', '_' } }),
            }),
            's' => try f.items.append(self.a, .{
                .op = .char_class,
                .ranges = try self.a.dupe([2]u8, &[_][2]u8{ .{ ' ', ' ' }, .{ '\t', '\t' }, .{ '\n', '\n' }, .{ '\r', '\r' } }),
            }),
            'S' => try f.items.append(self.a, .{
                .op = .neg_char_class,
                .ranges = try self.a.dupe([2]u8, &[_][2]u8{ .{ ' ', ' ' }, .{ '\t', '\t' }, .{ '\n', '\n' }, .{ '\r', '\r' } }),
            }),
            'n' => try f.items.append(self.a, .{ .op = .literal, .c = '\n' }),
            'r' => try f.items.append(self.a, .{ .op = .literal, .c = '\r' }),
            't' => try f.items.append(self.a, .{ .op = .literal, .c = '\t' }),
            else => try f.items.append(self.a, .{ .op = .literal, .c = escaped }),
        }
        return f;
    }
};

fn compilePattern(pattern: []const u8, a: std.mem.Allocator) !CompiledRegex {
    var parser: Parser = .{ .pattern = pattern, .a = a };
    var frag = try parser.parseAlternation();
    errdefer frag.deinit(a);

    // A leftover ')' (or any unconsumed input) means an unbalanced group.
    if (parser.pos != pattern.len) return error.InvalidPattern;

    // SEC-0025: final guard on total program size. `Frag.concat` enforces the
    // ceiling during every merge; this catches any single-fragment program that
    // never went through a `concat` (and documents the invariant at the seam).
    if (frag.items.items.len > max_program_insts) return error.InvalidPattern;

    try frag.items.append(a, .{ .op = .match_end });

    return .{ .instructions = try frag.items.toOwnedSlice(a) };
}

/// Size of the on-stack scratch buffer `executeMatch` uses for its NFA work
/// lists (PERF-0010). Programs whose scratch fits here are matched with **zero**
/// heap allocations — the schema hot path (short keys/patterns) stays on the
/// stack instead of paying ~5 `page_allocator` (mmap-class) round-trips per
/// `match()` call. Larger programs transparently fall back to `page_allocator`.
const scratch_stack_bytes: usize = 16 * 1024;

/// Worst-case scratch bytes for a program of `n_insts` instructions: two
/// `bool` reachability maps (`n` each) plus three `u32` work lists capped at
/// `2n+2`, `n+1`, `n+1`. Includes slack for `FixedBufferAllocator` alignment
/// padding so the "fits on stack" decision never under-counts.
fn scratchBytes(n_insts: usize) usize {
    return (2 * n_insts) + ((2 * n_insts + 2) + (n_insts + 1) + (n_insts + 1)) * @sizeOf(u32) + 64;
}

/// Single-pass Thompson/Pike NFA matcher (SEC-0008).
///
/// Previously the engine ran a fresh NFA simulation from every start offset,
/// each with its own `max_steps` budget — total work up to `(n+1) * max_steps`.
/// This version scans the input left-to-right exactly once and seeds a fresh
/// start thread at each position (so unanchored patterns still match anywhere),
/// while a *single global* step counter bounds total work across all start
/// positions. Exceeding `max_steps` returns `error.RegexLimit`.
///
/// PERF-0010: scratch is sized once and drawn from an on-stack
/// `FixedBufferAllocator` when it fits (the common short-pattern case), removing
/// the per-call `page_allocator` syscalls entirely; the work lists are reserved
/// to their provable upper bounds so the matcher never reallocates mid-scan.
/// When the program begins with an `anchor_start` the per-byte start re-seed is
/// skipped — for a `^…`-anchored pattern that re-seeded thread always dies at
/// the `anchor_start` guard (`sp != 0`), so skipping it is behavior-preserving
/// while eliminating O(n) dead-thread epsilon closures.
fn executeMatch(compiled: *const CompiledRegex, input: []const u8, max_steps: u32) !bool {
    const n_insts = compiled.instructions.len;

    // Prefer an on-stack arena; fall back to the heap only for large programs.
    var stack_buf: [scratch_stack_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
    const a: std.mem.Allocator = if (scratchBytes(n_insts) <= scratch_stack_bytes)
        fba.allocator()
    else
        std.heap.page_allocator;

    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(a);
    try work.ensureTotalCapacityPrecise(a, 2 * n_insts + 2);

    var in_current = try a.alloc(bool, n_insts);
    defer a.free(in_current);
    var in_next = try a.alloc(bool, n_insts);
    defer a.free(in_next);

    var current: std.ArrayList(u32) = .empty;
    defer current.deinit(a);
    try current.ensureTotalCapacityPrecise(a, n_insts + 1);
    var next: std.ArrayList(u32) = .empty;
    defer next.deinit(a);
    try next.ensureTotalCapacityPrecise(a, n_insts + 1);

    // A `^`-anchored program can only start a thread at position 0, so the
    // per-byte start re-seed is dead work and is skipped (PERF-0010).
    const anchored = n_insts > 0 and compiled.instructions[0].op == .anchor_start;

    // One global budget, shared across every start position.
    var budget = Budget{ .remaining = max_steps };

    @memset(in_current, false);
    // Seed the start thread at position 0.
    try addState(compiled, a, &current, in_current, &work, 0, 0, input.len, &budget);

    var sp: usize = 0;
    while (true) {
        // Any thread parked on match_end is an accept.
        for (current.items) |pc| {
            if (compiled.instructions[pc].op == .match_end) return true;
        }

        if (sp >= input.len) return false;

        next.clearRetainingCapacity();
        @memset(in_next, false);

        const c = input[sp];
        for (current.items) |pc| {
            try budget.spend();
            const inst = compiled.instructions[pc];
            switch (inst.op) {
                .literal => {
                    if (c == inst.c) {
                        try addState(compiled, a, &next, in_next, &work, pc + 1, sp + 1, input.len, &budget);
                    }
                },
                .any_char => {
                    if (c != '\n') {
                        try addState(compiled, a, &next, in_next, &work, pc + 1, sp + 1, input.len, &budget);
                    }
                },
                .char_class => {
                    if (matchCharClass(c, inst.ranges.?)) {
                        try addState(compiled, a, &next, in_next, &work, pc + 1, sp + 1, input.len, &budget);
                    }
                },
                .neg_char_class => {
                    if (!matchCharClass(c, inst.ranges.?)) {
                        try addState(compiled, a, &next, in_next, &work, pc + 1, sp + 1, input.len, &budget);
                    }
                },
                else => {},
            }
        }

        // Seed a fresh start thread at the next position so an unanchored
        // pattern can begin matching at any offset. For `^`-anchored programs
        // this thread always dies at the `anchor_start` guard, so skip it.
        if (!anchored) {
            try addState(compiled, a, &next, in_next, &work, 0, sp + 1, input.len, &budget);
        }

        const tmp_list = current;
        current = next;
        next = tmp_list;
        const tmp_set = in_current;
        in_current = in_next;
        in_next = tmp_set;

        sp += 1;
    }
}

/// Shared, mutable step budget for a single `match()` call.
const Budget = struct {
    remaining: u32,

    fn spend(self: *Budget) !void {
        if (self.remaining == 0) return error.RegexLimit;
        self.remaining -= 1;
    }
};

fn addState(
    compiled: *const CompiledRegex,
    a: std.mem.Allocator,
    list: *std.ArrayList(u32),
    in_list: []bool,
    work: *std.ArrayList(u32),
    pc: u32,
    sp: usize,
    input_len: usize,
    budget: *Budget,
) !void {
    work.clearRetainingCapacity();
    try work.append(a, pc);

    while (work.items.len > 0) {
        // Each epsilon-closure expansion costs one unit of the global budget so
        // that pathological alternation/quantifier nests cannot run unbounded.
        try budget.spend();

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

// ---------------------------------------------------------------------------
// GAP-0002: alternation `|` and grouping `(...)` must work.
// ---------------------------------------------------------------------------

test "regex alternation in group (GAP-0002)" {
    var re = try Regex.compile("^(cat|dog)$", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match("cat", 10000));
    try std.testing.expect(try re.match("dog", 10000));
    try std.testing.expect(!try re.match("cow", 10000));
    try std.testing.expect(!try re.match("catdog", 10000));
}

test "regex multiple groups with alternation (GAP-0002)" {
    var re = try Regex.compile("^(a|b)(c|d)$", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match("ac", 10000));
    try std.testing.expect(try re.match("ad", 10000));
    try std.testing.expect(try re.match("bc", 10000));
    try std.testing.expect(try re.match("bd", 10000));
    try std.testing.expect(!try re.match("aa", 10000));
    try std.testing.expect(!try re.match("a", 10000));
}

test "regex nested groups with quantifier (GAP-0002)" {
    var re = try Regex.compile("^((ab)|(cd))+$", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match("ab", 10000));
    try std.testing.expect(try re.match("cd", 10000));
    try std.testing.expect(try re.match("abcdab", 10000));
    try std.testing.expect(!try re.match("abx", 10000));
    try std.testing.expect(!try re.match("", 10000));
}

test "regex unanchored alternation found in string (GAP-0002)" {
    var re = try Regex.compile("cat|dog", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match("I have a dog", 10000));
    try std.testing.expect(try re.match("the cat sat", 10000));
    try std.testing.expect(!try re.match("I have a fish", 10000));
}

test "regex group quantifier applies to whole group (GAP-0002)" {
    var re = try Regex.compile("^(ab)+$", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match("ab", 10000));
    try std.testing.expect(try re.match("abab", 10000));
    try std.testing.expect(!try re.match("aba", 10000));
    try std.testing.expect(!try re.match("a", 10000));
}

test "regex literal before alternation group (GAP-0002)" {
    var re = try Regex.compile("a(bc|de)f", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match("abcf", 10000));
    try std.testing.expect(try re.match("adef", 10000));
    try std.testing.expect(!try re.match("abf", 10000));
    try std.testing.expect(!try re.match("abcdef", 10000));
}

test "regex non-capturing group prefix (GAP-0002)" {
    var re = try Regex.compile("^(?:cat|dog)s$", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match("cats", 10000));
    try std.testing.expect(try re.match("dogs", 10000));
    try std.testing.expect(!try re.match("cat", 10000));
}

test "regex unbalanced group rejected (GAP-0002)" {
    try std.testing.expectError(error.InvalidPattern, Regex.compile("(ab", std.testing.allocator));
    try std.testing.expectError(error.InvalidPattern, Regex.compile("ab)", std.testing.allocator));
}

test "regex alternation with quantifier inside group (GAP-0002)" {
    var re = try Regex.compile("^(a|b|c){2,3}$", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match("ab", 10000));
    try std.testing.expect(try re.match("abc", 10000));
    try std.testing.expect(!try re.match("a", 10000));
    try std.testing.expect(!try re.match("abca", 10000));
}

// ---------------------------------------------------------------------------
// SEC-0005: bounded repetition {n} / {n,m} must be capped.
// ---------------------------------------------------------------------------

test "regex bounded repetition exact cap (SEC-0005)" {
    try std.testing.expectError(error.InvalidPattern, Regex.compile("a{1000000000}", std.testing.allocator));
    try std.testing.expectError(error.InvalidPattern, Regex.compile("a{0,1000000000}", std.testing.allocator));
}

test "regex bounded repetition exact still works (SEC-0005)" {
    var re = try Regex.compile("a{5}", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match("aaaaa", 10000));
    try std.testing.expect(!try re.match("aaaa", 10000));
}

test "regex bounded repetition range still works (SEC-0005)" {
    var re = try Regex.compile("a{2,4}", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match("aa", 10000));
    try std.testing.expect(try re.match("aaaa", 10000));
    try std.testing.expect(!try re.match("a", 10000));
}

// ---------------------------------------------------------------------------
// SEC-0008: step budget is GLOBAL across start positions.
// ---------------------------------------------------------------------------

test "regex global step budget across start positions (SEC-0008)" {
    // An *unanchored* pattern that never matches against a long input. Because
    // it is unanchored, a fresh start thread is legitimately seeded at every
    // offset (this is exactly the "across start positions" the budget must
    // bound). With a per-start budget the total work would be ~ (n+1) *
    // max_steps and each restart would return false; with a single global
    // budget the total work is bounded by max_steps, so a small budget is
    // exhausted across the start positions and surfaces error.RegexLimit.
    //
    // NB: an anchored `^zzzzz$` would (correctly) return `false` here — its
    // per-byte re-seed is dead work and is skipped (PERF-0010), so it consumes
    // no budget past position 0. The global-budget guarantee is what this test
    // pins, and it is the unanchored case that exercises multiple start threads.
    var re = try Regex.compile("zzzzz", std.testing.allocator);
    defer re.deinit(std.testing.allocator);

    var buf: [10000]u8 = undefined;
    @memset(&buf, 'a');

    // A budget far smaller than the input length: a per-start design would
    // restart the budget at every offset and still return false; a global
    // budget is consumed once and surfaces error.RegexLimit.
    try std.testing.expectError(error.RegexLimit, re.match(&buf, 100));
}

test "regex global budget allows short matches (SEC-0008)" {
    // A genuinely matching short input must still succeed under a modest budget.
    var re = try Regex.compile("^a+$", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match("aaa", 10000));
}

// ---------------------------------------------------------------------------
// SEC-0025: nested bounded quantifiers must not multiply into a giant program.
// A total-instruction ceiling rejects the multiplication early, in O(1) memory.
// ---------------------------------------------------------------------------

test "regex nested bounded quantifier total cap (SEC-0025)" {
    // ((a{1000}){1000}){1000} would expand to ~10^9 instructions without a
    // global ceiling. It must be rejected quickly (the second nesting level
    // already exceeds max_program_insts) without a giant allocation.
    try std.testing.expectError(
        error.InvalidPattern,
        Regex.compile("(((a{1000}){1000}){1000})", std.testing.allocator),
    );
    // Two-level amplifier is rejected too.
    try std.testing.expectError(
        error.InvalidPattern,
        Regex.compile("((a{1000}){1000})", std.testing.allocator),
    );
}

test "regex bounded nesting within cap still compiles and matches (SEC-0025)" {
    // (a{50}){50} = 2500 instructions, comfortably under the ceiling. Anchored
    // so the match is a single O(n) literal chain (an unanchored all-`a` input
    // would seed O(n) parallel start threads — O(n^2) work — which is a property
    // of the matcher, not of the compile-time ceiling this test pins).
    {
        var re = try Regex.compile("^(a{50}){50}$", std.testing.allocator);
        defer re.deinit(std.testing.allocator);
        var buf: [2500]u8 = undefined;
        @memset(&buf, 'a');
        try std.testing.expect(try re.match(&buf, 1_000_000));
        try std.testing.expect(!try re.match("a", 1_000_000));
    }
    // Plain a{5} is unaffected by the ceiling.
    {
        var re = try Regex.compile("a{5}", std.testing.allocator);
        defer re.deinit(std.testing.allocator);
        try std.testing.expect(try re.match("aaaaa", 10000));
        try std.testing.expect(!try re.match("aaaa", 10000));
    }
    // A quantified alternation group still compiles and matches.
    {
        var re = try Regex.compile("^(ab|cd){3}$", std.testing.allocator);
        defer re.deinit(std.testing.allocator);
        try std.testing.expect(try re.match("ababab", 10000));
        try std.testing.expect(try re.match("abcdab", 10000));
        try std.testing.expect(try re.match("cdcdcd", 10000));
        try std.testing.expect(!try re.match("abab", 10000));
        try std.testing.expect(!try re.match("ab", 10000));
    }
}

// ---------------------------------------------------------------------------
// SEC-0027: the recursive-descent parser must bound group-nesting depth so a
// deeply nested pattern returns error.InvalidPattern instead of crashing.
// ---------------------------------------------------------------------------

test "regex deep group nesting rejected (SEC-0027)" {
    const a = std.testing.allocator;
    const n = 100_000;
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(a);
    try pattern.appendNTimes(a, '(', n);
    try pattern.append(a, 'a');
    try pattern.appendNTimes(a, ')', n);
    try std.testing.expectError(error.InvalidPattern, Regex.compile(pattern.items, a));
}

test "regex modest group nesting still compiles (SEC-0027)" {
    // Nesting within the depth bound must still work.
    var re = try Regex.compile("(((((abc)))))", std.testing.allocator);
    defer re.deinit(std.testing.allocator);
    try std.testing.expect(try re.match("abc", 10000));
    try std.testing.expect(!try re.match("abx", 10000));
}

// ---------------------------------------------------------------------------
// QUAL-0035: parseAlternation must not leak moved-out fragments on a mid-build
// OOM. Drive a FailingAllocator across every allocation index and require a
// clean OutOfMemory (or success) with no leaks under the checking allocator.
// ---------------------------------------------------------------------------

test "regex alternation compile is leak-clean under OOM (QUAL-0035)" {
    var fail_index: usize = 0;
    while (fail_index < 256) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const a = failing.allocator();
        if (Regex.compile("a|b|c|de|fg", a)) |re_const| {
            var re = re_const;
            re.deinit(a);
            // Once compilation succeeds for a given budget, larger budgets also
            // succeed — nothing more to probe.
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
        // std.testing.allocator (wrapped by FailingAllocator) panics on leak,
        // so reaching here means the failed compile freed every fragment.
    }
}

// ---------------------------------------------------------------------------
// PERF-0010 regression guard: the scratch-reuse + anchored-re-seed-skip changes
// must be exactly behavior-preserving across anchored, unanchored, alternation,
// grouped, and quantified patterns.
// ---------------------------------------------------------------------------

test "regex behavior preserved after scratch/reseed changes (PERF-0010)" {
    const Case = struct {
        pattern: []const u8,
        input: []const u8,
        want: bool,
    };
    const cases = [_]Case{
        // Anchored (start re-seed is skipped).
        .{ .pattern = "^abc$", .input = "abc", .want = true },
        .{ .pattern = "^abc$", .input = "xabc", .want = false },
        .{ .pattern = "^abc$", .input = "abcx", .want = false },
        .{ .pattern = "^[a-z]+$", .input = "hello", .want = true },
        .{ .pattern = "^[a-z]+$", .input = "Hello", .want = false },
        .{ .pattern = "^a+$", .input = "aaaa", .want = true },
        .{ .pattern = "^(cat|dog)$", .input = "dog", .want = true },
        .{ .pattern = "^(cat|dog)$", .input = "cow", .want = false },
        .{ .pattern = "^(ab)+$", .input = "ababab", .want = true },
        .{ .pattern = "^(ab)+$", .input = "aba", .want = false },
        .{ .pattern = "^(a|b|c){2,3}$", .input = "abc", .want = true },
        .{ .pattern = "^(a|b|c){2,3}$", .input = "abca", .want = false },
        // Unanchored (start re-seed stays active).
        .{ .pattern = "abc", .input = "xxabcyy", .want = true },
        .{ .pattern = "abc", .input = "xxabxyy", .want = false },
        .{ .pattern = "cat|dog", .input = "I have a dog", .want = true },
        .{ .pattern = "cat|dog", .input = "I have a fish", .want = false },
        .{ .pattern = "a(bc|de)f", .input = "zzadefzz", .want = true },
        .{ .pattern = "\\d+", .input = "abc123", .want = true },
        .{ .pattern = "\\d+", .input = "abcdef", .want = false },
        // Anchored-at-start only / anchored-at-end only.
        .{ .pattern = "^foo", .input = "foobar", .want = true },
        .{ .pattern = "^foo", .input = "barfoo", .want = false },
        .{ .pattern = "bar$", .input = "foobar", .want = true },
        .{ .pattern = "bar$", .input = "barfoo", .want = false },
        // A program with no instructions but match_end (empty pattern).
        .{ .pattern = "", .input = "anything", .want = true },
    };
    for (cases) |case| {
        var re = try Regex.compile(case.pattern, std.testing.allocator);
        defer re.deinit(std.testing.allocator);
        const got = try re.match(case.input, 100_000);
        std.testing.expectEqual(case.want, got) catch |err| {
            std.debug.print("pattern={s} input={s} want={} got={}\n", .{ case.pattern, case.input, case.want, got });
            return err;
        };
    }
}
