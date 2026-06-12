# Application Security Review — devnw/zig/json

**Target:** `/home/benji/src/gl/gitlab.com/devnw/zig/json` (GitLab: `devnw/zig/json`)
**Commit:** `3c238be` (branch `main`)
**Reviewer framing:** Defensive, evidence-first appsec review grounded in OWASP Top 10:2025 + CIS Controls v8.1.2
**Date:** 2026-06-11
**Toolchain used for verification:** Zig 0.16.0 (Debug). Reproductions built against the real package via an isolated `zig build` harness under `/tmp`.

---

## 1. Scope & Assumptions

**In scope (read directly):** all 23 `src/*.zig` files (~21,344 LOC), `build.zig`, `build.zig.zon`, `.gitlab-ci.yml`, `.pre-commit-config.yaml`, `scripts/detect_diamond_deps.py`, `Makefile`, `.gitleaks.toml`, `SECURITY.md`.

**Threat model (inferred — no doc supplied):** this is a library that parses *untrusted input* (JSON / JSON5 / JSONL / JSON-LD / CBOR / JSON Schema incl. regex patterns / JSON Pointer / JSONPath / JSON Patch / URIs / RFC 3339 timestamps / numbers). There is no network/auth surface. The primary lenses, in priority order, are: **memory safety** (OOB, double-free, use-after-free, uninitialized reads), **denial of service** (stack exhaustion via unbounded recursion, allocator exhaustion, integer-overflow panics, quadratic/exponential blowups, ReDoS), **parser-differential correctness**, and **error-path allocator hygiene (errdefer)**. Supply chain is secondary.

**Key assumptions:**

- **Build mode matters.** `build.zig:7` uses `standardOptimizeOption`, so the consumer chooses the optimize level. In **Debug/ReleaseSafe**, the many integer-overflow / `@intFromFloat` / `@intCast` sites below **panic → process abort (DoS)**. In **ReleaseFast/ReleaseSmall** the same sites become **silent UB / wraparound** (correctness corruption, parser-differential, or memory unsafety). Both are treated as in-scope harm. The CI runs tests in Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall (`.gitlab-ci.yml:107-139`), so all four are supported targets.
- **Parser-built `Value` trees are depth-bounded to 256** (`ParseOptions.max_depth=256`, `json.zig:78`; enforced in `parser.zig:125-138`). Several public APIs (`fromValue`, `applyPatch`, `jsonpath`, `ldExpand`, `stringify`, `cborDecode`, `Tokenizer`/`readValue`) accept *caller-supplied or independently-built* `Value` trees / token streams that are **not** guaranteed to respect that bound. This distinction drives the severity of every "unbounded recursion" finding.
- Transitive review of the `uri` and `thread_pool` sibling deps is out of scope; their *pinning/hash hygiene* is in scope.
- Reproductions were run in Debug. Where a finding's manifestation differs in Release, that is called out.

**Reproduction evidence is real.** Every "Confirmed (reproduced)" finding below was executed; the crash signal, panic string, or leak report is quoted from actual program output.

---

## 2. Executive Summary

- **The core RFC 8259 parser (`parser.zig`) is the strong part of this library.** It enforces depth, node-count, and byte limits consistently, rejects lone surrogates, validates UTF-8 per sequence, and uses arena allocation that makes its own error paths leak-free. Deep-nesting input is correctly rejected with `DepthLimit` (reproduced).
- **However, the library is much larger than its core parser, and the auxiliary surfaces are not held to the same standard.** Multiple **public, untrusted-input entry points crash the process** on tiny inputs. I reproduced **five distinct process-aborting DoS conditions** and **two memory-corruption conditions**, all from the public API:
  1. **Number exponent overflow** — `json.parse("1e99999999999", …)` panics (`number.zig:58`). A 13-byte JSON document aborts the *primary parse API*. **(ASR-001, Critical.)**
  2. **Regex compile-time allocator explosion** — a JSON Schema `"pattern":"a{1,2000000}"` (a ~26-byte schema) expands to millions of regex instructions; `a{1,500000000}` reaches tens of GB. Reproduced 10,000,000 instructions from a 12-byte pattern. No compile budget exists. **(ASR-002, Critical.)**
  3. **Regex quantified-char-class double-free** — compiling `[a-z]{3}` (or `\d{4}`) and freeing it segfaults via the public `json.regex` API (shared `.ranges` pointer freed N times). **(ASR-003, High → Critical for direct API users.)**
  4. **CBOR length-prefix allocator exhaustion** — a 5-byte CBOR payload declaring a 100-million-element array forces a multi-GB allocation before any element bytes are read. **(ASR-004, High.)**
  5. **Streaming tokenizer / JSON-LD / JSONPath / Duration crashes** — `readValue` has no depth limit (stack overflow reproduced at >10k frames); `json.jsonpath(…, "$[-9223372036854775808,0]")` panics on `i64` negation; `Duration.fromIso8601` panics via `@intFromFloat(inf)`; `ldExpand` overflows the stack on deep trees. **(ASR-005 through ASR-009.)**
- **A recurring anti-pattern: declared limits that are never enforced.** The streaming `Tokenizer` defines `max_depth` and `max_string_len` (`tokenizer.zig:66,68`) and `async.zig` defines `max_string_len` (`async.zig:99`) — **none are checked** in their parsing paths. This is worse than absent options because it implies protection that does not exist.
- **A recurring memory-hygiene anti-pattern: `errdefer` that frees only the container spine, not its built contents.** Confirmed leaks in `cbor.zig` (reproduced), `unmarshal.zig`, `tokenizer.zig` readValue, and `jsonld.zig`. Each is a repeatable memory-exhaustion DoS on adversarial input that allocates many children before failing late.
- **The `parallel.zig` chunking math drops a tail of up to 63 elements**, producing uninitialized result reads and silently wrong sums/validation results (data-integrity + uninitialized-memory).
- **Supply chain hygiene is good**: deps are git+https hash-pinned, a diamond-dep detector runs in pre-commit, CI verifies the Zig toolchain by SHA-256, and SAST/secret/SBOM scanning components are wired in. The main gaps are the unpinned `JSON-Schema-Test-Suite` clone and the regex/number/CBOR limits not being defense-in-depth-complete.

**Overall confidence: High.** Findings are backed by source-to-sink tracing plus executed reproductions for the most severe items.

**OWASP 2025 mapping:** the dominant categories here are **A10 Mishandling of Exceptional Conditions** (panics/aborts on malformed input, unenforced limits), **A06 Insecure Design** (missing budgets/caps by design across auxiliary parsers), and **A03 Software Supply Chain Failures** (secondary; mostly well-handled). CWE clusters: CWE-674 (uncontrolled recursion), CWE-789/400 (memory/resource exhaustion), CWE-190 (integer overflow), CWE-415/416 (double-free/UAF), CWE-457/908 (uninitialized read).

