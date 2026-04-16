// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! zigjsonschema - RFC 8259 JSON Parser and JSON Schema 2020-12 Validator
//!
//! A strict, spec-compliant JSON library for Zig 0.15.2 with:
//! - RFC 8259 compliant parsing (no comments, trailing commas, NaN, Infinity)
//! - Normalized base-10 decimal number model
//! - JSON Schema draft 2020-12 compilation and validation
//! - ECMA-262 regex support for pattern validation
//! - Type-safe encoding and unmarshaling with struct field tags
//! - Streaming tokenizer for memory-efficient parsing
//! - Time/Duration types with RFC 3339 and ISO 8601 support

const std = @import("std");

pub const parser = @import("parser.zig");
pub const emitter = @import("emitter.zig");
pub const encode_mod = @import("encode.zig");
pub const unmarshal_mod = @import("unmarshal.zig");
pub const tokenizer_mod = @import("tokenizer.zig");
pub const time_mod = @import("time.zig");
pub const unicode = @import("unicode.zig");
pub const number_mod = @import("number.zig");
pub const uri_mod = @import("uri.zig");
pub const pointer_mod = @import("pointer.zig");
pub const regex = @import("regex_ecma262.zig");
pub const schema_mod = @import("schema.zig");
pub const debug_mod = @import("debug.zig");
pub const patch_mod = @import("patch.zig");
pub const jsonl_mod = @import("jsonl.zig");
pub const schema_gen_mod = @import("schema_gen.zig");
pub const jsonpath_mod = @import("jsonpath.zig");
pub const simd_mod = @import("simd.zig");
pub const async_mod = @import("async.zig");
pub const jsonld_mod = @import("jsonld.zig");
pub const cbor_mod = @import("cbor.zig");

/// Parallel operations (requires `thread_pool`).
pub const parallel = @import("parallel.zig");

/// Error codes for parse and schema errors
pub const ErrorCode = enum {
    UnexpectedEof,
    UnexpectedToken,
    InvalidUtf8,
    InvalidString,
    InvalidEscape,
    InvalidSurrogate,
    InvalidNumber,
    TrailingGarbage,
    DuplicateKey,
    ByteLimit,
    DepthLimit,
    NodeLimit,
    SchemaLimit,
    RefDepthLimit,
    RegexLimit,
    RefUnresolved,
    SchemaInvalid,
};

/// Parse error with location information
pub const ParseError = struct {
    code: ErrorCode,
    line: u32,
    col: u32,
    offset: u32,

    pub fn init() ParseError {
        return .{ .code = .UnexpectedEof, .line = 1, .col = 1, .offset = 0 };
    }
};

/// Parser configuration options
pub const ParseOptions = struct {
    max_bytes: usize = 8 * 1024 * 1024,
    max_depth: u16 = 256,
    max_nodes: u32 = 1_000_000,
    allow_bom: bool = true,
    unique_keys: bool = true,
    /// Enable JSON5 extensions: comments, trailing commas, unquoted keys, hex numbers
    json5: bool = false,
};

/// Normalized base-10 decimal number representation
pub const Number = struct {
    lexeme: []const u8,
    sign: i8,
    digits: []const u8,
    exp10: i32,

    pub fn isInteger(self: Number) bool {
        return number_mod.isInteger(self);
    }

    pub fn compare(a: Number, b: Number) i32 {
        return number_mod.compare(a, b);
    }

    pub fn isMultipleOf(self: Number, divisor: Number) bool {
        return number_mod.isMultipleOf(self, divisor);
    }
};

/// Object member (key-value pair)
pub const Member = struct {
    k: []const u8,
    v: Value,
};

/// JSON value type
pub const Value = union(enum) {
    null,
    bool: bool,
    num: Number,
    str: []const u8,
    arr: []Value,
    obj: []Member,

    pub fn eql(a: Value, b: Value) bool {
        return valueEqual(a, b);
    }
};

