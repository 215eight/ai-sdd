# Slice: stale-run-surfacing (S4 — depends on S2)

## Delivers
Never silently drop a run. When reconciliation fails (a recorded `pipelineDir` doesn't resolve and S2's
migration couldn't heal it), surface it loudly: `ai-sdd status <name>` prints a `⚠ stale pipelineDir`
line showing the recorded path and the expected feature dir; and both `ProjectDashboardAssembler` and
`ProgramDashboardAssembler` attach the run **best-effort** (crediting its slice events directly) with a
`⚠ stale run` marker, instead of matching on exact path and rendering the feature as all-pending.

## Why
The adapter-interfaces failure: a real, completed run whose pointer went stale was dropped, and the
dashboard reported the feature 0% done with no breadcrumb. A dashboard that silently lies is the worst
failure mode — surface the drift so a human can fix it.

## Acceptance
- `ai-sdd status` on an unreconcilable run emits the `⚠ stale pipelineDir` line with recorded +
  expected paths.
- `ProjectDashboardAssembler` and `ProgramDashboardAssembler` render a `⚠ stale run` marker on any
  feature whose `runs/` entry exists but can't be matched to its `features/<name>/` dir, with the run
  state attached best-effort (not dropped to all-pending).
- A fixture reproducing adapter-interfaces (legacy absolute pointer) asserts the run is surfaced, not
  dropped; pairs with S2's healing path (healed → no marker; unhealable → marker).
- `swift build` + `swift test` green.

## Notes
Lives in `DashboardProjection` (`matchedState` / assembler) + the `status` command. The marker
serialization is the part Part B's verdict band later reuses as its freshness/trust signal — keep it a
single mechanism. Pure marker logic unit-tested without I/O.
