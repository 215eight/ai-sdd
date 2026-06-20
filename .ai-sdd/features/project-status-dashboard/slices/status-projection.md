# Slice: Status Projection

Build the pure model that classifies dashboard nodes from a pipeline and optional local run state.
This slice should not render HTML and should not perform file I/O.

## Brief

Add engine-level dashboard projection types and functions that convert `PipelineSpec`,
`SpecMetadata`, and optional `RunState` into rows and summary counts. The classification must handle
static/no-run graphs and local run-backed graphs.

## Acceptance

- A pure engine API derives per-node dashboard status values: done, in-progress, rework, escalated,
  runnable, pending.
- No-run behavior marks source nodes as runnable and dependent nodes as pending.
- Run-backed behavior uses `Scheduler.runnable`, `completedNodes`, `inProgressNodes`,
  `failedChecks`, and `escalatedNodes`.
- Projection rows include node id, stack, inherited/explicit owner, lane/milestone metadata,
  dependency count, status, and next-action hint.
- Summary counts include total features, total slices/nodes, done count, and per-status totals.
- Swift tests cover no-run roots, pending dependents, completed, in-progress, rework, escalated, and
  owner fallback data.

## Stack

swift
