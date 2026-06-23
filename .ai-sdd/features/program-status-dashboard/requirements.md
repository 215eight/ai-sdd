# Requirements: program-status-dashboard

> Status: **APPROVED** (human-confirmed 2026-06-22; all decisions closed).

## Goal
Make `ai-sdd graph --dashboard` accept a PROGRAM dir and render the master graph as a rich,
self-contained HTML dashboard: `ai-sdd graph .ai-sdd/programs/<slug> --dashboard --out <file>` shows
the program's feature nodes (`kind: pipeline`) + milestone gate nodes (`worker: milestone-gate`) +
`feature → milestone → feature` sequencing, with each feature node status-annotated by rolling up its
nested slice completion from the program run, milestone nodes styled distinctly as gates, a
program-level progress summary, and the existing chart vocabulary (status donut + grouped bar chart) —
the same self-contained, fully-escaped, no-server/no-CDN approach as the project dashboard. This is the
program tier of ADR-0027 dashboard work; the project and plant tiers already shipped.

## In scope
- A pure engine **program projection / rollup**: given a program `PipelineSpec` + the program's nested
  `RunState` (+ a loader for feature sub-pipelines), produce a `DashboardProjectionResult` whose rows
  are the program's feature nodes (rolled up to a single status) and milestone nodes (gate status),
  plus the summary aggregation the donut/bar chart already consume.
- A **program dashboard assembler** (`ProgramDashboardAssembler`) that loads the program pipeline,
  matches the program run by `RunMeta.pipelineDir`, resolves + loads each feature sub-pipeline to roll
  up its status, and emits `GraphRenderer.DashboardSection`(s) for `GraphRenderer.dashboardPage`.
- **CLI wiring**: relax the `--dashboard requires --project` gate so `--dashboard <programDir>` (no
  `--project`, no `--plant`) renders the program dashboard; `--dashboard --project <dir>` is unchanged.
- Distinct **milestone/gate styling** in the rendered graph/table, with pass vs blocked state.
- **Graceful degradation**: no program run → static graph statuses (sources runnable, downstream
  pending); missing/broken feature sub-pipeline → fall back to program-tier signals; never crash.
- Unit tests (Swift Testing) for the pure rollup + renderer, plus an assembler test that matches the
  run by `pipelineDir`. End-to-end verification against the real `guardrails` program + run.

## Out of scope
- Any change to the project dashboard, the plant dashboard, `--html`, single-graph, or plain Mermaid
  output (must remain byte-for-byte unchanged — additive only).
- A new top-level command or a new CLI flag (reuse `--dashboard`; gate is relaxed, not extended).
- Live/auto-refresh, a server, a CDN, authentication, remote run fragments, or the live overlay
  (ADR-0027 pending items remain out of scope).
- Deep multi-level drill-down pages per feature; the program dashboard shows ONE rolled-up status per
  feature node (the feature's own dashboard remains the project-tier view).
- Changing run-state storage, the engine's recursive execution, or the milestone-gate worker.

## Acceptance
1. `swift build`, `swift test`, and `swift run ai-sdd validate .ai-sdd` are all green.
2. `ai-sdd graph .ai-sdd/programs/guardrails --dashboard --out /tmp/prog.html` produces a
   self-contained HTML page rendering the three feature nodes (`locks`, `provenance`, `drift`), the
   `m1-guardrails-integrated` milestone, and the sequencing edges. Because the guardrails run is
   complete, the features show **done** and the milestone shows **passed**. No server/CDN; every
   name/id/status/text HTML-escaped; charts are inline SVG.
3. `ai-sdd graph .ai-sdd --project --dashboard --out /tmp/proj.html` still works unchanged.
4. Plain `ai-sdd graph .ai-sdd/programs/guardrails` and `ai-sdd graph .ai-sdd/programs/guardrails --html`
   Mermaid output are unchanged.
5. Unit tests cover, without file IO where possible: feature-node rollup precedence
   (done / in-progress / pending / runnable / escalated / rework), milestone-node gate status, no-run
   static degradation, missing-sub-pipeline degradation, HTML escaping, and that
   `ProgramDashboardAssembler` matches the program run by `pipelineDir`.

## Constraints
- Swift 6 + SwiftPM. Engine logic in `Sources/AISDDEngine/`; CLI surface in `Sources/AISDDCLI/`;
  shared Codable specs in `Sources/AISDDModels/`; all on-disk path literals in
  `Sources/AISDDEngine/Layout.swift` (no inline path strings).
- Swift Testing (`@Test`, `#expect`, `#require`, exact typed errors). Tests in
  `Tests/AISDDEngineTests/`.
- Reuse existing types — `DashboardProjection`/`DashboardStatus`/`DashboardProjectionRow`/`…Summary`/
  `…Result`/`DashboardNextActionHint`, `DashboardCharts`, `GraphRenderer`, `RunStore`/`RunState`/
  `RunMeta`, `SpecLoader`, `Scheduler`. Keep projection/rollup + renderer pure and unit-testable
  without file IO; HTML-escape every dynamic value and test it.
- Per `.ai-sdd/conventions/swift.md` and the conventions established in
  `.ai-sdd/features/project-status-dashboard/requirements.md`.

## Decisions
1. **(closed) Command surface — relax the gate, no new flag.** `--dashboard <dir>` with neither
   `--project` nor `--plant` treats `<dir>` as a PROGRAM pipeline dir and renders the program
   dashboard. `--dashboard --project <dir>` stays the project dashboard. `--dashboard` with no dir
   keeps an error. `--html`+`--dashboard` and `--plant`+`--dashboard` keep their existing errors.
2. **(closed) Feature-node status = rollup of nested slice state.** Precedence: escalated → rework →
   top-level completed (`.done`) → descend into `state.slices[node]` and roll up the feature
   sub-pipeline's projected rows (all done → done; any started → in-progress) → else runnable/pending
   by program-tier dependency readiness. No program run → static (source runnable, else pending).
3. **(closed) Milestone nodes use the existing plain-node status precedence** (escalated → rework →
   in-progress → done → runnable → pending) and are flagged so the renderer styles them distinctly as
   gates, surfacing pass (`.done`) vs blocked (rework/escalated/pending).
4. **(closed) Reuse the existing projection/summary/chart pipeline** so the donut and grouped bar
   chart (grouped by owner, fallback feature/node) work unchanged; the master graph is rendered as a
   status-annotated `DashboardSection` via `GraphRenderer.dashboardMermaid` + `dashboardPage`.
5. **(closed) Graceful degradation mirrors the project dashboard** — missing run → static statuses;
   missing/broken feature sub-pipeline → program-tier signals only; a truly invalid/empty program
   throws a clear typed error analogous to `ProjectDashboardError.noGraphs`. Never crash.
6. **(closed) Additive only** — every existing graph mode (single, `--project`, `--plant`, `--html`,
   plain Mermaid) is preserved unchanged; the program tier is purely new behavior on a previously
   erroring input.

## Proposed milestones
None — single coherent feature, sliced as a normal dependency graph (no phase gate needed).
