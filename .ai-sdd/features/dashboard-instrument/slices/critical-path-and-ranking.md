# Slice: critical-path-and-ranking (S2 — phase 1)

## Delivers
Pure DAG analysis over each feature's slice graph: compute the **longest dependency chain** (critical
path) per feature, and **rank runnable slices by downstream-unblock count** (how many slices each one
unblocks) instead of treating all runnable nodes as equal. Output is a projection the scaffold (S1),
attention band (S3), and detail band (S4) consume — this slice computes, it does not render.

## Why
"9 runnable" is the dashboard's most actionable number but today every runnable node looks equal — a
leaf and a slice that unblocks 12 others read the same. The EM needs the long pole and the top
unblockers surfaced.

## Acceptance
- Per-feature critical path (longest chain) computed deterministically over the DAG; a fixture with a
  known longest path asserts the right chain.
- Runnable slices ranked by transitive downstream-unblock count; ties broken deterministically.
- Pure functions, no I/O, fully unit-tested; `swift build` + `swift test` green.

## Notes
Lives in `DashboardProjection`. No rendering here — S3 and S4 consume the projection. Deterministic
(no wall-clock).