---

## 3. Findings Table

| ID | Title | Severity | Confidence | OWASP 2025 / CWE | Location |
|----|-------|----------|-----------|------------------|----------|
| ASR-001 | Number exponent `i32` overflow aborts the primary parse API | **Critical** | Confirmed (reproduced) | A10 / CWE-190 | `number.zig:58`, `tokenizer.zig:577` |
| ASR-002 | Regex `{n,m}` compiles by physical duplication with no cap → allocator/CPU exhaustion via schema `pattern` | **Critical** | Confirmed (reproduced) | A06/A10 / CWE-1333, CWE-789 | `regex_ecma262.zig:210-258` |
| ASR-003 | Regex quantified char-class shares `.ranges` ptr → double-free/segfault | **High** | Confirmed (reproduced) | A10 / CWE-415 | `regex_ecma262.zig:244-258` vs `55-60` |
| ASR-004 | CBOR array/map length-prefix drives unbounded pre-allocation | **High** | Confirmed (reproduced) | A06/A10 / CWE-789 | `cbor.zig:636, 683` |
| ASR-005 | Streaming `Tokenizer.readValue` has no depth limit → stack overflow | **High** | Confirmed (reproduced) | A10 / CWE-674 | `tokenizer.zig:501, 602, 628, 1394+` |
| ASR-006 | `Duration.fromIso8601` `@intFromFloat(inf)` panic on huge component | **High** | Confirmed (reproduced) | A10 / CWE-190 | `time.zig:336, 314` |
| ASR-007 | JSONPath union negative index `-minInt(i64)` negation panic | **High** | Confirmed (reproduced) | A10 / CWE-190 | `jsonpath.zig:477-478, 508-509` |
| ASR-008 | `number.isMultipleOf` materializes up to ~2e9 zero-digits (schema `multipleOf`) | **High** | Confirmed (code) | A06/A10 / CWE-789 | `number.zig:183-188` |
| ASR-009 | JSON-LD expand/compact/flatten/frame + `@context` loops: unbounded recursion, no cycle detection | **High** | Confirmed (reproduced) | A10/A06 / CWE-674 | `jsonld.zig:513, 634-641, 791, 1004` |
| ASR-010 | Reader/streaming tokenizer skips continuation-byte UTF-8 validation → parser-differential | **High** | Confirmed (code) | A06 / CWE-176, CWE-436 | `tokenizer.zig:1195-1203` |
| ASR-011 | Unmarshal error paths leak partially-built structs/slices (no errdefer cleanup) | **High** | Confirmed (code) | A10 / CWE-401 | `unmarshal.zig:545-581, 211-219, 363-379` |
| ASR-012 | CBOR `decodeArray`/`decodeMap` leak decoded prefix + dangling key on late error | **Medium** | Confirmed (reproduced) | A10 / CWE-401 | `cbor.zig:636-641, 683-694` |
| ASR-013 | `parallel.zig` chunk math drops up-to-63 tail → uninitialized reads / wrong sums | **High** | Confirmed (code) | A10 / CWE-457, CWE-908 | `parallel.zig:89, 102-113, 193, 262` |
| ASR-014 | Reader tokenizer + `async.zig` buffer unboundedly; `max_string_len` never enforced | **Medium** | Confirmed (code) | A06 / CWE-789 | `tokenizer.zig:1197, 1306`; `async.zig:218, 99` |
| ASR-015 | Tokenizer/JSONLD/patch/jsonpath leak built elements on error (spine-only errdefer) | **Medium** | Confirmed (code) | A10 / CWE-401 | `tokenizer.zig:604, 644-651`; `jsonld.zig:568, 580`; `patch.zig:135-365` |
| ASR-016 | `emitter`/`encode` serialize caller-built trees with no depth limit; encode has no cycle detection | **Medium** | Confirmed (code) | A10 / CWE-674 | `emitter.zig:329, 172-194`; `encode.zig:281, 1007, 1022` |
| ASR-017 | Patch `setKey`/`removeKey` latent double-free if `toOwnedSlice` OOMs after freeing old obj | **Medium** | Confirmed (code) | A10 / CWE-415 | `patch.zig:790, 835-837` |
| ASR-018 | Streaming/tokenizer/jsonld 32-bit/`u32`/`i32` overflow & truncation on >4 GiB / huge exponent | **Medium** | Confirmed (code) | A10 / CWE-190, CWE-197 | `tokenizer.zig:48, 577`; `cbor.zig:467, 545, 591` |
| ASR-019 | Regex `{n,m}` bound parsing uses unchecked `usize` arithmetic | **Medium** | Confirmed (code) | A10 / CWE-190 | `regex_ecma262.zig:219-231` |
| ASR-020 | Regex silently drops groups `()` and alternation `\|` → schema `pattern` validates incorrectly | **Medium** | Confirmed (code) | A06 / CWE-697 | `regex_ecma262.zig:263-270` |
| ASR-021 | `$ref` depth-exceed silently returns "valid" (validation bypass) | **Medium** | Confirmed (reproduced) | A06 / CWE-693 | `schema.zig:1057-1058` |
| ASR-022 | `regex_ecma262`, `number.isMultipleOf` use `page_allocator`, bypassing caller limits | **Medium** | Confirmed (code) | A06 / CWE-770 | `regex_ecma262.zig:292`; `number.zig:184` |
| ASR-023 | `jsonld` shared module-level `blank_node_counter` (data race / nondeterminism) | **Low** | Confirmed (code) | A06 / CWE-362 | `jsonld.zig:970` |
| ASR-024 | `parallel.getPool`/`deinitPool` use-after-deinit race; `@panic` on init failure | **Medium** | Confirmed (code) | A06 / CWE-416, CWE-248 | `parallel.zig:24, 26, 33-36` |
| ASR-025 | `JSON-Schema-Test-Suite` cloned unpinned (`--depth 1` from GitHub `main`) in CI | **Low** | Confirmed (config) | A03 / CWE-494 | `.gitlab-ci.yml:172` |
| ASR-026 | gitleaks allowlists `tests/` and `examples/` wholesale | **Low** | Confirmed (config) | A03 / CWE-798 | `.gitleaks.toml` |
| ASR-027 | `pointer.zig`/`number.isMultipleOf` per-call `page_allocator` temp churn | **Info** | Confirmed (code) | A06 | `pointer.zig:23`; `number.zig:184` |
| ASR-028 | `build.zig.zon` `minimum_zig_version` (0.15.2) below a dependency's requirement (0.16.0) | **Low** | Confirmed (config) | A03 / CWE-1104 | `build.zig.zon:4` |

