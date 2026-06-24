# Slice: burndown-and-eta (S6 — phase 2, deps: S5)

## Delivers
Two trajectory views built on S5's velocity: a **burndown** (cumulative slices-done over time,
reconstructed by replaying the timestamped append-only event log) and an **ETA as a band** —
`remaining ÷ recent velocity` rendered as a range with a confidence note, **suppressed entirely** when
history is too thin. Never a single false-precision date.

## Why
"Will we hit the date" is the #1 management question and today the dashboard is silent. Burndown shows
the trend; the ETA band answers the question honestly without pretending to a precision the data can't
support.

## Acceptance
- Burndown reconstructs cumulative-done-over-time from a timestamped-log fixture (log replay), with an
  injected `now` → deterministic.
- ETA renders as a confidence-banded range; a thin-history fixture shows it **suppressed**, not a date.
- Inline SVG (no CDN), self-contained.
- Pure functions, no wall-clock, unit-tested without I/O; `swift build` + `swift test` green.

## Notes
`DashboardCharts` (inline SVG) + `DashboardProjection`. Reuses S5's velocity; replay logic operates on
the append-only event log.
