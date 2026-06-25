# Canonical, Auto-Refreshed Dashboard Snapshot

> DRAFT — pending human approval of the Decisions below. Slices are NOT generated until this is approved.

## Source Brief

`brief.md`

## Goal

Make the committed dashboard snapshot a single, framework-defined, auto-refreshed artifact. Today
`ai-sdd graph … --dashboard` writes to a free-form, optional `--out` path (or stdout) and nothing
regenerates it at the end of a run — so the one artifact meant to give a team visibility is both
non-canonical (any filename → divergent partial snapshots) and stale (never auto-updated). This
feature gives the factory exactly one canonical dashboard path and regenerates that snapshot
automatically when a run completes, so a local run leaves an accurate, committed snapshot. Rendering
content is unchanged — this is about **where** the dashboard is written and **when**.

## In Scope

- A **canonical dashboard path** per factory, default `.ai-sdd/dashboard.html`. `ai-sdd graph .ai-sdd
  --project --dashboard` with **no `--out`** writes to that path (today it prints to stdout).
- `--out <path>` remains an explicit ad-hoc override; an explicit stdout escape hatch stays available.
- **Auto-regeneration at end of run:** when a run reaches terminal `done`, the canonical snapshot is
  regenerated from local run state and included in the run's commit. Applies to feature and program runs.
- **Idempotent + deterministic** output: regenerating over unchanged run state yields a byte-identical
  file (no generation-wall-clock churn; status times come from the run ledger). Safe to repeat / in CI.
- Reuse the existing `DashboardProjection` + `GraphRenderer` render path unchanged.

## Out Of Scope

- Multi-machine / live team status, shared state plane, server, HTTP, DB, auth, websockets.
- Changing the `.ai-sdd/runs` gitignore policy or force-tracking ledgers — runs stay local; the HTML
  snapshot remains the shared artifact.
- New dashboard content (charts, bands, owners) — projection/render output is unchanged.
- `--plant --dashboard` (multi-repo) canonicalization.

## Acceptance

- `ai-sdd graph .ai-sdd --project --dashboard` with no `--out` writes the HTML to the canonical path and
  prints `✓ wrote <canonical>`; it does not dump HTML to stdout by default.
- `--out <path>` still writes there; the documented stdout escape hatch still works.
- After a run completes locally, the canonical snapshot reflects that run's final status without the
  operator hand-typing a `graph` command, and the regenerated file is part of the run's commit.
- Regeneration is idempotent: twice over identical run state → no diff.
- Existing modes unchanged: single graph, `--project`, `--plant`, `--html`, explicit `--out`.
- Pure functions (canonical-path resolution; the terminal-completion trigger decision) are unit-tested
  without I/O; `swift build` + `swift test` green; `ai-sdd validate .ai-sdd/features/dashboard-canonical-snapshot` passes.

## Constraints

Swift 6, Swift Testing (`@Test`/`#expect`/`#require`, exact typed errors), on-disk path names in
`Layout.swift`, no design-doc jargon in code comments, pure/testable functions, "engine is the only
code." Reuse the existing `graph --dashboard` render path; change output destination + invocation, not
rendering. The end-of-run trigger must compose with the per-slice commit flow and `ai-sdd-run` without
altering `next`/`submit` scheduling semantics.

## Decisions (proposed — confirm or change each before closing)

1. **Canonical path + override** — *proposed:* fixed default `.ai-sdd/dashboard.html`; **no** config
   override in v1 (YAGNI; add a factory-config key later if a real need appears).
2. **stdout escape hatch** — *proposed:* `--out -` writes to stdout (conventional); `--out <path>`
   overrides to that path; no `--out` → canonical file.
3. **End-of-run trigger mechanism** — *proposed:* **engine-side** — when `submit` advances a run to
   terminal `done`, the engine regenerates the canonical snapshot (deterministic, can't be skipped,
   "engine is the only code"). Alternative was a step in the `ai-sdd-run` skill (skippable). This is
   the main decision.
4. **Scope of auto-regen** — *proposed:* terminal-only (on run `done`), not on every intermediate
   `submit`, to avoid rewriting the snapshot on each slice.
5. **Stray-snapshot guard** — *proposed:* **out of scope** for v1 (a future `drift` kind could warn when
   dashboard `*.html` exists outside the canonical path).
6. **Adopter migration** — *proposed:* bootstrap/seed does **not** auto-delete an existing non-canonical
   snapshot; it emits a one-line note. No destructive cleanup.
