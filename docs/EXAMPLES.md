# Examples

Practical examples demonstrating zig-json usage patterns.

## Table of Contents

- [Basic Parsing](#basic-parsing)
- [Encoding Zig Types](#encoding-zig-types)
- [Unmarshaling to Zig Types](#unmarshaling-to-zig-types)
- [Time and Duration Types](#time-and-duration-types)
- [JSON Schema Validation](#json-schema-validation)
- [JSON Patch Operations](#json-patch-operations)
- [JSONPath Queries](#jsonpath-queries)
- [JSON Lines (JSONL)](#json-lines-jsonl)
- [Schema Generation](#schema-generation)
- [Streaming Tokenizer](#streaming-tokenizer)
- [Async Incremental Parsing](#async-incremental-parsing)
- [SIMD Acceleration](#simd-acceleration)
- [CBOR Binary Encoding](#cbor-binary-encoding)
- [JSON-LD Processing](#json-ld-processing)
- [Working with Values](#working-with-values)
- [Pretty Printing](#pretty-printing)
- [Error Handling](#error-handling)
- [Streaming Output](#streaming-output)

---

## Basic Parsing

### Parse a JSON String

```zig
const std = @import("std");
const json = @import("json");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input =
        \\{
        \\  "name": "Alice",
        \\  "age": 30,
        \\  "emails": ["alice@example.com", "alice@work.com"]
        \\}
    ;

    var err = json.ParseError.init();
    var doc = try json.parse(allocator, input, .{}, &err);
    defer doc.deinit();

    // Access the root value
    std.debug.print("Parsed JSON with {d} members\n", .{doc.root.obj.len});
}
```

### Parse with Custom Options

```zig
var doc = try json.parse(allocator, input, .{
    .max_bytes = 1024 * 1024,      // 1MB limit
    .max_depth = 32,               // Max nesting depth
    .unique_keys = true,           // Reject duplicate keys
    .allow_bom = false,            // Reject UTF-8 BOM
}, &err);
```

---

## Encoding Zig Types

### Encode a Struct

```zig
const Point = struct {
    x: i32,
    y: i32,
    label: ?[]const u8 = null,
};

const p = Point{ .x = 100, .y = 200, .label = "origin" };

const output = try json.encode(allocator, p, .{});
defer allocator.free(output);
// {"x":100,"y":200,"label":"origin"}
```

### Field Configuration

```zig
const Person = struct {
    first_name: []const u8,
    last_name: []const u8,
    internal_id: u64,
    ssn: []const u8,

    pub const json_config = .{
        .first_name = json.FieldConfig{ .name = "firstName" },
        .last_name = json.FieldConfig{ .name = "lastName" },
        .internal_id = json.FieldConfig{ .skip = true },
        .ssn = json.FieldConfig{ .omitempty = true },
    };
};

const person = Person{
    .first_name = "John",
    .last_name = "Doe",
    .internal_id = 12345,
    .ssn = "",
};

const output = try json.encode(allocator, person, .{});
// {"firstName":"John","lastName":"Doe"}
```

### Binary Data Encoding

```zig
const Document = struct {
    name: []const u8,
    data: []const u8,

    pub const json_config = .{
        .data = json.FieldConfig{ .binary_format = .base64 },
    };
};

const doc = Document{
    .name = "secret.pdf",
    .data = "\x00\x01\x02\x03\x04",
};

const output = try json.encode(allocator, doc, .{});
// {"name":"secret.pdf","data":"AAECAwQ="}
```

### Custom Marshaler

```zig
const Point3D = struct {
    x: f64,
    y: f64,
    z: f64,

    pub fn jsonMarshal(self: @This(), alloc: std.mem.Allocator) !json.Value {
        var arr = try alloc.alloc(json.Value, 3);
        arr[0] = try json.toValue(alloc, self.x, .{});
        arr[1] = try json.toValue(alloc, self.y, .{});
        arr[2] = try json.toValue(alloc, self.z, .{});
        return .{ .arr = arr };
    }
};

const p = Point3D{ .x = 1.0, .y = 2.0, .z = 3.0 };
const output = try json.encode(allocator, p, .{ .allocator = allocator });
// [1,2,3]
```

---

## Unmarshaling to Zig Types

### Basic Unmarshaling

```zig
const Person = struct {
    name: []const u8,
    age: ?i32 = null,
    tags: []const []const u8 = &.{},
};

const input = "{\"name\": \"Alice\", \"age\": 30, \"tags\": [\"admin\", \"user\"]}";

var p = try json.unmarshal(Person, allocator, input);
defer json.free(Person, allocator, &p);

std.debug.print("Name: {s}, Age: {d}\n", .{p.name, p.age.?});
for (p.tags) |tag| {
    std.debug.print("  Tag: {s}\n", .{tag});
}
```

### Unmarshal with Error Info

```zig
const result = json.unmarshalWithInfo(Person, allocator, input);
switch (result) {
    .ok => |value| {
        defer json.free(Person, allocator, &value);
        // Use value
    },
    .err => |info| {
        std.debug.print("Error at {s}: {s}\n", .{info.path, info.message});
        std.debug.print("Expected: {s}, Found: {s}\n", .{
            info.expected orelse "N/A",
            info.found orelse "N/A",
        });
    },
}
```

### Custom Unmarshaler

```zig
const Point3D = struct {
    x: f64,
    y: f64,
    z: f64,

    pub fn jsonUnmarshal(alloc: std.mem.Allocator, value: json.Value) !Point3D {
        _ = alloc;
        if (value != .arr or value.arr.len != 3) return error.InvalidFormat;
        return .{
            .x = std.fmt.parseFloat(f64, value.arr[0].num.lexeme) catch return error.InvalidFormat,
            .y = std.fmt.parseFloat(f64, value.arr[1].num.lexeme) catch return error.InvalidFormat,
            .z = std.fmt.parseFloat(f64, value.arr[2].num.lexeme) catch return error.InvalidFormat,
        };
    }
};

const p = try json.unmarshal(Point3D, allocator, "[1.5, 2.5, 3.5]");
// p.x = 1.5, p.y = 2.5, p.z = 3.5
```

---

## Time and Duration Types

### RFC 3339 Timestamps

```zig
const Event = struct {
    name: []const u8,
    timestamp: json.Timestamp,
};

// Encode
const event = Event{
    .name = "deployment",
    .timestamp = json.Timestamp.fromUnix(1705314600),
};
const output = try json.encode(allocator, event, .{});
// {"name":"deployment","timestamp":"2024-01-15T10:30:00Z"}

// Unmarshal
const parsed = try json.unmarshal(Event, allocator, output);
std.debug.print("Unix time: {d}\n", .{parsed.timestamp.toUnix()});
```

### Unix Timestamps

```zig
const Response = struct {
    created_at: json.UnixTimestamp,
    updated_at: json.UnixTimestampMs,
};

const resp = Response{
    .created_at = .{ .seconds = 1705314600 },
    .updated_at = .{ .milliseconds = 1705314600123 },
};
const output = try json.encode(allocator, resp, .{});
// {"created_at":1705314600,"updated_at":1705314600123}
```

### Custom Formatted Timestamps

```zig
const SqlTimestamp = json.FormattedTimestamp(json.TimeFormat.sql_datetime);

const Record = struct {
    id: u64,
    created: SqlTimestamp,
};

const record = Record{
    .id = 1,
    .created = SqlTimestamp.fromUnix(1705314600),
};
const output = try json.encode(allocator, record, .{});
// {"id":1,"created":"2024-01-15 10:30:00"}
```

### ISO 8601 Durations

```zig
const Task = struct {
    name: []const u8,
    timeout: json.Duration,
};

const task = Task{
    .name = "backup",
    .timeout = json.Duration.fromSeconds(2 * 3600 + 30 * 60),
};
const output = try json.encode(allocator, task, .{});
// {"name":"backup","timeout":"PT2H30M"}
```

---

## JSON Schema Validation

### Basic Validation

```zig
const schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "name": {"type": "string", "minLength": 1},
    \\    "age": {"type": "integer", "minimum": 0, "maximum": 150}
    \\  },
    \\  "required": ["name", "age"]
    \\}
;

var err = json.ParseError.init();

// Parse and compile the schema
var schema_doc = try json.parse(allocator, schema_json, .{}, &err);
defer schema_doc.deinit();

var compiled = try json.compileSchema(allocator, &schema_doc, .{}, null, &err);
defer compiled.deinit();

// Validate
var instance_doc = try json.parse(allocator, "{\"name\": \"Alice\", \"age\": 30}", .{}, &err);
defer instance_doc.deinit();

const report = try json.validate(allocator, &compiled, instance_doc.root, .{});
defer allocator.free(report.errors);

if (report.ok) {
    std.debug.print("Valid!\n", .{});
}
```

### Handling Validation Errors

```zig
if (!report.ok) {
    for (report.errors) |e| {
        std.debug.print("Error at {s}: {s} ({s})\n", .{
            e.instance_ptr,
            e.message,
            e.keyword,
        });
    }
}
```

---

## JSON Patch Operations

### Apply Patch

```zig
const patch_mod = json.patch_mod;

var err = json.ParseError.init();
var doc = try json.parse(allocator, "{\"name\": \"Alice\", \"age\": 30}", .{}, &err);
defer doc.deinit();

const ops = [_]patch_mod.Operation{
    .{ .op = .replace, .path = "/age", .value = .{ .num = json.Number.fromInt(31) } },
    .{ .op = .add, .path = "/email", .value = .{ .str = "alice@example.com" } },
    .{ .op = .remove, .path = "/name" },
};

const result = try patch_mod.apply(allocator, doc.root, &ops);
defer patch_mod.freeValue(allocator, result);

const output = try json.stringify(allocator, result);
defer allocator.free(output);
// {"age":31,"email":"alice@example.com"}
```

### Generate Diff Patch

```zig
var from_doc = try json.parse(allocator, "{\"name\": \"Alice\"}", .{}, &err);
defer from_doc.deinit();

var to_doc = try json.parse(allocator, "{\"name\": \"Bob\", \"age\": 30}", .{}, &err);
defer to_doc.deinit();

const patch = try patch_mod.diff(allocator, from_doc.root, to_doc.root);
defer allocator.free(patch);

// patch contains: [{"op":"replace","path":"/name","value":"Bob"},{"op":"add","path":"/age","value":30}]
```

---

## JSONPath Queries

### Basic Queries

```zig
const input =
    \\{
    \\  "store": {
    \\    "books": [
    \\      {"title": "Book 1", "price": 10},
    \\      {"title": "Book 2", "price": 15},
    \\      {"title": "Book 3", "price": 20}
    \\    ]
    \\  }
    \\}
;

var err = json.ParseError.init();
var doc = try json.parse(allocator, input, .{}, &err);
defer doc.deinit();

// Get all book titles
var result = try json.jsonpath(allocator, doc.root, "$.store.books[*].title");
defer result.deinit();

for (result.values) |v| {
    std.debug.print("Title: {s}\n", .{v.str});
}
```

### Filter Expressions

```zig
// Books with price > 12
var result = try json.jsonpath(allocator, doc.root, "$.store.books[?(@.price > 12)]");
defer result.deinit();
// Returns Book 2 and Book 3

// Recursive descent - all prices anywhere in document
var all_prices = try json.jsonpath(allocator, doc.root, "$..price");
defer all_prices.deinit();
```

### Union Expressions

```zig
// Get first and third books
var result = try json.jsonpath(allocator, doc.root, "$.store.books[0,2]");
defer result.deinit();

// Get specific fields
var fields = try json.jsonpath(allocator, doc.root, "$.store.books[0]['title','price']");
defer fields.deinit();
```

---

## JSON Lines (JSONL)

### Parse JSONL File

```zig
const input =
    \\{"name": "Alice", "age": 30}
    \\{"name": "Bob", "age": 25}
    \\{"name": "Charlie", "age": 35}
;

var err_out = json.JsonlError.init();
var doc = try json.parseJsonl(allocator, input, .{}, &err_out);
defer doc.deinit();

// doc.root is an array of the parsed lines
for (doc.root.arr) |line| {
    const name = json.pointer_mod.evaluate(line, "/name");
    if (name) |n| std.debug.print("Name: {s}\n", .{n.str});
}
```

### Stream JSONL

```zig
var iter = json.jsonlIterator(allocator, input, .{});
defer iter.deinit();

while (try iter.next()) |value| {
    defer iter.freeValue(value);

    // Process each line individually
    const output = try json.stringify(allocator, value);
    defer allocator.free(output);
    std.debug.print("Line: {s}\n", .{output});
}
```

---

## Schema Generation

### Generate from Type

```zig
const Person = struct {
    name: []const u8,
    age: ?i32,
    email: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
};

const schema = try json.generateSchema(Person, allocator, .{});
defer json.freeSchema(allocator, schema);

const output = try json.stringify(allocator, schema);
defer allocator.free(output);
// {
//   "type": "object",
//   "properties": {
//     "name": {"type": "string"},
//     "age": {"type": ["integer", "null"]},
//     "email": {"type": ["string", "null"]},
//     "tags": {"type": "array", "items": {"type": "string"}}
//   },
//   "required": ["name"]
// }
```

---

## Streaming Tokenizer

### Low-Level Tokenization

```zig
const input = "{\"name\": \"Alice\", \"values\": [1, 2, 3]}";

var tokenizer = json.Tokenizer.init(input, .{});

while (true) {
    const token = tokenizer.next() catch |err| {
        std.debug.print("Error: {}\n", .{err});
        break;
    };

    if (token.type == .eof) break;

    switch (token.type) {
        .object_begin => std.debug.print("Object start\n", .{}),
        .object_end => std.debug.print("Object end\n", .{}),
        .array_begin => std.debug.print("Array start\n", .{}),
        .array_end => std.debug.print("Array end\n", .{}),
        .string => std.debug.print("String: {s}\n", .{token.value.?}),
        .number => std.debug.print("Number: {s}\n", .{token.value.?}),
        else => {},
    }
}
```

### Read from File

```zig
var file = try std.fs.cwd().openFile("data.json", .{});
defer file.close();

var tokenizer = json.readerTokenizer(allocator, file.reader(), .{});
defer tokenizer.deinit();

while (try tokenizer.next()) |token| {
    // Process tokens
}
```

---

## Async Incremental Parsing

### Feed Chunks Incrementally

```zig
var parser = json.AsyncParser.init(allocator, .{});
defer parser.deinit();

// Simulate receiving data in chunks
const chunks = [_][]const u8{
    "{\"name\":",
    " \"Alice\",",
    " \"age\": 30}",
};

for (chunks) |chunk| {
    try parser.feed(chunk);
}

if (try parser.finish()) |doc| {
    defer doc.deinit();
    std.debug.print("Parsed complete document\n", .{});
}
```

### Error Recovery

```zig
var parser = json.AsyncParser.init(allocator, .{
    .recovery_mode = .skip_value,
});
defer parser.deinit();

// Feed potentially malformed JSON
try parser.feed("[1, invalid, 3]");

if (try parser.finish()) |doc| {
    defer doc.deinit();
    std.debug.print("Recovered from {d} errors\n", .{parser.errors_recovered});
}
```

---

## SIMD Acceleration

### SIMD Parser

```zig
var parser = json.SimdParser.init(allocator, .{});
defer parser.deinit();

const doc = try parser.parse(large_json_input);
defer doc.deinit();
```

### Feature Detection

```zig
const features = json.simd_mod.detectFeatures();

std.debug.print("SIMD Support: {s}\n", .{features.describe()});
std.debug.print("  SSE4.2: {}\n", .{features.has_sse42});
std.debug.print("  AVX2: {}\n", .{features.has_avx2});
std.debug.print("  AVX-512F: {}\n", .{features.has_avx512f});
std.debug.print("  NEON: {}\n", .{features.has_neon});
std.debug.print("  Recommended width: {d}\n", .{features.recommended_width});
```

---

## CBOR Binary Encoding

### JSON to CBOR

```zig
var err = json.ParseError.init();
var doc = try json.parse(allocator, "{\"name\": \"Alice\", \"age\": 30}", .{}, &err);
defer doc.deinit();

const cbor_bytes = try json.cborEncode(allocator, doc.root, .{});
defer allocator.free(cbor_bytes);

std.debug.print("CBOR size: {d} bytes\n", .{cbor_bytes.len});
```

### CBOR to JSON

```zig
const decoded = try json.cborDecode(allocator, cbor_bytes, .{});
defer json.cborFree(allocator, decoded);

const json_output = try json.stringify(allocator, decoded);
defer allocator.free(json_output);
```

### Streaming CBOR Decoder

```zig
var decoder = json.cbor_mod.StreamingDecoder.init(allocator);
defer decoder.deinit();

// Feed CBOR data incrementally
for (chunks) |chunk| {
    try decoder.feed(chunk);

    while (true) {
        const result = decoder.decodeNext();
        switch (result) {
            .value => |v| {
                // Complete value decoded
                const output = try json.stringify(allocator, v);
                defer allocator.free(output);
                std.debug.print("Decoded: {s}\n", .{output});
            },
            .need_data => break,
            .done => break,
            .err => |e| return e,
        }
    }
}
```

### CBOR Diagnostic Notation

```zig
const diagnostic = try json.cborToDiagnostic(allocator, cbor_bytes);
defer allocator.free(diagnostic);
// {"name": "Alice", "age": 30}
```

---

## JSON-LD Processing

### Expand JSON-LD

```zig
const input =
    \\{
    \\  "@context": {
    \\    "name": "http://schema.org/name",
    \\    "Person": "http://schema.org/Person"
    \\  },
    \\  "@type": "Person",
    \\  "name": "Alice"
    \\}
;

var err = json.ParseError.init();
var doc = try json.parse(allocator, input, .{}, &err);
defer doc.deinit();

const expanded = try json.ldExpand(allocator, doc.root, .{});
defer json.ldFree(allocator, expanded);

const output = try json.stringify(allocator, expanded);
defer allocator.free(output);
// [{"@type":["http://schema.org/Person"],"http://schema.org/name":[{"@value":"Alice"}]}]
```

### Compact with Context

```zig
const context =
    \\{
    \\  "name": "http://schema.org/name",
    \\  "Person": "http://schema.org/Person"
    \\}
;

var ctx_doc = try json.parse(allocator, context, .{}, &err);
defer ctx_doc.deinit();

const compacted = try json.ldCompact(allocator, expanded, ctx_doc.root, .{});
defer json.ldFree(allocator, compacted);
```

### Remote Context Loading

```zig
var loader = json.jsonld_mod.RemoteContextLoader.init(allocator);
defer loader.deinit();

// Preload common contexts
try loader.preloadContext("https://schema.org/", schema_org_context);
try loader.preloadContext("https://w3id.org/security/v1", security_context);

// Use in JSON-LD processing
const options = json.LdOptions{
    .context_loader = &loader,
};

const expanded = try json.ldExpand(allocator, doc.root, options);
```

### Convert to N-Quads

```zig
const nquads = try json.ldToNQuads(allocator, doc.root, .{});
defer allocator.free(nquads);
// <http://example.org/alice> <http://schema.org/name> "Alice" .
```

---

## Working with Values

### Navigate Object Members

```zig
var doc = try json.parse(allocator, input, .{}, &err);
defer doc.deinit();

if (doc.root == .obj) {
    for (doc.root.obj) |member| {
        std.debug.print("Key: {s}\n", .{member.k});

        switch (member.v) {
            .str => |s| std.debug.print("  String: {s}\n", .{s}),
            .num => |n| std.debug.print("  Number: {s}\n", .{n.lexeme}),
            .bool => |b| std.debug.print("  Bool: {}\n", .{b}),
            .null => std.debug.print("  Null\n", .{}),
            .arr => |a| std.debug.print("  Array with {d} items\n", .{a.len}),
            .obj => |o| std.debug.print("  Object with {d} members\n", .{o.len}),
        }
    }
}
```

### Use JSON Pointer

```zig
const pointer = json.pointer_mod;

// Get nested value
if (pointer.evaluate(doc.root, "/users/0/email")) |value| {
    if (value == .str) {
        std.debug.print("Email: {s}\n", .{value.str});
    }
}
```

### Compare Values

```zig
var doc1 = try json.parse(allocator, "{\"a\":1,\"b\":2}", .{}, &err);
defer doc1.deinit();

var doc2 = try json.parse(allocator, "{\"b\":2,\"a\":1}", .{}, &err);
defer doc2.deinit();

// Objects with same content are equal regardless of key order
if (doc1.root.eql(doc2.root)) {
    std.debug.print("Values are equal\n", .{});
}
```

---

## Pretty Printing

### Using Preset Options

```zig
const data = .{ .x = 1, .y = 2, .nested = .{ .a = "hello" } };

// 2-space indentation
const pretty2 = try json.encode(allocator, data, json.encode_mod.pretty_2);

// 4-space indentation
const pretty4 = try json.encode(allocator, data, json.encode_mod.pretty_4);

// Tab indentation
const prettyTab = try json.encode(allocator, data, json.encode_mod.pretty_tab);
```

### Custom Indentation

```zig
const output = try json.encode(allocator, data, .{
    .indent = "    ",  // 4 spaces
});
```

---

## Error Handling

### Parse Errors

```zig
var err = json.ParseError.init();
const result = json.parse(allocator, "invalid json", .{}, &err);

if (result) |doc| {
    defer doc.deinit();
    // Success
} else |e| {
    std.debug.print("Parse error at line {d}, column {d}: {s}\n", .{
        err.line,
        err.col,
        @tagName(err.code),
    });
}
```

### Common Error Codes

```zig
switch (err.code) {
    .UnexpectedEof => std.debug.print("Unexpected end of input\n", .{}),
    .UnexpectedToken => std.debug.print("Unexpected character\n", .{}),
    .InvalidUtf8 => std.debug.print("Invalid UTF-8 sequence\n", .{}),
    .InvalidNumber => std.debug.print("Invalid number format\n", .{}),
    .DuplicateKey => std.debug.print("Duplicate object key\n", .{}),
    .DepthLimit => std.debug.print("Nesting too deep\n", .{}),
    else => std.debug.print("Error: {s}\n", .{@tagName(err.code)}),
}
```

---

## Streaming Output

### Write to File

```zig
var file = try std.fs.cwd().createFile("output.json", .{});
defer file.close();

const data = .{ .key = "value", .numbers = [_]i32{ 1, 2, 3 } };
try json.encodeToWriter(file.writer(), data, .{ .indent = "  " });
```

### Write to ArrayList

```zig
var list = std.ArrayList(u8).init(allocator);
defer list.deinit();

try json.encodeToWriter(list.writer(), data, .{});
const output = list.items;
```

### Write to stdout

```zig
const stdout = std.io.getStdOut().writer();
try json.encodeToWriter(stdout, data, .{ .indent = "  " });
try stdout.writeByte('\n');
```
