# Feature brief — Canonical, auto-refreshed dashboard snapshot

> Hand this to `ai-sdd-plan` as the brief. It is intentionally decision-rich so the planner does not
> have to invent scope. If anything here is ambiguous, STOP and ask before generating slices.

## Problem
The dashboard is a **per-machine snapshot of the local `.ai-sdd/runs` store** (runs are gitignored by
bootstrap; the README says so explicitly). The framework's transparency story therefore depends on a
**committed HTML snapshot** that one owner (or CI) regenerates and everyone reads. But today nothing
makes that snapshot canonical or fresh:

1. `ai-sdd graph … --dashboard --out <path>` takes a **free-form, optional `--out`** (`var out: String?`,
   `Sources/AISDDCLI/main.swift`). With no `--out` it prints to stdout; with one it writes to whatever
   filename the user types. Two people pick two names → **divergent, partial snapshots**. This has
   already happened in adopter repos (e.g. both `.ai-sdd/dashboard.html` and a repo-root
   `*-dashboard.html` exist side by side).
2. **Nothing regenerates the snapshot at the end of a run.** `grep dashboard` across all skills / hooks /
   scripts is empty; `next`/`submit` never touch it. So after a real local run the committed snapshot
   is stale until someone remembers the exact `graph --dashboard` incantation.

Net effect: the one artifact meant to give the team visibility is both **non-canonical** (any filename)
and **stale** (never auto-updated). This feature closes both halves.

## Goal
Make the committed dashboard snapshot a **single, framework-defined, auto-refreshed** artifact:
- exactly **one canonical path per factory**, not an arbitrary `--out` filename, and
- **regenerated automatically at the end of a run** so a local run leaves an accurate snapshot.

## In scope
- **Canonical dashboard path.** The factory has one dashboard location. Default **`.ai-sdd/dashboard.html`**.
  `ai-sdd graph .ai-sdd --project --dashboard` with **no `--out`** writes to that canonical path (today it
  prints to stdout). An optional factory-config key may override the path; absent config, the default holds.
- **`--out` becomes an explicit override**, not the only way to get a file. Ad-hoc/throwaway renders still
  work via `--out <path>`; piping to stdout stays available behind an explicit opt-in (`--out -` or `--stdout`).
- **Auto-regenerate at end of run.** When a run reaches a terminal state (its last node completes / the run
  is `done`), the canonical snapshot is regenerated from local run state and included in the run's commit,
  so `git`-visible status matches what actually ran. Applies to feature runs and program runs.
- **Idempotent + deterministic.** Re-running regeneration with unchanged run state produces a
  byte-identical file (no timestamps-of-generation churn in the committed output; status timestamps come
  from the run ledger, not wall-clock-at-render). Safe to run repeatedly / in CI.

## Out of scope (do NOT build)
- Multi-machine / live team status, any shared state plane, server, HTTP, DB, auth, websockets.
- Changing the `.ai-sdd/runs` gitignore policy or force-tracking run ledgers — runs stay local; the
  **HTML snapshot** remains the shared artifact.
- New dashboard *content* (charts, bands, owners) — this is about **where it's written and when**, not
  what it shows. `DashboardProjection` / `GraphRenderer` output is unchanged.
- `--plant --dashboard` (multi-repo) canonicalization.

## Acceptance (the bar — must all hold)
- `ai-sdd graph .ai-sdd --project --dashboard` **with no `--out`** writes the self-contained HTML to the
  canonical path and prints `✓ wrote <canonical>`; it does NOT dump HTML to stdout by default.
- An explicit `--out <path>` still writes there (override); the documented stdout escape hatch still works.
- After a run completes locally, the canonical snapshot on disk reflects that run's final status
  (the completed feature shows done) **without** the operator hand-typing a `graph` command — the run
  flow did it, and the regenerated file is part of the run's commit.
- Regeneration is idempotent: running it twice over identical run state yields no diff.
- Existing modes still work unchanged: single graph, `--project`, `--plant`, `--html`, and explicit `--out`.
- Pure functions (canonical-path resolution, the end-of-run trigger decision) are unit-tested without I/O;
  `swift build` + `swift test` green; `ai-sdd validate` passes on the new feature dir.

## Constraints (repo conventions)
Swift 6, Swift Testing (`@Test`/`#expect`/`#require`, assert exact typed errors), all on-disk path names
in `Layout.swift`, no design-doc jargon in code comments, pure/testable functions, "engine is the only
code." Reuse the existing `graph --dashboard` render path (`DashboardProjection` + `GraphRenderer`) — this
feature changes **output destination + invocation**, not rendering. The end-of-run hook must compose with
the existing per-slice commit flow and `ai-sdd-run` skill without breaking `next`/`submit` semantics.

## Decisions to confirm WITH the human before closing (do not assume)
1. **Canonical path + override:** default `.ai-sdd/dashboard.html`; is an override needed at all, and if so
   where does it live (a factory-config key vs a fixed path)? Prefer fixed default, optional config.
2. **stdout escape hatch:** `--out -` vs a `--stdout` flag vs "stdout only when `--dashboard` is combined
   with `--html`-less explicit request." Pick one.
3. **End-of-run trigger mechanism:** a step appended to the `ai-sdd-run` skill (agent-driven, simplest) vs
   an engine post-`submit`/commit hook (deterministic, can't be skipped). Trade-off: skippability vs
   "engine is the only code."
4. **Scope of auto-regen:** every `submit`, or only on terminal run completion? (Prefer terminal only, to
   avoid rewriting the snapshot on every intermediate slice.)
5. **Stray-snapshot guard (stretch):** should a deterministic check/`drift` kind warn when dashboard
   `*.html` files exist outside the canonical path (catching the divergence at its source)? In or out?
6. **Adopter migration:** for repos already carrying a non-canonical snapshot (e.g. a repo-root
   `*-dashboard.html`), does bootstrap/seed remove or leave it? (Likely a one-line note, not auto-delete.)
