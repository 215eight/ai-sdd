# Feature: provenance — generated vs hand-edited (ADR-0032)

> **APPROVED 2026-06-22 — decisions closed; slices generated.**

## Source Brief
`.ai-sdd/programs/guardrails/requirements.md` (sub-feature `provenance`) · [ADR-0032](../../../docs/decisions.md).

## Goal
Record what the generators produced so re-bootstrap never silently clobbers a hand-edited artifact, and
so `ai-sdd plan` can mark a change as diverged-from-generated. A committed `.ai-sdd/provenance.json` maps
each generated artifact → `{ generator, generatedAt, contentHash }`; consumers compare on-disk hash to
the recorded hash.

## In Scope
- A `Provenance` engine type + a committed `.ai-sdd/provenance.json` manifest (`path → {generator, generatedAt, contentHash}`).
- Write API: a generator records/updates an entry per artifact it emits (`generatedAt` is an **input**, hash is content-addressed → deterministic, no-op re-run = no diff).
- Read API: given an artifact path, report whether its current on-disk content matches the recorded hash (`pristine` | `hand-edited` | `untracked`).
- `ai-sdd plan` annotation: a changed artifact whose pre-change content already diverged from its recorded baseline is marked `hand-edited` in `PlanReport` output.
- A reusable "would re-bootstrap clobber this?" check (`hand-edited` ⇒ do not silently overwrite) — exposed as a function re-bootstrap/CLI can call.
- Tests: hash match/mismatch/untracked, deterministic manifest (same inputs → identical JSON), the `hand-edited` annotation in plan output.

## Out Of Scope
- Locks / `frozen` (the `locks` feature). Drift detection. Actually wiring every generator (bootstrap/compile-schema) to write provenance — this feature ships the manifest + APIs + the plan annotation + the clobber-guard function; generator write-call wiring beyond a representative hook is a follow-up if it bloats the slice.
- A three-way merge UI (re-bootstrap flags + requires confirmation; merge tooling is later).

## Acceptance
- `provenance.json` round-trips deterministically: regenerating with the same inputs (timestamp passed in) produces byte-identical JSON.
- Given a recorded entry, an unmodified artifact reports `pristine`; a modified one reports `hand-edited`; an unrecorded one reports `untracked`.
- `ai-sdd plan` marks a changed artifact that diverged from its recorded baseline as `hand-edited`.
- The clobber-guard returns "do not overwrite" for a `hand-edited` artifact.
- `swift build`, `swift test`, `swift run ai-sdd validate .ai-sdd` green.

## Constraints
- Reuse `PlanReport` (annotation), `Layout` (manifest path), the existing artifact write paths. Engine logic in `AISDDEngine`. Deterministic; **no clock reads** in engine — timestamp is passed in. Content hashing via a std mechanism (e.g. SHA over bytes).

## Decisions (proposed)
| # | Question | Proposed | Status |
|---|---|---|---|
| P1 | Hash algorithm | **SHA-256** over raw bytes (stable, std) | closed |
| P2 | Generator write-wiring scope | Ship manifest + APIs + plan annotation + clobber-guard; wire **one representative generator hook**; full bootstrap/compile-schema wiring is a follow-up slice if needed | closed |
| P3 | `generatedAt` format | ISO-8601 string, **passed in** (engine never reads the clock) | closed |
