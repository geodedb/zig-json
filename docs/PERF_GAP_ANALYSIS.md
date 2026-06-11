# Performance Gap Analysis — devnw/zig/json

**Date:** 2026-06-11 · **Commit:** `3c238be` · Scope: 23 `src/*.zig` + `bench/parallel_bench.zig`. Static analysis (no measurements taken); impact estimates are confidence-based.

## Findings Table

| ID | Title | PerfSeverity | Category | Location |
|----|-------|--------------|----------|----------|
| PERF-001 | SIMD module is dead code — never wired into any parse path | P1 | Unrealized acceleration | `src/simd.zig` (whole), `src/json.zig:534-558,702` |
| PERF-002 | JSON Patch clones the entire document on every operation — O(ops × docsize) | P0 | Memory / algorithmic | `src/patch.zig:51-58,64-106` |
| PERF-003 | Regex matcher allocates 6+ structures via `page_allocator` per NFA run, at every start position — O(N) allocs, O(N²) work | P0 | Memory / algorithmic | `src/regex_ecma262.zig:283-307,377-386` |
| PERF-004 | `number.isMultipleOf` uses `page_allocator` per call and materializes `10^exp` digits | P1 | Memory / algorithmic cliff | `src/number.zig:183-211` |
| PERF-005 | Schema validation allocates a fresh `ValidationContext` (5 hashmaps) per array element / per sub-schema branch | P1 | Memory / churn | `src/schema.zig:1243,1395,1425,1460,1470` |
| PERF-006 | `pointer.zig` evaluate/unescape use `page_allocator` per token | P2 | Memory / churn | `src/pointer.zig:23-24,58-82` |
| PERF-007 | Number parsing does redundant double work: lexeme dupe + full re-scan into a new ArrayList, per number | P2 | Memory / redundant work | `src/parser.zig:625-627`, `src/number.zig:68-104` |
| PERF-008 | `number.parseNumber` strips leading zeros with `orderedRemove(0)` in a loop — O(n²) | P2 | Algorithms | `src/number.zig:83-85` |
| PERF-009 | Parallel chunking drops tail elements and imbalances work (floor division + MAX_CHUNKS cap) | P1 | Concurrency (also correctness) | `src/parallel.zig:89,102-113` |
| PERF-010 | JSON-LD flatten deep-clones every node twice (node map + graph) | P2 | Memory / double-copy | `src/jsonld.zig:899,956` |
| PERF-011 | jsonpath re-parses the path string at every visited node | P2 | Algorithms / re-parse | `src/jsonpath.zig:374-516` |
| PERF-012 | `time.zig` date↔epoch conversion is O(years) per parse and per format | P2 | Algorithms | `src/time.zig:451-513` |
| PERF-013 | CBOR decode heap-allocates a lexeme string per number; streaming decoder memmoves remaining bytes per value | P2 | Memory / I-O | `src/cbor.zig:505,521,801,1205-1215` |
| PERF-014 | String serialization writes one byte at a time for the common (unescaped) case | P2 | I-O / throughput | `src/emitter.zig:222-295`, `src/encode.zig:413-474` |
| PERF-015 | Tokenizer/parser rebuild every string into a buffer even when it has zero escapes (no zero-copy fast path) | P2 | Memory / throughput | `src/tokenizer.zig:275-337`, `src/parser.zig:362-408` |
| PERF-016 | `simd.getFeatures` caches into a non-atomic global (`cached_features`) — data race | P3 | Concurrency | `src/simd.zig:181-190` |
| PERF-017 | SIMD `findFirstZero/NonZero` use scalar loops instead of `@ctz`/bitmask | P3 | Algorithms (dead code) | `src/simd.zig:608-624` |

## Highest-Value Actions (ranked)

1. **PERF-002** (patch O(ops×docsize)) and **PERF-003** (regex per-position `page_allocator`) are the two P0 hot-path cliffs reachable from untrusted input via JSON Patch and JSON Schema `pattern`.
2. **PERF-009** is P1 and also a silent correctness bug (dropped tail elements / undercounted results).
3. **PERF-001** (dead SIMD) is the biggest "unrealized performance" item: wire it in or drop the claim.
4. **PERF-004/005/007** are P1/P2 allocation-churn fixes concentrated in the schema/number paths.
