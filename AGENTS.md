# AGENTS.md

This repository is **`ai-sdd`** — a spec-driven *software factory*: a deterministic engine that
turns declarative specs (YAML) into a sequenced, gated build workflow. The principle is **"specs
are data; the engine is the only code"** — every structural element (Plant, Factory, Pipeline,
Worker, Check) is a spec; the engine only loads, validates, schedules, gates, and folds events.

## Read first (canonical)

- `docs/architecture.md` — the model and execution model. Authoritative.
- `docs/decisions.md` — the ADR ledger (all decisions Accepted/Dropped; none open).
- `docs/examples/minimal/` — a runnable pattern pipeline (architect → coder → reviewer).
- `docs/examples/orchestration/` — a dependency graph of slices, each running that cycle.

The architecture is **settled**. Do not make design decisions or edit the ADRs without asking —
surface options and let the maintainer decide. New questions go under "Open decisions" in
`docs/decisions.md`.

## Layout

- `Sources/FactoryModels` — Codable spec types (`PipelineSpec`, `WorkerSpec`, `CheckSpec`, …).
- `Sources/FactoryEngine` — `SpecLoader`, `SpecValidator`, `Scheduler`, `Reducer`, `RunStore`,
  `CheckRunner`, `Renderer`, type-safe `Layout`.
- `Sources/FactoryCLI` — the `factory` CLI: `validate · start · status · next · submit`.
- `Tests/FactoryEngineTests` — Swift Testing (`@Test`/`#expect`/`#require`).
- `legacy/` — the previous phase-engine implementation. **Reference only.** Generalize patterns
  from it; never extend it. (Its old docs under `docs/*_doc.md`, `docs/enterprise-*` are legacy too.)

## Build / test / run

```sh
swift build
swift test
swift run factory validate docs/examples/minimal
```

## Execution model — interactive (Mode B), the MVP

The engine is the **deterministic planner**; the **agent does the work via skills** (ADR-0026).
The engine owns control flow and **enforces gates** — the LLM never decides control flow.

Loop: `factory next <id>` (engine renders the runnable Worker) → agent does the work via the
worker's skill → `factory submit <id>` (engine validates output, runs gates, reduces, advances) →
repeat. A failing required gate routes to **rework**. An orchestration run's slices each descend
into their own plan→implement→review pipeline.

To drive a run, use the **`/factory-run`** command / the `factory-run` skill
(`.claude/skills/factory-run/`). A Worker's `task.skill: X` resolves to `<workspace>/skills/X.md`
in an example, or to the repo skill of that name in a real project.

A future MCP server (`factory next`/`submit` as MCP tools) is not built yet; drive via the CLI.

## Conventions

- Swift Testing, not XCTest. Assert **exact** typed errors (e.g. `SpecLoadError`), not `any Error`.
- All on-disk path names live in `Layout.swift` — no path string literals elsewhere.
- No design-doc jargon in code comments (no "Mode B", no ADR numbers); that vocabulary lives in
  `docs/` and commit messages.
- Work in reviewable pieces; build + test each; commit per piece. Don't push unless asked.
- `.factory/` (local run store) is gitignored.