---

## 4. Finding Details

### ASR-001 — Number exponent `i32` overflow aborts the primary parse API — **Critical**

**Evidence.** `number.zig:54-58` accumulates the exponent with unchecked `i32` arithmetic:

```zig
58:  exp_val = exp_val * 10 + @as(i32, lexeme[pos] - '0');
```

There is no bound on the number of exponent digits in the grammar (`parser.zig:635-651` `parseExponent` loops while digits remain). `parser.zig:627` feeds the lexeme to `number_mod.parseNumber`, so this is on the *default* `json.parse` path. The streaming tokenizer has the identical pattern at `tokenizer.zig:577`.

**Impact.** A 13-byte untrusted JSON document `1e99999999999` aborts the process in Debug/ReleaseSafe (`panic: integer overflow`) or silently produces a wrong `Number` in ReleaseFast (parser-differential, since two number paths and schema comparison consume `exp10`). This is the single most reachable DoS in the library: it requires no schema, no CBOR, no special API — just `json.parse` with default options.

**Reproduction (executed):**

```text
$ json.parse(a, "1e99999999999", .{}, &err)
thread 2237418 panic: integer overflow
  .../src/number.zig:58:31 in parseNumber
```

**Remediation.** Use checked arithmetic (`std.math.mul`/`add` with error return → map to `InvalidNumber`) or cap exponent-digit count (e.g., reject exponents with more than ~7 digits; JSON numbers beyond `±1e308` are not representable as f64 anyway). Apply the same fix at `tokenizer.zig:577`. Add a regression test for very long exponents and ReleaseFast.

---

### ASR-002 — Regex bounded-quantifier compile explosion (no budget) — **Critical**

**Evidence.** `regex_ecma262.zig:210-258` compiles `{n,m}` by *physically duplicating* the previous instruction `min` times and emitting two instructions per optional copy, with **no cap** on the explicit upper bound:

```zig
247:  for (0..min) |_| { try instructions.append(a, last_inst); }
253:  const optional_count = max -| min;
254:  for (0..optional_count) |_| {
255:      const split_idx: u32 = @intCast(instructions.items.len);
256:      try instructions.append(a, .{ .op = .split, .x = split_idx + 1, .y = split_idx + 2 });
257:      try instructions.append(a, last_inst);
258:  }
```

`compilePattern` receives **no step/size budget** (the `regex_max_steps` option guards only the *match* phase — `regex_ecma262.zig:318` — which I confirmed is genuinely ReDoS-resistant; see Secure Design Notes). The pattern string is the attacker-controlled JSON Schema `"pattern"` (or a `patternProperties` key), compiled at `schema.zig:401` / `schema.zig:457`.

**Impact.** Each `Instruction` is ~32 bytes. `a{1,500000000}` requests ~1 billion instructions ≈ tens of GB → OOM / multi-second CPU DoS, before any instance is validated. Reachable through the public `compileSchema` API with a tiny schema document.

**Reproduction (executed):**

```text
$ Regex.compile("a{1,5000000}", a)
  -> compiled OK, instruction count = 10000000     # 12-byte pattern → 10M instructions
$ compileSchema with {"pattern":"a{1,2000000}"}
  T5 schema compiled (pattern blowup succeeded, memory consumed)   # ~4M insts in arena
```

**Remediation.** Add a compiled-instruction-count cap (reject patterns whose expansion exceeds a small constant, e.g. 10k), cap `{n,m}` upper bounds, and pass a compile-time budget analogous to `regex_max_steps`. Better: implement `{n,m}` with `split`/`jump` loops (as `*`/`+` already do at `regex_ecma262.zig:178,200`) instead of duplication — this also fixes ASR-003.

---

### ASR-003 — Regex quantified char-class double-free / segfault — **High** (Critical for direct `json.regex` users)

**Evidence.** A char-class instruction owns a heap slice `.ranges` (`regex_ecma262.zig:119`, `132-152`). The `{n,m}` path copies `last_inst` *by value* (`regex_ecma262.zig:244, 249, 257`), so every duplicate shares the **same `.ranges` pointer**. `CompiledRegex.deinit` then frees each instruction's `.ranges` (`regex_ecma262.zig:55-60`), freeing the shared allocation N times.

**Impact.** Any benign quantified char-class pattern — `[a-z]{3}`, `\d{4}`, `[0-9]{2,4}` — double-frees on teardown. Reachable through the **public `json.regex` API** with a general-purpose allocator. (Note: it is *not* reachable through the schema path, because `schema.zig` allocates the regex in an **arena** and never calls `Regex.deinit` — the arena frees each allocation exactly once. So the blast radius is "consumers using `json.regex` directly," which is a documented public re-export at `json.zig:27`.)

**Reproduction (executed):**

```text
$ json.regex.Regex.compile("[a-z]{3}", a) then re.deinit(a)
Segmentation fault at address 0x7f506bce0000
  .../regex_ecma262.zig:57 in deinit  (a.free(r))
```

**Remediation.** `a.dupe` the ranges for each duplicated instruction, or (preferred) rewrite `{n,m}` using `split`/`jump` so only one instruction owns `.ranges`. Add a leak/double-free test under `DebugAllocator` for quantified classes.

---

### ASR-004 — CBOR length-prefix unbounded pre-allocation — **High**

**Evidence.** `cbor.zig:636` and `cbor.zig:683` allocate from the wire length *before* verifying that many items remain:

```zig
636:  const items = try self.allocator.alloc(json.Value, @intCast(length));   // array
683:  const members = try self.allocator.alloc(json.Member, @intCast(length)); // map
```

`length` comes from `readArgument` (up to ~2^64). Byte/text strings are capped by `max_string_len` (`cbor.zig:541, 587`), but **arrays and maps have no element cap** and no "remaining bytes" check.

**Impact.** A ~5-byte CBOR payload declaring a 100-million-element array forces ~100M × `sizeof(Value)` (~2.4 GB) allocation before any element is read; a 9-byte payload declaring 2^64 elements forces an immediate huge request. Classic CBOR OOM primitive.

**Reproduction (executed):**

```text
$ cborDecode([0x9a,0x06,0x00,0x00,0x00])   # array(100663296), 5 bytes
  -> err=UnexpectedEof  (after allocating ~2.4 GB)
$ cborDecode([0x9b, FF×7, FE])             # array(~2^64), 9 bytes
  -> err=OutOfMemory
```

**Remediation.** Reject `length > remaining_bytes` (an item needs ≥1 byte, a map pair ≥2), and/or add `max_array_len`/`max_map_len` options mirroring `max_string_len`. Grow an `ArrayList` as elements are actually decoded instead of pre-allocating. This also bounds the `@intCast(length)` (ASR-018) and the leak (ASR-012).

