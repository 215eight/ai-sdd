# Feature brief: program-status-dashboard

## Problem / the gap
`ai-sdd graph` renders a rich, self-contained HTML status dashboard, but ONLY at the project
tier: `ai-sdd graph .ai-sdd --project --dashboard --out <file>` lists the build pattern plus every
feature under `.ai-sdd/features/*` as a FLAT set, with a status donut, a per-owner bar chart, and a
status-annotated graph. It is program-blind: `--dashboard` errors with "requires --project" on
anything else, and `--project` never reads `.ai-sdd/programs/*`. So a program's master graph — its
feature nodes (`kind: pipeline`), its milestone gate nodes (`worker: milestone-gate`), and the
`feature → milestone → feature` sequencing — does NOT appear in any dashboard. Today the only way
to see a whole program is the plain Mermaid graph (`ai-sdd graph .ai-sdd/programs/<slug>`,
optionally `--html`), which has no status, rollups, or charts. This is ADR-0027 (graph/observability)
work — the dashboard shipped at the project and plant tiers; the program tier was never built.

## Goal
Make `--dashboard` accept a PROGRAM dir and render the master graph as a rich dashboard:
`ai-sdd graph .ai-sdd/programs/<slug> --dashboard --out <file>` produces a self-contained HTML page
showing the program's feature nodes + milestone nodes + sequencing, with:
- each FEATURE node (`kind: pipeline`) status-annotated by rolling up its slice completion from the
  program's nested run state;
- MILESTONE nodes (`worker: milestone-gate`) styled distinctly as gates, showing pass/blocked state
  from the run;
- a program-level progress summary (features complete / in-progress / pending; milestone pass/gate
  state) and the existing chart vocabulary (status donut; bar chart grouped by owner/feature);
- the same self-contained-HTML approach as the project dashboard: no server, no CDN, all
  names/ids/status/text HTML-escaped, inline SVG charts.

## Closed decisions (decision-closed brief)

### Command surface
- NO new flag. Relax the existing gate in `Graph.dashboardDoc()` (Sources/AISDDCLI/main.swift). Today
  the gate order is: reject `--html`+`--dashboard`; reject `--plant`+`--dashboard`; require
  `--project`; require a `dir`. New behavior:
  - `--dashboard --project <dir>` → project dashboard (UNCHANGED — `ProjectDashboardAssembler`).
  - `--dashboard <dir>` (no `--project`, no `--plant`, `dir` present) → PROGRAM dashboard via a new
    `ProgramDashboardAssembler.assemble(programDir:runStore:)`. The `dir` is a program pipeline dir.
  - `--dashboard` with no `dir` and no `--project` → keep an error directing the user to pass a dir.
  - `--html`+`--dashboard` and `--plant`+`--dashboard` → keep existing errors unchanged.
- Keep all other modes byte-for-byte unchanged: single graph, `--project` (markdown + `--html`),
  `--plant`, plain Mermaid output. Add the program tier; do not regress the others.

### Status rollup (the core new logic, in the engine)
- A program run's state is nested: program (top-level `RunState`) → feature (`state.slices[nodeId]`,
  itself a `RunState`) → slice. Match the program run by scanning `RunStore` and comparing
  `RunMeta.pipelineDir` to the program dir's standardized path (reuse the project dashboard's
  `matchedState` approach).