fn valueEqual(a: Value, b: Value) bool {
    if (@intFromEnum(a) != @intFromEnum(b)) return false;
    switch (a) {
        .null => return true,
        .bool => |av| return av == b.bool,
        .num => |an| return number_mod.compare(an, b.num) == 0,
        .str => |as| return std.mem.eql(u8, as, b.str),
        .arr => |aa| {
            const ba = b.arr;
            if (aa.len != ba.len) return false;
            for (aa, ba) |ai, bi| {
                if (!valueEqual(ai, bi)) return false;
            }
            return true;
        },
        .obj => |ao| {
            const bo = b.obj;
            if (ao.len != bo.len) return false;
            for (ao) |am| {
                var found = false;
                for (bo) |bm| {
                    if (std.mem.eql(u8, am.k, bm.k)) {
                        if (!valueEqual(am.v, bm.v)) return false;
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            }
            return true;
        },
    }
}

/// Parsed JSON document with arena allocator
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: Value,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }
};

/// Parse JSON input into a Document
pub fn parse(a: std.mem.Allocator, in: []const u8, o: ParseOptions, err: *ParseError) !Document {
    return parser.parse(a, in, o, err);
}

/// Stringify a value to minified JSON
pub fn stringify(a: std.mem.Allocator, v: Value) ![]u8 {
    return emitter.stringify(a, v);
}

/// Debug JSON: sorted keys, non-ASCII escaped
pub fn debugJson(a: std.mem.Allocator, v: Value) ![]u8 {
    return emitter.debugJson(a, v);
}

// ============================================================================
// Streaming Encoder
// ============================================================================

/// Streaming encoder options
pub const EncoderOptions = emitter.EncoderOptions;

/// Streaming JSON encoder type
pub fn StreamingEncoder(comptime WriterType: type) type {
    return emitter.Encoder(WriterType);
}

/// Create a streaming encoder for any writer type
pub fn streamingEncoder(allocator: std.mem.Allocator, writer: anytype, options: EncoderOptions) StreamingEncoder(@TypeOf(writer)) {
    return emitter.encoder(allocator, writer, options);
}

// ============================================================================
// Type-Safe Encoding
// ============================================================================

/// Encoding options for JSON output formatting
pub const EncodeOptions = encode_mod.EncodeOptions;

/// Field configuration for struct serialization via json_config
pub const FieldConfig = encode_mod.FieldConfig;

/// Binary encoding format for []u8 fields
pub const BinaryFormat = encode_mod.BinaryFormat;

/// Encode any Zig value to a JSON string
pub fn encode(a: std.mem.Allocator, value: anytype, options: EncodeOptions) ![]u8 {
    return encode_mod.encode(a, value, options);
}

/// Encode any Zig value to a writer (streaming)
pub fn encodeToWriter(writer: anytype, value: anytype, options: EncodeOptions) !void {
    return encode_mod.encodeToWriter(writer, value, options);
}

/// Convert any Zig value to a json.Value tree
pub fn toValue(a: std.mem.Allocator, value: anytype, options: EncodeOptions) !Value {
    return encode_mod.toValue(a, value, options);
}

// ============================================================================
// Unmarshaling - JSON to Zig types
// ============================================================================

/// Unmarshal error types
pub const UnmarshalError = unmarshal_mod.UnmarshalError;

/// Unmarshal options
pub const UnmarshalOptions = unmarshal_mod.UnmarshalOptions;

/// Enhanced error types for detailed diagnostics
pub const UnmarshalErrorKind = unmarshal_mod.UnmarshalErrorKind;

/// Detailed unmarshal error with JSON Pointer path and context
pub const UnmarshalErrorInfo = unmarshal_mod.UnmarshalErrorInfo;

/// Result type for unmarshaling with detailed error info
pub fn UnmarshalResult(comptime T: type) type {
    return unmarshal_mod.UnmarshalResult(T);
}

/// Parse and unmarshal JSON to type T
pub fn unmarshal(comptime T: type, allocator: std.mem.Allocator, input: []const u8) UnmarshalError!T {
    return unmarshal_mod.unmarshal(T, allocator, input);
}