---

### ASR-005 — Streaming `Tokenizer.readValue` unbounded recursion → stack overflow — **High**

**Evidence.** `readValue` → `readArray`/`readObject` → `readValue` recurse with no depth counter; `opts.max_depth` (`tokenizer.zig:66`) is **never consulted** by these functions (`tokenizer.zig:501-515, 602-626, 628-665`). The reader variant (`tokenizer.zig:1394+`) is worse — it streams, so depth is bounded only by the native stack.

**Impact.** The public `json.readValue` / `json.Tokenizer` path crashes on deeply nested input that the main `parser.zig` would reject. A consumer who chose the streaming tokenizer "for safety on large inputs" gets a stack-overflow abort instead.

**Reproduction (executed):**

```text
$ Tokenizer.init(a, "[" × 200000) ; readValue(&tok)
... readArray -> readValue -> readArray ...
Stopping trace after 10001 frames
process terminated with signal ABRT
```

**Remediation.** Thread a `depth` parameter through `readValue`/`readArray`/`readObject` (and the reader variants) and enforce `opts.max_depth`. `skipValue` (`tokenizer.zig:174-203`) also ignores `max_depth` and uses a `u16` depth counter that can overflow — fix both.

---

### ASR-006 — `Duration.fromIso8601` `@intFromFloat(inf)` panic — **High**

**Evidence.** `time.zig:314` scans an ISO-8601 numeric component (`[0-9.]`) with **no length bound**, parses it as `f64`, and `time.zig:336` does `total_nanos += @intFromFloat(@as(f64, …) * value)`. A long digit run parses to `inf`; `@intFromFloat(inf)` is out-of-range.

**Impact.** Reachable from untrusted input whenever an application unmarshals a JSON string field typed as `json.Duration` (the time types register unmarshalers, `time.zig:419-420`). Panics in Debug/ReleaseSafe, UB in ReleaseFast.

**Reproduction (executed):**

```text
$ Duration.fromIso8601("P" ++ "9"×350 ++ "Y")
thread panic: integer part of floating point value out of bounds
  .../time.zig:336 in fromIso8601
```

**Remediation.** Cap the component digit count, parse with checked integer arithmetic rather than `f64`+`@intFromFloat`, and use checked adds into `i128 total_nanos` (this also addresses the `i128` accumulation overflow, ASR-018 sibling).

---

### ASR-007 — JSONPath union negative-index negation panic — **High**

**Evidence.** `jsonpath.zig:477-478` (and `508-509`) negate an attacker-controlled `i64` index parsed from the path string:

```zig
477:  const actual_idx: usize = if (idx < 0)
478:      if (@as(usize, @intCast(-idx)) > arr.len) continue else arr.len - @as(usize, @intCast(-idx))
```

For `idx == minInt(i64)`, `-idx` overflows `i64`.

**Impact.** Public `json.jsonpath` with a fully attacker-controlled path string crashes (panic/abort). Confirmed reachable specifically via the **union** form `$[-9223372036854775808,0]` (the single-index path uses addition and is safe).

**Reproduction (executed):**

```text
$ json.jsonpath(a, root, "$[-9223372036854775808,0]")
thread panic: integer overflow
  .../jsonpath.zig:478 in executeQuery
```

(Single-index form `$[-9223372036854775808]` did **not** crash — only the union branch.)

**Remediation.** Guard `idx == std.math.minInt(i64)` before negating, or compute with `std.math.negateCast` / compare `idx < -@as(i64, @intCast(arr.len))` first.

---

### ASR-008 — `number.isMultipleOf` materializes ~2e9 zero-digits — **High**

**Evidence.** `number.zig:183-188` scales a number by appending `'0'` characters one per loop iteration, with `exp_diff = n.exp10 - div.exp10` controlling the count, using `std.heap.page_allocator` directly:

```zig
183:  for (0..@intCast(exp_diff)) |_| {
184:      n_int.append(std.heap.page_allocator, '0') catch return false;
185:  }
```

**Impact.** Reachable via JSON Schema `multipleOf` validation (`schema.zig` → `Number.isMultipleOf`). A value like `1e2000000000` drives ~2e9 iterations / ~2 GB allocation. Because it uses `page_allocator`, it bypasses any arena/caller allocation cap. (Note the interaction with ASR-001: in safe builds the exponent that produces this may itself panic earlier; in ReleaseFast the wrapped exponent can still drive a large `exp_diff`.)

**Remediation.** Bound `exp_diff`, use big-integer modular arithmetic instead of digit materialization, and use the caller's allocator (not `page_allocator`).

---

### ASR-009 — JSON-LD unbounded recursion + `@context` cycles — **High**

**Evidence.** No depth counter or cycle detection exists anywhere in `jsonld.zig`; `Options` has no `max_depth` field. `expandInternal` recurses on arrays (`jsonld.zig:541`) and members (`578`); `compactInternal` (`803, 822`), `generateNodeMap` (`934, 962`), `frameInternal` (`1018, 1044`), `cloneValue` (`1279, 1287`), and even `freeValue` (`1255, 1264`) all recurse unbounded. Context processing self-recurses via `document_loader` output (`jsonld.zig:634-641`) with **no "context already being processed" set**, so a loader returning a self-referential context loops forever.

**Impact.** Stack-overflow abort. For attacker-controlled JSON-LD *documents*, depth is bounded to 256 by the parser, but `ldExpand` et al. accept **caller-built `Value` trees** (the public API takes `Value`), and the `@context` loader cycle is unbounded regardless. Additionally, `@vocab`/prefix expansion (`jsonld.zig:391-398`) and double-cloning in flatten (`899, 956-962`) are memory-amplification vectors with no output/node cap.

**Reproduction (executed):**

```text
$ ldExpand(a, <100000-deep array Value tree>, .{})
Segmentation fault
  .../jsonld.zig:541 in expandInternal  (repeated frames)
```

**Remediation.** Thread a `depth` through every recursive function and fail past a cap; add a context-cycle seen-set in `processContext`; add `max_depth`/`max_nodes`/`max_output_size` to `Options`.

---

### ASR-010 — Reader/streaming tokenizer skips UTF-8 continuation validation (parser-differential) — **High**

**Evidence.** The reader/streaming tokenizer assembles a multi-byte sequence using only the lead byte (`unicode.utf8SeqLen`) and **never calls `decodeUtf8`/`isValidUtf8Seq`** on the result (`tokenizer.zig:1195-1203`): continuation bytes are appended verbatim. The slice tokenizer path *does* validate (`tokenizer.zig:319-328` → `unicode.decodeUtf8`), and `unicode.zig`'s standalone validators are correct (they reject overlong, surrogates, >U+10FFFF, and truncation — verified).

