# Slice: temporal-metrics-core (S5 — phase 2, deps: m1-no-data-band)

## Delivers
The first time-axis metrics, computed from run-integrity's `at` events with an **injected `now`**:
per-slice **cycle time** (`completed − started`), **WIP aging** (`now − started` for in-progress
slices, flagged beyond a threshold), and **velocity** (completions per trailing window) feeding the
verdict band's trajectory. Every metric **self-suppresses** (renders `—` / hides) when a run lacks
enough timestamped history — no false precision, no guessing on legacy un-timestamped events.

## Why
This is the temporal half the EM/CTO actually asks for ("are we moving, how fast"). It's gated behind
the program milestone because it needs the `at` events run-integrity lands.

## Acceptance
- Cycle time + WIP aging + velocity computed from a timestamped-event fixture with a **fixed injected
  `now`** → deterministic output.
- A thin-history (or un-timestamped) fixture shows the metrics self-suppressing rather than emitting
  zeros or false precision.
- Velocity feeds the verdict trajectory (replaces the placeholder from S1).
- Pure functions, no wall-clock, unit-tested without I/O; `swift build` + `swift test` green.

## Notes
`DashboardProjection` + verdict/portfolio render. `now` is a parameter, never read from the clock.
