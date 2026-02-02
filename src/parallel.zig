// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Parallel JSON operations using spice heartbeat scheduling.
//!
//! Provides parallel processing for batch JSON operations like
//! JSONL parsing, batch validation, and batch unmarshaling.

const std = @import("std");
const build_options = @import("build_options");
const spice = if (build_options.enable_spice) @import("spice") else struct {
    pub const ThreadPool = void;
    pub const Task = void;
    pub fn Future(comptime I: type, comptime O: type) type {
        _ = I;
        _ = O;
        return void;
    }
};

// ============================================================================
// Global Spice Thread Pool
// ============================================================================

var global_pool: if (build_options.enable_spice) ?spice.ThreadPool else void = if (build_options.enable_spice) null else {};
var pool_mutex: std.Thread.Mutex = .{};

pub fn getPool() if (build_options.enable_spice) *spice.ThreadPool else void {
    if (!build_options.enable_spice) return;

    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool == null) {
        global_pool = spice.ThreadPool.init(std.heap.page_allocator);
        global_pool.?.start(.{});
    }
    return &global_pool.?;
}

pub fn deinitPool() void {
    if (!build_options.enable_spice) return;

    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool) |*pool| {
        pool.deinit();
        global_pool = null;
    }
}

// ============================================================================
// Parallel JSONL Line Processing
// ============================================================================

/// Result of parsing a single JSON line
pub const LineResult = struct {
    line_num: usize,
    success: bool,
    error_msg: ?[]const u8 = null,
};

/// Context for parallel line processing
pub const LineProcessContext = struct {
    lines: []const []const u8,
    results: []LineResult,
    start_line: usize,
};

/// Process multiple JSON lines in parallel (for JSONL)
/// Returns number of successfully parsed lines
pub fn parallelProcessLines(
    lines: []const []const u8,
    results: []LineResult,
    comptime processFn: fn ([]const u8) bool,
) usize {
    std.debug.assert(lines.len == results.len);

    if (!build_options.enable_spice or lines.len < 16) {
        var success_count: usize = 0;
        for (lines, 0..) |line, i| {
            const success = processFn(line);
            results[i] = .{ .line_num = i, .success = success };
            if (success) success_count += 1;
        }
        return success_count;
    }

    const pool = getPool();
    return pool.call(usize, ParallelLineTask(processFn).task, LineProcessContext{
        .lines = lines,
        .results = results,
        .start_line = 0,
    });
}

fn ParallelLineTask(comptime processFn: fn ([]const u8) bool) type {
    return struct {
        pub fn task(t: *spice.Task, ctx: LineProcessContext) usize {
            const lines = ctx.lines;
            const results = ctx.results;
            const start_line = ctx.start_line;

            if (lines.len < 8) {
                var success_count: usize = 0;
                for (lines, 0..) |line, i| {
                    const success = processFn(line);
                    results[i] = .{ .line_num = start_line + i, .success = success };
                    if (success) success_count += 1;
                }
                return success_count;
            }

            const mid = lines.len / 2;
            const left_ctx = LineProcessContext{
                .lines = lines[0..mid],
                .results = results[0..mid],
                .start_line = start_line,
            };
            const right_ctx = LineProcessContext{
                .lines = lines[mid..],
                .results = results[mid..],
                .start_line = start_line + mid,
            };

            var fut = spice.Future(LineProcessContext, usize).init();
            fut.fork(t, task, right_ctx);

            const left_count = t.call(usize, task, left_ctx);
            const right_count = if (fut.join(t)) |val| val else t.call(usize, task, right_ctx);

            return left_count + right_count;
        }
    };
}

// ============================================================================
// Parallel Array Element Processing
// ============================================================================

/// Context for parallel array processing
pub fn ArrayProcessContext(comptime T: type) type {
    return struct {
        elements: []const T,
        results: []bool,
    };
}

/// Process array elements in parallel with a predicate
pub fn parallelArrayProcess(
    comptime T: type,
    elements: []const T,
    results: []bool,
    comptime predicate: fn (T) bool,
) usize {
    std.debug.assert(elements.len == results.len);

    if (!build_options.enable_spice or elements.len < 32) {
        var count: usize = 0;
        for (elements, 0..) |elem, i| {
            results[i] = predicate(elem);
            if (results[i]) count += 1;
        }
        return count;
    }

    const pool = getPool();
    const Ctx = ArrayProcessContext(T);
    return pool.call(usize, ParallelArrayTask(T, predicate).task, Ctx{
        .elements = elements,
        .results = results,
    });
}

fn ParallelArrayTask(comptime T: type, comptime predicate: fn (T) bool) type {
    const Ctx = ArrayProcessContext(T);
    return struct {
        pub fn task(t: *spice.Task, ctx: Ctx) usize {
            const elements = ctx.elements;
            const results = ctx.results;

            if (elements.len < 16) {
                var count: usize = 0;
                for (elements, 0..) |elem, i| {
                    results[i] = predicate(elem);
                    if (results[i]) count += 1;
                }
                return count;
            }

            const mid = elements.len / 2;
            const left_ctx = Ctx{ .elements = elements[0..mid], .results = results[0..mid] };
            const right_ctx = Ctx{ .elements = elements[mid..], .results = results[mid..] };

            var fut = spice.Future(Ctx, usize).init();
            fut.fork(t, task, right_ctx);

            const left_count = t.call(usize, task, left_ctx);
            const right_count = if (fut.join(t)) |val| val else t.call(usize, task, right_ctx);

            return left_count + right_count;
        }
    };
}

// ============================================================================
// Parallel Reduce for JSON Arrays
// ============================================================================

/// Parallel reduce over numeric array
pub fn parallelSum(comptime T: type, data: []const T) T {
    if (!build_options.enable_spice or data.len < 1024) {
        var sum: T = 0;
        for (data) |v| sum += v;
        return sum;
    }

    const pool = getPool();
    return pool.call(T, ParallelSumTask(T).task, data);
}

fn ParallelSumTask(comptime T: type) type {
    return struct {
        pub fn task(t: *spice.Task, data: []const T) T {
            if (data.len < 512) {
                var sum: T = 0;
                for (data) |v| sum += v;
                return sum;
            }

            const mid = data.len / 2;
            const left = data[0..mid];
            const right = data[mid..];

            var fut = spice.Future([]const T, T).init();
            fut.fork(t, task, right);

            const left_sum = t.call(T, task, left);
            const right_sum = if (fut.join(t)) |val| val else t.call(T, task, right);

            return left_sum + right_sum;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "parallel sum" {
    if (!build_options.enable_spice) return error.SkipZigTest;

    const data = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const sum = parallelSum(i64, &data);
    try std.testing.expectEqual(@as(i64, 55), sum);
}

test "parallel array process" {
    if (!build_options.enable_spice) return error.SkipZigTest;

    const elements = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var results: [10]bool = undefined;

    const count = parallelArrayProcess(i32, &elements, &results, struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);

    try std.testing.expectEqual(@as(usize, 5), count);
}
