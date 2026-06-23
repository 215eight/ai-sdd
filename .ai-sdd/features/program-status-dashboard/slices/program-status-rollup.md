# Slice: program-status-rollup

**Stack:** swift · **Depends on:** (none — source slice)

## Delivers
The pure engine logic that turns a PROGRAM pipeline + its nested run state into a
`DashboardProjectionResult` — the core new rollup. No file IO, no rendering, no CLI.

Add a program projection entry point in `Sources/AISDDEngine/` (extend `DashboardProjection` or add a
sibling, e.g. `ProgramDashboardProjection`) with a signature like:

```swift
static func project(
    program: PipelineSpec,
    metadata: SpecMetadata,
    state: RunState? = nil,
    featurePipeline: (_ node: PipelineNode) -> (spec: PipelineSpec, metadata: SpecMetadata)? = { _ in nil }
) -> DashboardProjectionResult
```

`featurePipeline` is an injectable closure that returns a feature node's loaded sub-pipeline (so this
stays pure/testable — the assembler slice supplies the real file-loading closure; tests pass an inline
map). Each program node becomes a `DashboardProjectionRow`:

- **Feature node** (`node.kind == "pipeline"`): roll up to one `DashboardStatus` in precedence order:
  1. `state?.escalatedNodes.contains(node.id)` → `.escalated`
  2. `state?.failedChecks[node.id] != nil` → `.rework`
  3. top-level `state?.completedNodes.contains(node.id)` → `.done`
  4. else, if a feature sub-pipeline is available, project it with the nested
     `state?.slices[node.id]` (reuse `DashboardProjection.project`) and collapse its rows:
       - non-empty and every row `.done` → `.done`
       - any row `.done`/`.inProgress`/`.rework`/`.escalated` → `.inProgress`
       - otherwise → fall through to (5)
  5. program-tier dependency readiness: source / deps-met (via `Scheduler.runnable`) → `.runnable`,
     else `.pending`. (No program `state` → this static rule is the whole answer.)
- **Milestone node** (`node.worker == "milestone-gate"`, i.e. not `kind: pipeline`): use the existing
  plain-node precedence (escalated → rework → in-progress → done → runnable → pending), exactly as the
  project dashboard derives a worker node's status from `state` + the runnable set.

Rows must carry enough for the renderer to distinguish gates from features — set a clear, testable
signal (e.g. reuse/extend `DashboardProjectionRow` so milestone rows are identifiable; keep it
`Codable`/`Equatable`/`Sendable`). Populate owner (node owner → metadata owner → name/stack fallback),
dependencyCount, and `nextActionHint` consistent with the project dashboard. Aggregate the same
`DashboardProjectionSummary` (totalNodeCount, doneCount, per-status totals) so the donut/bar charts
work unchanged.

## Acceptance
- Pure function(s), no file IO. New types stay `Codable`/`Equatable`/`Sendable`.
- Swift Testing unit tests in `Tests/AISDDEngineTests/` cover, with inline `PipelineSpec` + `RunState`
  (+ inline featurePipeline map) fixtures:
  - feature-node rollup precedence: escalated, rework, top-level done, nested all-done → done,
    nested any-started → in-progress, runnable (source/deps-met), pending (deps unmet);
  - no-run static degradation (sources runnable, downstream pending);
  - missing feature sub-pipeline (closure returns nil) degrades to program-tier signals, no crash;
  - milestone-node gate status precedence;
  - summary counts match the rows.
- `swift build` + `swift test` green.
