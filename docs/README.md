# zig-json Documentation

A fully RFC 8259 compliant JSON library for Zig with JSON Schema 2020-12 validation support.

## Table of Contents

- [Getting Started](./GETTING_STARTED.md)
- [API Reference](./API.md)
- [Examples](./EXAMPLES.md)
- [Roadmap](./ROADMAP.md)

## Features

### Current Features

- **RFC 8259 Compliant Parsing** - Strict JSON parsing with proper error handling
- **JSON Schema 2020-12 Validation** - Full draft 2020-12 support with ECMA-262 regex
- **Type-Safe Encoding** - Encode any Zig type to JSON with comptime reflection
- **Streaming Output** - Writer-based API for memory-efficient encoding
- **Pretty Printing** - Configurable indentation and formatting
- **Normalized Numbers** - Exact decimal representation without floating-point errors
- **Unicode Support** - Full UTF-8 and surrogate pair handling

### Planned Features

See the [Roadmap](./ROADMAP.md) for upcoming features and their implementation status.

## Quick Example

```zig
const std = @import("std");
const json = @import("json");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse JSON
    var err = json.ParseError.init();
    var doc = try json.parse(allocator,
        \\{"name": "zig-json", "version": 1}
    , .{}, &err);
    defer doc.deinit();

    // Encode Zig types to JSON
    const Point = struct { x: i32, y: i32 };
    const point = Point{ .x = 10, .y = 20 };

    const output = try json.encode(allocator, point, .{});
    defer allocator.free(output);
    // output: {"x":10,"y":20}
}
```

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .json = .{
        .url = "https://gitlab.com/devnw/zig/json/-/archive/main/json-main.tar.gz",
        // Add hash after first fetch
    },
},
```

Then in your `build.zig`:

```zig
const json = b.dependency("json", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("json", json.module("json"));
```

## Project Links

- [GitLab Repository](https://gitlab.com/devnw/zig/json)
- [Issue Tracker](https://gitlab.com/devnw/zig/json/-/issues)
- [Roadmap & Planned Features](./ROADMAP.md)