/// Parse and unmarshal JSON with detailed error info
pub fn unmarshalWithInfo(comptime T: type, allocator: std.mem.Allocator, input: []const u8) UnmarshalResult(T) {
    return unmarshal_mod.unmarshalWithInfo(T, allocator, input);
}

/// Unmarshal from Value tree
pub fn fromValue(comptime T: type, allocator: std.mem.Allocator, value: Value) UnmarshalError!T {
    return unmarshal_mod.fromValue(T, allocator, value);
}

/// Unmarshal from Value tree with detailed error info
pub fn fromValueWithInfo(comptime T: type, allocator: std.mem.Allocator, value: Value, opts: UnmarshalOptions) UnmarshalResult(T) {
    return unmarshal_mod.fromValueWithInfo(T, allocator, value, opts);
}

/// Free memory allocated during unmarshaling
pub fn free(comptime T: type, allocator: std.mem.Allocator, value: *T) void {
    unmarshal_mod.free(T, allocator, value);
}

// ============================================================================
// Streaming Tokenizer
// ============================================================================

/// Tokenizer for streaming JSON parsing
pub const Tokenizer = tokenizer_mod.Tokenizer;

/// Token types
pub const TokenType = tokenizer_mod.TokenType;

/// Token with value and position
pub const Token = tokenizer_mod.Token;

/// Tokenizer options
pub const TokenizerOptions = tokenizer_mod.TokenizerOptions;

/// Read the next JSON value from a tokenizer stream
/// More memory-efficient for extracting specific values from large documents
pub const readValue = tokenizer_mod.readValue;

/// Free memory allocated by readValue
pub const freeValue = tokenizer_mod.freeValue;

// ============================================================================
// Reader-based Tokenizer
// ============================================================================

/// Options for reader-based tokenizer
pub const ReaderTokenizerOptions = tokenizer_mod.ReaderTokenizerOptions;

/// Reader tokenizer error codes
pub const ReaderTokenizerError = tokenizer_mod.ReaderTokenizerError;

/// Create a ReaderTokenizer type for a specific reader type
pub const ReaderTokenizer = tokenizer_mod.ReaderTokenizer;

/// Create a reader tokenizer from any reader type
pub const readerTokenizer = tokenizer_mod.readerTokenizer;

/// Read the next JSON value from a reader tokenizer
pub const readValueFromReader = tokenizer_mod.readValueFromReader;

// ============================================================================
// Time Types
// ============================================================================

/// RFC 3339 timestamp (marshals to/from "2024-01-15T10:30:00Z")
pub const Timestamp = time_mod.Timestamp;

/// Unix timestamp in seconds (marshals to/from numbers)
pub const UnixTimestamp = time_mod.UnixTimestamp;

/// Unix timestamp in milliseconds (marshals to/from numbers)
pub const UnixTimestampMs = time_mod.UnixTimestampMs;

/// ISO 8601 duration (marshals to/from "PT2H30M")
pub const Duration = time_mod.Duration;

/// Custom time format configuration (strftime-like patterns)
pub const TimeFormat = time_mod.TimeFormat;

/// Create a custom formatted timestamp type with a specific format pattern
/// Example: `const SqlTimestamp = json.FormattedTimestamp(json.TimeFormat.sql_datetime);`
pub const FormattedTimestamp = time_mod.FormattedTimestamp;

/// Format a timestamp using a custom format pattern
pub const formatTimestamp = time_mod.formatTimestamp;

/// Parse a timestamp from a string using a custom format pattern
pub const parseTimestamp = time_mod.parseTimestamp;

/// JSON Schema draft version
pub const Draft = enum { draft2020_12 };

/// Custom format validator function type
/// Returns true if the string value matches the format
pub const FormatValidatorFn = *const fn (value: []const u8) bool;

/// Custom format validator entry
pub const FormatValidator = struct {
    name: []const u8,
    validate: FormatValidatorFn,
};