**Impact.** The same bytes (e.g. an overlong `\xF0\x80\x80\x80` or a UTF-16 surrogate `\xED\xA0\x80`) are **rejected by the slice parser but accepted by the streaming/reader parser**, and re-emitted verbatim. This is a UTF-8 smuggling / validation-bypass primitive when one component streams and another slices/validates. No OOB (the EOF guard at `tokenizer.zig:1201` prevents over-read).

**Remediation.** Call `unicode.decodeUtf8` on the assembled sequence in the reader/streaming path exactly as the slice path does; reject on error.

---

### ASR-011 — Unmarshal error paths leak partially-built results — **High**

**Evidence.** `unmarshalStruct` populates fields into a stack `result` with no `errdefer` that frees already-populated fields; if a later field fails (`TypeMismatch`/`IntegerOverflow`/`MissingField`), earlier `dupe`d strings / `alloc`ed slices leak (`unmarshal.zig:545-581, 604-621`). The slice path has a spine-only errdefer that frees the backing array but not already-built elements (`unmarshal.zig:211-219`, fixed-size `246-250`, path-tracking twin `363-379`). The codebase's own tests acknowledge this — comments at `unmarshal.zig:1519, 1532` say "Use simple/fixed types to avoid partial allocation issues."

**Impact.** Repeatable memory-exhaustion DoS: an attacker sends JSON that successfully unmarshals N-1 allocating fields/elements, then fails on the last. Each request leaks the prefix. Reachable via `json.unmarshal` / `json.fromValue`. Integer parsing itself is **safe** (range-checked via `std.fmt.parseInt`, `unmarshal.zig:1122-1127` — verified, no truncation), and no type confusion was found (`@ptrCast` only on comptime default pointers, `unmarshal.zig:610`).

**Remediation.** On any error after a field/element is populated, walk and `freeInternal` the populated prefix (the primitive exists at `unmarshal.zig:1241` but is never called on the error path). Also add a recursion-depth bound to `fromValueInternal` so the public `fromValue` is safe on deep caller-built trees.

---

### ASR-012 — CBOR `decodeArray`/`decodeMap` leak on late error — **Medium**

**Evidence.** `cbor.zig:637` (`errdefer self.allocator.free(items)`) and `cbor.zig:684` free only the slice, not already-decoded elements; `decodeMap` additionally leaks the current `member.k` if the value decode fails after the key was assigned (`cbor.zig:692-693`).

**Reproduction (executed, under `DebugAllocator`):**

```text
$ cborDecode(map(3) with two valid pairs then a malformed value)
CBOR decode err=UnexpectedBreak
error(DebugAllocator): memory address ... leaked:  .../cbor.zig:596 decodeTextString
error(DebugAllocator): memory address ... leaked:  .../cbor.zig:505 decodeUnsignedInt
  (multiple leaked addresses traced to decodeMap)
```

**Remediation.** Decode into an `ArrayList` with a contents-freeing `errdefer` (as the indefinite paths already do correctly, `cbor.zig:648-653, 701-707`), tracking the high-water index. Fix alongside ASR-004.

---

### ASR-013 — `parallel.zig` chunk math drops a tail of up to 63 elements — **High**

**Evidence.** `parallel.zig:89` floors `chunk_size = lines.len / MAX_CHUNKS`; the assignment loop stops at `n == MAX_CHUNKS (64)` while `i < lines.len`, leaving the tail `[i, lines.len)` (up to 63 entries) unassigned to any chunk (`parallel.zig:102-113`; identical at `193, 262`). `parallelProcessLines`/`parallelArrayProcess` then read the caller's `results` buffer for those untouched tail entries (`parallel.zig:128-132, 222-226`) — **uninitialized reads**; `parallelSum` simply omits them (`285-287`) — **silently wrong sum**. Worker output slots themselves are correctly disjoint and `wait_group`-synchronized (verified — no data race in the writes). A secondary path (`parallel.zig:116-126`) ignores `submitBatch().submitted`, dropping chunks under pool backpressure.

**Impact.** Deterministic, input-size-driven: e.g. `lines.len=100000` leaves 32 entries uncovered. Returns garbage `success`/`line_num` (uninitialized-memory info), undercounted validation success, and wrong sums — a correctness/integrity failure that could defeat a validation gate built on these helpers.

**Remediation.** Size chunks as `ceil(len / MAX_CHUNKS)`, or `assert(i == len)` and process any residual tail sequentially; check `submitBatch().submitted == n`.

---

### ASR-014 — Unbounded buffering; `max_string_len` never enforced — **Medium**

**Evidence.** The reader tokenizer appends every string/number byte to a growing buffer with no length check (`tokenizer.zig:1197, 1202, 1306-1372`); `opts.max_string_len` (`tokenizer.zig:904`) is never referenced. `async.addInput` appends to `self.input` with no cap (`async.zig:218`) and `parseString` never checks `max_string_len` (`async.zig:99`). (The fixed `read_buffer` itself does *not* grow — verified — and a 0-byte reader cleanly EOFs, no infinite loop, `tokenizer.zig:1110-1114`.)

**Impact.** A single giant token or a never-closing stream forces unbounded memory growth → OOM DoS on the streaming/untrusted-input path.

**Remediation.** Enforce `max_string_len` in both string scanners; cap or compact `async.input` past `pos`.

---

### ASR-015 — Tokenizer/JSON-LD/patch leak built elements on error (spine-only errdefer) — **Medium**

**Evidence.** `readArray`/`readObject` use `defer items.deinit` / `defer members.deinit` that free only the spine, leaking already-parsed element trees and the duped key on a mid-parse error; `readObject` lacks `errdefer free(key)` (`tokenizer.zig:604, 644-651`; reader variants `1410-1469`). JSON-LD builders leak built `Value` members (`jsonld.zig:568`), and `expandKey` leaks `expanded_key` when the value is dropped for `{"x":null}` (`jsonld.zig:580`). `toNQuads` never frees its fully-owned `expanded` tree (`jsonld.zig:1110-1122`). Patch builders leak partial clones on OOM (`patch.zig:135-365`).

**Impact.** Repeatable per-request leaks on adversarial input (e.g. `{"a":1,"b" 2}` leaks via the streaming readers). Memory-exhaustion DoS amplifier.

**Remediation.** Use contents-freeing `errdefer` loops and `errdefer free(key)` immediately after each key dupe.

---

### ASR-016 — Serialization recursion unbounded on caller-built trees; encode lacks cycle detection — **Medium**

