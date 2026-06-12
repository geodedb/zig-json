// SPDX-License-Identifier: Apache-2.0
// Example 06: JSON Patch (RFC 6902)
//
// This example demonstrates how to use JSON Patch operations to modify
// JSON documents. JSON Patch is useful for partial updates in REST APIs.

const std = @import("std");
const json = @import("json");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var err = json.ParseError.init();

    // =========================================================================
    // 1. Add operation
    // =========================================================================
    std.debug.print("=== 1. Add Operation ===\n", .{});

    const original_json =
        \\{"name": "Alice", "age": 30}
    ;
    var original = try json.parse(allocator, original_json, .{}, &err);
    defer original.deinit();

    // Add a new field
    const add_ops = [_]json.PatchOperation{
        .{
            .op = .add,
            .path = "/email",
            .value = json.Value{ .str = "alice@example.com" },
        },
    };

    const after_add = try json.applyPatch(allocator, original.root, &add_ops);
    defer json.freePatchValue(allocator, after_add);

    const add_result = try json.stringify(allocator, after_add);
    defer allocator.free(add_result);
    std.debug.print("  After add: {s}\n", .{add_result});

    // =========================================================================
    // 2. Remove operation
    // =========================================================================
    std.debug.print("\n=== 2. Remove Operation ===\n", .{});

    const remove_ops = [_]json.PatchOperation{
        .{
            .op = .remove,
            .path = "/age",
        },
    };

    const after_remove = try json.applyPatch(allocator, original.root, &remove_ops);
    defer json.freePatchValue(allocator, after_remove);

    const remove_result = try json.stringify(allocator, after_remove);
    defer allocator.free(remove_result);
    std.debug.print("  After remove: {s}\n", .{remove_result});

    // =========================================================================
    // 3. Replace operation
    // =========================================================================
    std.debug.print("\n=== 3. Replace Operation ===\n", .{});

    const replace_ops = [_]json.PatchOperation{
        .{
            .op = .replace,
            .path = "/age",
            .value = json.Value{ .num = .{
                .lexeme = "31",
                .sign = 1,
                .digits = "31",
                .exp10 = 0,
            } },
        },
    };

    const after_replace = try json.applyPatch(allocator, original.root, &replace_ops);
    defer json.freePatchValue(allocator, after_replace);

    const replace_result = try json.stringify(allocator, after_replace);
    defer allocator.free(replace_result);
    std.debug.print("  After replace: {s}\n", .{replace_result});

    // =========================================================================
    // 4. Move operation
    // =========================================================================
    std.debug.print("\n=== 4. Move Operation ===\n", .{});

    const move_json =
        \\{"user": {"name": "Bob"}, "admin": null}
    ;
    var move_doc = try json.parse(allocator, move_json, .{}, &err);
    defer move_doc.deinit();

    const move_ops = [_]json.PatchOperation{
        .{
            .op = .move,
            .path = "/admin",
            .from = "/user/name",
        },
    };

    const after_move = try json.applyPatch(allocator, move_doc.root, &move_ops);
    defer json.freePatchValue(allocator, after_move);

    const move_result = try json.stringify(allocator, after_move);
    defer allocator.free(move_result);
    std.debug.print("  After move: {s}\n", .{move_result});

    // =========================================================================
    // 5. Copy operation
    // =========================================================================
    std.debug.print("\n=== 5. Copy Operation ===\n", .{});

    const copy_json =
        \\{"source": "value", "target": null}
    ;
    var copy_doc = try json.parse(allocator, copy_json, .{}, &err);
    defer copy_doc.deinit();

    const copy_ops = [_]json.PatchOperation{
        .{
            .op = .copy,
            .path = "/target",
            .from = "/source",
        },
    };

    const after_copy = try json.applyPatch(allocator, copy_doc.root, &copy_ops);
    defer json.freePatchValue(allocator, after_copy);

    const copy_result = try json.stringify(allocator, after_copy);
    defer allocator.free(copy_result);
    std.debug.print("  After copy: {s}\n", .{copy_result});

    // =========================================================================
    // 6. Test operation
    // =========================================================================
    std.debug.print("\n=== 6. Test Operation ===\n", .{});

    const test_ops_pass = [_]json.PatchOperation{
        .{
            .op = .@"test",
            .path = "/name",
            .value = json.Value{ .str = "Alice" },
        },
    };

    const test_result = json.applyPatch(allocator, original.root, &test_ops_pass);
    if (test_result) |result| {
        json.freePatchValue(allocator, result);
        std.debug.print("  Test passed: /name equals \"Alice\"\n", .{});
    } else |patch_err| {
        std.debug.print("  Test failed: {}\n", .{patch_err});
    }

    // Test that fails
    const test_ops_fail = [_]json.PatchOperation{
        .{
            .op = .@"test",
            .path = "/name",
            .value = json.Value{ .str = "Bob" },
        },
    };

    const test_fail = json.applyPatch(allocator, original.root, &test_ops_fail);
    if (test_fail) |result| {
        json.freePatchValue(allocator, result);
        std.debug.print("  Unexpectedly passed\n", .{});
    } else |patch_err| {
        std.debug.print("  Test correctly failed (expected): {}\n", .{patch_err});
    }

    // =========================================================================
    // 7. Array operations
    // =========================================================================
    std.debug.print("\n=== 7. Array Operations ===\n", .{});

    const array_json =
        \\{"items": ["a", "b", "c"]}
    ;
    var array_doc = try json.parse(allocator, array_json, .{}, &err);
    defer array_doc.deinit();

    // Add to array at specific index
    const arr_add_ops = [_]json.PatchOperation{
        .{
            .op = .add,
            .path = "/items/1", // Insert at index 1
            .value = json.Value{ .str = "x" },
        },
    };

    const after_arr_add = try json.applyPatch(allocator, array_doc.root, &arr_add_ops);
    defer json.freePatchValue(allocator, after_arr_add);

    const arr_add_result = try json.stringify(allocator, after_arr_add);
    defer allocator.free(arr_add_result);
    std.debug.print("  After array insert at [1]: {s}\n", .{arr_add_result});

    // Append to array using "-"
    const arr_append_ops = [_]json.PatchOperation{
        .{
            .op = .add,
            .path = "/items/-", // Append to end
            .value = json.Value{ .str = "z" },
        },
    };

    const after_arr_append = try json.applyPatch(allocator, array_doc.root, &arr_append_ops);
    defer json.freePatchValue(allocator, after_arr_append);

    const arr_append_result = try json.stringify(allocator, after_arr_append);
    defer allocator.free(arr_append_result);
    std.debug.print("  After array append: {s}\n", .{arr_append_result});

    // =========================================================================
    // 8. Chaining multiple operations
    // =========================================================================
    std.debug.print("\n=== 8. Chaining Multiple Operations ===\n", .{});

    const chain_json =
        \\{"name": "Doc", "version": 1, "draft": true}
    ;
    var chain_doc = try json.parse(allocator, chain_json, .{}, &err);
    defer chain_doc.deinit();

    // Apply multiple operations atomically
    const chain_ops = [_]json.PatchOperation{
        .{
            .op = .replace,
            .path = "/version",
            .value = json.Value{ .num = .{
                .lexeme = "2",
                .sign = 1,
                .digits = "2",
                .exp10 = 0,
            } },
        },
        .{
            .op = .remove,
            .path = "/draft",
        },
        .{
            .op = .add,
            .path = "/published",
            .value = json.Value{ .bool = true },
        },
    };

    const after_chain = try json.applyPatch(allocator, chain_doc.root, &chain_ops);
    defer json.freePatchValue(allocator, after_chain);

    const chain_result = try json.stringify(allocator, after_chain);
    defer allocator.free(chain_result);
    std.debug.print("  After chained operations: {s}\n", .{chain_result});

    // =========================================================================
    // 9. Parsing patch document from JSON
    // =========================================================================
    std.debug.print("\n=== 9. Parsing Patch Document from JSON ===\n", .{});

    const patch_json =
        \\[
        \\  {"op": "add", "path": "/status", "value": "active"},
        \\  {"op": "remove", "path": "/age"}
        \\]
    ;
    var patch_doc = try json.parse(allocator, patch_json, .{}, &err);
    defer patch_doc.deinit();

    const parsed_ops = try json.parsePatch(allocator, patch_doc.root);
    defer allocator.free(parsed_ops);

    std.debug.print("  Parsed {d} operations from JSON\n", .{parsed_ops.len});
    for (parsed_ops) |op| {
        std.debug.print("    - {}: {s}\n", .{ op.op, op.path });
    }

    // Apply the parsed patch
    const after_parsed = try json.applyPatch(allocator, original.root, parsed_ops);
    defer json.freePatchValue(allocator, after_parsed);

    const parsed_result = try json.stringify(allocator, after_parsed);
    defer allocator.free(parsed_result);
    std.debug.print("  Result: {s}\n", .{parsed_result});

    std.debug.print("\nAll examples completed successfully!\n", .{});
}