/// Schema compilation options
pub const SchemaOptions = struct {
    draft: Draft = .draft2020_12,
    max_schema_bytes: usize = 8 * 1024 * 1024,
    max_ref_depth: u16 = 64,
    max_errors: u16 = 8,
    format_assertion: bool = true,
    regex_max_steps: u32 = 1_000_000,
    /// Custom format validators (checked before built-in formats)
    custom_formats: ?[]const FormatValidator = null,
};

/// External schema resolver function type
pub const ResolveFn = *const fn (ctx: *anyopaque, uri_str: []const u8, a: std.mem.Allocator) anyerror![]const u8;

/// External schema resolver
pub const Resolver = struct {
    ctx: *anyopaque,
    resolve: ResolveFn,
};

/// Compiled JSON Schema
pub const CompiledSchema = struct {
    arena: std.heap.ArenaAllocator,
    root: *schema_mod.SchemaNode,
    base_uri: []const u8,
    anchors: std.StringHashMap(*schema_mod.SchemaNode),
    dynamic_anchors: std.StringHashMap(*schema_mod.SchemaNode),
    /// Registry mapping $id URIs to SchemaNodes for reference resolution
    id_registry: std.StringHashMap(*schema_mod.SchemaNode),
    /// External schema resolver for remote refs
    resolver: ?Resolver = null,
    /// Schema options used for compilation
    opts: SchemaOptions = .{},

    pub fn deinit(self: *CompiledSchema) void {
        self.arena.deinit();
    }
};

/// Compile a JSON Schema document
pub fn compileSchema(a: std.mem.Allocator, doc: *const Document, o: SchemaOptions, r: ?Resolver, err: *ParseError) !CompiledSchema {
    return schema_mod.compile(a, doc, o, r, err);
}

/// Single validation error
pub const ValidationError = struct {
    instance_ptr: []const u8,
    schema_ptr: []const u8,
    keyword: []const u8,
    message: []const u8,
};

/// Validation result with errors
pub const ValidationReport = struct {
    ok: bool,
    errors: []ValidationError,
};

/// Validate a value against a compiled schema
pub fn validate(a: std.mem.Allocator, sch: *const CompiledSchema, inst: Value, o: SchemaOptions) !ValidationReport {
    return schema_mod.validate(a, sch, inst, o);
}

/// Format validation report for debugging
pub fn debugReport(a: std.mem.Allocator, r: ValidationReport) ![]u8 {
    return debug_mod.formatReport(a, r);
}

// ============================================================================
// JSON Patch (RFC 6902)
// ============================================================================

/// Patch operation type
pub const PatchOpType = patch_mod.OpType;

/// A single patch operation
pub const PatchOperation = patch_mod.Operation;

/// Error types for patch operations
pub const PatchError = patch_mod.PatchError;

/// Apply a JSON Patch document to a value
/// Returns a new modified document (does not modify original)
pub fn applyPatch(allocator: std.mem.Allocator, doc: Value, patch: []const PatchOperation) PatchError!Value {
    return patch_mod.apply(allocator, doc, patch);
}

/// Parse a patch document from JSON Value
pub fn parsePatch(allocator: std.mem.Allocator, patch_doc: Value) PatchError![]PatchOperation {
    return patch_mod.parsePatch(allocator, patch_doc);
}

/// Free a value created by applyPatch or applyMergePatch
pub const freePatchValue = patch_mod.freeValue;

/// Generate a JSON Patch document that transforms 'from' into 'to'
/// Returns an array of operations that can be applied with applyPatch
pub fn diffPatch(allocator: std.mem.Allocator, from: Value, to: Value) PatchError![]PatchOperation {
    return patch_mod.diff(allocator, from, to);
}

/// Free operations returned by diffPatch
pub const freeDiffOperations = patch_mod.freeDiffOperations;

/// Serialize patch operations to a JSON Value
pub fn patchToValue(allocator: std.mem.Allocator, ops: []const PatchOperation) PatchError!Value {
    return patch_mod.patchToValue(allocator, ops);
}

/// Apply a JSON Merge Patch (RFC 7396) to a document
/// Returns a new modified document (does not modify original)
pub fn applyMergePatch(allocator: std.mem.Allocator, target: Value, patch: Value) patch_mod.PatchError!Value {
    return patch_mod.mergePatch(allocator, target, patch);
}

