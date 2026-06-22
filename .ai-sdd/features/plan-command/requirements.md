# `ai-sdd plan` — risk-tiered preview of factory-artifact changes (thin slice)

> **APPROVED 2026-06-22 — decisions closed; slices generated.** Planning gate (Step 2) cleared.

## Source Brief

`docs/examples/plan-command-brief.md` — cycle-1 thin slice of [ADR-0030](../../../docs/decisions.md).

## Goal

Add an `ai-sdd plan` subcommand that previews **pending `.ai-sdd/` changes** (git working tree vs the
committed baseline) and **classifies each changed artifact by blast radius**, computed deterministically
from the loaded spec graph. It exits **non-zero when any change is `contract`-tier** so a human/CI/agent
must explicitly acknowledge a contract-level change before committing — the `terraform plan` for the
factory. This slice ships the classifier substrate plus the `contract` tier end-to-end; it is read-only.

## In Scope

- A new read-only `Plan` subcommand in `Sources/AISDDCLI/main.swift`, registered in the `subcommands:`
  list, taking the `.ai-sdd` dir argument like `validate`.
- Detect changed files under `.ai-sdd/` between the working tree and a baseline via git
  (`git diff --name-status`), default `HEAD`, overridable with `--since <ref>`. Added / modified / deleted
  all detected.
- A deterministic classifier in `Sources/AISDDEngine` (new type, `ChangePlan`) mapping each changed path
  to a tier: `schemas/*.schema.yaml` → **contract**; `conventions/*`, `skills/*` → **refresh**;
  `workers/*`, `pipeline.yaml`, `checks/*` → **local**; other non-runtime paths → **local** (`unclassified`).
- **Consumer resolution for `contract`:** for a changed schema, load pipeline + workers via `SpecLoader`
  and list every worker whose `consumes` includes that schema (node id + worker name) — that list is the
  blast radius.
- Human-readable output grouped by tier; each item shows its path and (for `contract`) consuming workers.
- Exit non-zero when any change is `contract` or higher; `0` otherwise. `--require-ack <tier>` lowers the
  threshold; default `contract`.
- Run the existing `validate` wiring check **first**; refuse with the validation error on an invalid graph.
- Unit tests per tier, consumer resolution, exit-code threshold, `--since`, and the no-changes case.

## Out Of Scope

- Enforced freeze/locks and any real `frozen`-tier rendering (next ADR/cycle).
- The judge/intent-check re-eval flag (ADR-0007).
- Provenance (generated-vs-hand-edited) and drift detection.
- A no-write dry-run of the bootstrap skill.
- Machine/JSON output, non-git baselines, auto-commit/auto-fix.
- Modifying marker-managed shared files beyond reporting their managed block.

## Acceptance

- `ai-sdd plan .ai-sdd` with no `.ai-sdd/` changes prints "no changes" and exits `0`.
- Editing a `conventions/<stack>.md` → classified **refresh**, exit `0`.
- Editing a `workers/<x>.worker.yaml` → classified **local**, exit `0`.
- Editing a `schemas/<x>.schema.yaml` → classified **contract**, lists every worker that `consumes` `<x>`
  (fixture with ≥2 consumers), exits **non-zero**.
- `--require-ack local` makes a `local`-only change exit non-zero.
- `--since <ref>` diffs against `<ref>` instead of `HEAD`.
- Output is grouped by tier with per-item blast radius.
- `plan` against an invalid graph fails with the validation error, not a classification.
- `ai-sdd plan --help` documents the argument, `--since`, and `--require-ack`.

## Constraints

- Swift; follow `.ai-sdd/conventions/swift.md`. Engine behavior under `AISDDEngine`, CLI surface under
  `AISDDCLI`, tests under `Tests/AISDDEngineTests` (Swift Testing: `@Test`/`#expect`, typed errors).
- **Reuse `SpecLoader` and the `validate` path** — no new spec parsing or a second loader. Keep any new
  path constants in `Layout.swift` (naming/layering convention).
- Classification is **engine logic over loaded specs** (ADR-0001), deterministic and grounded in the graph
  — no model, no content heuristics. CLI command is a thin wrapper over the engine type.
- `plan` is **read-only**: never modify, write, or stage a file.
- Git access via `Process` (shell); baseline is the committed tree.
- Tier names match ADR-0030 exactly (`refresh` · `local` · `contract`; `frozen` reserved/unused here).
- Run `swift build`, `swift test`, `swift run ai-sdd validate .ai-sdd` before submitting.

## Decisions (closed — approved 2026-06-22)

| # | Question | Resolution | Status |
|---|---|---|---|
| D1 | Exit-code value for an ack-required plan | **`2`** — distinct from `validate`'s failure code, so CI tells "contract change pending" from "invalid graph". | closed |
| D2 | Deleted schema that still has consumers | Classify **contract** and additionally flag it as a **breaking removal** (consumers now reference a missing schema). | closed |
| D3 | Newly added schema with **0** consumers | **contract** tier, blast radius "0 consumers (new)"; it does **not** trip the non-zero exit (nothing depends on it yet) unless `--require-ack` says so. | closed |
| D4 | Tier granularity for a changed `checks/*` | **local** for this slice; richer check-blast-radius (classify by the worker it gates) is a later refinement. | closed |
| D5 | New-type placement | `ChangePlan` engine type in `AISDDEngine`; no new `AISDDModels` spec type (no persisted artifact). | closed |
