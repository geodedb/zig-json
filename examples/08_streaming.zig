// SPDX-License-Identifier: Apache-2.0
// Example 08: Streaming JSON (Tokenizer and Encoder)
//
// This example demonstrates streaming JSON parsing and encoding,
// which is more memory-efficient for large documents or when you
// only need specific parts of the data.

const std = @import("std");
const json = @import("json");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // =========================================================================
    // 1. Streaming tokenizer - parse without building full tree
    // =========================================================================
    std.debug.print("=== 1. Streaming Tokenizer ===\n", .{});

    const sample_json =
        \\{"name": "Alice", "age": 30, "tags": ["dev", "zig"]}
    ;

    // Create a tokenizer
    var tokenizer = json.Tokenizer.init(sample_json, .{});

    std.debug.print("  Tokens in document:\n", .{});
    while (true) {
        const token = tokenizer.next() catch break;
        if (token.token_type == .eof) break;

        std.debug.print("    Type: {}, Value: ", .{token.token_type});
        if (token.value) |val| {
            switch (token.token_type) {
                .string => std.debug.print("\"{s}\"", .{val}),
                .number => std.debug.print("{s}", .{val}),
                else => std.debug.print("{s}", .{val}),
            }
        } else {
            std.debug.print("(none)", .{});
        }
        std.debug.print("\n", .{});
    }

    // =========================================================================
    // 2. Read specific values from tokenizer
    // =========================================================================
    std.debug.print("\n=== 2. Read Values from Tokenizer ===\n", .{});

    var tokenizer2 = json.Tokenizer.init(sample_json, .{});

    // Read the entire value as a json.Value tree
    var value = try json.readValue(&tokenizer2, allocator);
    defer json.freeValue(allocator, &value);

    std.debug.print("  Read complete value: ", .{});
    switch (value) {
        .obj => std.debug.print("object with {d} members\n", .{value.obj.len}),
        .arr => std.debug.print("array with {d} elements\n", .{value.arr.len}),
        else => std.debug.print("other type\n", .{}),
    }

    // =========================================================================
    // 3. Streaming encoder - write to a stream
    // =========================================================================
    std.debug.print("\n=== 3. Streaming Encoder ===\n", .{});

    // Create a buffer to write to
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(allocator);

    // Create a streaming encoder with pretty printing
    var encoder = json.streamingEncoder(allocator, buffer.writer(allocator), .{
        .indent = "  ",
        .sort_keys = false,
    });

    // Write JSON incrementally
    try encoder.beginObject();

    try encoder.writeObjectKey("name");
    try encoder.writeString("Bob");

    try encoder.writeObjectKey("scores");
    try encoder.beginArray();
    try encoder.writeNumber(95);
    try encoder.writeNumber(87);
    try encoder.writeNumber(92);
    try encoder.endArray();

    try encoder.writeObjectKey("active");
    try encoder.writeBool(true);

    try encoder.endObject();

    std.debug.print("  Streamed output:\n{s}\n", .{buffer.items});

    // =========================================================================
    // 4. Encode to writer directly
    // =========================================================================
    std.debug.print("\n=== 4. Encode to Writer ===\n", .{});

    const User = struct {
        id: u64,
        name: []const u8,
        email: []const u8,
    };

    const user = User{
        .id = 12345,
        .name = "Charlie",
        .email = "charlie@example.com",
    };

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    // Write directly to the output buffer
    try json.encodeToWriter(output.writer(allocator), user, .{ .indent = "  " });

    std.debug.print("  Encoded to writer:\n{s}\n", .{output.items});

    // =========================================================================
    // 5. Process large arrays item by item
    // =========================================================================
    std.debug.print("\n=== 5. Processing Large Arrays ===\n", .{});

    const large_array =
        \\[
        \\  {"id": 1, "value": "first"},
        \\  {"id": 2, "value": "second"},
        \\  {"id": 3, "value": "third"}
        \\]
    ;

    var arr_tokenizer = json.Tokenizer.init(large_array, .{});

    // Skip the opening bracket
    var first_token = try arr_tokenizer.next();
    std.debug.print("  First token: {} (expecting array_start)\n", .{first_token.token_type});

    // Process each item without loading the entire array
    var count: usize = 0;
    while (true) {
        // Check if we've reached the end
        if (arr_tokenizer.peek()) |peeked| {
            if (peeked == ']') {
                _ = try arr_tokenizer.next(); // consume the ]
                break;
            }
        } else break;

        // Read the next value
        var item = try json.readValue(&arr_tokenizer, allocator);
        defer json.freeValue(allocator, &item);

        count += 1;

        // Process the item
        if (item == .obj) {
            for (item.obj) |m| {
                if (std.mem.eql(u8, m.k, "id")) {
                    std.debug.print("    Processing item with id: {s}\n", .{m.v.num.lexeme});
                }
            }
        }

        // Skip comma if present
        if (arr_tokenizer.peek()) |p| {
            if (p == ',') {
                _ = try arr_tokenizer.next();
            }
        }
    }
    std.debug.print("  Processed {d} items\n", .{count});

    // =========================================================================
    // 6. Memory-efficient encoding of large data
    // =========================================================================
    std.debug.print("\n=== 6. Memory-Efficient Large Data Encoding ===\n", .{});

    // For very large data, you can encode directly to a file or network socket
    // Here we demonstrate with a buffer

    var large_output: std.ArrayListUnmanaged(u8) = .empty;
    defer large_output.deinit(allocator);

    var large_encoder = json.streamingEncoder(allocator, large_output.writer(allocator), .{});

    try large_encoder.beginArray();

    // Simulate generating many items
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try large_encoder.beginObject();

        try large_encoder.writeObjectKey("index");
        try large_encoder.writeNumber(i);

        try large_encoder.writeObjectKey("squared");
        try large_encoder.writeNumber(i * i);

        try large_encoder.endObject();
    }

    try large_encoder.endArray();

    std.debug.print("  Generated array: {s}\n", .{large_output.items});

    std.debug.print("\nAll examples completed successfully!\n", .{});
}