// ============================================================================
// JSON Lines (JSONL)
// ============================================================================

/// Options for JSONL parsing
pub const JsonlOptions = jsonl_mod.JsonlOptions;

/// Error during JSONL parsing
pub const JsonlError = jsonl_mod.JsonlError;

/// JSONL streaming iterator
pub const JsonlIterator = jsonl_mod.Iterator;

/// Parse entire JSONL document into array of values
pub fn parseJsonl(allocator: std.mem.Allocator, input: []const u8, options: JsonlOptions, err_out: *JsonlError) !Document {
    return jsonl_mod.parseAll(allocator, input, options, err_out);
}

/// Create a streaming JSONL iterator
pub fn jsonlIterator(allocator: std.mem.Allocator, input: []const u8, options: JsonlOptions) JsonlIterator {
    return jsonl_mod.iterator(allocator, input, options);
}

// ============================================================================
// Schema Generation
// ============================================================================

/// Options for schema generation
pub const SchemaGenOptions = schema_gen_mod.GenOptions;

/// Generate JSON Schema from a Zig type
pub fn generateSchema(comptime T: type, allocator: std.mem.Allocator, options: SchemaGenOptions) !Value {
    return schema_gen_mod.generate(T, allocator, options);
}

/// Free a generated schema value
pub const freeSchema = schema_gen_mod.freeSchema;

// ============================================================================
// JSONPath Query
// ============================================================================

/// JSONPath query error
pub const PathError = jsonpath_mod.PathError;

/// Result of a JSONPath query
pub const QueryResult = jsonpath_mod.QueryResult;

/// Execute a JSONPath query on a JSON value
pub fn jsonpath(allocator: std.mem.Allocator, root: Value, path: []const u8) PathError!QueryResult {
    return jsonpath_mod.query(allocator, root, path);
}

// ============================================================================
// SIMD-Optimized Parsing
// ============================================================================

/// SIMD vector size used for optimizations
pub const SIMD_VECTOR_SIZE = simd_mod.VECTOR_SIZE;

/// SIMD parser for accelerated JSON parsing
pub const SimdParser = simd_mod.SimdParser;

/// SIMD parser options
pub const SimdParseOptions = simd_mod.SimdParseOptions;

/// Batch processor for SIMD operations
pub const BatchProcessor = simd_mod.BatchProcessor;

/// Skip whitespace using SIMD operations
pub const skipWhitespaceSIMD = simd_mod.skipWhitespaceSIMD;

/// Find structural characters using SIMD
pub const findStructuralSIMD = simd_mod.findStructuralSIMD;

/// Scan string boundaries using SIMD
pub const scanStringSIMD = simd_mod.scanStringSIMD;

/// Validate UTF-8 using SIMD
pub const validateUtf8SIMD = simd_mod.validateUtf8SIMD;

/// Check if SIMD is available on this platform
pub const simdAvailable = simd_mod.simdAvailable;

// ============================================================================
// Async Parsing Support
// ============================================================================

/// Async parser state
pub const AsyncState = async_mod.AsyncState;

/// Async parse progress information
pub const AsyncParseProgress = async_mod.ParseProgress;

/// Async parse result
pub const AsyncParseResult = async_mod.AsyncParseResult;

/// Async parse error
pub const AsyncParseError = async_mod.ParseError;

/// Async parser options
pub const AsyncParseOptions = async_mod.AsyncParseOptions;

/// Incremental async JSON parser
pub const AsyncParser = async_mod.AsyncParser;

/// Async JSON value iterator
pub const AsyncIterator = async_mod.AsyncIterator;

/// Parse JSON asynchronously with progress callbacks
pub const parseAsync = async_mod.parseAsync;

// ============================================================================
// JSON-LD Support
// ============================================================================

/// JSON-LD keywords
pub const LdKeywords = jsonld_mod.Keywords;

/// JSON-LD IRI type classification
pub const LdIriType = jsonld_mod.IriType;

