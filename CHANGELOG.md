# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.6] - 2026-06-11

Security, correctness, and robustness hardening across the whole library, from an
iterative application-security review plus a code-quality/performance/gap audit
(converged after five review passes; test count 305 → 466, green in Debug,
ReleaseSafe, ReleaseFast, and ReleaseSmall).

### Security / robustness (untrusted input)

- Fixed numerous process-aborting crashes reachable from a few bytes of untrusted
  input: number-exponent `i32` overflow on the primary parse path, the streaming
  tokenizer's exponent overflow, `Duration.fromIso8601` `@intFromFloat(inf)`,
  JSONPath `minInt(i64)` index negation, `isMultipleOf` `u64` overflow, the CBOR
  array/map length-prefix OOM, CBOR tag-chain / nested-indefinite-string stack
  overflow, and an `@enumFromInt` abort when unmarshaling out-of-range enum values.
- Fixed memory-safety bugs: a regex quantified-char-class double-free, OOM-path
  double-frees in JSON Patch, a `RemoteContextLoader` use-after-free, and many
  error-path leaks (CBOR, tokenizer, unmarshal, JSON-LD) that previously leaked
  partially-built values.
- Bounded previously-unbounded work: recursion-depth limits enforced in the
  streaming tokenizer, JSON-LD processor (plus `@context` cycle detection), the
  serializers, and the schema compiler/validator; a per-query node-visit budget
  for JSONPath recursive descent; CBOR length caps; and a regex compile-size cap.
- Closed validation bypasses: schema `$ref` depth-exceed and unknown JSONPath
  filter predicates now fail closed; the regex engine returns
  `error.UnsupportedPattern` for groups/alternation instead of silently
  mis-compiling them.
- The streaming tokenizer now validates UTF-8 (rejecting overlong encodings and
  surrogates), closing a parser-differential with the slice parser.

### Fixed (correctness)

- The streaming tokenizer parsed fractional numbers incorrectly (`1.5` decoded as
  `0.1`); all number paths now route through the canonical `number.parseNumber`.
- `parseIntKeyword` honors the decimal exponent (`1e2` → 100); the parallel batch
  helpers no longer drop a tail of up to 63 elements (which returned uninitialized
  memory and wrong sums).

### Changed

- `minimum_zig_version` aligned to `0.16.0`; dependencies bumped to `uri` v0.1.6
  and `thread-pool` v0.2.5.
- The internal dead `uri` module was removed; `json.uri_mod` now re-exports the
  external `uri` dependency the validator actually uses.
- Documentation now accurately describes the SIMD primitives as opt-in (not wired
  into the default scalar parser) and discloses that regex alternation/grouping
  and the JSONPath function extensions are not implemented.

## [0.1.0] - 2026-01-24

Initial public release under Apache-2.0 license.

### Added

- Merge request template for contributions
- Issue templates for bug reports, features, and questions

#### Core Features
- RFC 8259 compliant JSON parsing with proper error handling
- JSON Schema 2020-12 validation with ECMA-262 regex support
- Type-safe encoding of any Zig type to JSON with comptime reflection
- JSON Pointer (RFC 6901) support
- Streaming/writer-based API for memory-efficient encoding
- Pretty printing with configurable indentation and formatting
- Normalized numbers with exact decimal representation
- Full UTF-8 and Unicode surrogate pair handling
- Zero external dependencies - pure Zig implementation

#### High-Priority Features (#7-#11)
- JSON to Zig type unmarshaling
- Streaming tokenizer
- Custom marshaler interface
- Struct field tags support
- Time/Duration type support

#### Medium-Priority Features (#12-#16)
- Error location tracking with line/column information
- Duplicate key detection options
- Comment handling (strip/preserve modes)
- Trailing comma tolerance
- Maximum depth limits for parsing

#### Streaming & Enhanced Features (#19-#21)
- Streaming JSON APIs
- Enhanced unknown field capture
- Event-based parsing interface

#### Extended Format Support (#22-#27)
- JSON5 parsing support
- JSON Patch (RFC 6902) operations
- JSON Lines (JSONL) streaming format
- Automatic JSON Schema generation from Zig types
- Custom format extensions

#### Advanced Features (#28-#36)
- JSONPath query language support
- Custom time format parsing
- Reader-based tokenizer
- JSON diff and comparison utilities
- Schema compilation caching
- SIMD-accelerated parsing (where supported)
- Async/concurrent parsing support
- JSON-LD linked data support
- CBOR binary encoding

#### Documentation
- Comprehensive API documentation
- Getting started guide
- Usage examples and recipes
- Feature roadmap

#### CI/CD
- GitLab CI pipeline with DevNW CI Catalog components
- Secret Detection integration
- Advanced SAST and Dependency Scanning
- SBOM generation
- Code coverage support
- Multi-platform testing (Linux, macOS, Windows, FreeBSD, NetBSD)

### Fixed
- Invalid .neon feature check for AArch64 architecture
- Dynamic ref handling in schema validation
- URI dependency support for schema references
- Various test case corrections

### Changed
- Removed 'zig' prefix from library name for cleaner imports
- Updated README to reflect correct library naming
- Updated CI catalog components to v1.7.1
- Updated uri dependency to use GitLab archive URL

## [0.0.1] - 2025-12-30

Initial development release.

### Added
- Initial JSON parser implementation
- Basic encoding functionality
- Round-trip parsing and encoding tests
- URI support for schema references
- GitLab CI configuration with SAST and Secret Detection

[Unreleased]: https://gitlab.com/devnw/zig/json/-/compare/v0.1.0...HEAD
[0.1.0]: https://gitlab.com/devnw/zig/json/-/compare/v0.0.1...v0.1.0
[0.0.1]: https://gitlab.com/devnw/zig/json/-/releases/v0.0.1
