# Slice: dashboard-band-scaffold (S1 — phase 1)

## Delivers
Reshape `ai-sdd graph --project --dashboard` from a flat scroll of equal-weight feature blocks into
the inverted pyramid — **project first, features as progressive disclosure**. Adds the **verdict band**
(one derived trajectory line `on track`/`slipping`/`stalled`, the generation timestamp, and the
freshness/trust badge that **reuses run-integrity's `⚠ stale run` marker**) and the **portfolio band**
(one health row per feature: status + slice-count % + owner + current blocker). The existing per-feature
graph/table drops to the **detail band** beneath. The whole-project rollup renders before any single
feature's internals.

## Why
An EM/CTO reads in three passes (verdict → triage → drill); today's page is only the drill layer. The
scaffold is the substrate the attention/detail/temporal slices render into.

## Acceptance
- `--project --dashboard` renders verdict + portfolio + detail bands; the project rollup appears
  **before** any per-feature detail.
- Verdict band shows a derived trajectory (from blockers + escalations; velocity wired later), the
  generation timestamp (from an injected `now`), and the reused stale-run freshness badge.
- Portfolio band shows one health row per feature (status, slice-count %, owner with `unowned`
  fallback, blocker); headline is labelled **slices**, not effort.
- Existing modes (`--project`, `--plant`, `--html`, program dashboard) still render.
- Pure assembler/render functions unit-tested without I/O; `swift build` + `swift test` green.

## Notes
`GraphRenderer.dashboardPage` + `ProjectDashboardAssembler`. Inject `now`; reuse — don't fork — the
shipped renderer. The stale-run marker comes from run-integrity's S4; this slice consumes it.
