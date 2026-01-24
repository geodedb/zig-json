# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Merge request template for contributions
- Issue templates for bug reports, features, and questions

### Changed
- Updated CI catalog components to v1.7.1

## [0.1.0] - 2026-01-23

Initial public release under Apache-2.0 license.

### Added

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
