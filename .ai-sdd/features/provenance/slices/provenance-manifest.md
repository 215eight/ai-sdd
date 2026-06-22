# Slice: provenance-manifest

## Delivers
The provenance manifest + its read/write engine APIs.

- A `Provenance` engine type backed by a committed `.ai-sdd/provenance.json` (path constant in `Layout.swift`): map `path → { generator, generatedAt, contentHash }`.
- **Write API**: record/update an entry for an emitted artifact. `generatedAt` is an **input** (ISO-8601 string, P3 — engine never reads the clock); `contentHash` is **SHA-256** over the artifact bytes (P1). Serialization is deterministic (stable key order) so the same inputs produce byte-identical JSON (no-op re-run = no diff).
- **Read API**: given an artifact path, return `pristine | hand-edited | untracked` by comparing current on-disk hash to the recorded hash.
- **Clobber-guard**: a function returning "do not overwrite" for a `hand-edited` artifact (what re-bootstrap calls before regenerating).
- Pure/injectable where possible; unit-testable against a temp manifest + temp artifacts, no clock.

## Acceptance
- Round-trip determinism: same inputs (incl. passed-in timestamp) → byte-identical `provenance.json`.
- An unmodified recorded artifact → `pristine`; a modified one → `hand-edited`; an unrecorded one → `untracked`.
- The clobber-guard returns "do not overwrite" for `hand-edited`, "ok" for `pristine`/`untracked`.
- SHA-256 hashing; no clock reads in engine code.
- `swift build` + `swift test` green.

## Stack
swift — `Sources/AISDDEngine/Provenance.swift`, `Layout.swift`, tests in `Tests/AISDDEngineTests/EngineTests.swift`.

## depends_on
(none — first slice)
