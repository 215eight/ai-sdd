# Feature: drift-conventions — Kind 3 convention↔code drift (ADR-0033)

> **APPROVED 2026-06-22 — decisions closed (DC1–DC5 confirmed as proposed); slices generated.**

## Source Brief
This conversation's task brief · [ADR-0033](../../../docs/decisions.md) (the convention↔code kind,
"deterministic citation breakage, not judging") · the deferred slice brief
[`.ai-sdd/features/drift/slices/drift-conventions.md`](../drift/slices/drift-conventions.md).

## Goal
Complete the third deterministic kind of `ai-sdd drift` — **convention↔code** — which was deferred
because the convention Discovery Record's "Evidence" column is free-form prose that no parser can
split into real citations vs vocabulary/absence without the NLP judgment ADR-0033 forbids. Deliver it
in two ordered parts: **(1)** give the Discovery Record a typed, machine-readable evidence schema so a
parser reads citations with zero heuristics; **(2)** implement drift Kind 3 over that schema —
mechanically re-check each convention row's citations (cited path exists / cited command exits 0); a
broken citation flags an ungrounded convention with remedy `re-bootstrap <stack>`. The repo stays
reconciled throughout (`ai-sdd drift .` reports no convention findings on the real, converted
`swift.md`).

## In Scope
- **Part 1 — typed evidence schema.** A structured, heuristic-free evidence format for each Discovery
  Record row carrying machine-checkable citations and an explicit "no checkable citation" state.
  - Update the bootstrap skill that AUTHORS conventions — **both** identical copies:
    `skills/ai-sdd-bootstrap/SKILL.md` and the vendored `.ai-sdd/skills/ai-sdd-bootstrap/SKILL.md`
    (§1 "Discover the repo" + the prescribed Discovery Record format) so a future re-bootstrap emits
    the typed format.
  - Convert the existing `.ai-sdd/conventions/swift.md` Discovery Record to the typed format. Every
    typed citation written for the real repo **must pass** (cited path exists / cited command exits 0);
    open-gap / "no X found" rows carry **no** citation.
- **Part 2 — drift Kind 3.** A third `DriftKind` case (`conventionCitation`) in
  `Sources/AISDDEngine/Drift.swift`, composing additively with Kinds 1+2 (the `CaseIterable` enum, the
  `DriftFinding` struct, the grouped CLI output, and the `DriftCommand` wiring).
  - For each `conventions/<stack>.md`, parse the typed citations; check path existence via
    `FileManager`; run cited commands via the engine's injectable shell executor (the
    `CheckRunner.execute` / `ArtifactDiff.execute` pattern) and check exit 0. A broken citation ⇒ a
    `conventionCitation` finding, remedy `re-bootstrap <stack>`.
  - Open-gap / no-citation rows are **skipped**, never flagged.
  - Strictly deterministic — flag via citation breakage only; no LLM/NLP judging. Provenance-aware
    (a finding on a `hand-edited` convention is annotated) and advisory (exit 0 clean / 1 on findings,
    never blocks), matching the existing kinds.
- Tests (Swift Testing, `Tests/AISDDEngineTests`): a convention with a missing cited path **and** a
  failing cited command is flagged; intact citations are not flagged; an open-gap / no-citation row is
  skipped, not flagged — positive drift cases over **temp fixtures**, not the real repo.

## Out Of Scope
- LLM/NLP judging of convention-vs-code (only deterministic citation breakage).
- Auto-fixing or auto-re-bootstrapping (drift only reports + names the remedy).
- A blocking gate (drift stays advisory).
- Re-checking commit-SHA evidence as a drift signal (see decision DC2 — a historical SHA existing is
  not a staleness signal).
- Changing Kinds 1/2 behavior, or other stacks' convention files (only `swift.md` exists today).

## Acceptance
- The bootstrap skill (both copies, kept byte-identical) prescribes the typed evidence format in §1.
- `.ai-sdd/conventions/swift.md` is converted to the typed format; every confirmed row's citations
  pass; every open-gap row carries no citation.
- `Sources/AISDDEngine/Drift.swift` has a third `DriftKind` (`conventionCitation`); a convention with a
  missing cited path (and a failing cited command) is flagged with the `re-bootstrap <stack>` remedy;
  intact citations produce no finding; an open-gap / no-citation row is skipped.
- Kind 3 is deterministic (no model invoked), provenance-aware, and advisory (never blocks).
- **Correctness anchor:** `swift run ai-sdd drift .` reports **no convention findings** on the real
  converted `swift.md`.
- `swift build`, `swift test`, `swift run ai-sdd validate .ai-sdd` green throughout.

## Constraints
- Engine logic in `AISDDEngine`, CLI in `AISDDCLI`, tests in `Tests/AISDDEngineTests` (Swift Testing),
  path literals centralized in `Layout.swift` — per `.ai-sdd/conventions/swift.md`.
- Reuse the existing injectable shell-executor pattern (`CheckRunner.execute` / `ArtifactDiff.execute`)
  — the engine stays pure (no clock, command running injected so tests don't shell out).
- Model Kind 3 on the existing `DriftKind` cases as they stand after the recent SchemaCompiler refactor
  (Kind 3 is additive and orthogonal to Kind 1's delegation to `SchemaCompiler`).

## Decisions (proposed — confirm or change each)
| # | Question | Proposed | Status |
|---|---|---|---|
| DC1 | How/where do typed citations live? | In the Discovery Record table's **Evidence cell**, as labeled-prefix backticked tokens — `` `path:<repo-relative-path>` `` and `` `cmd:<command>` ``. A parser collects **only** tokens with a known prefix; all other text (prose, vocabulary in backticks like `` `@Test` ``) is ignored. **One** human+machine-readable source, no separate block to desync. | closed |
| DC2 | Which citation types are drift-checked? | Exactly two: **`path:`** (existence via `FileManager`) and **`cmd:`** (exit 0 via the injected executor). Commit SHAs and other prose are **not** typed citations (a historical SHA existing is not a staleness signal) — they stay as ordinary prose if a row wants to reference one. | closed |
| DC3 | How is "no checkable citation" expressed? | A row with **no typed token** in its Evidence cell has nothing to verify → **skipped**, not flagged. Open-gap rows keep `Status: open gap` and carry no `path:`/`cmd:` token. The skip rule keys purely off "zero typed tokens" — no heuristic. | closed |
| DC4 | Real-repo evidence: globs & command cost | Concrete repo-relative paths **only** (no globs — globs aren't existence-checkable). Commands are cited faithfully where a convention *is* a command (e.g. Build → `cmd:swift build`); `ai-sdd drift` running them is acceptable for an advisory maintenance command. Keep cited commands to ones that exit 0 quickly where possible. | closed |
| DC5 | Slicing | Two slices: **`typed-evidence-schema`** (Part 1) → **`drift-kind3`** (Part 2, `depends_on: typed-evidence-schema`). Natural prerequisite ordering; each is one plan→implement→review cycle. | closed |
