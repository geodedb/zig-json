# Code Quality Gap Analysis — devnw/zig/json

**Date:** 2026-06-11 · **Commit:** `3c238be` · Scope: 23 `src/*.zig` (~21,300 LOC) + `build.zig`. Read-only manual review.

Findings are quality/maintainability-focused; they avoid re-reporting known security findings except where a distinct maintainability angle exists.

## Findings Summary

| ID | Title | Severity | Category | Location |
|----|-------|----------|----------|----------|
| QUAL-001 | `simd.zig` (~1,007 LOC) re-exported but never wired into any real parser — dead module | High | Dead Code | `src/simd.zig`; `src/json.zig:34,534-558` |
| QUAL-002 | Three full JSON-grammar parsers (parser/tokenizer/async) duplicate the grammar; already diverging | High | DRY | `src/parser.zig:142`, `src/tokenizer.zig`, `src/async.zig:619-919` |
| QUAL-003 | `Number` built three ways with diverging invariants; async produces a structurally malformed `Number` | High | DRY / Correctness | `src/async.zig:820-825` vs `src/tokenizer.zig:561-598` vs `src/parser.zig:537` |
| QUAL-004 | Two parallel URI implementations; internal `src/uri.zig` (public) is dead, schema uses external dep | High | Dead Code / API | `src/json.zig:25,693`; `src/schema.zig:17` |
| QUAL-005 | `freeValue` reimplemented in 6 modules, `cloneValue` in 3, value-equality in 4 — divergent ownership | High | DRY | (see detail) |
| QUAL-006 | Tokenizer `max_depth`/`max_string_len` documented as limits but never enforced in `skipValue` | High | API / Error Handling | `src/tokenizer.zig:64-68,179-219,900-904` |
| QUAL-007 | Latent compile error: `encodeInt` called with 2 args, declared with 3 (non-exhaustive-enum branch) | High | Error Handling / Dead Code | `src/encode.zig:668` vs `:521` |
| QUAL-008 | Two near-identical encoding option structs: `EncodeOptions` vs `EncoderOptions` | Medium | API | `src/encode.zig:92`; `src/emitter.zig:20` |
| QUAL-009 | Float NaN/Inf serialization policy diverges between the two encoders | Medium | API | `src/encode.zig:531-568`; `src/emitter.zig:153-162` |
| QUAL-010 | JSON string-escaping reimplemented 5×; unicode-escape helper 3× | Medium | DRY | `src/encode.zig`, `src/emitter.zig` |
| QUAL-011 | JSON Pointer (un)escape reimplemented 4×; canonical `pointer.zig` not reused | Medium | DRY | `src/pointer.zig:58,85`; `src/patch.zig:309`; `src/schema.zig:1005` |
| QUAL-012 | Dual unmarshal dispatch trees (`fromValueInternal` vs `…WithPath`) duplicate ~600 lines | Medium | DRY | `src/unmarshal.zig:171,295` |
| QUAL-013 | `std.heap.page_allocator` hard-coded in hot paths, bypassing caller allocator | Medium | API / Maintainability | `src/pointer.zig:23`; `src/regex_ecma262.zig:292,386`; `src/parallel.zig:24` |
| QUAL-014 | Encoder reports state-machine misuse as `error.OutOfMemory` | Medium | Error Handling | `src/emitter.zig:75,79,98,102` |
| QUAL-015 | `parseIntKeyword` silently returns 0 on parse failure and ignores `exp10` | Medium | Error Handling | `src/schema.zig:560-564` |
| QUAL-016 | Declared-but-unenforced / dead options: async `max_string_len`, `json5`; `AsyncIterator.next` stub; jsonl `allow_trailing_newline` | Medium | Dead Code | `src/async.zig:100-102,1054`; `src/jsonl.zig:30` |
| QUAL-017 | CBOR `Decoder` and `StreamingDecoder` duplicate ~6 decode primitives, already diverging | Medium | DRY | `src/cbor.zig:439-756` vs `:1236-1445` |
| QUAL-018 | `*Error` naming used for both error sets and diagnostic structs | Medium | Naming / API | `src/jsonl.zig:34`; `src/json.zig:64` vs `src/async.zig:63` |
| QUAL-019 | Inconsistent allocator naming (`a` vs `allocator`) and position (pointer.zig allocator-last) | Medium | API | `src/pointer.zig:85,103,118`; `src/emitter.zig:314` |
| QUAL-020 | Several overly long functions (>100 lines) | Medium | Maintainability | `src/schema.zig:1057` (460), `src/encode.zig:1108` (211), etc. |
| QUAL-021 | Lightly tested auxiliary modules: schema_gen, jsonl, debug, uri, time date-math | Medium | Test Quality | (see detail) |
| QUAL-022 | Pervasive `catch unreachable` on `bufPrint` with implicit buffer-size invariants | Low | Error Handling | `src/time.zig` (41×), `src/encode.zig:1119`, `src/schema_gen.zig:323` |
| QUAL-023 | OOM/errors collapsed into "not found": `catch return null` / `put catch {}` | Low | Error Handling | `src/jsonld.zig:206,211`; `src/schema.zig:669,682` |
| QUAL-024 | Stale version string ("Zig 0.15.2") in code/README; library targets 0.16.0 | Low | Docs | `src/json.zig:6`; `README.md:3,12` |
| QUAL-025 | Doc-comment gaps: ownership contracts on key public fns (`compile`, `validate`, `SchemaNode`, parallel globals) | Low | Docs | `src/schema.zig:97,710,31`; `src/parallel.zig:19,29` |
| QUAL-026 | Silent regex mis-compilation: `\|`, `(`, `)` parsed as no-ops; `{n,}` capped at 1000 | Low | Error Handling | `src/regex_ecma262.zig:233,263,267` |
| QUAL-027 | Magic numbers: indefinite-length sentinels, fixed `[256]`/`[32]`/`[64]` buffers, duration approximations | Low | Naming / Maintainability | `src/cbor.zig`, `src/schema.zig:890`, `src/time.zig:327` |
| QUAL-028 | Dead/placeholder code: `createDocumentLoader` always null; unused `resolveDynamicRef` params; unreachable cleanup branch | Low | Dead Code | `src/jsonld.zig:274-288`; `src/schema.zig:835`; `src/unmarshal.zig:594` |

