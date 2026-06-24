# Slice: detail-graph-context (S4 — phase 1, deps: S1, S2)

## Delivers
Make the per-feature detail band useful for driving execution. Two things: (1) **pair each feature's
dependency graph with its master-requirements definition** — pull the feature's requirement summary /
acceptance from `.ai-sdd/features/<feature>/requirements.md` and render it alongside the graph so the
"why" sits next to the "what depends on what"; (2) **display the slice identifier on every graph node**
(e.g. `align-to-tag-action`), the exact id a coding agent references — not a prettified label. Mark the
critical path (from S2) on the nodes in the same pass.

## Why
For people driving execution with a coding agent, the graph is the driver but lacks context, and the
agent speaks in slice ids the current graph doesn't surface. Pairing the definition + showing the ids
lines the dashboard up with how the work is actually discussed.

## Acceptance
- Each per-feature detail renders the graph **and** the feature's master-requirements definition.
- **Every graph node displays its slice id**; a fixture asserts the id text appears on nodes.
- The critical path (S2) is marked on the nodes.
- Missing/absent requirements text degrades gracefully (graph still renders).
- Pure render functions unit-tested without I/O; `swift build` + `swift test` green.

## Notes
`GraphRenderer` node rendering + `ProjectDashboardAssembler` detail band. Reads requirements markdown
by path (convention, like the architect intake). No wall-clock.
