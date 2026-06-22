# Feature: drift — detect when committed artifacts go stale (ADR-0033)

> **APPROVED 2026-06-22 — decisions closed; slices generated.**

## Source Brief
`.ai-sdd/programs/guardrails/requirements.md` (sub-feature `drift`) · [ADR-0033](../../../docs/decisions.md).

## Goal
Tell the adopter *when* reality has moved out from under the committed factory. `ai-sdd drift [<dir>]`
reports divergence deterministically, names each finding's remedy, and is advisory (non-blocking).

## In Scope
- `ai-sdd drift [<dir>]` subcommand (read-only) + a `Drift` engine type. Reports findings grouped by kind; each names its remedy.
- **Kind 1 — stale gate:** recompile each schema's checks in-memory (the `ai-sdd-compile-schema` logic) and diff vs the committed `checks/*.check.yaml`; a difference = stale gate. Remedy: `recompile <schema>`.
- **Kind 2 — fixture↔schema:** validate known fixtures against current schemas via `SchemaValidator`; a failure = contract drift. Remedy: `fix fixture <path>`.
- **Kind 3 (MVP-conditional, D3) — convention↔code:** mechanically re-check each `conventions/<stack>.md` Discovery Record citation (cited path exists / cited command exits 0); a broken citation flags an ungrounded convention. Remedy: `re-bootstrap <stack>`. **Ship iff it stays thin; else defer to a follow-up slice (flagged in the run).**
- Advisory exit: `0` clean, non-zero when findings exist (for CI visibility); never blocks a run.
- Provenance-aware: a finding on a `hand-edited` artifact (from the `provenance` feature) is annotated as such.
- Tests per kind against fixtures (stale check, bad fixture, broken citation); clean repo → no findings, exit 0.

## Out Of Scope
- Auto-fixing (drift only reports + names remedies). LLM-judging conventions (only deterministic citation breakage). Blocking gates (drift is advisory). The surfacing-completeness check (covered separately by `ai-sdd surface --check`).

## Acceptance
- A schema whose committed check is stale vs a recompile is reported under stale-gate with `recompile` remedy.
- A fixture that violates its schema is reported under fixture↔schema with `fix fixture` remedy.
- (If Kind 3 ships) a broken convention citation is reported with `re-bootstrap` remedy.
- A fully-reconciled repo reports no findings and exits `0`; with findings, exits non-zero.
- A finding on a `hand-edited` artifact is annotated.
- `ai-sdd drift --help`; `swift build`, `swift test`, `swift run ai-sdd validate .ai-sdd` green.

## Constraints
- Reuse the `ai-sdd-compile-schema` compiler, `SchemaValidator`, `SpecLoader`, the convention Discovery Record citations, and `Provenance` (annotation). Engine logic in `AISDDEngine`, CLI in `AISDDCLI`. Deterministic; Kind 3 limited to flagging via citation breakage.

## Decisions (proposed)
| # | Question | Proposed | Status |
|---|---|---|---|
| Dr1 | Kind 3 (convention-citation) in MVP? | Ship the **two deterministic kinds** for sure; include Kind 3 iff thin, else follow-up slice (per program D3) | closed |
| Dr2 | Advisory exit code on findings | **`1`** (non-zero for CI; never blocks a run) | closed |
| Dr3 | Which fixtures for Kind 2 | The repo's existing schema fixtures / examples under `docs/examples/` + `.ai-sdd` | closed |
