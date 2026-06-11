# Requirements-to-Code Gap Analysis — devnw/zig/json

**Date:** 2026-06-11 · **Commit:** `3c238be` · Requirements derived from README, docs/, CHANGELOG, ROADMAP, and the public API in `src/json.zig`.

## Test Infrastructure Status

| Action | Command | Status |
|--------|---------|--------|
| Build | `zig build` | PASS |
| Unit Tests | `zig build test` | PASS (305/305) |
| Acceptance | `zig build test-accept` | PASS (14/14) |
| Edge-case | `zig build test-data` | PASS (34/34) |
| Schema Suite | `zig build test-schema` | FAIL (1/38) — `testdata/JSON-Schema-Test-Suite/` empty (GAP-012) |
| All | `zig build test-all` | FAIL (354/391) — solely due to missing schema-suite fixtures |

## Status Summary

| Status | Count |
|--------|-------|
| Implemented | 15 |
| Partial | 8 |
| Not Implemented | 2 |
| Unknown | 0 |

## Findings Table

| Gap-ID | Requirement / Feature | Status | Severity | Location |
|--------|----------------------|--------|----------|----------|
| GAP-001 | ECMA-262 regex: alternation `\|` and grouping `()` silently discarded | Partial | Critical | `src/regex_ecma262.zig:263-270` |
| GAP-002 | Schema `$ref` depth-exceed silently returns valid (no `RefDepthLimit` error) | Partial | High | `src/schema.zig:1058` |
| GAP-003 | Streaming tokenizer ignores `max_depth` / `max_string_len` options | Partial | High | `src/tokenizer.zig:65-68` |
| GAP-004 | ECMA-262 `\s`/`\S` missing form-feed, vertical-tab, NBSP, other Unicode whitespace | Partial | Medium | `src/regex_ecma262.zig:146-153` |
| GAP-005 | JSONPath function extensions absent (`length()`, `match()`, `search()`, `value()`, `count()`, `keys()`) | Partial | Medium | `src/jsonpath.zig` |
| GAP-006 | SIMD utilities never wired into parser or tokenizer (dead code) | Not Implemented | Medium | `src/simd.zig` |
| GAP-007 | ROADMAP/docs advertise `BatchProcessor.findAllStructurals()` which does not exist | Not Implemented | Low | `src/simd.zig`, `docs/ROADMAP.md:728` |
| GAP-008 | `AsyncIterator.next()` is a stub returning `null` unconditionally | Partial | High | `src/async.zig:1054-1057` |
| GAP-009 | JSON-LD `@import` context keyword silently skipped; blank-node counter is global mutable state | Partial | Medium | `src/jsonld.zig:619-680,970` |
| GAP-010 | JSON-LD remote context loading is a no-op placeholder | Partial | Medium | `src/jsonld.zig:282-288` |
| GAP-011 | `parallel.zig` tail-element drop: floor-division chunk math leaves up to 63 elements unprocessed; uninitialized reads | Partial | High | `src/parallel.zig:89,102-113,193,262` |
| GAP-012 | JSON Schema official Test Suite fixtures missing; 37/38 `test-schema` fail with `FileNotFound` (harness should skip gracefully) | Not Implemented | High | `testdata/JSON-Schema-Test-Suite/` (empty); `tests/schema_suite.zig` |

## Notes

- GAP-001/004 overlap security ASR-020 and quality QUAL-026 (regex correctness). GAP-002 overlaps ASR-021. GAP-003 overlaps ASR-005/ASR-014/QUAL-006. GAP-006/007 overlap QUAL-001/PERF-001. GAP-011 overlaps ASR-013/PERF-009. These are tracked once and closed together by module.
- GAP-012 fix: make `tests/schema_suite.zig` skip with a clear message (not `FileNotFound` failures) when the suite directory is absent, so local `test-all` is green without the external clone; keep CI cloning a pinned SHA.
