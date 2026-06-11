# API Reference

Complete API documentation for zig-json - a comprehensive JSON library for Zig 0.16.0.

## Table of Contents

- [Core Types](#core-types)
- [Parsing](#parsing)
- [Encoding](#encoding)
- [Unmarshaling](#unmarshaling)
- [Time Types](#time-types)
- [JSON Schema Validation](#json-schema-validation)
- [JSON Patch (RFC 6902)](#json-patch-rfc-6902)
- [JSON Lines (JSONL)](#json-lines-jsonl)
- [JSONPath Query](#jsonpath-query)
- [Schema Generation](#schema-generation)
- [Streaming Tokenizer](#streaming-tokenizer)
- [SIMD Primitives](#simd-primitives)
- [Async Parsing](#async-parsing)
- [JSON-LD](#json-ld)
- [CBOR Encoding](#cbor-encoding-rfc-8949)
- [Options Reference](#options-reference)

---

## Core Types

### `Value`

The fundamental JSON value type:

```zig
pub const Value = union(enum) {
    null,
    bool: bool,
    num: Number,
    str: []const u8,
    arr: []Value,
    obj: []Member,

    pub fn eql(a: Value, b: Value) bool;
};
```

### `Member`

Key-value pair in JSON objects:

```zig
pub const Member = struct {
    k: []const u8,  // Key
    v: Value,       // Value
};
```

### `Number`

Normalized base-10 decimal representation preserving exact precision:

```zig
pub const Number = struct {
    lexeme: []const u8,   // Original string representation
    sign: i8,             // 1 or -1
    digits: []const u8,   // Normalized digit string
    exp10: i32,           // Base-10 exponent

    pub fn isInteger(self: Number) bool;
    pub fn compare(a: Number, b: Number) i32;
    pub fn isMultipleOf(self: Number, divisor: Number) bool;
};
```

### `Document`

Parsed JSON document with arena allocator:

```zig
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: Value,

    pub fn deinit(self: *Document) void;
};
```

---

## Parsing

### `parse`

```zig
pub fn parse(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: ParseOptions,
    err: *ParseError
) !Document
```

Parse JSON input into a `Document` containing a `Value` tree.

**Example**:

```zig
var err = json.ParseError.init();
var doc = try json.parse(allocator, "{\"key\": \"value\"}", .{}, &err);
defer doc.deinit();

// Access the parsed value
for (doc.root.obj) |m| {
    std.debug.print("{s}: {any}\n", .{m.k, m.v});
}
```

### `stringify`

```zig
pub fn stringify(allocator: std.mem.Allocator, value: Value) ![]u8
```

Convert a `json.Value` to minified JSON string.

### `debugJson`

```zig
pub fn debugJson(allocator: std.mem.Allocator, value: Value) ![]u8
```

Convert to JSON with sorted keys and escaped non-ASCII. Useful for reproducible test output.

---

## Encoding

### `encode`

```zig
pub fn encode(
    allocator: std.mem.Allocator,
    value: anytype,
    options: EncodeOptions
) ![]u8
```

Encode any Zig value to a JSON string.

**Supported Types**:

| Zig Type | JSON Output |
|----------|-------------|
| `bool` | `true` / `false` |
| integers | Number |
| floats | Number (NaN/Inf -> `null` by default) |
| `[]const u8` | String |
| `?T` | Value or `null` |
| `enum` | String (tag name) |
| `struct` | Object |
| tuple | Array |
| `[]T`, `[N]T` | Array |
| `union(enum)` | `{"tag": payload}` |

**Example**:

```zig
const Point = struct { x: i32, y: i32 };
const p = Point{ .x = 10, .y = 20 };

const output = try json.encode(allocator, p, .{});
defer allocator.free(output);
// {"x":10,"y":20}

// With pretty printing
const pretty = try json.encode(allocator, p, .{ .indent = "  " });
defer allocator.free(pretty);
```

### `encodeToWriter`

```zig
pub fn encodeToWriter(
    writer: anytype,
    value: anytype,
    options: EncodeOptions
) !void
```

Encode directly to a writer (streaming):

```zig
var file = try std.fs.cwd().createFile("output.json", .{});
defer file.close();
try json.encodeToWriter(file.writer(), my_data, .{ .indent = "  " });
```

### `toValue`

```zig
pub fn toValue(
    allocator: std.mem.Allocator,
    value: anytype,
    options: EncodeOptions
) !Value
```

Convert any Zig value to a `json.Value` tree.

### Struct Field Configuration

Use `json_config` to customize field serialization:

```zig
const Person = struct {
    first_name: []const u8,
    last_name: []const u8,
    internal_id: u64,
    metadata: Metadata,

    pub const json_config = .{
        .first_name = FieldConfig{ .name = "firstName" },
        .last_name = FieldConfig{ .name = "lastName" },
        .internal_id = FieldConfig{ .skip = true },
        .metadata = FieldConfig{ .@"inline" = true },
    };
};
```

### `FieldConfig` Options

```zig
pub const FieldConfig = struct {
    name: ?[]const u8 = null,          // Custom JSON key name
    skip: bool = false,                 // Skip this field entirely
    omitempty: bool = false,            // Omit if null/zero/empty
    stringify: bool = false,            // Encode numbers as strings
    binary_format: ?BinaryFormat = null, // Encoding for []u8 fields
    @"inline": bool = false,            // Flatten nested struct fields
    unknown: bool = false,              // Capture unknown JSON members
};
```

### Binary Formats

```zig
pub const BinaryFormat = enum {
    utf8,        // Default - UTF-8 string
    base64,      // RFC 4648 standard Base64
    base64url,   // RFC 4648 URL-safe Base64
    hex,         // Lowercase hexadecimal
    hex_upper,   // Uppercase hexadecimal
    base32,      // RFC 4648 Base32
};
```

### Custom Marshaler

Types can implement `jsonMarshal` for custom serialization:

```zig
const Point = struct {
    x: f64,
    y: f64,

    pub fn jsonMarshal(self: @This(), allocator: std.mem.Allocator) !json.Value {
        var arr = try allocator.alloc(json.Value, 2);
        arr[0] = try json.toValue(allocator, self.x, .{});
        arr[1] = try json.toValue(allocator, self.y, .{});
        return .{ .arr = arr };
    }
};

// Encode with allocator for custom marshalers
const output = try json.encode(allocator, point, .{ .allocator = allocator });
```

---

## Unmarshaling

### `unmarshal`

```zig
pub fn unmarshal(
    comptime T: type,
    allocator: std.mem.Allocator,
    input: []const u8
) UnmarshalError!T
```

Parse JSON and decode into a Zig type:

```zig
const Person = struct {
    name: []const u8,
    age: ?i32 = null,
};

const p = try json.unmarshal(Person, allocator, "{\"name\": \"Alice\", \"age\": 30}");
defer json.free(Person, allocator, &p);

std.debug.print("Name: {s}, Age: {d}\n", .{p.name, p.age.?});
```

### `unmarshalWithInfo`

Returns detailed error information with JSON Pointer paths:

```zig
pub fn unmarshalWithInfo(
    comptime T: type,
    allocator: std.mem.Allocator,
    input: []const u8
) UnmarshalResult(T)
```

**Example**:

```zig
const result = json.unmarshalWithInfo(MyType, allocator, input);
switch (result) {
    .ok => |value| {
        // Use value
    },
    .err => |info| {
        std.debug.print("Error at {s}: {s}\n", .{info.path, info.message});
    },
}
```

### `fromValue`

Unmarshal from existing Value tree:

```zig
pub fn fromValue(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: Value
) UnmarshalError!T
```

### `free`

Free memory allocated during unmarshaling:

```zig
pub fn free(comptime T: type, allocator: std.mem.Allocator, value: *T) void
```

### Custom Unmarshaler

Types can implement `jsonUnmarshal`:

```zig
const Point = struct {
    x: f64,
    y: f64,

    pub fn jsonUnmarshal(allocator: std.mem.Allocator, value: json.Value) !Point {
        _ = allocator;
        if (value != .arr or value.arr.len != 2) return error.InvalidFormat;
        return .{
            .x = std.fmt.parseFloat(f64, value.arr[0].num.lexeme) catch return error.InvalidFormat,
            .y = std.fmt.parseFloat(f64, value.arr[1].num.lexeme) catch return error.InvalidFormat,
        };
    }
};
```

---

## Time Types

### `Timestamp`

RFC 3339 formatted timestamp:

```zig
const ts = json.Timestamp.fromUnix(1705314600);

// Convert to RFC 3339 string
const s = try ts.toRfc3339(allocator);
defer allocator.free(s);
// "2024-01-15T10:30:00Z"

// Parse from string
const parsed = try json.Timestamp.fromRfc3339("2024-01-15T10:30:00Z");
```

### `UnixTimestamp` / `UnixTimestampMs`

Unix timestamps as numbers:

```zig
const Response = struct {
    created_at: json.UnixTimestamp,
    updated_at: json.UnixTimestampMs,
};

// Encodes as: {"created_at":1705314600,"updated_at":1705314600000}
```

### `Duration`

ISO 8601 duration strings:

```zig
const d = json.Duration.fromSeconds(2 * 3600 + 30 * 60 + 15);
const s = try d.toIso8601(allocator);
defer allocator.free(s);
// "PT2H30M15S"
```

### `FormattedTimestamp`

Custom timestamp formats:

```zig
const SqlTimestamp = json.FormattedTimestamp(json.TimeFormat.sql_datetime);
const ts = SqlTimestamp.fromUnix(1705314600);

const s = try ts.format(allocator);
// "2024-01-15 10:30:00"
```

**Available Formats**:

- `TimeFormat.rfc3339` - `"%Y-%m-%dT%H:%M:%SZ"`
- `TimeFormat.rfc3339_ms` - `"%Y-%m-%dT%H:%M:%S.%fZ"`
- `TimeFormat.iso8601_date` - `"%Y-%m-%d"`
- `TimeFormat.us_date` - `"%m/%d/%Y"`
- `TimeFormat.eu_date` - `"%d/%m/%Y"`
- `TimeFormat.sql_datetime` - `"%Y-%m-%d %H:%M:%S"`

---

## JSON Schema Validation

### `compileSchema`

```zig
pub fn compileSchema(
    allocator: std.mem.Allocator,
    doc: *const Document,
    options: SchemaOptions,
    resolver: ?Resolver,
    err: *ParseError
) !CompiledSchema
```

### `validate`

```zig
pub fn validate(
    allocator: std.mem.Allocator,
    schema: *const CompiledSchema,
    instance: Value,
    options: SchemaOptions
) !ValidationReport
```

**Example**:

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
var schema_doc = try json.parse(allocator, schema_json, .{}, &err);
defer schema_doc.deinit();

var compiled = try json.compileSchema(allocator, &schema_doc, .{}, null, &err);
defer compiled.deinit();

const report = try json.validate(allocator, &compiled, instance, .{});
if (!report.ok) {
    for (report.errors) |e| {
        std.debug.print("Error at {s}: {s}\n", .{e.instance_ptr, e.message});
    }
}
```

---

## JSON Patch (RFC 6902)

### `applyPatch`

```zig
pub fn applyPatch(
    allocator: std.mem.Allocator,
    doc: Value,
    patch: []const PatchOperation
) PatchError!Value
```

### `parsePatch`

```zig
pub fn parsePatch(
    allocator: std.mem.Allocator,
    patch_doc: Value
) PatchError![]PatchOperation
```

### `diffPatch`

Generate a patch from two values:

```zig
pub fn diffPatch(
    allocator: std.mem.Allocator,
    from: Value,
    to: Value
) PatchError![]PatchOperation
```

### `applyMergePatch`

RFC 7396 Merge Patch:

```zig
pub fn applyMergePatch(
    allocator: std.mem.Allocator,
    target: Value,
    patch: Value
) PatchError!Value
```

**Example**:

```zig
const ops = [_]json.PatchOperation{
    .{ .op = .add, .path = "/tags", .value = .{ .arr = &[_]json.Value{} } },
    .{ .op = .add, .path = "/tags/-", .value = .{ .str = "new" } },
};

const result = try json.applyPatch(allocator, doc, &ops);
defer json.freePatchValue(allocator, result);
```

---

## JSON Lines (JSONL)

### `parseJsonl`

Parse entire JSONL document:

```zig
pub fn parseJsonl(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: JsonlOptions,
    err_out: *JsonlError
) !Document
```

### `jsonlIterator`

Stream JSONL line by line:

```zig
pub fn jsonlIterator(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: JsonlOptions
) JsonlIterator
```

**Example**:

```zig
const input =
    \\{"name": "Alice"}
    \\{"name": "Bob"}
;

var iter = json.jsonlIterator(allocator, input, .{});
defer iter.deinit();

while (try iter.next()) |value| {
    defer iter.freeValue(value);
    // Process each line
}
```

---

## JSONPath Query

### `jsonpath`

```zig
pub fn jsonpath(
    allocator: std.mem.Allocator,
    root: Value,
    path: []const u8
) PathError!QueryResult
```

**Supported Syntax**:

- `$` - Root element
- `.name` or `['name']` - Child element
- `..` - Recursive descent
- `*` - Wildcard (all children)
- `[n]` - Array index
- `[start:end:step]` - Array slice
- `[?(@.field == value)]` - Filter expression
- `[a,b,c]` or `[0,1,2]` - Union expressions

**Example**:

```zig
var result = try json.jsonpath(allocator, doc.root, "$.users[*].name");
defer result.deinit();

for (result.values) |name| {
    std.debug.print("Name: {s}\n", .{name.str});
}
```

---

## Schema Generation

### `generateSchema`

Generate JSON Schema from a Zig type:

```zig
pub fn generateSchema(
    comptime T: type,
    allocator: std.mem.Allocator,
    options: SchemaGenOptions
) !Value
```

**Example**:

```zig
const Person = struct {
    name: []const u8,
    age: ?i32,
    tags: []const []const u8,
};

const schema = try json.generateSchema(Person, allocator, .{});
defer json.freeSchema(allocator, schema);

const output = try json.stringify(allocator, schema);
defer allocator.free(output);
// {"type":"object","properties":{"name":{"type":"string"},...}}
```

---

## Streaming Tokenizer

### `Tokenizer`

Low-level token-based parsing:

```zig
var tokenizer = json.Tokenizer.init(input, .{});

while (tokenizer.next()) |token| {
    switch (token.type) {
        .object_begin => std.debug.print("{\n", .{}),
        .string => std.debug.print("String: {s}\n", .{token.value.?}),
        // ...
    }
} else |err| {
    // Handle error
}
```

### `ReaderTokenizer`

Tokenize from any reader:

```zig
var file = try std.fs.cwd().openFile("data.json", .{});
defer file.close();

var tokenizer = json.readerTokenizer(allocator, file.reader(), .{});
defer tokenizer.deinit();

while (try tokenizer.next()) |token| {
    // Process token
}
```

### `readValue`

Read complete values from tokenizer:

```zig
var tokenizer = json.Tokenizer.init(input, .{});
const value = try json.readValue(allocator, &tokenizer);
defer json.freeValue(allocator, value);
```

---

## SIMD Primitives

The library ships a set of standalone, tested SIMD scanning primitives in the
`simd` module (re-exported as `json.simd_mod`). They are **opt-in** and are
**not** wired into the default parser/tokenizer/unmarshaler, which are scalar.
They operate on raw byte slices and do not, by themselves, perform JSON
validation, escape decoding, or surrogate-pair handling.

### `SimdParser`

A standalone helper that wraps the scanning primitives with cursor and
line/column tracking. It is independent of the default `json.parse` entry
point and does not build a `Value`/`Document` tree:

```zig
var sp = json.SimdParser.init(input, .{});
sp.skipWhitespace();
const next = sp.findNextStructural();
_ = next;
```

### Batch Helpers

```zig
var processor = json.BatchProcessor.init(allocator);

// Locate string spans: returns []{ start, end }
const spans = try processor.findAllStrings(input);
defer allocator.free(spans);

// Count structural characters
const counts = processor.countStructurals(input);
// counts.objects, counts.arrays, counts.strings, counts.colons, counts.commas
```

### Free-Function Primitives

```zig
// Skip leading whitespace (returns index of first non-whitespace byte)
const first = json.skipWhitespaceSIMD(input);

// Validate UTF-8 (SIMD ASCII fast path with scalar fallback)
const valid = json.validateUtf8SIMD(input);

// Runtime check for SIMD availability
const have_simd = json.simdAvailable();
```

### Feature Detection

```zig
const features = json.simd_mod.detectFeatures();
std.debug.print("SIMD: {s}, Width: {d}\n", .{
    features.describe(),
    features.recommended_width,
});
```

### `SIMDFeatures`

```zig
pub const SIMDFeatures = struct {
    has_simd: bool,
    has_sse42: bool,
    has_avx2: bool,
    has_avx512f: bool,
    has_neon: bool,
    recommended_width: u8,

    pub fn describe(self: SIMDFeatures) []const u8;
};
```

---

## Async Parsing

### `AsyncParser`

Incremental async JSON parser:

```zig
var parser = json.AsyncParser.init(allocator, .{});
defer parser.deinit();

// Feed data incrementally
try parser.feed(chunk1);
try parser.feed(chunk2);

// Get result when complete
if (try parser.finish()) |doc| {
    defer doc.deinit();
    // Use parsed document
}
```

### Error Recovery

```zig
var parser = json.AsyncParser.init(allocator, .{
    .recovery_mode = .skip_value,
});

// Parser will attempt to recover from errors
try parser.feed(malformed_json);
std.debug.print("Recovered from {d} errors\n", .{parser.errors_recovered});
```

### `AsyncIterator`

Iterate over streaming JSON values:

```zig
var iter = json.AsyncIterator.init(allocator);
defer iter.deinit();

while (try iter.feed(chunk)) |value| {
    defer iter.freeValue(value);
    // Process complete value
}
```

---

## JSON-LD

### `ldExpand`

Expand JSON-LD document:

```zig
pub fn ldExpand(
    allocator: std.mem.Allocator,
    document: Value,
    options: LdOptions
) !Value
```

### `ldCompact`

Compact with context:

```zig
pub fn ldCompact(
    allocator: std.mem.Allocator,
    document: Value,
    context: Value,
    options: LdOptions
) !Value
```

### `ldFlatten` / `ldFrame`

```zig
pub fn ldFlatten(
    allocator: std.mem.Allocator,
    document: Value,
    context: ?Value,
    options: LdOptions
) !Value

pub fn ldFrame(
    allocator: std.mem.Allocator,
    document: Value,
    frame: Value,
    options: LdOptions
) !Value
```

### `ldToNQuads`

Convert to N-Quads format:

```zig
pub fn ldToNQuads(
    allocator: std.mem.Allocator,
    document: Value,
    options: LdOptions
) ![]const u8
```

### Remote Context Loading

```zig
var loader = json.jsonld_mod.RemoteContextLoader.init(allocator);
defer loader.deinit();

// Preload contexts
try loader.preloadContext("https://schema.org/", schema_org_context);

// Load with caching
const ctx = try loader.loadContext("https://schema.org/");
```

---

## CBOR Encoding (RFC 8949)

### `cborEncode`

```zig
pub fn cborEncode(
    allocator: std.mem.Allocator,
    value: Value,
    options: CborEncodeOptions
) ![]u8
```

### `cborDecode`

```zig
pub fn cborDecode(
    allocator: std.mem.Allocator,
    data: []const u8,
    options: CborDecodeOptions
) !Value
```

### Streaming Decoder

```zig
var decoder = json.cbor_mod.StreamingDecoder.init(allocator);
defer decoder.deinit();

while (have_data) {
    try decoder.feed(chunk);

    while (true) {
        const result = decoder.decodeNext();
        switch (result) {
            .value => |v| {
                // Complete value decoded
            },
            .need_data => break,
            .done => break,
            .err => |e| return e,
        }
    }
}
```

### `cborToDiagnostic`

Convert CBOR to diagnostic notation:

```zig
pub fn cborToDiagnostic(
    allocator: std.mem.Allocator,
    data: []const u8
) ![]const u8
```

**Example**:

```zig
const json_val = doc.root;
const cbor_bytes = try json.cborEncode(allocator, json_val, .{});
defer allocator.free(cbor_bytes);

const decoded = try json.cborDecode(allocator, cbor_bytes, .{});
defer json.cborFree(allocator, decoded);
```

---

## Options Reference

### `ParseOptions`

```zig
pub const ParseOptions = struct {
    max_bytes: usize = 8 * 1024 * 1024,
    max_depth: u16 = 256,
    max_nodes: u32 = 1_000_000,
    allow_bom: bool = true,
    unique_keys: bool = true,
    json5: bool = false,  // Enable JSON5 extensions
};
```

### `EncodeOptions`

```zig
pub const EncodeOptions = struct {
    indent: ?[]const u8 = null,
    emit_null_optional_fields: bool = false,
    escape_non_ascii: bool = false,
    escape_slash: bool = false,
    allocator: ?std.mem.Allocator = null,
    deterministic: bool = false,
    stringify_numbers: bool = false,
    default_binary_format: BinaryFormat = .utf8,
    allow_nan_infinity: bool = false,
    format_nil_slice_as_null: bool = false,
    use_fmt_formatter: bool = false,
};
```

**Presets**: `json.encode_mod.minified`, `pretty_2`, `pretty_4`, `pretty_tab`

### `UnmarshalOptions`

```zig
pub const UnmarshalOptions = struct {
    ignore_unknown_fields: bool = true,
    use_field_tags: bool = true,
    default_binary_format: BinaryFormat = .utf8,
    allow_nan_infinity: bool = false,
    match_case_insensitive: bool = false,
};
```

### `SchemaOptions`

```zig
pub const SchemaOptions = struct {
    draft: Draft = .draft2020_12,
    max_schema_bytes: usize = 8 * 1024 * 1024,
    max_ref_depth: u16 = 64,
    max_errors: u16 = 8,
    format_assertion: bool = true,
    regex_max_steps: u32 = 1_000_000,
    custom_formats: ?[]const FormatValidator = null,
};
```

### `AsyncParseOptions`

```zig
pub const AsyncParseOptions = struct {
    max_depth: u16 = 256,
    max_nodes: u32 = 1_000_000,
    chunk_size: usize = 4096,
    recovery_mode: ErrorRecoveryMode = .none,
};

pub const ErrorRecoveryMode = enum {
    none,
    skip_value,
    resync,
};
```

### `CborEncodeOptions` / `CborDecodeOptions`

```zig
pub const CborEncodeOptions = struct {
    use_definite_length: bool = true,
    tag_datetime: bool = false,
    canonical: bool = false,
};

pub const CborDecodeOptions = struct {
    max_depth: u16 = 256,
    max_bytes: usize = 8 * 1024 * 1024,
    allow_unknown_tags: bool = true,
};
```

---

## Error Types

### `UnmarshalError`

```zig
pub const UnmarshalError = error{
    TypeMismatch,
    MissingField,
    UnknownField,
    InvalidFormat,
    IntegerOverflow,
    DuplicateField,
    OutOfMemory,
    JsonParse,
};
```

### `UnmarshalErrorInfo`

```zig
pub const UnmarshalErrorInfo = struct {
    path: []const u8,            // JSON Pointer path
    kind: UnmarshalErrorKind,
    expected: ?[]const u8 = null,
    found: ?[]const u8 = null,
    message: []const u8,

    pub fn format(self: UnmarshalErrorInfo, allocator: std.mem.Allocator) ![]u8;
};
```

### `PathError`

```zig
pub const PathError = error{
    InvalidPath,
    SyntaxError,
    OutOfMemory,
};
```

### `PatchError`

```zig
pub const PatchError = error{
    InvalidPatch,
    InvalidPath,
    PathNotFound,
    TestFailed,
    OutOfMemory,
};
```

### `CborError`

```zig
pub const CborError = error{
    InvalidCbor,
    UnsupportedType,
    OutOfMemory,
    MaxDepthExceeded,
    MaxBytesExceeded,
};
```

---

## Submodules

Advanced access to internal modules:

| Module | Description |
|--------|-------------|
| `json.parser` | Low-level parser |
| `json.emitter` | Low-level emitter |
| `json.encode_mod` | Encoding implementation |
| `json.unmarshal_mod` | Unmarshaling implementation |
| `json.tokenizer_mod` | Streaming tokenizer |
| `json.time_mod` | Time types |
| `json.unicode` | UTF-8 utilities |
| `json.number_mod` | Number parsing |
| `json.pointer_mod` | JSON Pointer (RFC 6901) |
| `json.schema_mod` | JSON Schema internals |
| `json.regex` | ECMA-262 regex |
| `json.patch_mod` | JSON Patch |
| `json.jsonl_mod` | JSON Lines |
| `json.jsonpath_mod` | JSONPath |
| `json.schema_gen_mod` | Schema generation |
| `json.simd_mod` | Opt-in SIMD scanning primitives (not used by default parser) |
| `json.async_mod` | Async parsing |
| `json.jsonld_mod` | JSON-LD |
| `json.cbor_mod` | CBOR |