/// Get the type of an IRI
pub const getLdIriType = jsonld_mod.getIriType;

/// JSON-LD processing options
pub const LdOptions = jsonld_mod.Options;

/// JSON-LD active context
pub const LdContext = jsonld_mod.Context;

/// JSON-LD term definition
pub const LdTermDefinition = jsonld_mod.TermDefinition;

/// JSON-LD processor
pub const LdProcessor = jsonld_mod.Processor;

/// Expand a JSON-LD document
pub fn ldExpand(allocator: std.mem.Allocator, document: Value, options: LdOptions) !Value {
    return jsonld_mod.expand(allocator, document, options);
}

/// Compact a JSON-LD document
pub fn ldCompact(allocator: std.mem.Allocator, document: Value, context: Value, options: LdOptions) !Value {
    return jsonld_mod.compact(allocator, document, context, options);
}

/// Flatten a JSON-LD document
pub fn ldFlatten(allocator: std.mem.Allocator, document: Value, context: ?Value, options: LdOptions) !Value {
    return jsonld_mod.flatten(allocator, document, context, options);
}

/// Frame a JSON-LD document
pub fn ldFrame(allocator: std.mem.Allocator, document: Value, frame_val: Value, options: LdOptions) !Value {
    return jsonld_mod.frame(allocator, document, frame_val, options);
}

/// Convert JSON-LD to N-Quads format
pub fn ldToNQuads(allocator: std.mem.Allocator, document: Value, options: LdOptions) ![]const u8 {
    return jsonld_mod.toNQuads(allocator, document, options);
}

// ============================================================================
// CBOR Encoding (RFC 8949)
// ============================================================================

/// CBOR major types
pub const CborMajorType = cbor_mod.MajorType;

/// CBOR simple values
pub const CborSimpleValue = cbor_mod.SimpleValue;

/// Well-known CBOR tags
pub const CborTag = cbor_mod.Tag;

/// CBOR encoding options
pub const CborEncodeOptions = cbor_mod.EncodeOptions;

/// CBOR decoding options
pub const CborDecodeOptions = cbor_mod.DecodeOptions;

/// CBOR error types
pub const CborError = cbor_mod.CborError;

/// CBOR encoder
pub const CborEncoder = cbor_mod.Encoder;

/// CBOR decoder
pub const CborDecoder = cbor_mod.Decoder;

/// Encode a JSON value to CBOR bytes
pub fn cborEncode(allocator: std.mem.Allocator, value: Value, options: CborEncodeOptions) ![]u8 {
    return cbor_mod.encode(allocator, value, options);
}

/// Decode CBOR bytes to a JSON value
pub fn cborDecode(allocator: std.mem.Allocator, data: []const u8, options: CborDecodeOptions) !Value {
    return cbor_mod.decode(allocator, data, options);
}

/// Free a decoded CBOR value
pub const cborFree = cbor_mod.free;

/// Convert CBOR to diagnostic notation string
pub fn cborToDiagnostic(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    return cbor_mod.toDiagnostic(allocator, data);
}

test {
    _ = parser;
    _ = emitter;
    _ = encode_mod;
    _ = unmarshal_mod;
    _ = tokenizer_mod;
    _ = time_mod;
    _ = unicode;
    _ = number_mod;
    _ = uri_mod;
    _ = pointer_mod;
    _ = regex;
    _ = schema_mod;
    _ = debug_mod;
    _ = patch_mod;
    _ = jsonl_mod;
    _ = schema_gen_mod;
    _ = jsonpath_mod;
    _ = simd_mod;
    _ = async_mod;
    _ = jsonld_mod;
    _ = cbor_mod;
    _ = parallel;
}

test "parallel re-export is reachable" {
    // Smoke test: verify parallel.zig is reachable through the public json
    // module, and exercise parallelSum end-to-end.
    const data = [_]u32{ 1, 2, 3, 4 };
    const total = parallel.parallelSum(u32, &data);
    try std.testing.expectEqual(@as(u32, 10), total);

    // deinitPool() must be callable through the re-export.
    parallel.deinitPool();
}
