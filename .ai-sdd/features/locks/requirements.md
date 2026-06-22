# Feature: locks — enforced freeze via the `frozen` tier (ADR-0031)

> **APPROVED 2026-06-22 — decisions closed; slices generated.**

## Source Brief
`.ai-sdd/programs/guardrails/requirements.md` (sub-feature `locks`) · [ADR-0031](../../../docs/decisions.md).

## Goal
Make the reserved `frozen` tier real so `ai-sdd plan` *refuses* an unintended change to a protected
artifact. Add `frozen` as the top `Tier`; declare protected paths in a committed `.ai-sdd/locks.yaml`
glob manifest; promote a change to a locked path to `frozen`; `ai-sdd plan` renders it ✗ and exits `3`
regardless of `--require-ack`; `--unlock <path>` downgrades for one invocation.

## In Scope
- Add `frozen` as the top case of `Tier` (above `contract`) in `ChangePlan.swift`, in the `Comparable` order.
- Load `.ai-sdd/locks.yaml` — a list of path globs (path-prefix + `*`, scoped under `.ai-sdd/`), each with a `reason` (D2).
- After base-tier classification, promote a change whose path matches a lock glob to `frozen`, carrying a `locked` flag with the reason.
- `PlanReport`: render `frozen` as a hard ✗ with the reason; `plan` exits **`3`** when any change is `frozen`, independent of `--require-ack`.
- `--unlock <path>` (repeatable): downgrade a matching frozen change to its base tier for this invocation only (the lock is unchanged).
- Tests: glob matching, promotion to frozen, exit 3, `--unlock` downgrade, `frozen` not waved through by `--require-ack`.

## Out Of Scope
- Provenance / `hand-edited` annotation (the `provenance` feature). Drift. A git pre-commit hook (optional convenience, not built here). Editing `locks.yaml` interactively (it's a hand-edited committed file).

## Acceptance
- A change to a path matching a `locks.yaml` glob is classified `frozen`, rendered ✗ with its reason, and `ai-sdd plan` exits `3`.
- `--require-ack contract` (or any threshold) does NOT wave a `frozen` change through — still exits 3.
- `--unlock <path>` downgrades that path's change to its base tier; `plan` then exits per the normal threshold.
- A non-locked change is unaffected (tiers/exit unchanged from today).
- `frozen` sorts above `contract` in `Tier`.
- `swift build`, `swift test`, `swift run ai-sdd validate .ai-sdd` green.

## Constraints
- Reuse `ChangePlan`/`Tier`, `PlanReport`, `Layout` (the `locks.yaml` path constant). No second classifier. Engine logic in `AISDDEngine`, CLI in `AISDDCLI`, tests in `Tests/AISDDEngineTests`. Deterministic.

## Decisions (proposed)
| # | Question | Proposed | Status |
|---|---|---|---|
| L1 | Frozen exit code | **`3`** (per ADR-0031; distinct from validate's 1 and ack's 2) | closed |
| L2 | `locks.yaml` absent | Treat as "no locks" — no `frozen` promotion, no error | closed |
| L3 | `--unlock` of a non-frozen path | No-op (warn, don't error) | closed |