**Evidence.** `emitter.emitValue` (`emitter.zig:329, 340, 362`) and the streaming `Encoder.writeValue` (`172-194`) recurse with no depth guard. `encode.zig` recurses over runtime slices / `json.Value` / `*T` pointers with no depth bound and **no cycle detection** (`encode.zig:281, 1007, 1022`); a cyclic pointer graph infinitely recurses. The `depth` parameter in `encode.zig` is used only for indentation, never checked.

**Impact.** `stringify`/`encode`/`toValue` on a deep or cyclic caller-built structure overflows the stack (uncatchable abort). Bounded for parser-built `Value` trees (≤256) but not for programmatically-built ones. String escaping itself is correct and OOB-safe (verified); binary base64/base32/hex sizing is overflow-safe (streamed, verified).

**Remediation.** Thread and enforce a depth limit through `emitValue`/`writeValue`/`encodeValue`/`toValueInternal`; document that cyclic pointer graphs are unsupported (or detect them).

---

### ASR-017 — Patch `setKey`/`removeKey` latent double-free on OOM — **Medium**

**Evidence.** `patch.zig:835` frees the old `obj` *before* `patch.zig:837` `toOwnedSlice` (which can OOM); on that error the caller's outer `errdefer freeValue(allocator, result)` (`patch.zig:742`) frees the now-dangling `result` again. Same shape in `removeKey` (`patch.zig:790`).

**Impact.** Double-free / use-after-free, gated on allocator failure (not directly attacker-controlled, but a real memory-safety bug). Note: move/copy aliasing and the `digits.ptr != lexeme.ptr` double-free guard (`patch.zig:373-378`) were reviewed and are **safe**.

**Remediation.** Build the new slice first, then free the old `obj` only after `toOwnedSlice` succeeds.

---

### ASR-018 — Integer overflow/truncation on >4 GiB inputs & huge exponents — **Medium**

**Evidence.** Token `offset` is `u32` set via `@intCast(self.pos)` (`tokenizer.zig:48, 120, 1000`) — panics/truncates on ≥4 GiB streams. `cbor.zig:467` `self.pos + count > self.data.len` can wrap if `max_string_len` is raised; `@intCast(u64 length)` (`cbor.zig:545, 591, 636, 683`) truncates on 32-bit targets. `parseNumberToken` exponent (`tokenizer.zig:577`) overflows `i32` (sibling of ASR-001).

**Impact.** Panic-DoS in safe builds on very large inputs; silent corruption / OOB in ReleaseFast (the CBOR `pos+count` wrap is an OOB-read primitive if `max_string_len` is enlarged).

**Remediation.** Use `usize` offsets or saturating arithmetic; replace `pos + count > len` with `count > len - pos`; cap CBOR counts (ASR-004).

---

### ASR-019 / ASR-020 — Regex bound-parsing overflow + dropped groups/alternation — **Medium**

**Evidence.** `{n,m}` bounds parsed with unchecked `usize` math (`regex_ecma262.zig:219-222, 228-231`) — `a{999999999999999999999}` overflows (panic safe / wrap fast). Groups `()` and alternation `|` are silently dropped as no-ops (`regex_ecma262.zig:263-270`), so `(foo|bar)` and `[a-z]|[0-9]` compile to incorrect programs.

**Impact.** ASR-019: another panic/wrap DoS via schema `pattern`. ASR-020: **security-relevant correctness** — a schema author relying on `pattern` as an input-validation control gets silently wrong validation (e.g. an allowlist `^(admin|user)$` does not behave as written).

**Remediation.** Parse bounds with `std.fmt.parseInt` + caps; implement or explicitly *reject* groups/alternation rather than silently dropping them.

---

### ASR-021 — `$ref` depth-exceed silently returns "valid" — **Medium**

**Evidence.** `schema.zig:1057-1058`: `validateNode(... depth: u16)` does `if (depth > ctx.opts.max_ref_depth) return;` — a bare `return` (no error, no failure recorded). `depth` increments only on `$ref` traversal (`schema.zig:1071, 1078`), not structural recursion.

**Impact.** A schema with `$ref` chains deeper than `max_ref_depth` (64) **stops validating and reports the instance as valid** — a validation bypass. Confirmed: a self-referential `{"$ref":"#"}` schema validates `42` as `ok=true` (reproduced). This correctly prevents stack exhaustion (good) but the bypass-as-valid semantics are a security weakness when schema validation is an enforcement boundary.

**Remediation.** On ref-depth exceed, record a validation error / fail closed rather than returning "valid".

---

### ASR-022 / ASR-024 — `page_allocator` bypass + global pool lifecycle — **Medium**

**Evidence.** `regex_ecma262.zig:292` (`runNFA`) and `number.zig:184` use `std.heap.page_allocator` directly, bypassing any caller-imposed bounded/arena allocator. `parallel.getPool` returns `&global_pool.?` after releasing the mutex (`parallel.zig:26`); a concurrent `deinitPool` (`33-36`) destroys it under an in-flight caller (use-after-free). `parallel.zig:24` `@panic` on pool-init failure converts a recoverable error into an abort.

**Remediation.** Plumb the caller's allocator into the regex matcher and `isMultipleOf`; document `deinitPool` as requiring quiescence (or refcount); return an error instead of panicking on init failure.

---

### ASR-023 — Shared `blank_node_counter` data race — **Low**

**Evidence.** `jsonld.zig:970` is a module-level `var`, shared across all processors/threads. Not memory-unsafe, but a data race and a source of non-deterministic blank-node IDs under concurrency.

**Remediation.** Move the counter into the `Processor` instance.

---

### ASR-025 / ASR-026 / ASR-028 — Supply-chain gaps — **Low**

**Evidence.** CI clones the `JSON-Schema-Test-Suite` with `--depth 1` from GitHub `main`, **unpinned** (`.gitlab-ci.yml:172`) — a test-time integrity gap (a compromised upstream `main` could influence the schema test job). `.gitleaks.toml` allowlists `tests/` and `examples/` wholesale, so a real secret committed there is not detected. `build.zig.zon:4` declares `minimum_zig_version = "0.15.2"` while the `thread_pool 0.2.5` dep requires 0.16.0 — a version-floor inconsistency that can produce confusing build failures for downstreams.

**Remediation.** Pin the test-suite to a commit SHA; narrow the gitleaks allowlist to specific fixture files; align `minimum_zig_version` to the highest transitive requirement (0.16.0).

---

## 5. Secure Design Notes (what the code does well)

