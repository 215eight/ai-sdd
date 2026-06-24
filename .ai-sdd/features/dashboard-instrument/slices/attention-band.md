# Slice: attention-band (S3 — phase 1, deps: S1, S2)

## Delivers
The triage panel between verdict and portfolio: the 3–6 items that need a human — **escalations**,
**rework loops**, and the **top unblockers** (from S2's ranking). It renders **nothing** when there is
nothing to act on (no empty-state noise). Items link to the feature/slice they concern.

## Why
Today rework/escalation is a thin colored border buried in a per-feature table; an EM scanning the page
can't answer "what do I act on" in five seconds. The attention band makes the on-fire items the second
thing on the page.

## Acceptance
- Lists escalations, rework loops, and top unblockers when present; each item names its feature/slice.
- Renders **nothing** (no header, no empty box) when there is nothing needing action — asserted by a
  clean-state fixture.
- Top-unblocker ordering comes from S2's downstream-unblock ranking.
- Pure render functions unit-tested without I/O; `swift build` + `swift test` green.

## Notes
Sits in the S1 band structure; consumes S2's projection. No wall-clock.
