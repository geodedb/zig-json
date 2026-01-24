# JSON Library Examples

This directory contains practical examples demonstrating the features of the JSON library.

## Examples Overview

| Example | Description |
|---------|-------------|
| `01_basic_parsing.zig` | Parse JSON strings into Zig data structures |
| `02_encoding.zig` | Encode Zig types to JSON with various formatting options |
| `03_schema_validation.zig` | Validate JSON data against JSON Schema (draft 2020-12) |
| `04_unmarshaling.zig` | Type-safe JSON to Zig struct conversion |
| `05_field_tags.zig` | Customize field names and behavior with `json_config` |
| `06_json_patch.zig` | Modify JSON documents with RFC 6902 JSON Patch |
| `07_jsonpath.zig` | Query JSON documents with JSONPath expressions |
| `08_streaming.zig` | Memory-efficient streaming parsing and encoding |
| `09_custom_marshaler.zig` | Implement custom serialization with `jsonMarshal` |
| `10_json5.zig` | JSON5 extended syntax (comments, trailing commas, etc.) |

## Building and Running Examples

### Using the Example Build File

```bash
# Build all examples
zig build -f examples/build.zig

# Run a specific example
zig build run-01 -f examples/build.zig
zig build run-02 -f examples/build.zig
# etc.
```

### Running Directly

```bash
cd examples
zig run 01_basic_parsing.zig --main-mod-path .. --deps json
```

### Quick Test

```bash
# From the json library root
zig test examples/01_basic_parsing.zig --main-mod-path . --deps json
```

## Example Highlights

### 1. Basic Parsing

```zig
const input = \\{"name": "Alice", "age": 30};
var err = json.ParseError.init();
var doc = try json.parse(allocator, input, .{}, &err);
defer doc.deinit();

// Access values
for (doc.root.obj) |member| {
    std.debug.print("{s}: ", .{member.k});
}
```

### 2. Encoding Zig Types

```zig
const Point = struct { x: i32, y: i32 };
const point = Point{ .x = 10, .y = 20 };

// Minified
const min = try json.encode(allocator, point, .{});
// Pretty printed
const pretty = try json.encode(allocator, point, .{ .indent = "  " });
```

### 3. Schema Validation

```zig
const schema_json = \\{"type": "string", "minLength": 1};
var schema_doc = try json.parse(allocator, schema_json, .{}, &err);
var compiled = try json.compileSchema(allocator, &schema_doc, .{}, null, &err);

var data_doc = try json.parse(allocator, "\"hello\"", .{}, &err);
const report = try json.validate(allocator, &compiled, data_doc.root, .{});

if (report.ok) {
    std.debug.print("Valid!\n", .{});
}
```

### 4. Unmarshaling to Structs

```zig
const User = struct { name: []const u8, age: u32 };
const input = \\{"name": "Alice", "age": 30};

var user = try json.unmarshal(User, allocator, input);
defer json.free(User, allocator, &user);

std.debug.print("Name: {s}, Age: {d}\n", .{user.name, user.age});
```

### 5. Field Tags

```zig
const User = struct {
    first_name: []const u8,
    password: []const u8,

    pub const json_config = .{
        .first_name = json.FieldConfig{ .name = "firstName" },
        .password = json.FieldConfig{ .skip = true },
    };
};
```

### 6. JSON Patch

```zig
const ops = [_]json.PatchOperation{
    .{ .op = .add, .path = "/email", .value = json.Value{ .str = "test@example.com" } },
    .{ .op = .remove, .path = "/age" },
};

var result = try json.applyPatch(allocator, original.root, &ops);
```

### 7. JSONPath Query

```zig
var result = try json.jsonpath(allocator, doc.root, "$.store.books[*].title");
defer result.deinit();

for (result.values) |title| {
    std.debug.print("Title: {s}\n", .{title.str});
}
```

### 8. Streaming

```zig
// Tokenizer for memory-efficient parsing
var tokenizer = json.Tokenizer.init(input, .{});
while (true) {
    const token = tokenizer.next() catch break;
    if (token.token_type == .eof) break;
    // Process token...
}

// Streaming encoder
var encoder = json.streamingEncoder(allocator, writer, .{});
try encoder.beginObject();
try encoder.writeObjectKey("name");
try encoder.writeString("value");
try encoder.endObject();
```

### 9. Custom Marshaler

```zig
const Point = struct {
    x: f64, y: f64,

    pub fn jsonMarshal(self: @This(), allocator: Allocator) !json.Value {
        var arr = try allocator.alloc(json.Value, 2);
        arr[0] = try json.toValue(allocator, self.x, .{});
        arr[1] = try json.toValue(allocator, self.y, .{});
        return .{ .arr = arr };
    }
};
// Encodes as [x, y] instead of {"x": ..., "y": ...}
```

## Key Concepts

### Memory Management

- Always call `doc.deinit()` after parsing to free memory
- Use `defer` for cleanup: `defer doc.deinit();`
- For unmarshaled types, use `json.free(T, allocator, &value)`
- Encoded strings must be freed: `defer allocator.free(json_string);`

### Error Handling

```zig
var err = json.ParseError.init();
const doc = json.parse(allocator, input, .{}, &err) catch |e| {
    std.debug.print("Error at line {d}, col {d}: {}\n", .{
        err.line, err.col, err.code
    });
    return e;
};
```

### Parse Options

```zig
const opts = json.ParseOptions{
    .max_bytes = 1024 * 1024,  // 1MB limit
    .max_depth = 64,           // Nesting limit
    .max_nodes = 10000,        // Node count limit
    .unique_keys = true,       // Reject duplicate keys
    .json5 = false,            // Strict RFC 8259
};
```

### Encode Options

```zig
const opts = json.EncodeOptions{
    .indent = "  ",                    // Pretty print
    .emit_null_optional_fields = true, // Include null fields
    .escape_non_ascii = true,          // \uXXXX escaping
    .deterministic = true,             // Sorted keys
    .stringify_numbers = true,         // Numbers as strings
};
```

## License

Apache-2.0 - See the main project LICENSE file.
