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

/// Lazily initialize and return the process-wide thread pool.
///
/// Returns an error (rather than aborting) when pool initialization fails,
/// so callers can fall back to sequential processing instead of crashing the
/// whole process on a recoverable `error.OutOfMemory` (ASR-024).
///
/// Lifecycle contract: the returned pointer is owned by the global pool and is
/// only valid while no `deinitPool()` runs concurrently. `deinitPool()`
/// requires quiescence — see its doc comment. The mutex here guards
/// initialization only; it does NOT keep the pool alive across the borrow.
pub fn getPool() !*tp.ThreadPool {
    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool == null) {
        global_pool = try tp.ThreadPool.init(std.heap.page_allocator, .{});
    }
    return &global_pool.?;
}

/// Tear down the process-wide thread pool.
///
/// QUIESCENCE CONTRACT (ASR-024): the caller MUST ensure there are no in-flight
/// users of the pool when calling this — i.e. no other thread is inside
/// `getPool()`, `parallelProcessLines`, `parallelArrayProcess`, or
/// `parallelSum` (or otherwise holding a pointer returned by `getPool()`).
/// This is typically a program-shutdown / test-teardown operation. Calling it
/// while a parallel helper is running on another thread is a use-after-free:
/// the mutex below only serializes the `deinit()` itself, it cannot revoke a
/// `*ThreadPool` already borrowed by a concurrent caller. A full reference
/// count was deliberately not added to keep the locking simple and
/// deadlock-free; honor the contract instead.
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

    const pool = getPool() catch {
        // Pool unavailable (ASR-024): fall back to sequential rather than abort.
        var success_count: usize = 0;
        for (lines, 0..) |line, j| {
            const success = processFn(line);
            results[j] = .{ .line_num = j, .success = success };
            if (success) success_count += 1;
        }
        return success_count;
    };
    // Ceil division so the last chunk absorbs the remainder; floor division
    // dropped the tail [n*chunk_size, lines.len) and left those result entries
    // uninitialized (ASR-013 / PERF-009 / GAP-011).
    const chunk_size = @max(THRESHOLD, (lines.len + MAX_CHUNKS - 1) / MAX_CHUNKS);

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
    // With ceil division every element is now assigned to a chunk.
    std.debug.assert(i == lines.len);

    var wg = pool.waitGroup();
    const res = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        // Fallback: sequential
        var success_count: usize = 0;
        for (lines, 0..) |line, j| {
            const success = processFn(line);
            results[j] = .{ .line_num = j, .success = success };
            if (success) success_count += 1;
        }
        return success_count;
    };
    // Backpressure may queue fewer chunks than submitted; run the remainder
    // synchronously so no chunk is silently dropped (ASR-013).
    for (chunks[res.submitted..n]) |*chunk| {
        for (chunk.lines, 0..) |line, k| {
            const success = chunk.process_fn(line);
            chunk.results[k] = .{ .line_num = chunk.start_line + k, .success = success };
        }
    }
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

    const pool = getPool() catch {
        // Pool unavailable (ASR-024): fall back to sequential rather than abort.
        var count: usize = 0;
        for (elements, 0..) |elem, j| {
            results[j] = predicate(elem);
            if (results[j]) count += 1;
        }
        return count;
    };
    // Ceil division so the tail is never dropped (ASR-013 / PERF-009 / GAP-011);
    // floor division left tail `results` entries uninitialized.
    const chunk_size = @max(THRESHOLD, (elements.len + MAX_CHUNKS - 1) / MAX_CHUNKS);

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
    // With ceil division every element is now assigned to a chunk.
    std.debug.assert(i == elements.len);

    var wg = pool.waitGroup();
    const res = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        // Fallback: sequential
        var count: usize = 0;
        for (elements, 0..) |elem, j| {
            results[j] = predicate(elem);
            if (results[j]) count += 1;
        }
        return count;
    };
    // Process any chunks the pool could not queue (backpressure) synchronously
    // so no element is left unwritten (ASR-013).
    for (chunks[res.submitted..n]) |*chunk| {
        for (chunk.elements, 0..) |elem, k| {
            chunk.base.results[k] = predicate(elem);
        }
    }
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

    const pool = getPool() catch {
        // Pool unavailable (ASR-024): fall back to sequential rather than abort.
        var sum: T = 0;
        for (data) |v| sum += v;
        return sum;
    };
    // Ceil division so the tail is summed too (ASR-013 / PERF-009 / GAP-011);
    // floor division silently omitted [n*chunk_size, data.len) → wrong sum.
    const chunk_size = @max(THRESHOLD, (data.len + MAX_CHUNKS - 1) / MAX_CHUNKS);

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
    // With ceil division every element is now assigned to a chunk.
    std.debug.assert(i == data.len);

    var wg = pool.waitGroup();
    const res = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        // Fallback: sequential
        var sum: T = 0;
        for (data) |v| sum += v;
        return sum;
    };
    // Compute partials for any chunks the pool could not queue (backpressure)
    // synchronously so their contribution is not lost (ASR-013).
    for (chunks[res.submitted..n]) |*chunk| {
        var sum: T = 0;
        for (chunk.data) |v| sum += v;
        chunk.partial = sum;
    }
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

