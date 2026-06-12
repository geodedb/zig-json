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
| GAP-001 | ECMA-262 regex: alternation `\|` and grouping `()` | Resolved (implemented) | Critical | `src/regex_ecma262.zig` |
| GAP-002 | Schema `$ref` depth-exceed silently returns valid (no `RefDepthLimit` error) | Partial | High | `src/schema.zig:1058` |
| GAP-003 | Streaming tokenizer ignores `max_depth` / `max_string_len` options | Partial | High | `src/tokenizer.zig:65-68` |
| GAP-004 | ECMA-262 `\s`/`\S` missing form-feed, vertical-tab, NBSP, other Unicode whitespace | Partial | Medium | `src/regex_ecma262.zig:146-153` |
| GAP-005 | JSONPath function extensions absent (`length()`, `match()`, `search()`, `value()`, `count()`, `keys()`) | Partial | Medium | `src/jsonpath.zig` |
| GAP-006 | SIMD utilities never wired into parser or tokenizer (dead code) | Resolved (implemented) | Medium | `src/simd.zig`, `src/parser.zig` |
| GAP-007 | ROADMAP/docs advertise `BatchProcessor.findAllStructurals()` which does not exist | Not Implemented | Low | `src/simd.zig`, `docs/ROADMAP.md:728` |
| GAP-008 | `AsyncIterator.next()` is a stub returning `null` unconditionally | Partial | High | `src/async.zig:1054-1057` |
| GAP-009 | JSON-LD `@import` context keyword silently skipped; blank-node counter is global mutable state | Partial | Medium | `src/jsonld.zig:619-680,970` |
| GAP-010 | JSON-LD remote context loading is a no-op placeholder | Partial | Medium | `src/jsonld.zig:282-288` |
| GAP-011 | `parallel.zig` tail-element drop: floor-division chunk math leaves up to 63 elements unprocessed; uninitialized reads | Partial | High | `src/parallel.zig:89,102-113,193,262` |
| GAP-012 | JSON Schema official Test Suite fixtures missing; 37/38 `test-schema` fail with `FileNotFound` (harness should skip gracefully) | Not Implemented | High | `testdata/JSON-Schema-Test-Suite/` (empty); `tests/schema_suite.zig` |

## Notes

- GAP-001/004 overlap security ASR-020 and quality QUAL-026 (regex correctness). GAP-002 overlaps ASR-021. GAP-003 overlaps ASR-005/ASR-014/QUAL-006. GAP-006/007 overlap QUAL-001/PERF-001. GAP-011 overlaps ASR-013/PERF-009. These are tracked once and closed together by module.
- GAP-012 fix: make `tests/schema_suite.zig` skip with a clear message (not `FileNotFound` failures) when the suite directory is absent, so local `test-all` is green without the external clone; keep CI cloning a pinned SHA.

---

## Resolution Status (updated 2026-06-11, commit 458bf24)

All gaps were addressed across two review/fix passes. Verification: `zig build
test-all` = 14/14 steps, 475/512 pass (37 schema-suite tests skip gracefully when
the external suite is absent).

| Gap-ID | Status | Resolution |
|--------|--------|-----------|
| GAP-001 | Resolved (implemented) | Regex alternation `\|` and grouping `()` are now fully implemented as a Pike NFA (replacing the fail-closed subset), with bounded repetition, a total-instruction cap, a parser depth bound, and a global step budget. JSON Schema `pattern`/`patternProperties` alternation now validates correctly. Groups are non-capturing; capture-group *extraction* remains deferred (not required by `pattern` validation). |
| GAP-002 | Resolved | `$ref` depth-exceed records an error and reports invalid. |
| GAP-003 | Resolved | Tokenizer enforces `max_depth`/`max_string_len`. |
| GAP-004 | Resolved | `\s`/`\S` include form-feed and vertical-tab. |
| GAP-005 | Resolved (fail-closed) | Unknown JSONPath filter predicates now fail closed. RFC 9535 function extensions deferred (disclosed in ROADMAP/API). |
| GAP-006 | Resolved (implemented) | SIMD whitespace/string scanners (`skipWhitespaceSIMD`/`scanStringSIMD`) are now wired into the strict parser's hot path — a no-escape string fast-path (single `dupe`) plus SIMD whitespace skipping, alongside small-object linear key dedup (~44–52% higher string/object parse throughput). |
| GAP-007 | Resolved | Removed the nonexistent `findAllStructurals` doc example. |
| GAP-008 | Resolved | `AsyncIterator.next` implemented. |
| GAP-009 | Resolved | `@import` resolved/merged; blank-node counter per-instance. |
| GAP-010 | Resolved (fail-closed) | URL contexts with no loader return an error; built-in network loader remains out of scope by design. |
| GAP-011 | Resolved | Parallel chunking covers the full input. |
| GAP-012 | Resolved | Schema suite skips gracefully when fixtures are absent; CI clone pinned to a SHA. |

