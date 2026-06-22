# Feature: `ai-sdd plan` — risk-tiered preview of factory-artifact changes (thin slice)

> Hand this to `ai-sdd-plan` as the feature brief. It is the **cycle-1 thin slice** of [ADR-0030](../decisions.md)
> — the `contract` tier carries the value; the `frozen` tier and judge-recheck are deferred to later
> cycles (locks/provenance/drift). Decision-closed so the planner does not invent scope; if anything is
> ambiguous, STOP and ask before drafting requirements.

## Goal

Add an `ai-sdd plan` subcommand that previews **pending `.ai-sdd/` changes** (the git working tree vs the
committed baseline) and **classifies each changed artifact by blast radius**, computed deterministically
from the loaded spec graph. It exits **non-zero when any change is `contract`-tier** so a human (or CI/
agent) must explicitly acknowledge a contract-level change before committing. This is the `terraform plan`
for the factory: see the classified impact before you commit, instead of squinting at a raw `git diff`.
This slice ships the classifier substrate and the `contract` tier end-to-end; it is read-only and writes
nothing.

## In scope

- A new read-only `Plan` subcommand in `Sources/AISDDCLI/main.swift`, registered in the `subcommands:`
  list alongside `Validate`/`Status`/etc., taking the `.ai-sdd` dir argument like `validate`.
- Detecting changed artifact files under `.ai-sdd/` between the working tree and a baseline, via git
  (`git diff --name-status`), default baseline `HEAD`, overridable with `--since <ref>`. Added / modified /
  deleted are all detected.
- A deterministic classifier in `Sources/AISDDEngine` (new type, e.g. `ChangePlan`) that maps each changed
  path to a tier:
  - `schemas/*.schema.yaml` → **contract**
  - `conventions/*`, `skills/*` → **refresh**
  - `workers/*`, `pipeline.yaml`, `checks/*` → **local**
  - anything else under `.ai-sdd/` (non-runtime) → **local** (default), labeled `unclassified`
- **Consumer resolution for the `contract` tier:** for a changed schema, load the pipeline + workers
  (reuse `SpecLoader`) and list **every worker whose `consumes` includes that schema** — node id + worker
  name. That list IS the blast radius.
- Human-readable output grouped by tier, each item showing its path and (for `contract`) the consuming
  workers.
- Exit code: **non-zero when any change is `contract` or higher**; `0` otherwise. `--require-ack <tier>`
  lowers the threshold (e.g. `--require-ack local` makes any `local` change also exit non-zero). Default
  threshold = `contract`.
- `plan` runs the existing `validate` wiring check **first** and refuses (clear error) on an invalid graph,
  so it never classifies against broken specs.
- Unit tests covering each tier, consumer resolution, the exit-code threshold, `--since`, and the
  no-changes case.

## Out of scope

- **Enforced freeze/locks** and any real rendering of the `frozen` tier — that's the next ADR/cycle; `plan`
  here knows only `refresh`/`local`/`contract`.
- The **judge/intent-check re-eval flag** (ADR-0007) — deferred.
- **Provenance** (generated-vs-hand-edited tracking) and **drift detection** — separate guardrails.
- A true **no-write dry-run** of the bootstrap skill — `plan` gates on the working tree, not on bootstrap.
- **Machine/JSON output**, non-git baselines, and any auto-commit or auto-fix behavior.
- Touching marker-managed shared files beyond reporting their managed block (`AGENTS.md`/`.gitignore`).

## Acceptance

- `ai-sdd plan .ai-sdd` with no `.ai-sdd/` changes prints "no changes" and exits `0`.
- Editing a `conventions/<stack>.md` is classified **refresh** and exits `0`.
- Editing a `workers/<x>.worker.yaml` is classified **local** and exits `0`.
- Editing a `schemas/<x>.schema.yaml` is classified **contract**, lists **every** worker that `consumes`
  `<x>` (verified against a fixture with ≥2 consumers), and exits **non-zero**.
- `--require-ack local` makes a `local`-only change exit non-zero.
- `--since <ref>` diffs against `<ref>` instead of `HEAD`.
- Output is grouped by tier with per-item blast radius shown.
- Running `plan` against an invalid graph fails with the validation error, not a classification.
- `ai-sdd plan --help` documents the argument, `--since`, and `--require-ack`.

## Constraints

- Swift; follow `.ai-sdd/conventions/swift.md`. **Reuse `SpecLoader` and the `validate` path** — no new
  spec parsing or a second loader.
- Classification is **engine logic over the loaded specs** (ADR-0001), deterministic and grounded in the
  graph — **no model, no heuristics on file content**. The CLI command is a thin wrapper over the engine
  type, matching the existing subcommand pattern.
- `plan` is **read-only**: it must not modify, write, or stage any file.
- Git access via `Process` (shell), consistent with the repo's git-as-store direction; baseline is the
  committed tree.
- Tier names match ADR-0030 exactly (`refresh` · `local` · `contract`, with `frozen` reserved/unused here).

## Open questions

- **O1** Exit-code value for an ack-required plan — propose **`2`** (distinct from `validate`'s failure
  code) so CI can tell "contract change pending" from "invalid graph."
- **O2** A **deleted** schema that still has consumers — propose classify as **contract** and additionally
  flag it as a breaking removal (the consumers now reference a missing schema).
- **O3** A **newly added** schema with no consumers yet — propose **contract** tier with blast radius
  "0 consumers (new)", so adding a contract is visible but not ack-blocking unless `--require-ack` says so.
  (Decide: does a 0-consumer contract change trip the non-zero exit? Proposed: **no** — nothing depends on
  it yet.)
- **O4** Should `plan` classify a changed **`checks/*`** by what it gates (its worker) rather than flat
  `local`? Proposed: **local** for this slice; richer check-blast-radius is a later refinement.
