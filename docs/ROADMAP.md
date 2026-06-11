# Roadmap

This document outlines planned features for zig-json, organized by priority. Each feature links to its corresponding GitLab issue for detailed discussion and tracking.

## Priority Levels

- **Critical**: Core functionality gaps that significantly limit library usage
- **High**: Important features for production-ready status
- **Medium**: Enhancements that improve flexibility and developer experience
- **Low**: Nice-to-have features and edge case handling

---

## Completed Features

- [x] RFC 8259 compliant JSON parsing
- [x] JSON Schema 2020-12 validation
- [x] ECMA-262 regex pattern support (subset: alternation `|` and grouping
      `()` are not implemented — patterns using them return
      `error.UnsupportedPattern` rather than matching incorrectly)
- [x] Zig type to JSON encoding
- [x] Writer-based streaming output
- [x] Pretty-print formatting
- [x] Normalized decimal number handling
- [x] Full Unicode/UTF-8 support
- [x] JSON Pointer (RFC 6901) evaluation
- [x] JSON to Zig type unmarshaling (#7)
- [x] Streaming JSON tokenizer (#8)
- [x] Custom marshaler/unmarshaler interface (#9)
- [x] Struct field tag support (#10)
- [x] Time and duration support (#11)
- [x] Binary data format options (#12)
- [x] Comprehensive options system (#13)
- [x] Inline/flatten struct fields (#14)
- [x] Unknown member capture (#15)
- [x] Enhanced error types (#16)
- [x] NaN and Infinity handling (#17)
- [x] std.fmt.Formatter support (#18)
- [x] Streaming Encoder API (#19)
- [x] Streaming Value Reader (#20)
- [x] StringHashMap unknown capture (#21)
- [x] JSON5 Support (#22)
- [x] RFC 6902 JSON Patch (#23)
- [x] RFC 7396 JSON Merge Patch (#24)
- [x] JSON Lines (JSONL) parsing (#25)
- [x] Schema Generation from Zig types (#26)
- [x] Custom Format Validators (#27)
- [x] JSONPath Query Expressions (#28) (the RFC 9535 function extensions —
      `length()`, `count()`, `match()`, `search()`, `value()`, `keys()` — are not
      implemented; an unrecognized filter predicate evaluates to no-match)
- [x] Custom Time Formats (#29)
- [x] Reader-based Streaming Tokenizer (#30)
- [x] JSON Diff Generation (RFC 6902) (#31)
- [x] Schema $ref Resolution Caching (#32)
- [x] Standalone SIMD scanning primitives (opt-in, not wired into the default parser) (#33)
- [x] Async parsing support (#34)
- [x] JSON-LD Support (#35)
- [x] CBOR Encoding (RFC 8949) (#36)

---

## Planned Features

All planned features have been completed. The library is feature-complete.

---

## Feature Details

### #7 - JSON to Zig Type Unmarshaling/Decoding

**Status**: Completed

Unmarshal/decode JSON directly into native Zig types.

**API**:

```zig
// Unmarshal JSON bytes directly to a Zig type
pub fn unmarshal(comptime T: type, allocator: Allocator, input: []const u8) !T

// Unmarshal from a json.Value tree
pub fn fromValue(comptime T: type, allocator: Allocator, value: Value) !T

// Unmarshal with detailed error info
pub fn unmarshalWithInfo(comptime T: type, allocator: Allocator, input: []const u8) UnmarshalResult(T)
```

**Features**:

- Primitive type decoding (bool, integers, floats, strings)
- Optional type handling
- Struct field mapping with comptime reflection
- Array/slice decoding
- Enum and tagged union decoding

---

### #8 - Streaming JSON Tokenizer

**Status**: Completed

Low-level streaming tokenizer for memory-efficient parsing.

**API**:

```zig
pub const Tokenizer = struct {
    pub fn init(input: []const u8, options: TokenizerOptions) Tokenizer;
    pub fn next(self: *Tokenizer) !?Token;
};
```

---

### #9 - Custom Marshaler/Unmarshaler Interface

**Status**: Completed

Types can customize JSON serialization/deserialization via `jsonMarshal` and `jsonUnmarshal` methods.

**Example**:

```zig
const CustomDate = struct {
    year: u16, month: u8, day: u8,

    pub fn jsonMarshal(self: CustomDate, allocator: Allocator) !json.Value {
        var buf: [10]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}",
            .{self.year, self.month, self.day}) catch unreachable;
        return .{ .str = try allocator.dupe(u8, str) };
    }
};
```

---

### #10 - Struct Field Tag Support

**Status**: Completed

Customize JSON field names and behavior per struct field via `json_config`.

**Example**:

```zig
const Person = struct {
    first_name: []const u8,
    age: ?u32,

    pub const json_config = .{
        .first_name = FieldConfig{ .name = "firstName" },
        .age = FieldConfig{ .omitempty = true },
    };
};
```

**Supported Options**:

- `name` - Custom field name
- `omitempty` - Omit if empty/zero
- `skip` - Skip field entirely
- `stringify` - Encode numbers as strings
- `inline` - Flatten nested struct
- `unknown` - Capture unknown fields
- `binary_format` - Binary encoding format

---

### #11 - Time and Duration Support

**Status**: Completed

First-class time types with automatic marshaling.

**Types**:

- `Timestamp` - RFC 3339 timestamps ("2024-01-15T10:30:00Z")
- `UnixTimestamp` - Unix seconds (numbers)
- `UnixTimestampMs` - Unix milliseconds (numbers)
- `Duration` - ISO 8601 durations ("PT2H30M")

---

### #12 - Binary Data Format Options

**Status**: Completed

Multiple encoding formats for `[]u8` fields.

**Formats**:

```zig
pub const BinaryFormat = enum {
    utf8,       // Default - UTF-8 string
    base64,     // RFC 4648 standard
    base64url,  // RFC 4648 URL-safe
    hex,        // Lowercase hexadecimal
    hex_upper,  // Uppercase hexadecimal
    base32,     // RFC 4648
};
```

---

### #13 - Comprehensive Options System

**Status**: Completed

Fine-grained control over encoding and unmarshaling.

**EncodeOptions**:

- `indent` - Pretty-print indentation
- `deterministic` - Sort keys alphabetically
- `stringify_numbers` - Encode all numbers as strings
- `emit_null_optional_fields` - Emit null for optional fields
- `escape_non_ascii` - Escape non-ASCII characters
- `escape_slash` - Escape forward slashes
- `default_binary_format` - Default binary encoding
- `allow_nan_infinity` - Encode NaN/Infinity as strings
- `format_nil_slice_as_null` - Empty slices as null
- `use_fmt_formatter` - Use format() method for types

**UnmarshalOptions**:

- `ignore_unknown_fields` - Silently ignore unknown fields
- `use_field_tags` - Use json_config for field mapping
- `default_binary_format` - Default binary decoding
- `allow_nan_infinity` - Parse "NaN"/"Infinity" strings
- `match_case_insensitive` - Case-insensitive field matching

---

### #14 - Inline/Flatten Struct Fields

**Status**: Completed

Promote nested struct fields to the parent level.

**Example**:

```zig
const User = struct {
    id: u64,
    metadata: Metadata,

    pub const json_config = .{
        .metadata = FieldConfig{ .inline = true },
    };
};

// Encodes to: {"id":1,"created_at":123,"updated_at":456}
// Instead of: {"id":1,"metadata":{"created_at":123,...}}
```

---

### #15 - Unknown Member Capture

**Status**: Completed

Capture unknown JSON fields into a designated struct field.

**Example**:

```zig
const Config = struct {
    name: []const u8,
    extra: []json.Member,  // Captures unknown fields

    pub const json_config = .{
        .extra = FieldConfig{ .unknown = true },
    };
};
```

---

### #16 - Enhanced Error Types

**Status**: Completed

Rich semantic errors with JSON Pointer paths.

**Types**:

```zig
pub const UnmarshalErrorInfo = struct {
    path: []const u8,      // e.g., "/users/0/email"
    kind: UnmarshalErrorKind,
    expected: ?[]const u8,
    found: ?[]const u8,
    message: []const u8,
};

pub const UnmarshalErrorKind = enum {
    type_mismatch,
    missing_field,
    unknown_field,
    invalid_format,
    integer_overflow,
    duplicate_field,
    json_parse,
};
```

---

### #17 - NaN and Infinity Handling

**Status**: Completed

Encode/decode NaN and Infinity as JSON strings.

**Example**:

```zig
const options = EncodeOptions{ .allow_nan_infinity = true };
// NaN -> "NaN", Infinity -> "Infinity", -Infinity -> "-Infinity"

const unmarshal_opts = UnmarshalOptions{ .allow_nan_infinity = true };
// "NaN" -> NaN, "Infinity" -> Infinity
```

---

### #18 - std.fmt.Formatter Support

**Status**: Completed

Use Zig's `format()` method for custom string encoding.

**Example**:

```zig
const Point = struct {
    x: i32, y: i32,

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("({d}, {d})", .{ self.x, self.y });
    }
};

// With use_fmt_formatter = true:
// Point{.x=10, .y=20} encodes as "(10, 20)"
```

---

### #19 - Streaming Encoder API

**Status**: Completed

Build JSON output incrementally without constructing a Value tree first.

**API**:

```zig
pub fn StreamingEncoder(comptime WriterType: type) type;
pub fn streamingEncoder(allocator: Allocator, writer: anytype, options: EncoderOptions) StreamingEncoder(@TypeOf(writer));
```

**Example**:

```zig
var buf: std.ArrayList(u8) = .empty;
defer buf.deinit(allocator);

var enc = json.streamingEncoder(allocator, buf.writer(allocator), .{});
defer enc.deinit();

try enc.beginObject();
try enc.writeKey("name");
try enc.writeString("Alice");
try enc.writeKey("age");
try enc.writeInt(@as(u32, 30));
try enc.endObject();

// Result: {"name":"Alice","age":30}
```

**Methods**:

- `beginObject()` / `endObject()` - Start/end JSON object
- `beginArray()` / `endArray()` - Start/end JSON array
- `writeKey(key)` - Write object key
- `writeNull()`, `writeBool(val)`, `writeString(val)` - Write primitives
- `writeInt(val)`, `writeFloat(val)` - Write numbers
- `writeValue(json.Value)` - Write an existing Value tree
- `writeRaw(json_string)` - Write pre-formatted JSON

---

### #20 - Streaming Value Reader

**Status**: Completed

Read JSON values directly from tokenizer without building full tree first.

**API**:

```zig
pub fn readValue(tokenizer: *Tokenizer) !json.Value;
pub fn freeValue(allocator: Allocator, value: json.Value) void;
```

**Example**:

```zig
var tokenizer = json.Tokenizer.init(allocator, input, .{});
defer tokenizer.deinit();

// Read just the values you need
const value = try json.readValue(&tokenizer);
defer json.freeValue(allocator, value);

// Process value...
```

---

### #21 - StringHashMap Unknown Capture

**Status**: Completed

Use `std.StringHashMap(json.Value)` as an alternative to `[]json.Member` for capturing unknown fields.

**Example**:

```zig
const Config = struct {
    name: []const u8,
    extra: std.StringHashMap(json.Value),  // Alternative to []json.Member

    pub const json_config = .{
        .extra = FieldConfig{ .unknown = true },
    };
};
```

**Benefits**:

- O(1) lookup for captured fields by key
- More convenient for accessing specific unknown fields
- Same round-trip behavior as []json.Member

---

### #22 - JSON5 Support

**Status**: Completed

Parse JSON5, an extension of JSON with additional syntax features.

**Features**:

- Single-line (`//`) and multi-line (`/* */`) comments
- Trailing commas in objects and arrays
- Unquoted object keys (ECMAScript identifiers)
- Single-quoted strings with additional escape sequences
- Hexadecimal numbers (`0xFF`)
- Leading decimal point (`.5` = `0.5`)
- Trailing decimal point (`5.` = `5.0`)
- Positive sign prefix (`+5`)
- NaN and Infinity literals

**Usage**:

```zig
var err = json.ParseError.init();
var doc = try json.parse(allocator, input, .{ .json5 = true }, &err);
```

---

### #23 - RFC 6902 JSON Patch

**Status**: Completed

Apply and parse JSON Patch documents for modifying JSON values.

**Operations**:

- `add` - Add a value at the target path
- `remove` - Remove the value at the target path
- `replace` - Replace the value at the target path
- `move` - Move a value from one location to another
- `copy` - Copy a value from one location to another
- `test` - Test that a value equals an expected value

**API**:

```zig
// Apply a patch
const result = try json.applyPatch(allocator, doc, &ops);
defer json.freePatchValue(allocator, result);

// Parse a patch document
const ops = try json.parsePatch(allocator, patch_value);
```

---

### #24 - RFC 7396 JSON Merge Patch

**Status**: Completed

Apply JSON Merge Patch for simpler partial updates.

**Rules**:

- If patch is not an object, it replaces the target entirely
- For each key in the patch:
  - If value is `null`, remove the key from target
  - Otherwise, recursively merge

**API**:

```zig
const result = try json.applyMergePatch(allocator, target, patch);
defer json.freePatchValue(allocator, result);
```

---

### #25 - JSON Lines (JSONL) Parsing

**Status**: Completed

Parse newline-delimited JSON (NDJSON/JSON Lines) format.

**API**:

```zig
// Parse all lines at once
var err: json.JsonlError = undefined;
var doc = try json.parseJsonl(allocator, input, .{}, &err);
defer doc.deinit();
// doc.root is an array of parsed values

// Streaming iterator for large files
var iter = json.jsonlIterator(allocator, input, .{});
while (try iter.next(&err)) |*d| {
    var doc = d.*;
    defer doc.deinit();
    // Process each value...
}
```

---

### #26 - Schema Generation from Zig Types

**Status**: Completed

Generate JSON Schema (draft 2020-12) from Zig type definitions.

**Supported Types**:

- Structs → object schema with properties
- Enums → string enum schema
- Optionals → anyOf with null
- Arrays/slices → array schema with items
- Unions → oneOf schema
- Primitives → appropriate type schemas

**API**:

```zig
const Person = struct {
    name: []const u8,
    age: u32,
    email: ?[]const u8 = null,
};

const schema = try json.generateSchema(Person, allocator, .{});
defer json.freeSchema(allocator, schema);
// Produces: {"type":"object","properties":{"name":{"type":"string"},...}}
```

---

### #27 - Custom Format Validators

**Status**: Completed

Register custom format validators for JSON Schema validation.

**API**:

```zig
fn validatePhoneNumber(str: []const u8) bool {
    return std.mem.startsWith(u8, str, "+") and str.len >= 10;
}

const custom_formats = [_]json.FormatValidator{
    .{ .name = "phone", .validate = validatePhoneNumber },
};

const result = try json.validate(allocator, &schema, doc.root, .{
    .custom_formats = &custom_formats,
});
```

---

### #28 - JSONPath Query Expressions

**Status**: Completed

Query JSON documents using JSONPath syntax (Stefan Goessner specification).

**Supported Operators**:

- `$` - Root element
- `.name` or `['name']` - Child element
- `..` - Recursive descent
- `*` - Wildcard (all children)
- `[n]` - Array index (positive and negative)
- `[start:end:step]` - Array slice
- `[?(@.field == value)]` - Filter expression

**API**:

```zig
const result = try json.jsonpath(allocator, doc.root, "$.users[*].name");
defer result.deinit();

for (result.values) |value| {
    std.debug.print("{s}\n", .{value.str});
}
```

---

### #29 - Custom Time Formats

**Status**: Completed

User-defined format strings for time types beyond RFC 3339/ISO 8601.

**Supported Format Specifiers**:

- `%Y` - 4-digit year
- `%y` - 2-digit year
- `%m` - 2-digit month
- `%d` - 2-digit day
- `%H` - 24-hour hour
- `%I` - 12-hour hour
- `%M` - Minute
- `%S` - Second
- `%f` - Microseconds
- `%p` - AM/PM
- `%z` - Timezone offset
- `%Z` - Timezone name

**API**:

```zig
const SqlTimestamp = json.FormattedTimestamp(json.TimeFormat.sql_datetime);

// Parse
const ts = try SqlTimestamp.parse("2024-01-15 10:30:00");

// Format
const s = try ts.format(allocator);
defer allocator.free(s);
// Result: "2024-01-15 10:30:00"
```

**Built-in Formats**:

- `TimeFormat.rfc3339` - RFC 3339 (`2024-01-15T10:30:00Z`)
- `TimeFormat.sql_datetime` - SQL format (`2024-01-15 10:30:00`)
- `TimeFormat.us_date` - US date (`01/15/2024`)
- `TimeFormat.eu_date` - European date (`15/01/2024`)
- `TimeFormat.iso8601_date` - ISO date (`2024-01-15`)

---

### #30 - Reader-based Streaming Tokenizer

**Status**: Completed

Tokenize JSON from any `std.io.Reader` source without loading the entire input into memory.

**API**:

```zig
var file = try std.fs.cwd().openFile("large.json", .{});
defer file.close();

var tokenizer = try json.readerTokenizer(allocator, file.reader(), .{});
defer tokenizer.deinit();

while (true) {
    const token = try tokenizer.next();
    if (token.type == .eof) break;
    // Process token...
}

// Or read a complete value:
const value = try json.readValueFromReader(&tokenizer);
defer json.freeValue(allocator, value);
```

---

### #31 - JSON Diff Generation (RFC 6902)

**Status**: Completed

Generate JSON Patch documents that transform one JSON value into another.

**API**:

```zig
// Generate diff
const ops = try json.diffPatch(allocator, from, to);
defer json.freeDiffOperations(allocator, ops);

// Apply the diff to verify
const result = try json.applyPatch(allocator, from, ops);
defer json.freePatchValue(allocator, result);

// Serialize to JSON
const patch_json = try json.patchToValue(allocator, ops);
defer json.freePatchValue(allocator, patch_json);
```

---

### #32 - Schema $ref Resolution Caching

**Status**: Completed

Improved performance for JSON Schema validation through caching of resolved `$ref` and `$dynamicRef` references.

**Benefits**:

- Avoids repeated URI parsing and resolution during validation
- Significant speedup for schemas with many references
- Automatic cache invalidation per validation session
- No API changes required - optimization is transparent

---

### #33 - Standalone SIMD Scanning Primitives

**Status**: Completed (opt-in primitives only)

Vectorized JSON scanning helpers built on Zig's `@Vector` types. These are
standalone, tested primitives available for opt-in use. They are **not** wired
into the library's default parser, tokenizer, or unmarshaler, which remain
scalar. The primitives operate on raw byte slices and do not, on their own,
perform JSON validation, escape decoding, or surrogate-pair handling.

**Primitives**:

- Whitespace skipping using SIMD vector comparisons
- Structural character detection (braces, brackets, quotes, colons, commas)
- String boundary scanning with quote/backslash detection
- UTF-8 validation (SIMD ASCII fast path with scalar fallback)
- Batch helpers for counting structurals and locating string spans

**API**:

```zig
const simd = json.simd_mod;

// Batch helpers
var processor = simd.BatchProcessor.init(allocator);

// Locate string spans: returns []{ start, end }
const spans = try processor.findAllStrings(input);
defer allocator.free(spans);

// Count structural characters
const counts = processor.countStructurals(input);
// counts.objects, counts.arrays, counts.strings, counts.colons, counts.commas

// Skip leading whitespace (returns index of first non-whitespace byte)
const first = simd.skipWhitespaceSIMD(input);

// Validate UTF-8
const valid = simd.validateUtf8SIMD(input);
```

---

### #34 - Async Parsing Support

**Status**: Completed

Non-blocking incremental JSON parsing for async contexts with progress reporting.

**Features**:

- Incremental parsing with configurable yield intervals
- Progress callbacks and cancellation support
- Memory-efficient streaming from any source
- Resume parsing after yielding

**API**:

```zig
const async_parser = json.async_parser;

// Create parser
var parser = async_parser.AsyncParser.init(allocator, .{
    .yield_interval = 4096,  // Yield every 4KB
    .max_depth = 256,
});
defer parser.deinit();

// Feed data incrementally
try parser.feed(chunk1);
try parser.feed(chunk2);

// Parse with yielding
while (true) {
    const result = parser.parse();
    switch (result) {
        .yield => |progress| {
            // Report progress, check for cancellation
            std.debug.print("Progress: {d}%\n", .{progress.percent * 100});
        },
        .done => |value| {
            // Parsing complete
            break;
        },
        .err => |e| {
            // Handle error
            break;
        },
    }
}
```

---

### #35 - JSON-LD Support

**Status**: Completed

JSON for Linked Data (JSON-LD) processing including context expansion, compaction, and serialization.

**Features**:

- Context expansion and compaction (JSON-LD 1.1)
- Document flattening
- N-Quads serialization
- Frame processing

**API**:

```zig
const jsonld = json.jsonld;

// Expand document
const expanded = try jsonld.expand(allocator, document, .{});

// Compact with context
const compacted = try jsonld.compact(allocator, document, context, .{});

// Flatten
const flattened = try jsonld.flatten(allocator, document, context, .{});

// Convert to N-Quads
const nquads = try jsonld.toNQuads(allocator, document, .{});
defer allocator.free(nquads);
```

---

### #36 - CBOR Encoding (RFC 8949)

**Status**: Completed

Concise Binary Object Representation encoding and decoding per RFC 8949.

**Features**:

- Full major type support (0-7)
- Indefinite-length encoding
- Canonical encoding option
- Tag support (datetime, bignum, etc.)
- Diagnostic notation output
- Streaming encoding

**API**:

```zig
const cbor = json.cbor;

// Encode JSON to CBOR
const bytes = try cbor.encode(allocator, json_value, .{});
defer allocator.free(bytes);

// Decode CBOR to JSON
const value = try cbor.decode(allocator, cbor_bytes, .{});
defer cbor.free(allocator, value);

// Canonical encoding
const canonical = try cbor.encode(allocator, value, .{ .canonical = true });

// Diagnostic notation
const diag = try cbor.toDiagnostic(allocator, cbor_bytes);
defer allocator.free(diag);
// e.g., '{"name": "Alice", "age": 30}'
```

**Supported CBOR Types**:

- Unsigned integers (major type 0)
- Negative integers (major type 1)
- Byte strings (major type 2)
- Text strings (major type 3)
- Arrays (major type 4)
- Maps (major type 5)
- Tags (major type 6)
- Simple values and floats (major type 7)

---

## Contributing

Contributions are welcome! Please check the linked issues for detailed specifications and discussion before starting work on a feature.

1. Pick an issue from the list above
2. Comment on the issue to indicate you're working on it
3. Submit a merge request with your implementation
4. Include tests for new functionality

## References

This roadmap is inspired by Go's `encoding/json/v2` package design:

- [Go Blog: A new experimental Go API for JSON](https://go.dev/blog/jsonv2-exp)
- [Go encoding/json/v2 Package](https://pkg.go.dev/encoding/json/v2)
