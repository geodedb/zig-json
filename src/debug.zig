// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Debug Utilities
//!
//! Provides formatting for validation reports and other debug output.

const std = @import("std");
const json = @import("json.zig");

const ValidationError = json.ValidationError;
const ValidationReport = json.ValidationReport;

/// Format a validation report as human-readable text
pub fn formatReport(a: std.mem.Allocator, r: ValidationReport) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);

    if (r.ok) {
        try buf.appendSlice(a, "Validation: OK\n");
    } else {
        try buf.appendSlice(a, "Validation: FAILED\n");
        try buf.appendSlice(a, "Errors:\n");

        for (r.errors, 0..) |err, i| {
            try buf.appendSlice(a, "  ");
            var num_buf: [10]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{i + 1}) catch "?";
            try buf.appendSlice(a, num_str);
            try buf.appendSlice(a, ". ");

            // Instance pointer
            try buf.appendSlice(a, "at ");
            if (err.instance_ptr.len == 0) {
                try buf.appendSlice(a, "(root)");
            } else {
                try buf.appendSlice(a, err.instance_ptr);
            }

            // Keyword
            try buf.appendSlice(a, " [");
            try buf.appendSlice(a, err.keyword);
            try buf.appendSlice(a, "]: ");

            // Message
            try buf.appendSlice(a, err.message);
            try buf.append(a, '\n');

            // Schema location
            try buf.appendSlice(a, "     schema: ");
            if (err.schema_ptr.len == 0) {
                try buf.appendSlice(a, "(root)");
            } else {
                try buf.appendSlice(a, err.schema_ptr);
            }
            try buf.append(a, '\n');
        }
    }

    return buf.toOwnedSlice(a);
}

/// Format validation errors as JSON array
pub fn formatReportJson(a: std.mem.Allocator, r: ValidationReport) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);

    try buf.append(a, '[');

    for (r.errors, 0..) |err, i| {
        if (i > 0) try buf.append(a, ',');
        try buf.append(a, '{');

        try buf.appendSlice(a, "\"instancePointer\":");
        try writeJsonString(a, &buf, err.instance_ptr);
        try buf.append(a, ',');

        try buf.appendSlice(a, "\"schemaPointer\":");
        try writeJsonString(a, &buf, err.schema_ptr);
        try buf.append(a, ',');

        try buf.appendSlice(a, "\"keyword\":");
        try writeJsonString(a, &buf, err.keyword);
        try buf.append(a, ',');

        try buf.appendSlice(a, "\"message\":");
        try writeJsonString(a, &buf, err.message);

        try buf.append(a, '}');
    }

    try buf.append(a, ']');

    return buf.toOwnedSlice(a);
}

fn writeJsonString(a: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(a, "\\\""),
            '\\' => try buf.appendSlice(a, "\\\\"),
            '\n' => try buf.appendSlice(a, "\\n"),
            '\r' => try buf.appendSlice(a, "\\r"),
            '\t' => try buf.appendSlice(a, "\\t"),
            else => {
                if (c < 0x20) {
                    try buf.appendSlice(a, "\\u00");
                    const hex = "0123456789ABCDEF";
                    try buf.append(a, hex[(c >> 4) & 0xF]);
                    try buf.append(a, hex[c & 0xF]);
                } else {
                    try buf.append(a, c);
                }
            },
        }
    }
    try buf.append(a, '"');
}

test "format empty report" {
    var errors = [_]ValidationError{};
    const report = ValidationReport{ .ok = true, .errors = &errors };
    const result = try formatReport(std.testing.allocator, report);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "OK") != null);
}

test "format report with errors" {
    var errors = [_]ValidationError{
        .{
            .instance_ptr = "/name",
            .schema_ptr = "/properties/name",
            .keyword = "type",
            .message = "expected string",
        },
    };
    const report = ValidationReport{ .ok = false, .errors = &errors };
    const result = try formatReport(std.testing.allocator, report);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "FAILED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "/name") != null);
}

test "format report json" {
    var errors = [_]ValidationError{
        .{
            .instance_ptr = "/x",
            .schema_ptr = "/properties/x",
            .keyword = "minimum",
            .message = "too small",
        },
    };
    const report = ValidationReport{ .ok = false, .errors = &errors };
    const result = try formatReportJson(std.testing.allocator, report);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "[{"));
    try std.testing.expect(std.mem.indexOf(u8, result, "\"keyword\":\"minimum\"") != null);
}
