# Slice: plan-annotation

## Delivers
The `hand-edited` surfacing in `ai-sdd plan` + a representative generator write-hook.

- `PlanReport`: for each changed artifact, consult `Provenance`; if its pre-change content already diverged from the recorded baseline, annotate the item `hand-edited` in the grouped output (orthogonal to tier — a `hand-edited` contract change shows both).
- Wire **one representative generator** to record provenance when it emits an artifact (P2 — proves the write path end-to-end; full bootstrap/compile-schema wiring is a follow-up if it would bloat this slice — flag it, don't inline it).
- Tests: a changed artifact diverged-from-baseline renders `hand-edited`; a pristine changed artifact does not; the wired generator records a correct entry.

## Acceptance
- `ai-sdd plan` marks a changed, diverged-from-recorded artifact as `hand-edited`; pristine ones are unmarked.
- The representative generator writes a valid provenance entry on emit.
- `swift build`, `swift test`, `swift run ai-sdd validate .ai-sdd` green.

## Stack
swift — `Sources/AISDDEngine/PlanReport.swift`, the chosen generator site, tests in `Tests/AISDDEngineTests/EngineTests.swift`.

## depends_on
provenance-manifest
