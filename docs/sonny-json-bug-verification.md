# SONNY JSON dependency bug batch

Scope: SONNY-2449 and SONNY-2780 in `devnw/zig/json`. No dependency pin, release, or downstream acceptance is claimed here. Tested locally with Zig 0.16.0, matching CI.

## SONNY-2449 — ownership and allocation failures

Executable regressions initially failed for partial `toValue` allocation cleanup, borrowed string/nested-slice defaults, plain parsing/decoding OOM masked as format errors, and detailed OOM reported as `json_parse`. Later numeric-allocation regression exposed the parser's number-error translation and was fixed before acceptance.

- Initialize partially built Value containers and clean them on failure, including nested inline members. The existing depth-limit regression now uses the leak-checking allocator directly, not an arena.
- Deep-clone native default shapes into the caller allocator with rollback. Tests cover strings, pointers, nested structs/slices, arrays, optionals, sentinel slices and tagged unions, including failure after a default was populated.
- Propagate `error.OutOfMemory` through plain unmarshal/fromValue, parser number allocation and custom unmarshaling.
- Preserve the public tagged-result shape of `unmarshalWithInfo`; report allocation failure with `UnmarshalErrorKind.out_of_memory`, an empty path and static message. This is deliberately not a change to an error-union return signature. Exhaustive enum switches must handle the new kind.
- Allocation-failure sweeps cover defaults, binary/string decoding, detailed paths, and numbers.

## SONNY-2780 — Unicode and JSON5

- Async escaped surrogate pairs now combine into a Unicode scalar instead of emitting CESU-8; invalid/lone surrogate halves are rejected.
- JSON5 double-quoted values and object keys use JSON5 escape handling. Existing single-quoted/unquoted handling is retained.
- Terminal percent-escape decoding was already correct in current source; added a regression, not an unnecessary implementation change.

## Local verification

The following commands completed successfully after the fixes:

- `zig build -j2 --summary all` — build passed.
- `zig build test-all -j2 --summary all` — 644 passed, 1 skipped: unit 555 passed/1 skipped, acceptance 15, data 34, schema 40.
- `zig build test -Doptimize=ReleaseSafe -j2 --summary all` — 555 passed, 1 skipped.
- `zig build test -Doptimize=ReleaseFast -j2 --summary all` — 555 passed, 1 skipped.
- `zig build test -Doptimize=ReleaseSmall -j2 --summary all` — 555 passed, 1 skipped.
- `git diff --check` — passed before documentation additions.

Schema test data was fetched using the repository script, pinned at `fe8c2f0de2041943975932b6bf4bd882625b6cfb`. An initial test-all failure due to missing schema data was resolved by that fetch; it was not treated as a passing check.

## Remaining gates

Hosted MR pipeline, review/merge, and downstream consumer qualification remain pending. No issues are marked Done by this document. Library changes do not add an authentication scope; caller-provided JSON crosses the parser boundary. Organization domain mapping and deployment auth context are not established by this library scope.
