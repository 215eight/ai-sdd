# Slice: dedupe-drift

## Delivers
Removes the duplicated Tier-1 structural-check logic from `Drift.swift` now that `SchemaCompiler`
owns it (C4 — user amendment 2026-06-22).

- Refactor `Sources/AISDDEngine/Drift.swift` Kind 1 (stale-gate) detection to delegate to
  `SchemaCompiler.structuralCheck(name:version:schema:)` and `SchemaCompiler.structuralCheckName(for:)`.
- Remove the now-redundant private copies `Drift.expectedStructuralCheck(for:)` and
  `Drift.structuralCheckName(for:)` (or make them thin forwarders if any caller/test depends on them —
  prefer outright removal, updating call sites).
- Behavior is unchanged: a reconciled repo still yields no stale-gate findings; a divergent or
  missing/orphaned structural check is still reported with the same `recompile <schema>` remedy.

## Acceptance
- `Drift` Kind 1 computes the expected structural check via `SchemaCompiler` — no private Tier-1
  template remains in `Drift.swift`.
- The existing `DriftTests` (stale-gate found, orphan found, reconciled repo clean, hand-edited
  annotation) all still pass unchanged; the `SchemaCompiler` anchor test still passes.
- `swift build`, `swift test`, `swift run ai-sdd validate .ai-sdd` green.

## Stack
swift — `Sources/AISDDEngine/Drift.swift` (delegate to `SchemaCompiler`); adjust
`Tests/AISDDEngineTests/` only if a test referenced the removed private API. Reconcile with any
separate drift feature branch first if one exists.

## depends_on
extract-compiler (needs `SchemaCompiler` to exist before Drift can delegate to it)