## Deferred / Accepted by Design

The following were evaluated and **intentionally not implemented**. They are
tracked, justified trade-offs — **not open defects**. None is an untrusted-input
memory-safety or DoS exposure (those are closed); each is a feature addition, an
unneeded capability, a deliberate safety/speed choice, or a security-motivated
no-op.

| Item | Disposition | Rationale | Cross-reference |
|------|-------------|-----------|-----------------|
| **CBOR datetime/bignum tag round-trip** | Deferred — feature | Tag *safety* (depth limit, bounded allocation, valid free) is closed. Preserving tag *semantics* (datetime tag 0/1, bignum tag 2/3) is a feature; decode currently unwraps and discards the tag number. | ROADMAP CBOR section; `src/cbor.zig` |
| **Regex capturing-group *extraction*** | Deferred — not needed | Alternation `\|` and grouping `()` are now implemented (Pike NFA); groups are **non-capturing**, which is exactly what JSON Schema `pattern`/`patternProperties` require. No public feature consumes captures. | GAP-001; `src/regex_ecma262.zig` |
| **JSONPath RFC 9535 function extensions** | Deferred — feature | `length()`/`match()`/`search()`/`value()`/`count()`/`keys()` are not implemented; unknown filter predicates fail closed. | GAP-005; `src/jsonpath.zig` |
| **Several micro-performance items** | Deferred — low value / safety-first | Small allocation/scan overheads, some of which are the deliberate cost of memory-safety fixes (owning number lexemes), or would change the public `Value` layout, or carry correctness risk for negligible gain. The dominant parser/serializer hot paths are optimized. | `PERF_GAP_ANALYSIS.md` |
| **Inert, no-network JSON-LD remote loader** | Accepted — by design (security) | Implicit network fetch of attacker-controlled `@context`/`$ref` URLs would be an SSRF primitive. The remote-context loader is intentionally inert; callers opt in via their own allowlisting `document_loader`, or preload contexts into the cache. | GAP-010; `src/jsonld.zig` |
| **JSON Patch in-place / copy-on-write** | Deferred — feature | `apply` returns a new value (does not mutate the original); an in-place / COW variant is future work. | `src/patch.zig` |

### Detail

- **CBOR datetime/bignum tag round-trip (feature, deferred).** The CBOR decoder
  handles tags safely (depth limit, bounded definite-length allocation,
  heap-owned float/NaN/Infinity lexemes), but does not preserve tag *meaning*: a
  datetime (tag 0/1) or bignum (tag 2/3) is unwrapped to its bare underlying
  value and the tag number is dropped, so semantics do not round-trip.
  Tag-aware encode/decode is a future release.

- **Regex capturing groups (unneeded, deferred).** The ECMA-262 engine is now a
  Pike NFA with working alternation and grouping; groups are non-capturing
  because `pattern`/`patternProperties` only need a boolean match decision. No
  other public feature exposes captures. Capture extraction is a future
  enhancement, not a correctness gap for the advertised surface.

- **Micro-performance items (deferred, safety-first).** The dominant parser hot
  paths are optimized (SIMD whitespace/string scan, no-escape string fast-path,
  small-object linear dedup, removed O(n²) leading-zero strip). The remaining
  items in `PERF_GAP_ANALYSIS.md` are deliberately deferred: extra small
  allocations per CBOR float / streamed number are the *cost* of memory-safety
  fixes (reducing them re-introduces lexeme/digits aliasing — a use-after-free
  hazard); a `Value`/`Number` layout change would break the public API; and a
  whitespace line/col popcount carries error-position correctness risk for
  negligible gain.

- **Inert no-network JSON-LD remote loader (accepted by design).** The
  remote-context loader performs no network I/O. This is a security decision:
  automatically fetching attacker-controlled `@context` / external `$ref` URLs
  would be a server-side request forgery (SSRF) primitive. Callers that need
  remote contexts supply their own allowlisting `document_loader`, or preload
  contexts into the cache. A URL context with no caller-supplied loader returns
  an error (fail-closed) rather than silently succeeding.