- For a FEATURE node (`kind: pipeline`) compute one rolled-up `DashboardStatus`:
  - No run state for the program → static graph status: runnable if its program-tier deps are met
    (a source node), else pending. Never crash.
  - With run state, in precedence order:
    1. `state.escalatedNodes.contains(node)` → `.escalated`
    2. `state.failedChecks[node] != nil` → `.rework`
    3. top-level `state.completedNodes.contains(node)` → `.done`
    4. else descend into `state.slices[node]` (the feature's nested `RunState`), load the feature
       sub-pipeline (resolve the node's relative `pipeline:` path against the program dir), project
       it with that nested state, and roll up the feature's own rows:
         - all feature rows `.done` (and at least one row) → `.done`
         - any feature row started (`.done`/`.inProgress`/`.rework`/`.escalated`) → `.inProgress`
         - else fall through to runnable/pending by program-tier dep readiness
    5. else runnable (program-tier deps met) / pending.
  - If the feature sub-pipeline cannot be loaded (missing/broken), degrade gracefully: use only the
    program-tier signals (escalated/rework/completed/runnable/pending), never crash.
- For a MILESTONE node (`worker: milestone-gate`, not `kind: pipeline`) use the existing program-tier
  status derivation (the same precedence the project dashboard uses for a plain node:
  escalated → rework → in-progress → done → runnable → pending). Mark these rows distinctly as gates
  so the renderer can style them as gates (e.g. a `milestone`/`gate` flag or the existing `milestone`
  field on the row) and surface pass (`.done`) vs blocked (`.rework`/`.escalated`/`.pending`) state.

### Projection / rendering reuse
- Reuse `DashboardProjection` types (`DashboardStatus`, `DashboardProjectionRow`,
  `DashboardProjectionSummary`, `DashboardProjectionResult`, `DashboardNextActionHint`),
  `DashboardCharts` (`statusDonut`, `groupedBarChart`, `defaultColors`), and `GraphRenderer`
  (`dashboardPage`, `DashboardSection`, `dashboardMermaid`, styles/legend/section/table HTML).
- Add a pure program-projection entry point that yields a `DashboardProjectionResult` whose rows are
  the program's nodes (features rolled up + milestones), plus the existing summary aggregation, so the
  donut and bar chart work unchanged. Group the bar chart by owner (fallback to feature/node), as in
  the project dashboard.
- The program dashboard page should present the master graph as a `DashboardSection` (heading like
  `Program · <name>`), with the status-annotated Mermaid graph (`dashboardMermaid`) showing the
  feature/milestone nodes + sequencing edges, the status legend, the donut, and the grouped bar chart.
  Distinguish milestone/gate nodes visually from feature nodes in the graph and/or table.

### Graceful degradation
- No run for the program → render a static graph dashboard (source nodes runnable, downstream
  pending), exactly as the project dashboard degrades. Never crash on a missing run, a missing
  feature sub-pipeline, or an unreadable program dir (surface a clear typed error only for a truly
  invalid/empty program, mirroring `ProjectDashboardError.noGraphs`).

## Constraints / conventions
- Swift 6 + SwiftPM. Engine logic in `Sources/AISDDEngine/`, CLI surface in `Sources/AISDDCLI/`,
  shared Codable specs in `Sources/AISDDModels/`, path literals in `Sources/AISDDEngine/Layout.swift`
  (no inline path strings). Tests in `Tests/AISDDEngineTests/` with Swift Testing (`@Test`,
  `#expect`, `#require`, exact typed errors). Per `.ai-sdd/conventions/swift.md`.
- Keep the projection/rollup and renderer PURE and unit-testable WITHOUT file IO where possible
  (construct `PipelineSpec` + `RunState` fixtures inline). HTML-escape every name/id/status/text and
  test escaping explicitly. Mirror the established conventions in
  `.ai-sdd/features/project-status-dashboard/requirements.md`.

## Verification (acceptance)
- `swift build`, `swift test`, `swift run ai-sdd validate .ai-sdd` all green.
- `ai-sdd graph .ai-sdd/programs/guardrails --dashboard --out /tmp/prog.html` renders the three
  feature nodes (locks, provenance, drift) + the `m1-guardrails-integrated` milestone + sequencing
  with sensible statuses. The guardrails run is COMPLETE, so features show done and m1 shows
  passed. Self-contained HTML (no server/CDN), everything escaped.
- `ai-sdd graph .ai-sdd --project --dashboard --out /tmp/proj.html` still works unchanged.
- Plain `ai-sdd graph .ai-sdd/programs/guardrails` (and `--html`) Mermaid output unchanged.
- Unit tests cover: feature-node rollup precedence (done/in-progress/pending/runnable/escalated/
  rework), milestone-node gate status, no-run static degradation, missing-sub-pipeline degradation,
  HTML escaping, and that the program assembler matches the run by `pipelineDir`.

## Reference (real model to test against)
- `.ai-sdd/programs/guardrails/pipeline.yaml` — feature nodes (`kind: pipeline` → `../../features/<feat>`),
  one `worker: milestone-gate` node (`m1-guardrails-integrated`), sequencing edges
  (`locks,provenance → m1 → drift`).
- `.ai-sdd/runs/guardrails` — the COMPLETED program run (gitignored local state); nested
  program→feature→slice `RunState` via `RunState.slices[String: RunState]` and `scoped` events.
- `.ai-sdd/programs/guardrails/requirements.md` — the master-graph shape.