- **The core RFC 8259 parser is solid.** `parser.zig` enforces `max_bytes`, `max_nodes`, and `max_depth=256` consistently via `checkLimits()` (`parser.zig:125-138`), incrementing depth in both `parseArray` and `parseObject` *and* re-checking after the increment (`parser.zig:659-662, 715-718`). Deep-nesting input is correctly rejected with `DepthLimit` — **reproduced** (100k-deep array → `JsonLimit/DepthLimit`, no crash). It rejects lone high/low surrogates (`parser.zig:452-483`), validates each UTF-8 sequence before copying (`parser.zig:388-403`), rejects leading zeros, trailing garbage, and unescaped control chars, and defaults `unique_keys=true`.
- **Arena allocation in the core parser and schema compiler makes their own error paths leak-free** — `parse` uses an arena with `errdefer p.arena.deinit()` (`parser.zig:836-837`); `Document.deinit`/`CompiledSchema.deinit` free everything at once. This is why the regex double-free (ASR-003) does *not* fire through the schema path.
- **The regex *matcher* is genuinely ReDoS-resistant.** It is a Thompson/Pike lockstep NFA with per-PC dedup (`regex_ecma262.zig:391-422`) and an enforced per-character step budget (`regex_ecma262.zig:318-319`, `regex_max_steps` default 1,000,000). I verified the budget works as a positive control (a 5000-`a` input against `a*a*a*a*b` returns `false` within budget, no hang). The ReDoS surface is the *compiler* (ASR-002), not the matcher.
- **`unicode.zig`'s standalone validators are correct** — they reject overlong encodings, surrogates (U+D800–DFFF), codepoints > U+10FFFF, and truncated sequences, with no OOB (verified by case analysis). The slice tokenizer uses them correctly; only the streaming path bypasses them (ASR-010).
- **Unmarshal integer conversion is range-checked** via `std.fmt.parseInt` (no `@intCast` truncation of untrusted integers), and no `@ptrCast`-based type confusion exists (`unmarshal.zig` — verified).
- **CBOR has a working depth limit** for arrays/maps (`cbor.zig:440, 623, 670`, default 256) and correctly terminates indefinite-length items on EOF (no infinite loop).
- **Parallel worker output slots are disjoint and `wait_group`-synchronized** — no data race in the writes themselves (the defect is dropped tail coverage, ASR-013).
- **Supply chain posture is above average for an OSS library:** git+https deps are content-hash-pinned (`build.zig.zon`), a custom diamond-dependency detector runs in pre-commit (`scripts/detect_diamond_deps.py`), the Zig toolchain is downloaded and **SHA-256-verified against the signed index** in CI (`.gitlab-ci.yml:39-78`), and SAST + dependency-scanning + secret-scanning + gitleaks + SBOM-generate/scan components are all wired in. A `SECURITY.md` with a private disclosure channel and a 48-hour acknowledgment SLA is present. Tests run across Debug/ReleaseSafe/ReleaseFast/ReleaseSmall, and a coverage-guided fuzz job exists (though gated to scheduled/manual pipelines).

---

## 6. Coverage Gaps & Questions

**Answers to the five posed questions:**