// ----------------------------------------------------------------------------
// Tail-coverage regression tests (ASR-013 / PERF-009 / GAP-011)
//
// These exercise input sizes whose `len` is NOT a multiple of MAX_CHUNKS and
// is large enough that the old floor-division `chunk_size = len / 64` left a
// tail of up to 63 elements unassigned to any chunk. Before the fix:
//   * parallelSum dropped the tail   -> wrong (too-small) sum.
//   * parallelArrayProcess / parallelProcessLines never wrote the tail
//     `results` entries -> uninitialized reads + undercounted success.
// The sizes below were chosen so floor division would have dropped a tail; see
// the per-helper THRESHOLD clamp (a size only drops a tail when len/64 >=
// THRESHOLD and len % 64 != 0).
// ----------------------------------------------------------------------------

const tail_drop = struct {
    fn alwaysTrue(_: []const u8) bool {
        return true;
    }
    fn nonNeg(x: i64) bool {
        return x >= 0;
    }
};

test "parallelSum covers the tail for non-multiples of 64" {
    const allocator = std.testing.allocator;
    // sum(THRESHOLD=1024) only drops a tail when len/64 >= 1024, i.e.
    // len >= 65536 and len % 64 != 0. 65537 (1 dropped), 66000 (16 dropped),
    // 70001 (49 dropped) all triggered the bug; 9973 stays sequential so it
    // is a control that must also match.
    const sizes = [_]usize{ 9973, 65537, 66000, 70001 };
    for (sizes) |len| {
        const data = try allocator.alloc(i64, len);
        defer allocator.free(data);
        var expected: i64 = 0;
        for (data, 0..) |*v, idx| {
            v.* = @intCast((idx % 7) + 1); // 1..7, all positive
            expected += v.*;
        }
        const got = parallelSum(i64, data);
        try std.testing.expectEqual(expected, got);
    }
    deinitPool();
}

test "parallelArrayProcess writes and counts every element (no tail drop)" {
    const allocator = std.testing.allocator;
    // array-process(THRESHOLD=32): drops a tail when len/64 >= 32, i.e.
    // len >= 2048 and len % 64 != 0. 9973 (53 dropped), 50000 (16 dropped),
    // 70001 (49 dropped) all triggered the bug.
    const sizes = [_]usize{ 9973, 50000, 70001 };
    const sentinel = false;
    for (sizes) |len| {
        const elements = try allocator.alloc(i64, len);
        defer allocator.free(elements);
        const results = try allocator.alloc(bool, len);
        defer allocator.free(results);
        // Prefill results with a sentinel so an unwritten (formerly
        // uninitialized) tail entry is observable as `false`.
        @memset(results, sentinel);

        var expected: usize = 0;
        for (elements, 0..) |*e, idx| {
            // Alternate sign so the predicate is true for ~half, and the tail
            // is forced to contain `true` results that must be written.
            e.* = if (idx % 2 == 0) @as(i64, 1) else @as(i64, -1);
            if (e.* >= 0) expected += 1;
        }

        const count = parallelArrayProcess(i64, elements, results, tail_drop.nonNeg);
        try std.testing.expectEqual(expected, count);

        // Every entry must equal the true predicate value: proves the tail was
        // written (no leftover sentinel / uninitialized read).
        for (elements, results) |e, r| {
            try std.testing.expectEqual(e >= 0, r);
        }
    }
    deinitPool();
}

test "parallelProcessLines writes and counts every line (no tail drop)" {
    const allocator = std.testing.allocator;
    // process-lines(THRESHOLD=16): drops a tail when len/64 >= 16, i.e.
    // len >= 1024 and len % 64 != 0. 9973 (53), 50000 (16), 65537 (1),
    // 70001 (49) all triggered the bug.
    const sizes = [_]usize{ 9973, 50000, 65537, 70001 };
    for (sizes) |len| {
        const lines = try allocator.alloc([]const u8, len);
        defer allocator.free(lines);
        const results = try allocator.alloc(LineResult, len);
        defer allocator.free(results);
        for (lines) |*l| l.* = "x";
        // Sentinel: mark every result not-yet-written with success=false and an
        // impossible line_num so any unwritten tail entry is detectable.
        for (results) |*r| r.* = .{ .line_num = std.math.maxInt(usize), .success = false };

        const count = parallelProcessLines(lines, results, tail_drop.alwaysTrue);

        // alwaysTrue => every line is a success; success_count must equal len.
        try std.testing.expectEqual(len, count);
        // Every result entry must have been written with its own index and
        // success=true (no leftover sentinel / uninitialized tail).
        for (results, 0..) |r, idx| {
            try std.testing.expectEqual(idx, r.line_num);
            try std.testing.expect(r.success);
        }
    }
    deinitPool();
}

test "parallel helpers handle exact multiples of 64 (no regression)" {
    const allocator = std.testing.allocator;
    // 65536 = 1024 * 64: exact multiple, must still be fully covered.
    const len: usize = 65536;
    const data = try allocator.alloc(i64, len);
    defer allocator.free(data);
    var expected: i64 = 0;
    for (data, 0..) |*v, idx| {
        v.* = @intCast((idx % 5) + 1);
        expected += v.*;
    }
    try std.testing.expectEqual(expected, parallelSum(i64, data));
    deinitPool();
}
