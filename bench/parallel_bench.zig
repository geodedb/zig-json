//! JSON Parallel Operations Benchmark

const std = @import("std");
const parallel = @import("parallel");

const WARMUP_RUNS = 3;
const BENCH_RUNS = 5;

const BenchResult = struct {
    seq_ns: u64,
    par_ns: u64,

    fn speedup(self: BenchResult) f64 {
        if (self.par_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.seq_ns)) / @as(f64, @floatFromInt(self.par_ns));
    }

    fn seqMs(self: BenchResult) f64 {
        return @as(f64, @floatFromInt(self.seq_ns)) / 1_000_000.0;
    }

    fn parMs(self: BenchResult) f64 {
        return @as(f64, @floatFromInt(self.par_ns)) / 1_000_000.0;
    }
};

fn isValidJson(line: []const u8) bool {
    // Simple JSON validation - check for balanced braces/brackets
    if (line.len == 0) return false;
    var depth: i32 = 0;
    for (line) |c| {
        switch (c) {
            '{', '[' => depth += 1,
            '}', ']' => depth -= 1,
            else => {},
        }
        if (depth < 0) return false;
    }
    return depth == 0;
}

fn benchParallelLineProcessing(allocator: std.mem.Allocator, num_lines: usize) !BenchResult {
    // Create JSONL-style data
    const lines = try allocator.alloc([]const u8, num_lines);
    defer allocator.free(lines);

    const line_template = "{\"id\": 123, \"name\": \"test\", \"value\": 456}";
    for (lines) |*line| {
        line.* = line_template;
    }

    var results = try allocator.alloc(parallel.LineResult, num_lines);
    defer allocator.free(results);

    // Sequential processing
    var seq_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        var success_count: usize = 0;
        for (lines, 0..) |line, i| {
            const valid = isValidJson(line);
            results[i] = .{ .line_num = i, .success = valid };
            if (valid) success_count += 1;
        }
        seq_total += timer.read();
        std.mem.doNotOptimizeAway(&success_count);
    }

    // Parallel processing
    var par_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        const count = parallel.parallelProcessLines(lines, results, isValidJson);
        par_total += timer.read();
        std.mem.doNotOptimizeAway(&count);
    }

    return .{ .seq_ns = seq_total / BENCH_RUNS, .par_ns = par_total / BENCH_RUNS };
}

fn isEvenNumber(x: i64) bool {
    return @mod(x, 2) == 0;
}

fn benchParallelArrayProcess(allocator: std.mem.Allocator, size: usize) !BenchResult {
    const elements = try allocator.alloc(i64, size);
    defer allocator.free(elements);
    var results = try allocator.alloc(bool, size);
    defer allocator.free(results);

    for (elements, 0..) |*e, i| e.* = @intCast(i);

    // Sequential
    var seq_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        var count: usize = 0;
        for (elements, 0..) |elem, i| {
            results[i] = isEvenNumber(elem);
            if (results[i]) count += 1;
        }
        seq_total += timer.read();
        std.mem.doNotOptimizeAway(&count);
    }

    // Parallel
    var par_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        const count = parallel.parallelArrayProcess(i64, elements, results, isEvenNumber);
        par_total += timer.read();
        std.mem.doNotOptimizeAway(&count);
    }

    return .{ .seq_ns = seq_total / BENCH_RUNS, .par_ns = par_total / BENCH_RUNS };
}

fn benchParallelSum(allocator: std.mem.Allocator, size: usize) !BenchResult {
    const data = try allocator.alloc(i64, size);
    defer allocator.free(data);

    for (data, 0..) |*d, i| d.* = @intCast(i + 1);

    // Sequential
    var seq_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        var sum: i64 = 0;
        for (data) |v| sum += v;
        seq_total += timer.read();
        std.mem.doNotOptimizeAway(&sum);
    }

    // Parallel
    var par_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        const sum = parallel.parallelSum(i64, data);
        par_total += timer.read();
        std.mem.doNotOptimizeAway(&sum);
    }

    return .{ .seq_ns = seq_total / BENCH_RUNS, .par_ns = par_total / BENCH_RUNS };
}

fn printBenchResult(name: []const u8, size: usize, result: BenchResult) void {
    const speedup = result.speedup();
    const indicator: []const u8 = if (speedup >= 1.5) " [FAST]" else if (speedup >= 1.0) " [OK]" else " [SLOW]";
    std.debug.print("{s:<18} {d:>10} {d:>10.3} ms {d:>10.3} ms {d:>8.2}x{s}\n", .{
        name,
        size,
        result.seqMs(),
        result.parMs(),
        speedup,
        indicator,
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("========================================================================\n", .{});
    std.debug.print("      JSON Library - Thread Pool Parallel Operations Benchmark\n", .{});
    std.debug.print("========================================================================\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Warmup: {d} runs, Benchmark: {d} runs (averaged)\n", .{ WARMUP_RUNS, BENCH_RUNS });
    std.debug.print("Legend: [FAST] = >1.5x speedup, [OK] = faster, [SLOW] = slower\n\n", .{});

    std.debug.print("{s:<18} {s:>10} {s:>12} {s:>12} {s:>10}\n", .{ "Operation", "Size", "Sequential", "Parallel", "Speedup" });
    std.debug.print("{s:->18} {s:->10} {s:->12} {s:->12} {s:->10}\n", .{ "", "", "", "", "" });

    // Line processing benchmark
    const line_sizes = [_]usize{ 100, 1_000, 10_000, 50_000 };
    for (line_sizes) |size| {
        const result = try benchParallelLineProcessing(allocator, size);
        printBenchResult("Line Processing", size, result);
    }
    std.debug.print("\n", .{});

    // Array process benchmark
    const array_sizes = [_]usize{ 1_000, 10_000, 100_000, 1_000_000 };
    for (array_sizes) |size| {
        const result = try benchParallelArrayProcess(allocator, size);
        printBenchResult("Array Process", size, result);
    }
    std.debug.print("\n", .{});

    // Sum benchmark
    for (array_sizes) |size| {
        const result = try benchParallelSum(allocator, size);
        printBenchResult("Sum", size, result);
    }

    std.debug.print("\n", .{});
}