## Cross-Cutting Themes

1. **Duplication of `Value` lifecycle and JSON grammar is the dominant maintainability risk** — three parsers (QUAL-002/003), 6× `freeValue` (QUAL-005), 5× string escaping (QUAL-010), 4× pointer escaping (QUAL-011), dual unmarshal trees (QUAL-012), dual CBOR decoders (QUAL-017), all already drifting in correctness (async `Number`, jsonld equality, streaming CBOR floats).
2. **Declared-but-unenforced configuration** (QUAL-006, QUAL-016) and **two-of-everything public surfaces** (QUAL-004 URI, QUAL-008 encode options, QUAL-001 unwired SIMD) make the public API promise more than it delivers.
3. **Allocator discipline is excellent almost everywhere**, which makes the `page_allocator` exceptions (QUAL-013) stand out as untestable hot-path regressions.

## Most Actionable

- **QUAL-007** (compile error) and **QUAL-003** (malformed async `Number`) are correctness bugs on real, if untested, paths — fix first.
- **QUAL-001** (dead SIMD) and **QUAL-004** (dead URI) remove ~1,260 LOC of misleading public surface.
- **QUAL-005 / QUAL-010 / QUAL-002** consolidate the largest sources of divergence-risk duplication.

### Detail notes

- **QUAL-003:** `async.zig:820-825` sets `.digits = lexeme` (entire lexeme incl. sign/`.`/`e`) and `.exp10 = 0`; `Number.compare/isInteger/isMultipleOf` assume normalized digits/exp10 → silently wrong. Fix: route async + tokenizer number building through `number_mod.parseNumber`.
- **QUAL-007:** `encode.zig:521` `encodeInt(writer, value, stringify)` (3 params) but `:668` calls with 2 in the non-exhaustive-enum branch → `error: expected 3 argument(s), found 2` when that path instantiates.
- **QUAL-021:** schema_gen (unions/optionals/nested/arrays/int-min-max untested), jsonl (per-line error out-param never asserted), debug (control-char escaping never exercised), time (`isLeapYear`/`daysFromEpoch`/`daysToDate`, leap-day & negative-date branches untested).
