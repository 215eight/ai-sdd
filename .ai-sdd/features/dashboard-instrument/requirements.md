# Feature: dashboard-instrument (Part B of run-integrity-and-dashboard)

> **APPROVED 2026-06-24 — decisions closed; slices + milestone emitted.** Planning gate (Step 2) cleared.

## Source brief

`run-integrity-brief.md` (repo root), **Part B** scope. Part A (engine/ledger work) is the separate
`run-integrity` feature (already planned) and is out of scope here. This feature is gated at the
**program tier** by `m1-time-axis-ready`, so when it starts, run-integrity's reconciliation +
timestamped `at` events + owner-from-git already exist.

## Goal

Turn `ai-sdd graph --project --dashboard` from a flat scroll of equal-weight feature blocks into a
project-first management instrument: an inverted pyramid (verdict → attention → portfolio → detail)
that answers an EM/CTO's real questions. The **no-new-data band** reads only the DAG + status that
exist today; the **temporal band** layers velocity / cycle-time / burndown / ETA on top, computed
from run-integrity's `at` events with an injected `now`.

## In scope

### No-new-data band (DAG + status only)
- **Inverted-pyramid restructure**, project-first: the whole-project rollup is the landing; features
  are progressive disclosure.
- **Verdict band:** one trajectory line (`on track` / `slipping` / `stalled`, derived from blockers +
  escalations + — once available — velocity, NOT the raw %), the generation timestamp, and the
  **freshness/trust badge reusing run-integrity's `⚠ stale run` marker** (one mechanism, not a second).
- **Attention band:** the 3–6 items needing a human — escalations, rework loops, top unblockers;
  renders nothing when there's nothing to act on.
- **Portfolio band:** one health row per feature (status + slice-count % + owner + current blocker).
- **Detail band:** each feature's graph **paired with its master-requirements definition**, and
  **every graph node displays its slice identifier** (the id agents reference, e.g.
  `s1-protocols-and-exports`), not just a prettified label.
- **Critical-path highlighting** (longest dependency chain per feature) + **runnable ranked by
  downstream-unblock count**.
- **Honest gaps:** absent `owner` → explicit `unowned`; headline labelled **slices** (not effort).

### Temporal band (depends on `at` events; injected `now`)
- Per-slice **cycle time** (`completed − started`) + **WIP aging** (`now − started`, flag beyond
  threshold).
- **Velocity** (completions per window) feeding the verdict trajectory.
- **ETA as a band** (range + confidence note), suppressed when history is thin — never a single date.
- **Burndown** (cumulative done over time via timestamped-log replay).
- **"What changed since T-7d"** (replay log to a prior instant + diff: completed / newly blocked /
  newly escalated).

## Out of scope
- All Part A engine/ledger work (name resolver, `pipelineDir`, event timestamps, owner capture,
  skill rewrite, pre-commit hook) — the `run-integrity` feature.
- Effort / story-point weighting; a false-precision ETA date; any wall-clock read inside a
  gate/check/pure renderer; server / auto-refresh / live multi-machine; timestamp backfill;
  assign-ahead owner flow.
- Replacing existing modes — `--project`, `--plant`, `--html`, and the program dashboard keep working.

## Acceptance
- `ai-sdd graph .ai-sdd --project --dashboard --out <f>` renders the four bands; the **project rollup
  renders before any per-feature detail**.
- Attention band is **empty when nothing needs action**, else lists escalations / rework / top
  unblockers.
- Critical path is marked per feature; runnable nodes ranked by downstream-unblock count.
- Each per-feature detail pairs the graph with its master-requirements definition; **every node shows
  its slice id** (a fixture asserts the id text appears on nodes).
- Verdict band shows a derived trajectory + generation timestamp + the reused stale-run freshness
  badge; absent owner renders `unowned`.
- Temporal metrics render from a **fixed injected `now`** (deterministic output); a thin-history
  fixture shows them self-suppressing rather than emitting false precision.
- Burndown reconstructs from a timestamped-log fixture; "what changed since T-7d" diffs a replayed
  prior state.
- Existing modes still work; `swift build` + `swift test` green; `ai-sdd validate
  .ai-sdd/features/dashboard-instrument` passes.

## Constraints
- Swift 6; `.ai-sdd/conventions/swift.md`. Renderers in `AISDDEngine` (`GraphRenderer`,
  `DashboardProjection` / `ProjectDashboardAssembler` / `ProgramDashboardAssembler`,
  `DashboardCharts`); CLI shim in `AISDDCLI`. Pure render/projection functions unit-tested without
  I/O; "now" injected. Self-contained static HTML (inline SVG, no CDN). Reuse the shipped renderer —
  no second dashboard path.

## Milestones
- **`m1-no-data-band`** — **automated**. Phase gate: the no-new-data dashboard must render correctly
  (four bands, project-first, slice-ids on nodes, critical path) before the temporal band layers on.
  Validates `swift build` + `swift test` + `ai-sdd validate .ai-sdd`, plus the four-band render
  fixture. Owner: **maintainer**. Gates phase-1 slices → phase-2 (temporal) slices.

## Proposed slice decomposition (for approval)

**Phase 1 — no-new-data band** (S1/S2 parallel; S3/S4 follow both):
- **S1 `dashboard-band-scaffold`** — the inverted-pyramid reshape: verdict band (trajectory +
  freshness badge reusing the stale-run marker) + portfolio band (project-first health rows) + detail
  band wiring (existing graph becomes the detail layer). (no deps)
- **S2 `critical-path-and-ranking`** — longest-chain-per-feature computation + runnable-ranked-by-
  downstream-unblock. Pure DAG analysis. (no deps)
- **S3 `attention-band`** — triage panel (escalations / rework / top unblockers), empty when nothing.
  (deps: S1, S2)
- **S4 `detail-graph-context`** — pair each feature's graph with its master-requirements definition +
  slice ids on every node; consume S2's critical-path marking. (deps: S1, S2)

**Milestone `m1-no-data-band`** (automated) — deps: S1, S2, S3, S4.

**Phase 2 — temporal band** (S5/S7 parallel after milestone; S6 follows S5):
- **S5 `temporal-metrics-core`** — cycle time + WIP aging + velocity from `at` events, injected `now`,
  self-suppressing; feeds verdict trajectory. (deps: m1-no-data-band)
- **S6 `burndown-and-eta`** — burndown (log replay) + ETA-as-a-band. (deps: S5)
- **S7 `whats-changed-diff`** — "what changed since T-7d" via replay-to-prior-instant + diff.
  (deps: m1-no-data-band)

## Decisions (closed 2026-06-24)

- **D1 — 7-slice, two-phase decomposition above.** Status: `closed`.
- **D2 — phase the bands with an automated intra-feature milestone `m1-no-data-band`.** It validates
  the no-data dashboard renders correctly before temporal metrics layer on. *Alternative considered:*
  plain `depends_on` edges with no milestone node (lighter, but no explicit "phase-1 verified"
  checkpoint). Recommend the milestone since the no-data band is the substrate everything else renders
  into. Status: `closed`.
- **D3 — S4 (detail-graph-context) depends on S2 (critical-path)** so node rendering can mark the
  critical path in one pass. Status: `closed`.
- **D4 — verdict trajectory is derived, not the raw %**, and the freshness badge **reuses**
  run-integrity's `⚠ stale run` marker (single trust mechanism). Status: `closed`.
- **D5 — temporal metrics self-suppress on thin history and render from an injected `now`** (no
  wall-clock, no false-precision ETA). Status: `closed`.
