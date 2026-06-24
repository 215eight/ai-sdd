# Slice: whats-changed-diff (S7 — phase 2, deps: m1-no-data-band)

## Delivers
The "what changed since T-7d" view: replay the timestamped append-only event log to a prior instant
(`now − 7d`, the window injected, not wall-clock-derived) and **diff** against the present — what
**completed**, what **newly blocked**, what **newly escalated** since then. A weekly-cadence reader's
"what moved" answer.

## Why
An EM looking weekly wants motion, not a freeze-frame. The timestamped log makes point-in-time replay
cheap, so the diff comes almost for free once the time axis exists — and it's independent of the
velocity/ETA work, so it parallels S5/S6.

## Acceptance
- Given a timestamped-log fixture and an injected `now` + window, the view lists completed / newly
  blocked / newly escalated since the prior instant; deterministic output.
- Empty window (nothing changed) renders an explicit "no change" state, not a broken/empty diff.
- Pure replay+diff functions, no wall-clock, unit-tested without I/O; `swift build` + `swift test`
  green.

## Notes
`DashboardProjection` replay-to-instant + diff. Independent of S5/S6 — parallel after the milestone.