1. **Are recursion/nesting depth limits enforced consistently across entry points?** **No.** The core `parser.zig` enforces `max_depth` (reproduced safe). But it is **not** enforced in: the streaming `Tokenizer.readValue`/`skipValue` (ASR-005), `jsonld` expand/compact/flatten/frame and `@context` (ASR-009), `emitter`/`encode` serialization (ASR-016), and `fromValue`/`patch`/`jsonpath` on caller-built trees (ASR-011, P1/J1). Schema validation bounds `$ref` depth but *not* structural depth (relying on the parser's bound) and bypasses-as-valid on exceed (ASR-021). Several modules declare `max_depth`/`max_string_len` options that are **never checked** (tokenizer, async).

2. **Is the ECMA-262 regex engine bounded against ReDoS?** **At match time, yes** (enforced step budget, verified). **At compile time, no** — `{n,m}` expansion is uncapped (ASR-002, Critical) and bound parsing overflows (ASR-019). Groups/alternation are silently dropped, which is a correctness/validation issue (ASR-020).

3. **Do error paths leak or double-free?** **Both occur.** Confirmed leaks in `cbor.zig` (reproduced), `unmarshal.zig`, the tokenizer `readValue` paths, and `jsonld.zig` (ASR-011, ASR-012, ASR-015). Confirmed double-free/segfault in `regex_ecma262.zig` (reproduced, ASR-003) and a latent OOM-gated double-free in `patch.zig` (ASR-017). The arena-based core parser/schema paths are clean.

4. **Are SIMD fast paths equivalent to scalar on adversarial input?** The SIMD module's bounds are correctly checked before every vector load and UTF-8 multi-byte validation is correctly delegated to the scalar path — **no OOB or smuggling in `simd.zig`**. Critically, **the SIMD module is dead code**: it is re-exported from `json.zig` but never wired into `parser.zig`/`tokenizer.zig`/`unmarshal.zig`. The real parser-differential is elsewhere — the **streaming tokenizer skips UTF-8 continuation validation** (ASR-010), accepting overlong/surrogate sequences the slice parser rejects.

5. **Any integer overflow in size computations?** **Yes, several** — number exponent (ASR-001, Critical, reproduced), duration component (ASR-006, reproduced), jsonpath negation (ASR-007, reproduced), regex bounds (ASR-019), `isMultipleOf` scaling (ASR-008), and `u32` offset / CBOR `pos+count` / 32-bit `@intCast` (ASR-018).

**Coverage gaps / not fully exercised in this review:**

- The `uri` and `thread_pool` dependencies' *internals* were out of scope; `parallel.zig`'s `submitBatch` partial-success handling (ASR-013) depends on dependency semantics I read from the pinned source but did not stress under real pool saturation.
- I did not run the project's own fuzz target end-to-end; ASR-001/006/007 are exactly the kind of input it should catch — confirm whether the fuzz corpus already contains them.
- `schema_gen.zig`, `jsonl.zig`, and `debug.zig` received lighter review (no high-severity findings surfaced, but they were not exhaustively traced).
- ReleaseFast behavior of the overflow sites was reasoned about but reproduced only in Debug; the silent-wrap parser-differential consequences (ASR-001, ASR-010, ASR-018) deserve a dedicated ReleaseFast differential test.
- No business/threat-model doc was supplied; severities assume "library parses fully-untrusted input from a security boundary." If a given deployment only ever feeds trusted input to (say) `jsonpath`/`Duration`/streaming tokenizer, those severities drop.

---

## 7. Prioritized Next Actions

**P0 — fix before exposing any of these APIs to untrusted input (process-aborting / memory-corrupting):**

1. **ASR-001** — bound/checked-arithmetic the number exponent (`number.zig:58`, `tokenizer.zig:577`). This crashes the *primary* `json.parse` API on a 13-byte input; it is the highest-leverage fix.
2. **ASR-002** — cap regex compiled-instruction count and `{n,m}` bounds; add a compile budget (`regex_ecma262.zig:210-258`).
3. **ASR-003** — fix the quantified-char-class double-free (dupe `.ranges` per copy, or use `split`/`jump` loops).
4. **ASR-006 / ASR-007** — guard `@intFromFloat`/duration digits (`time.zig:336`) and the `minInt(i64)` negation (`jsonpath.zig:478, 509`).
5. **ASR-004** — cap CBOR array/map element counts against remaining input (`cbor.zig:636, 683`).

**P1 — DoS / integrity / bypass:**
6. **ASR-005 / ASR-009 / ASR-016** — add and *enforce* depth limits in the streaming tokenizer, JSON-LD processor (plus context-cycle detection), and the emitter/encode serializers; add depth bounds to `fromValue`/patch/jsonpath for caller-built trees.
7. **ASR-011 / ASR-012 / ASR-015** — fix errdefer hygiene (free built contents, not just spines) across unmarshal, CBOR, tokenizer, and JSON-LD. Add `DebugAllocator` leak tests for partial-failure inputs.
8. **ASR-013** — fix `parallel.zig` chunk coverage (`ceil` division + assert) and honor `submitBatch().submitted`.
9. **ASR-010** — make the streaming tokenizer validate UTF-8 continuation bytes like the slice path.
10. **ASR-021** — make schema `$ref` depth-exceed fail closed.
11. **ASR-008 / ASR-014 / ASR-022** — bound `isMultipleOf` scaling and enforce `max_string_len`; route regex/number allocations through the caller's allocator.

**P2 — correctness / hardening / hygiene:**
12. **ASR-020 / ASR-019** — implement or explicitly reject regex groups/alternation; checked bound parsing.
13. **ASR-017 / ASR-024 / ASR-023** — patch OOM double-free reorder; pool lifecycle/UAF and `@panic`→error; per-instance blank-node counter.
14. **ASR-025 / ASR-026 / ASR-028** — pin the test-suite SHA; narrow the gitleaks allowlist; align `minimum_zig_version`.

**Cross-cutting recommendations:**

- Add a **shared limits policy** (depth, string length, node count, output size) that *every* parser/processor accepts and enforces, and add a test that asserts each public untrusted-input entry point rejects (rather than crashes on) a deep-nesting, huge-number, huge-string, and huge-quantifier input.
- Add a **ReleaseFast differential test** for the overflow sites (ASR-001/006/007/018) — in safe builds they panic; the silent-wrap behavior in ReleaseFast must be regression-guarded.
- Treat "an option exists" as a **contract** — audit `max_depth`/`max_string_len`/`regex_max_steps` for actual enforcement at every use site; an unenforced limit is a latent vuln.
- Feed ASR-001, ASR-006, ASR-007 into the existing fuzz corpus and consider promoting the fuzz job out of scheduled-only.

---

*Reproductions were performed in an isolated `zig build` harness under `/tmp` against the package at commit `3c238be`; the repository was not modified. All "Confirmed (reproduced)" findings quote actual program output (crash signal, panic string, instruction count, or leak report).*

---

## Resolution Status (updated 2026-06-11)

Two fix passes addressed all 28 first-pass findings; a second adversarial pass
(NASR-001..NASR-004, NQUAL/NPERF series) caught regressions and missed cases,
which were then fixed. Final state: `zig build test` = 442 passing (Debug,
ReleaseSafe, ReleaseFast).

**First-pass findings (ASR-001..ASR-028): all Resolved.** The five reproduced
process-aborts (number exponent, regex compile blowup, Duration, JSONPath,
CBOR OOM), the two memory-corruption conditions (regex double-free, parallel
uninitialized read), and the validation bypass (`$ref` fail-open) are fixed with
regression tests. ASR-020 (regex groups/alternation) is resolved fail-closed
(returns `error.UnsupportedPattern`); full implementation is deferred.

**Second-pass findings (all Resolved):**

- NASR-001 — streaming tokenizer exponent crash + fractional-number corruption:
  routed `parseNumberToken` through `number.parseNumber`.
- NASR-002 — jsonld depth-limit error path leak: contents-freeing errdefers.
- NASR-003 — `isMultipleOf` u64 overflow panic: u128 modular intermediates.
- NASR-004 — unmarshal `*T` WithInfo leak: free pointee before `.err`.
- NQUAL-002..009 / NPERF-001 — error-contract, ownership re-exports, depth
  off-by-one, dead branch, UTF-8 single-pass: all fixed.

**Residual/accepted:** CBOR array/map still pre-sizes to `min(prefix, remaining)`
(input-proportional, not the original 5-byte→GB primitive); regex
alternation/grouping and JSONPath functions are fail-closed but unimplemented;
JSON Patch retains the per-op full-clone cost. These are bounded/by-design and
tracked in the gap and performance analyses.

### Iteration 4-5: deep-sweep findings (all Resolved → Converged)

Continued adversarial passes after the second-pass batch surfaced progressively
deeper issues, each fixed with regression tests:

- **NEW-001 (Critical)** — CBOR tag chains / nested indefinite strings bypassed
  `max_depth` (depth only counted in array/map) → ~500 KB payload stack-overflow
  abort. Fixed: depth accounting moved into `decodeValue`/`decodeTagged`; nested
  indefinite strings rejected per RFC 8949.
- **NEW-002 (High)** — `unmarshal` into an exhaustive enum aborted on an
  out-of-range number (`@enumFromInt`). Fixed: `std.enums.fromInt` → error.
- **NEW-003 (High)** — JSONPath recursive descent had no work budget →
  combinatorial C(D,N) CPU/memory DoS. Fixed: per-query node-visit budget
  (1,000,000) → `error.QueryTooComplex`.
- **NEW-004 (Medium)** — array/string `@context` expansion leaked a `Context`
  per call. Fixed: free the seed clone exactly once (errdefer-target tracking).
- **NEW-005 (Low)** — `RemoteContextLoader` cache eviction used a freed key.
  Fixed: `fetchRemove` before free.

Also added defense-in-depth: a structural-recursion cap in the schema compiler
and validator (`max_schema_depth=512`), and a `createTermDefinition` errdefer.

**Convergence (iteration 5):** an exhaustive final appsec sweep of every
`@enumFromInt`/`@intFromFloat`/`@intCast`/`@truncate`/`@ptrCast`/`unreachable`
site and every recursive/iterative path found them all range-guarded,
budget-bounded, or provably unreachable from untrusted input. Both the appsec
review and the gap/quality/performance audit report **no new findings**. Final
state: `zig build test` = 466 passing in Debug, ReleaseSafe, and ReleaseFast.
