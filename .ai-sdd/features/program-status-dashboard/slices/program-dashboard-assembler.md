# Slice: program-dashboard-assembler

**Stack:** swift · **Depends on:** program-status-rollup

## Delivers
The file-aware assembler that turns a program dir on disk into a renderable dashboard, plus the
renderer touches that style milestone/gate nodes distinctly. No CLI yet.

1. **`ProgramDashboardAssembler`** in `Sources/AISDDEngine/` (sibling of `ProjectDashboardAssembler`):
   ```swift
   static func assemble(programDir: URL, runStore: RunStore,
                        fileManager: FileManager = .default) throws -> ProjectDashboard
   ```
   - Load the program pipeline via `SpecLoader.loadPipeline(atDirectory:)`.
   - Match the program run by scanning `runStore.runIds()` and comparing standardized
     `RunMeta.pipelineDir` to the program dir (reuse the project dashboard's `matchedState` approach;
     factor a shared helper if clean).
   - Build the feature-sub-pipeline loader closure: for a `kind: pipeline` node, resolve `node.pipeline`
     relative to `programDir` and `SpecLoader.loadPipeline(atDirectory:)` it; return nil on failure
     (graceful degradation). Pass this closure into the program-status-rollup projection.
   - Emit one `GraphRenderer.DashboardSection` for the master graph (heading e.g.
     `Program · <name>`), with `mermaid: GraphRenderer.dashboardMermaid(...)` of the program spec +
     projected rows so the graph is status-annotated.
   - Throw a clear typed error for a truly invalid/empty program (analogous to
     `ProjectDashboardError.noGraphs`); never crash on a missing run or a broken feature sub-pipeline.
   - Reuse path literals via `Layout.swift` (programs dir, pipeline file, etc.); no inline path strings.

2. **Renderer milestone/gate styling** in `Sources/AISDDEngine/GraphRenderer.swift`: render milestone
   rows distinctly from feature rows — in the status-annotated Mermaid (`dashboardMermaid`, e.g. a gate
   node shape) and/or the table/graph HTML — and surface pass vs blocked. Keep it additive: the
   project/plant dashboards and all existing graph modes must be unchanged. Escape every dynamic value.

## Acceptance
- Swift Testing tests in `Tests/AISDDEngineTests/` using a temp-dir program (write a `pipeline.yaml`
  with feature nodes + a `milestone-gate` node + edges, plus minimal feature sub-pipelines) and a
  `RunStore`:
  - assembler matches the program run by `pipelineDir` and produces the expected section(s) with
    rolled-up feature statuses + milestone gate status;
  - no-run case degrades to static statuses;
  - missing/broken feature sub-pipeline degrades, no crash;
  - invalid/empty program throws the typed error;
  - milestone rows render with the distinct gate styling and dynamic values are HTML-escaped.
- Existing project/plant dashboard tests still pass unchanged.
- `swift build` + `swift test` green.
