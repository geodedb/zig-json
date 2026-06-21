# FIPS-140-3 Status — json

**REQ-ID:** REQ-FIPS-EXEMPT-001 — non-security crypto/hash/RNG sites are
allow-listed (exempt) from the workspace FIPS-140-3 routing requirement per
`docs/superpowers/specs/2026-06-20-fips-pqc-design.md` §5.

**Mode:** This library performs only **non-security** hashing: a JSON-Schema
`$ref` resolution cache key. It is **exempt** from the workspace FIPS-140-3
routing requirement (see `fips` package spec
`docs/superpowers/specs/2026-06-20-fips-pqc-design.md` §5). No site produces,
protects, or verifies a secret, key, credential, authentication tag, or
signature; therefore none is routed through the `crypto_backend` seam and none
links the OpenSSL FIPS provider. When a consumer builds with `-Dfips=true`,
this library is unaffected: it adds no `-Dfips` flag and changes no behavior.

## Exempt call sites

| File:Line | Primitive | Use | Why non-security (exempt) |
|-----------|-----------|-----|---------------------------|
| `src/schema.zig:681` | `std.hash.Wyhash` | JSON-Schema `$ref` resolution cache key (`ref` + `base_uri`) | Hashmap lookup only; not a secret |

Line numbers are pre-annotation approximations.

## zlint allow-list

The site above carries an inline `// fips-exempt: non-security — <reason>`
annotation so the `zlint` FIPS rule treats it as allow-listed rather than a
violation. Adding a new `std.crypto` / `std.hash` / `std.Random` use to this
library REQUIRES adding both the inline annotation and a row in the table
above.
