# Slice: drift-kind3  (Part 2 — convention↔code drift over the typed schema)

## Delivers
The third deterministic `DriftKind` — `conventionCitation` — checking the typed citations the
prerequisite slice introduced. Additive to Kinds 1+2; deterministic; advisory; provenance-aware.

- **Engine (`Sources/AISDDEngine/Drift.swift`):**
  - Add `case conventionCitation = "convention-citation"` to the `CaseIterable` `DriftKind` enum.
  - Add a `Drift.ConventionInput` (the `conventions/<stack>.md` repo-relative path + its parsed typed
    citations) and extend `Drift.scan(...)` to emit `conventionCitation` findings additively (grouped
    after Kinds 1+2, deterministically ordered).
  - Parse the Discovery Record: extract each row's Evidence cell, collect ONLY backticked tokens
    starting with `path:` or `cmd:` (zero heuristics, DC1). Rows with zero typed tokens are skipped
    (DC3).
  - Check `path:` tokens for existence via `FileManager`; run `cmd:` tokens via the engine's injectable
    shell executor (model on `CheckRunner.execute` — `@Sendable (String, URL) -> (Int32, String)`,
    default `CheckRunner.shell`; tests inject a stub so they don't shell out) and check exit 0.
  - A broken citation (missing path / non-zero command) ⇒ a `conventionCitation` `DriftFinding` whose
    subject is the convention path, detail names the broken citation, remedy `re-bootstrap <stack>`.
    Provenance annotation (`handEdited`) applied the same way Kinds 1+2 do.
  - Strictly deterministic — flag via citation breakage ONLY; no LLM/NLP judging.
- **CLI (`Sources/AISDDCLI/main.swift` `DriftCommand`):** load every `.ai-sdd/conventions/*.md`, build
  `ConventionInput`s, pass them into `Drift.scan`, and render `convention-citation` findings in the
  existing grouped output (it already loops `DriftKind.allCases`). Note the hand-edited set for each
  convention file via the existing `noteHandEdited`. Advisory exit unchanged (0 clean / 1 on findings).
- **Path literals:** any new fixed path lives in `Layout.swift` per conventions.

## Acceptance
- A convention with a missing cited `path:` (and a failing cited `cmd:`) is reported under
  `convention-citation` with a `re-bootstrap <stack>` remedy (temp-fixture test).
- A convention whose citations all hold produces no finding (temp-fixture test).
- An open-gap / no-typed-token row is skipped, not flagged (temp-fixture test).
- Kind 3 is deterministic (executor injected; no model), provenance-aware, advisory (never blocks).
- **Correctness anchor:** `swift run ai-sdd drift .` reports no `convention-citation` findings on the
  real converted `.ai-sdd/conventions/swift.md`.
- `swift build`, `swift test`, `swift run ai-sdd validate .ai-sdd` green.

## Stack
swift — `Sources/AISDDEngine/Drift.swift`, `Sources/AISDDCLI/main.swift`, `Sources/AISDDEngine/Layout.swift`,
tests in `Tests/AISDDEngineTests/`.

## depends_on
typed-evidence-schema
