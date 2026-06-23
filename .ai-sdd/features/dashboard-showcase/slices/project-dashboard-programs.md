# Slice: project-dashboard-programs

**Stack:** swift · **Depends on:** (none — source slice)

## Delivers
`ai-sdd graph .ai-sdd --project --dashboard` becomes the whole-repo view: it keeps every
`Feature · <name>` section AND adds a `Program · <slug>` section per `.ai-sdd/programs/*`.

In `Sources/AISDDEngine/DashboardProjection.swift`:
- Extract a shared helper `programSection(programDir:runStore:fileManager:) -> GraphRenderer.DashboardSection`
  (or `-> DashboardSection?`) from the existing `ProgramDashboardAssembler.assemble` so the
  per-program section (load program pipeline, match run, feature-sub-pipeline loader, program rollup,
  `Program · <name>` heading + status-annotated `dashboardMermaid`) is reusable. `ProgramDashboardAssembler.assemble`
  must keep its current behavior/signature (refactor it to call the helper; do not regress its tests).
- Extend `ProjectDashboardAssembler.assemble(factoryDir:runStore:fileManager:)` to also enumerate
  `<factoryDir>/programs/*` directories (via `Layout.programsDir`), and for each, append the
  `programSection(...)` to the dashboard sections. Order: existing `Feature ·` sections first, then
  `Program ·` sections, each sorted alphabetically by slug. A program that fails to load is skipped
  gracefully (mirroring how a broken feature degrades) — never crash. The dashboard summary/donut/bar
  aggregate across feature + program sections automatically (they already sum over all sections).
- No CLI change (the `--project` path already calls `ProjectDashboardAssembler`). Path literals via
  `Layout.swift` only.

## Acceptance
- `ProjectDashboardAssembler.assemble` over a factory dir containing both `features/*` and `programs/*`
  returns sections: all `Feature ·` first, then `Program ·` per program (alphabetical), with the
  program rollup statuses.
- A factory with NO programs dir behaves exactly as today (only `Feature ·` sections) — no regression;
  existing project-dashboard tests still pass.
- A broken/unloadable program dir is skipped, not fatal.
- `ProgramDashboardAssembler.assemble` standalone behavior + its tests are unchanged.
- Swift Testing unit tests (temp-dir factory with features + a program with a milestone-gate node, plus
  a RunStore) cover the combined sections, the no-programs case, and the broken-program skip.
- `swift build` + `swift test` green.
