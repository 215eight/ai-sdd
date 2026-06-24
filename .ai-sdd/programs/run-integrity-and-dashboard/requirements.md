# Program: Run integrity + the dashboard as a management instrument

> **APPROVED 2026-06-24 — decisions closed; master graph emitted.** Planning gate (Step 2) cleared.

## Source brief

`run-integrity-brief.md` (repo root) — decision-rich, two-theme brief: Part A (run-ledger
correctness) and Part B (dashboard as an EM/CTO instrument), joined by the timestamped-events
keystone.

## Goal

Stop the factory dashboard from silently lying about what is done, and turn it from an engineer's
DAG-debug view into an instrument an engineering manager / CTO can drive execution from. Part A makes
the run ledger self-healing and enforced (engine self-starts and resolves names, `pipelineDir` goes
repo-relative, stale runs are surfaced not dropped, the `/ai-sdd-run` skill verifies "done" against
the engine, a pre-commit tripwire catches slices committed without a submit) and gives the ledger a
**time axis** (timestamped events). Part B consumes that ledger to render a project-first,
four-band dashboard (verdict → attention → portfolio → detail) with critical-path, owner-from-git,
and — gated on the time axis — velocity / cycle-time / burndown / ETA.

## Sub-features (each → its own `ai-sdd-plan` feature)

Single-owner program; owners nominal (the maintainer drives, factory sub-agents do the work). The
program tier is used for the **`m1` milestone gate** between the two features, not multi-person
coordination.

- **`run-integrity`** (Part A) — the name resolver (`next`/`submit`/`status` self-start, slice→feature
  lookup with ambiguity errors), repo-relative `pipelineDir` + legacy absolute-path migration,
  stale-run surfacing in `status` and both dashboard assemblers, the status-driven `/ai-sdd-run`
  skill rewrite, the bootstrap pre-commit tripwire, **and the timestamped-events keystone** (every
  event carries a UTC `at`; events are Part A's ledger, so the time axis is owned here) plus
  **owner-from-git capture** into events. Owner: **maintainer**.
- **`dashboard-instrument`** (Part B) — restructure `ai-sdd graph --project --dashboard` into the
  inverted pyramid: verdict band (trajectory + freshness/trust badge reusing the Part A stale-run
  signal), attention band (escalations / rework / top unblockers), portfolio band (project-first,
  one health row per feature), detail band (per-feature graph **paired with its master-requirements
  definition** and carrying **slice identifiers** on every node), critical-path highlighting, and the
  temporal metrics (cycle time, WIP aging, velocity, ETA-band, burndown, "what changed since T-7d").
  Owner: **maintainer**.

## Milestones

- **`m1-time-axis-ready`** — **automated**. Gates `dashboard-instrument` until `run-integrity` lands
  and verifies: the reconciliation works and the event ledger has a usable time axis + owner.
  Proposed validation command: `swift build` + `swift test` + `swift run ai-sdd validate .ai-sdd`,
  plus smoke checks that (a) a freshly written run event carries a `Z`-suffixed UTC `at` timestamp,
  (b) a run with a legacy absolute `pipelineDir` is reconciled (not dropped) by `ai-sdd status` /
  the project dashboard, and (c) a slice owner is populated from git identity. Owner: **maintainer**.
  (Manual↔automated swaps only this node's worker/checks per docs/milestones.md.)

## Sequencing

- `run-integrity` → `m1-time-axis-ready`
- `m1-time-axis-ready` → `dashboard-instrument`

A strict 2-feature chain: Part A completes and the time axis is verified at the milestone before
Part B begins. See the parallelism tradeoff in Decisions (D5).

## Constraints

- Swift 6; follow `.ai-sdd/conventions/swift.md`. Engine logic in `AISDDEngine`, CLI shims in
  `AISDDCLI`, tests in `Tests/AISDDEngineTests` (Swift Testing — `@Test`/`#expect`/`#require`, exact
  typed errors). On-disk paths via `URL`; path constants in `Layout.swift`.
- Pure resolver / renderer functions are unit-tested without I/O; "now" is always **injected** (no
  wall-clock read inside gates, schema checks, or renderers).
- The skill rewrite lives in `skills/ai-sdd-run/SKILL.md`; the pre-commit hook install lives in the
  `ai-sdd-bootstrap` skill; the hook itself is POSIX shell. No new runtime deps.
- Reuse the shipped substrate — `RunStore`/`RunState`, `GraphRenderer`, `ProjectDashboardAssembler`,
  `ProgramDashboardAssembler`, the `SpecLoader`. No second loader/renderer.

## Decisions (closed 2026-06-24)

- **D1 — 2-feature program.** `run-integrity` (Part A) + `dashboard-instrument` (Part B). Status:
  `closed`.
- **D2 — `run-integrity` owns the timestamped-events keystone and owner-from-git.** They mutate the
  event ledger, which is Part A's responsibility. Status: `closed`.
- **D3 — one milestone, `m1-time-axis-ready`, automated.** It is the integration gate that holds
  `dashboard-instrument` until the reconciliation + time axis + owner land and verify together.
  Status: `closed`.
- **D4 — owners nominal (`maintainer`), single-owner program.** The program tier is used for the
  milestone gate, not people coordination. Status: `closed`.
- **D5 — accept program-tier serialization; defer no-new-data parallelism.** At the program tier a
  node is a whole feature, so `m1` gates *all* of `dashboard-instrument` on `run-integrity` — giving
  up the brief's "no-new-data band runs in parallel with Part A" parallelism. We accept this to keep
  the 2-feature shape you asked for. Forward-only escape hatch if the lost parallelism ever matters:
  amend into 3 features (`dashboard-core` parallel to `run-integrity`, `dashboard-temporal` gated on
  `m1`) — a pure append, no rewrite of started nodes. Status: `closed`.
