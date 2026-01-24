# Getting Started

A quick guide to start using zig-json in your project.

## Installation

### Using Zig Package Manager

Add zig-json to your `build.zig.zon`:

```zig
.{
    .name = "my-project",
    .version = "0.0.0",
    .dependencies = .{
        .json = .{
            .url = "https://gitlab.com/devnw/zig/json/-/archive/main/json-main.tar.gz",
            // Run `zig build` once to get the hash, then add it here:
            // .hash = "...",
        },
    },
}
```

Then configure your `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get the json dependency
    const json = b.dependency("json", .{
        .target = target,
        .optimize = optimize,
    });

    // Create your executable
    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the json module
    exe.root_module.addImport("json", json.module("json"));

    b.installArtifact(exe);
}
```

## First Steps

### 1. Import the Library

```zig
const std = @import("std");
const json = @import("json");
```

### 2. Parse JSON

```zig
pub fn main() !void {
    // Use an allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // JSON input
    const input = "{\"message\": \"Hello, World!\"}";

    // Parse
    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    // Access the value
    if (doc.root == .obj) {
        for (doc.root.obj) |member| {
            if (std.mem.eql(u8, member.k, "message")) {
                std.debug.print("{s}\n", .{member.v.str});
            }
        }
    }
}
```

### 3. Encode Zig Types

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Define a struct
    const Response = struct {
        success: bool,
        message: []const u8,
        data: ?i32,
    };

    // Create an instance
    const response = Response{
        .success = true,
        .message = "Operation completed",
        .data = 42,
    };

    // Encode to JSON
    const output = try json.encode(allocator, response, .{});
    defer allocator.free(output);

    std.debug.print("{s}\n", .{output});
    // {"success":true,"message":"Operation completed","data":42}
}
```

### 4. Validate with JSON Schema

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Define a schema
    const schema_json =
        \\{
        \\  "type": "object",
        \\  "required": ["name"],
        \\  "properties": {
        \\    "name": {"type": "string"},
        \\    "age": {"type": "integer", "minimum": 0}
        \\  }
        \\}
    ;

    var err = json.ParseError.init();

    // Compile the schema
    var schema_doc = try json.parse(allocator, schema_json, .{}, &err);
    defer schema_doc.deinit();

    var compiled = try json.compileSchema(allocator, &schema_doc, .{}, null, &err);
    defer compiled.deinit();

    // Validate data
    var data_doc = try json.parse(allocator, "{\"name\": \"Alice\"}", .{}, &err);
    defer data_doc.deinit();

    const report = try json.validate(allocator, &compiled, data_doc.root, .{});
    defer allocator.free(report.errors);

    if (report.ok) {
        std.debug.print("Valid!\n", .{});
    } else {
        std.debug.print("Invalid: {d} errors\n", .{report.errors.len});
    }
}
```

## Common Patterns

### Handle Parse Errors

```zig
const result = json.parse(allocator, input, .{}, &err);

if (result) |doc| {
    defer doc.deinit();
    // Use doc.root
} else |e| {
    switch (e) {
        error.JsonParse => {
            std.debug.print("Parse error at line {d}, col {d}: {s}\n", .{
                err.line, err.col, @tagName(err.code),
            });
        },
        else => return e,
    }
}
```

### Pretty Print JSON

```zig
// 2-space indentation
const pretty = try json.encode(allocator, data, .{ .indent = "  " });

// Or use a preset
const pretty2 = try json.encode(allocator, data, json.encode_mod.pretty_2);
```

### Stream to a File

```zig
var file = try std.fs.cwd().createFile("output.json", .{});
defer file.close();

try json.encodeToWriter(file.writer(), data, .{ .indent = "  " });
```

## Next Steps

- Read the [API Reference](./API.md) for complete documentation
- Check out [Examples](./EXAMPLES.md) for more usage patterns
- See the [Roadmap](./ROADMAP.md) for upcoming features

## Getting Help

- [GitLab Issues](https://gitlab.com/devnw/zig/json/-/issues) - Report bugs or request features
- [GitLab Repository](https://gitlab.com/devnw/zig/json) - Source code and contributions
