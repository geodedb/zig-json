// SPDX-License-Identifier: Apache-2.0
// Example 05: Struct Field Tags (json_config)
//
// This example demonstrates how to customize JSON encoding/decoding behavior
// using struct field tags via the json_config declaration.

const std = @import("std");
const json = @import("json");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // =========================================================================
    // 1. Custom field names with 'name'
    // =========================================================================
    std.debug.print("=== 1. Custom Field Names ===\n", .{});

    const User = struct {
        first_name: []const u8,
        last_name: []const u8,
        email_address: []const u8,

        // Define custom JSON names for fields
        pub const json_config = .{
            .first_name = json.FieldConfig{ .name = "firstName" },
            .last_name = json.FieldConfig{ .name = "lastName" },
            .email_address = json.FieldConfig{ .name = "email" },
        };
    };

    const user = User{
        .first_name = "John",
        .last_name = "Doe",
        .email_address = "john@example.com",
    };

    const user_json = try json.encode(allocator, user, .{});
    defer allocator.free(user_json);
    std.debug.print("  Encoded: {s}\n", .{user_json});
    // Output: {"firstName":"John","lastName":"Doe","email":"john@example.com"}

    // =========================================================================
    // 2. Skipping fields with 'skip'
    // =========================================================================
    std.debug.print("\n=== 2. Skipping Fields ===\n", .{});

    const Credentials = struct {
        username: []const u8,
        password: []const u8, // Should never be serialized
        api_key: []const u8, // Internal only

        pub const json_config = .{
            .password = json.FieldConfig{ .skip = true },
            .api_key = json.FieldConfig{ .skip = true },
        };
    };

    const creds = Credentials{
        .username = "admin",
        .password = "secret123",
        .api_key = "sk-12345",
    };

    const creds_json = try json.encode(allocator, creds, .{});
    defer allocator.free(creds_json);
    std.debug.print("  Encoded (sensitive fields omitted): {s}\n", .{creds_json});
    // Output: {"username":"admin"}

    // =========================================================================
    // 3. Omitting empty values with 'omitempty'
    // =========================================================================
    std.debug.print("\n=== 3. Omitting Empty Values ===\n", .{});

    const Response = struct {
        status: i32,
        message: []const u8,
        error_code: i32,
        debug_info: []const u8,

        pub const json_config = .{
            .error_code = json.FieldConfig{ .omitempty = true },
            .debug_info = json.FieldConfig{ .omitempty = true },
        };
    };

    // Success response (error_code = 0, debug_info = "")
    const success = Response{
        .status = 200,
        .message = "OK",
        .error_code = 0,
        .debug_info = "",
    };

    const success_json = try json.encode(allocator, success, .{});
    defer allocator.free(success_json);
    std.debug.print("  Success response: {s}\n", .{success_json});
    // Output: {"status":200,"message":"OK"} - empty fields omitted

    // Error response (error_code = 42)
    const error_resp = Response{
        .status = 500,
        .message = "Internal Error",
        .error_code = 42,
        .debug_info = "Stack trace here",
    };

    const error_json = try json.encode(allocator, error_resp, .{});
    defer allocator.free(error_json);
    std.debug.print("  Error response: {s}\n", .{error_json});
    // Output: {"status":500,"message":"Internal Error","error_code":42,"debug_info":"Stack trace here"}

    // =========================================================================
    // 4. Stringifying numbers with 'stringify'
    // =========================================================================
    std.debug.print("\n=== 4. Stringifying Numbers ===\n", .{});

    // JavaScript can't handle large integers precisely (> 2^53)
    const Entity = struct {
        id: u64,
        count: u32,

        pub const json_config = .{
            // Stringify id to preserve precision in JavaScript
            .id = json.FieldConfig{ .stringify = true },
        };
    };

    const entity = Entity{
        .id = 9007199254740993, // Too large for JS Number
        .count = 100,
    };

    const entity_json = try json.encode(allocator, entity, .{});
    defer allocator.free(entity_json);
    std.debug.print("  Entity with stringified ID: {s}\n", .{entity_json});
    // Output: {"id":"9007199254740993","count":100}

    // =========================================================================
    // 5. Binary encoding formats
    // =========================================================================
    std.debug.print("\n=== 5. Binary Encoding Formats ===\n", .{});

    const BinaryData = struct {
        name: []const u8,
        sha256: []const u8,
        content: []const u8,

        pub const json_config = .{
            .sha256 = json.FieldConfig{ .binary_format = .hex },
            .content = json.FieldConfig{ .binary_format = .base64 },
        };
    };

    const data = BinaryData{
        .name = "example.txt",
        .sha256 = &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE },
        .content = "Hello, World!",
    };

    const data_json = try json.encode(allocator, data, .{});
    defer allocator.free(data_json);
    std.debug.print("  Binary data: {s}\n", .{data_json});

    // =========================================================================
    // 6. Inline/flatten nested structs
    // =========================================================================
    std.debug.print("\n=== 6. Flattening Nested Structs ===\n", .{});

    const Metadata = struct {
        created_at: i64,
        updated_at: i64,
    };

    const Document = struct {
        id: u64,
        title: []const u8,
        meta: Metadata,

        pub const json_config = .{
            // Flatten metadata fields into the parent object
            .meta = json.FieldConfig{ .@"inline" = true },
        };
    };

    const doc = Document{
        .id = 1,
        .title = "My Document",
        .meta = .{ .created_at = 1234567890, .updated_at = 1234567900 },
    };

    const doc_json = try json.encode(allocator, doc, .{});
    defer allocator.free(doc_json);
    std.debug.print("  Flattened: {s}\n", .{doc_json});
    // Output: {"id":1,"title":"My Document","created_at":1234567890,"updated_at":1234567900}
    // Note: no "meta" wrapper object

    // =========================================================================
    // 7. Combining multiple options
    // =========================================================================
    std.debug.print("\n=== 7. Combining Multiple Options ===\n", .{});

    const ApiResponse = struct {
        data: []const u8,
        internal_id: u64,
        request_id: u64,
        debug: []const u8,

        pub const json_config = .{
            .data = json.FieldConfig{ .name = "payload" },
            .internal_id = json.FieldConfig{ .skip = true },
            .request_id = json.FieldConfig{
                .name = "requestId",
                .stringify = true,
            },
            .debug = json.FieldConfig{ .omitempty = true },
        };
    };

    const response = ApiResponse{
        .data = "result",
        .internal_id = 999,
        .request_id = 12345678901234,
        .debug = "",
    };

    const response_json = try json.encode(allocator, response, .{ .indent = "  " });
    defer allocator.free(response_json);
    std.debug.print("  Combined config:\n{s}\n", .{response_json});

    std.debug.print("\nAll examples completed successfully!\n", .{});
}
