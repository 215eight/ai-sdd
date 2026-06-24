# Slice: event-timestamps-and-owner (S1 — keystone)

## Delivers
Give the run event ledger a time axis and an owner. Every event appended to
`.ai-sdd/runs/<feature>/events/` carries a `Z`-suffixed UTC `at` timestamp (RFC 3339), stamped at
append time, and a slice `owner` derived from git identity (`user.name` + `user.email`, with the slice
commit's author as fallback). The log stays append-only and replayable. "Now" is never read inside a
pure function, gate, or schema check — it is injected by the caller (so renderers/gates stay
reproducible and unit-testable without I/O).

## Why it's the keystone
The program's `m1-time-axis-ready` milestone gates the entire `dashboard-instrument` feature on this
landing — Part B's temporal metrics (velocity, cycle time, burndown, ETA) are unbuildable until events
carry `at`. Owner-from-git fills the dashboard's people view from the same enrichment.

## Acceptance
- A newly appended `nodeStarted` / `nodeCompleted` / rework / escalation event carries an `at` field
  in `…Z` UTC form; a fixture with events whose source instants are in two different zones orders them
  correctly when read back.
- Legacy events with no `at` load without error; any consumer treats missing `at` as "unknown" (no
  crash, no zero-substitution).
- Each slice's `owner` is captured from git identity at start/submit; a no-git-identity fixture yields
  `unowned` (no guess).
- No engine code on the gate/check/pure-render path reads the wall clock; the timestamp source is
  injected at the append boundary. Unit tests assert determinism with a fixed injected clock.
- `swift build` + `swift test` green.

## Notes
Round-trip (`read → mutate → write`) must preserve both old un-timestamped events and new timestamped
ones. Owner is the interim source; the assign-ahead flow is explicitly out of scope.
