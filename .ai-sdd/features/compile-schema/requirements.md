# Feature: compile-schema — extract the schema→checks compiler into the engine

> **APPROVED 2026-06-22 — decisions closed; slices generated.**

## Source Brief
Task brief: "extract the ai-sdd schema→checks compiler out of skill prose and into the engine as a
reusable library." Today the compilation lives ONLY as LLM prose in the `ai-sdd-compile-schema` skill;
no engine function does it, so nothing can recompile checks programmatically (this already capped the
sibling `ai-sdd drift` feature to a single Tier-1 check).

## Goal
Make the deterministic schema→checks compilation a real, reusable engine library. A new `SchemaCompiler`
takes a parsed `Schema` and returns the `CheckSpec(s)` it compiles to — pure (no IO) in the core, IO at
the edges — so it is unit-testable and callable from any engine code or CLI. The extracted compiler,
run over the repo's `schemas/*.schema.yaml`, MUST reproduce the committed structural checks.

## In Scope
- A `SchemaCompiler` engine type in `Sources/AISDDEngine/` (pure): parsed `SchemaSpec` (+ name/version)
  → compiled `CheckSpec(s)`, each tagged by origin (auto-generated vs authored).
- **Tier-1 (structural):** the fixed mechanical template keyed off schema name/version/format — one
  `<name>.structure` deterministic check, `required: true`. The correctness anchor.
- **Tier-2 (rules), mechanical part:** an explicit-`command` rule is copied verbatim, blocking iff its
  severity is blocking (auto-generated). Requires modeling `rules` on the schema.
- **Tier-3 (judge) + intent rules (the non-deterministic boundary):** modeled EXPLICITLY as
  "authored, not auto-generated" markers — never a fabricated command/verdict.
- A thin `ai-sdd compile <schema>` CLI subcommand (read-only; prints committed-shape `kind: Check`
  YAML, `--json` for machine output), mirroring `check`/`scope`/`cover`.
- Update the `ai-sdd-compile-schema` skill to drive the engine compiler for the deterministic tiers.
- A correctness-anchor test: compile every real `.ai-sdd/schemas/*.schema.yaml` and assert the
  structural check matches the committed `checks/<name>.structure.check.yaml` semantically; per-tier
  unit tests.
- **Dedupe `Drift` Kind 1 onto `SchemaCompiler`** (user amendment, 2026-06-22): refactor
  `Drift.swift`'s stale-gate detection to delegate to `SchemaCompiler.structuralCheck(...)` /
  `structuralCheckName(...)`, removing the private `Drift.expectedStructuralCheck` /
  `Drift.structuralCheckName` copies. The existing `DriftTests` and the new anchor test must still
  pass. A downstream slice (`depends_on` the extraction).

## Out Of Scope
- Auto-wiring compiled check ids onto producer workers from the CLI (stays a skill/human step).
- Cross-artifact resolution of intent→trusted-executor commands (scope/cover) — left authored.
- Writing/committing compiled checks from the CLI (`compile` prints; the human/skill commits).

## Acceptance
- `SchemaCompiler.compile(...)` over each committed schema reproduces the committed structural check
  (same name, checkKind, command, required) — verified by a test that reads the real repo.
- An explicit-command rule compiles to a verbatim deterministic check, blocking by severity.
- An intent-only rule and a judge compile to advisory `authored` markers (no fabricated command).
- `ai-sdd compile <schema>` prints the compiled checks (and `--json`); `--help` documents it.
- The `ai-sdd-compile-schema` skill references the engine command for the deterministic tiers.
- `Drift` Kind 1 delegates to `SchemaCompiler` (no private Tier-1 copy remains in `Drift.swift`);
  `DriftTests` and the anchor test stay green.
- `swift build`, `swift test`, `swift run ai-sdd validate .ai-sdd` all green.

## Constraints
- Follow `.ai-sdd/conventions/swift.md`: engine logic in `AISDDEngine`, CLI in `AISDDCLI`, shared
  Codable spec types in `AISDDModels`, path literals centralized in `Layout.swift`, tests in
  `Tests/AISDDEngineTests` with Swift Testing.
- The structural `command` MUST match the COMMITTED reality `swift run ai-sdd check <schema> <artifact>`
  (not the skill prose's abbreviated `ai-sdd check …`).
- Pure core (no IO); IO/serialization at the edges (CLI + a rendering helper).

## Decisions (proposed)
| # | Question | Proposed | Status |
|---|---|---|---|
| C1 | How far to model Tier-2/Tier-3? | Add optional `rules`/`judge` to `SchemaSpec`; compile explicit-command Tier-2 mechanically; emit intent rules + judges as explicit **authored** markers (don't fake them) | closed |
| C2 | CLI surface | Add a read-only `ai-sdd compile <schema>` (prints committed-shape YAML, `--json`) AND update the skill to call it | closed |
| C3 | Structural command form | Match the **committed** `swift run ai-sdd check …` (not the skill's abbreviated form) | closed |
| C4 | Touch `Drift.swift` (dedupe its Tier-1 copy)? | **Yes** — dedupe it onto `SchemaCompiler` as a downstream `dedupe-drift` slice (user amendment 2026-06-22). Reconcile with any separate drift branch first; keep `DriftTests` green | closed |
| C5 | Correctness anchor | A test compiles every real schema and asserts the structural check == the committed gate | closed |
