// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Parallel JSON operations using thread-pool flat submission.
//!
//! Provides parallel processing for batch JSON operations like
//! JSONL parsing, batch validation, and batch unmarshaling.

const std = @import("std");
const tp = @import("thread_pool");

// ============================================================================
// Global Thread Pool
// ============================================================================

var global_pool: ?tp.ThreadPool = null;
var pool_mutex: tp.sync.Mutex = .{};

pub fn getPool() *tp.ThreadPool {
    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool == null) {
        global_pool = tp.ThreadPool.init(std.heap.page_allocator, .{}) catch @panic("thread-pool: init failed");
    }
    return &global_pool.?;
}

pub fn deinitPool() void {
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

const MAX_CHUNKS = 64;

/// Chunk context for parallel line processing
const LineChunk = struct {
    lines: []const []const u8,
    results: []LineResult,
    start_line: usize,
    process_fn: *const fn ([]const u8) bool,
};

fn lineChunkTask(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
    const chunk: *LineChunk = @ptrCast(@alignCast(ctx_ptr));
    for (chunk.lines, 0..) |line, i| {
        const success = chunk.process_fn(line);
        chunk.results[i] = .{ .line_num = chunk.start_line + i, .success = success };
    }
}

/// Process multiple JSON lines in parallel (for JSONL).
/// Returns number of successfully parsed lines.
pub fn parallelProcessLines(
    lines: []const []const u8,
    results: []LineResult,
    comptime processFn: fn ([]const u8) bool,
) usize {
    std.debug.assert(lines.len == results.len);

    const THRESHOLD = 16;
    if (lines.len < THRESHOLD) {
        var success_count: usize = 0;
        for (lines, 0..) |line, i| {
            const success = processFn(line);
            results[i] = .{ .line_num = i, .success = success };
            if (success) success_count += 1;
        }
        return success_count;
    }

    const pool = getPool();
    const chunk_size = @max(THRESHOLD, lines.len / MAX_CHUNKS);

    // Wrap processFn in a type-erased function pointer
    const Wrapper = struct {
        fn call(line: []const u8) bool {
            return processFn(line);
        }
    };

    var chunks: [MAX_CHUNKS]LineChunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < lines.len and n < MAX_CHUNKS) {
        const end = @min(i + chunk_size, lines.len);
        chunks[n] = .{
            .lines = lines[i..end],
            .results = results[i..end],
            .start_line = i,
            .process_fn = &Wrapper.call,
        };
        batch[n] = .{ .task_fn = &lineChunkTask, .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }

    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        // Fallback: sequential
        var success_count: usize = 0;
        for (lines, 0..) |line, j| {
            const success = processFn(line);
            results[j] = .{ .line_num = j, .success = success };
            if (success) success_count += 1;
        }
        return success_count;
    };
    wg.wait();

    var success_count: usize = 0;
    for (results) |r| {
        if (r.success) success_count += 1;
    }
    return success_count;
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

/// Chunk context for parallel array processing (type-erased)
const ArrayChunkBase = struct {
    results: []bool,
    run_fn: *const fn (ctx: *anyopaque) void,
};

fn arrayChunkTask(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
    const base: *ArrayChunkBase = @ptrCast(@alignCast(ctx_ptr));
    base.run_fn(ctx_ptr);
}

/// Process array elements in parallel with a predicate.
pub fn parallelArrayProcess(
    comptime T: type,
    elements: []const T,
    results: []bool,
    comptime predicate: fn (T) bool,
) usize {
    std.debug.assert(elements.len == results.len);

    const THRESHOLD = 32;
    if (elements.len < THRESHOLD) {
        var count: usize = 0;
        for (elements, 0..) |elem, i| {
            results[i] = predicate(elem);
            if (results[i]) count += 1;
        }
        return count;
    }

    const Chunk = struct {
        // base must be first so ptrCast in arrayChunkTask aligns correctly
        base: ArrayChunkBase,
        elements: []const T,
    };

    const ChunkRunner = struct {
        fn run(ctx_ptr: *anyopaque) void {
            const chunk: *Chunk = @ptrCast(@alignCast(ctx_ptr));
            for (chunk.elements, 0..) |elem, i| {
                chunk.base.results[i] = predicate(elem);
            }
        }
    };

    const pool = getPool();
    const chunk_size = @max(THRESHOLD, elements.len / MAX_CHUNKS);

    var chunks: [MAX_CHUNKS]Chunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < elements.len and n < MAX_CHUNKS) {
        const end = @min(i + chunk_size, elements.len);
        chunks[n] = .{
            .base = .{ .results = results[i..end], .run_fn = &ChunkRunner.run },
            .elements = elements[i..end],
        };
        batch[n] = .{ .task_fn = &arrayChunkTask, .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }

    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        // Fallback: sequential
        var count: usize = 0;
        for (elements, 0..) |elem, j| {
            results[j] = predicate(elem);
            if (results[j]) count += 1;
        }
        return count;
    };
    wg.wait();

    var count: usize = 0;
    for (results) |r| {
        if (r) count += 1;
    }
    return count;
}

// ============================================================================
// Parallel Reduce for JSON Arrays
// ============================================================================

/// Chunk context for parallel sum
fn SumChunk(comptime T: type) type {
    return struct {
        data: []const T,
        partial: T,
    };
}

fn makeSumTask(comptime T: type) tp.TaskFn {
    return struct {
        fn run(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
            const chunk: *SumChunk(T) = @ptrCast(@alignCast(ctx_ptr));
            var sum: T = 0;
            for (chunk.data) |v| sum += v;
            chunk.partial = sum;
        }
    }.run;
}

/// Parallel reduce over numeric array
pub fn parallelSum(comptime T: type, data: []const T) T {
    const THRESHOLD = 1024;
    if (data.len < THRESHOLD) {
        var sum: T = 0;
        for (data) |v| sum += v;
        return sum;
    }

    const pool = getPool();
    const chunk_size = @max(THRESHOLD, data.len / MAX_CHUNKS);

    var chunks: [MAX_CHUNKS]SumChunk(T) = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < data.len and n < MAX_CHUNKS) {
        const end = @min(i + chunk_size, data.len);
        chunks[n] = .{ .data = data[i..end], .partial = 0 };
        batch[n] = .{ .task_fn = makeSumTask(T), .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }

    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        // Fallback: sequential
        var sum: T = 0;
        for (data) |v| sum += v;
        return sum;
    };
    wg.wait();

    var total: T = 0;
    for (chunks[0..n]) |chunk| total += chunk.partial;
    return total;
}

// ============================================================================
// Tests
// ============================================================================

test "parallel sum" {
    const data = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const sum = parallelSum(i64, &data);
    try std.testing.expectEqual(@as(i64, 55), sum);
}

test "parallel array process" {
    const elements = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var results: [10]bool = undefined;

    const count = parallelArrayProcess(i32, &elements, &results, struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);

    try std.testing.expectEqual(@as(usize, 5), count);
}
