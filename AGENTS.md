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
- `Sources/FactoryCLI` — the `ai-sdd` CLI: `validate · start · status · next · submit`.
- `Tests/FactoryEngineTests` — Swift Testing (`@Test`/`#expect`/`#require`).
- `legacy/` — the previous phase-engine implementation and its planning docs (`legacy/docs/`).
  **Reference only.** Generalize patterns from it; never extend it.

## Build / test / run

```sh
swift build
swift test
swift run ai-sdd validate docs/examples/minimal
```

## Execution model — interactive

The engine is the **deterministic planner**; the **agent does the work via skills** (ADR-0026).
The engine owns control flow and **enforces gates** — the LLM never decides control flow.

Loop: `ai-sdd next <id>` (engine renders the runnable Worker) → agent does the work via the
worker's skill → `ai-sdd submit <id>` (engine validates output, runs gates, reduces, advances) →
repeat. A failing required gate routes to **rework**. An orchestration run's slices each descend
into their own plan→implement→review pipeline.

A Worker's `task.skill: X` resolves to `<workspace>/skills/X.md` in an example, or to the repo
skill of that name in a real project.

A future MCP server (`ai-sdd next`/`submit` as MCP tools) is not built yet; drive via the CLI.

## Framework skills are provider-neutral

The factory must run under any coding agent (claude-code, codex, …) — ADR-0021/0026. So skills are
**not** authored inside an agent-specific folder. They live once, provider-neutral, and each agent
gets a thin pointer:

- **Canonical source:** `skills/<name>/SKILL.md` (this repo's framework skills: `ai-sdd-bootstrap`,
  `ai-sdd-plan`, `ai-sdd-compile-schema`, `ai-sdd-run`). In a *target* repo the equivalent home
  is `.ai-sdd/skills/`.
- **Codex / any agent:** this `AGENTS.md` is the cross-agent surface — Codex reads it natively.
- **Claude Code:** `.claude/skills/<name>` is a **symlink** to the canonical `skills/<name>` (so
  Claude's mechanism finds it without duplicating content).

The **`ai-sdd-bootstrap`** skill wires this for a target repo (copy framework skills into
`.ai-sdd/skills/`, write `AGENTS.md`, create the per-agent symlinks). The engine itself is already
provider-neutral — `ai-sdd` is a CLI any agent calls over a shell.

## Conventions

- Swift Testing, not XCTest. Assert **exact** typed errors (e.g. `SpecLoadError`), not `any Error`.
- All on-disk path names live in `Layout.swift` — no path string literals elsewhere.
- No design-doc jargon in code comments (no "Mode B", no ADR numbers); that vocabulary lives in
  `docs/` and commit messages.
- Work in reviewable pieces; build + test each; commit per piece. Don't push unless asked.
- `.ai-sdd/` (local run store) is gitignored.
