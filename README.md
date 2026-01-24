# json

A fully RFC 8259 compliant JSON library for Zig 0.15.2 with JSON Schema 2020-12 validation.

[![Build Status](https://gitlab.com/devnw/zig/json/badges/main/pipeline.svg)](https://gitlab.com/devnw/zig/json/-/pipelines)

## Features

- **RFC 8259 Compliant Parsing** - Strict JSON parsing with proper error handling
- **JSON Schema 2020-12 Validation** - Full draft support with ECMA-262 regex
- **Type-Safe Encoding** - Encode any Zig type to JSON with comptime reflection
- **Streaming Output** - Writer-based API for memory-efficient encoding
- **Pretty Printing** - Configurable indentation and formatting
- **Normalized Numbers** - Exact decimal representation without floating-point errors
- **Unicode Support** - Full UTF-8 and surrogate pair handling
- **Zero External Dependencies** - Pure Zig implementation

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

## Quick Start

### Parse JSON

```zig
const std = @import("std");
const json = @import("json");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input =
        \\{"name": "json", "version": 1}
    ;

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    // Access parsed values
    for (doc.root.obj) |member| {
        std.debug.print("{s}: ", .{member.k});
        switch (member.v) {
            .str => |s| std.debug.print("{s}\n", .{s}),
            .num => |n| std.debug.print("{s}\n", .{n.lexeme}),
            else => std.debug.print("...\n", .{}),
        }
    }
}
```

### Encode Zig Types

```zig
const Point = struct { x: i32, y: i32 };
const point = Point{ .x = 10, .y = 20 };

// Minified output
const output = try json.encode(allocator, point, .{});
defer allocator.free(output);
// {"x":10,"y":20}

// Pretty printed
const pretty = try json.encode(allocator, point, .{ .indent = "  " });
defer allocator.free(pretty);
// {
//   "x": 10,
//   "y": 20
// }
```

### Validate with JSON Schema

```zig
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

// Compile schema
var schema_doc = try json.parse(allocator, schema_json, .{}, &err);
defer schema_doc.deinit();

var compiled = try json.compileSchema(allocator, &schema_doc, .{}, null, &err);
defer compiled.deinit();

// Validate instance
var data_doc = try json.parse(allocator, "{\"name\": \"Alice\"}", .{}, &err);
defer data_doc.deinit();

const report = try json.validate(allocator, &compiled, data_doc.root, .{});
defer allocator.free(report.errors);

if (report.ok) {
    std.debug.print("Valid!\n", .{});
}
```

## Documentation

- **[Getting Started](docs/GETTING_STARTED.md)** - Installation and first steps
- **[API Reference](docs/API.md)** - Complete API documentation
- **[Examples](docs/EXAMPLES.md)** - Usage patterns and recipes
- **[Roadmap](docs/ROADMAP.md)** - Planned features and issue tracking

## Supported Types for Encoding

| Zig Type | JSON Output |
|----------|-------------|
| `bool` | `true` / `false` |
| `integers` | Number |
| `floats` | Number (NaN/Inf → `null`) |
| `[]const u8` | String |
| `?T` | Value or `null` |
| `enum` | String (tag name) |
| `struct` | Object |
| `tuple` | Array |
| `[]T`, `[N]T` | Array |
| `union(enum)` | `{"tag": value}` |

## Building

```bash
# Build the library
zig build

# Run all tests
zig build test-all --summary all

# Individual test suites
zig build test          # Unit tests
zig build test-accept   # Acceptance tests
zig build test-data     # Edge case tests
zig build test-schema   # JSON Schema test suite

# Generate documentation
zig build docs
```

## Project Structure

```
json/
├── src/
│   ├── json.zig        # Main library interface
│   ├── parser.zig      # RFC 8259 parser
│   ├── emitter.zig     # Value stringification
│   ├── encode.zig      # Zig type encoding
│   ├── schema.zig      # JSON Schema validator
│   ├── number.zig      # Decimal number handling
│   ├── unicode.zig     # UTF-8 utilities
│   ├── pointer.zig     # JSON Pointer (RFC 6901)
│   └── regex_ecma262.zig # Pattern validation
├── tests/
│   ├── accept.zig      # Acceptance tests
│   ├── testdata.zig    # Edge case tests
│   └── schema_suite.zig # JSON Schema test suite
├── docs/               # Documentation
├── testdata/           # Test fixtures
└── build.zig
```

## Specifications

This library implements:

- **[RFC 8259](https://datatracker.ietf.org/doc/html/rfc8259)** - JSON Data Interchange Format
- **[RFC 6901](https://datatracker.ietf.org/doc/html/rfc6901)** - JSON Pointer
- **[JSON Schema 2020-12](https://json-schema.org/specification)** - Validation vocabulary

## Roadmap

Key planned features (see [full roadmap](docs/ROADMAP.md)):

| Feature | Priority | Issue |
|---------|----------|-------|
| JSON to Zig type unmarshaling | Critical | [#7](https://gitlab.com/devnw/zig/json/-/issues/7) |
| Streaming tokenizer | High | [#8](https://gitlab.com/devnw/zig/json/-/issues/8) |
| Custom marshaler interface | High | [#9](https://gitlab.com/devnw/zig/json/-/issues/9) |
| Struct field tags | High | [#10](https://gitlab.com/devnw/zig/json/-/issues/10) |
| Time/Duration support | High | [#11](https://gitlab.com/devnw/zig/json/-/issues/11) |

## Cross-Platform Support

| Platform | Status |
|----------|--------|
| Linux x86_64 | ✅ Tested |
| Linux ARM64 | ✅ Tested |
| macOS ARM64 | ✅ Tested |
| macOS x86_64 | ✅ Tested |
| Windows x86_64 | ✅ Tested |
| FreeBSD x86_64 | ✅ Builds |
| NetBSD x86_64 | ✅ Builds |

## Contributing

Contributions are welcome! Please check the [issue tracker](https://gitlab.com/devnw/zig/json/-/issues) for open tasks.

1. Pick an issue or create one for your feature
2. Fork the repository
3. Create your feature branch
4. Add tests for new functionality
5. Submit a merge request

## License

Apache-2.0 License - See [LICENSE](LICENSE) for details.
