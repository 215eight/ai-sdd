# Feature: run-integrity (Part A of run-integrity-and-dashboard)

> **APPROVED 2026-06-24 — decisions closed; slices emitted.** Planning gate (Step 2) cleared.

## Source brief

`run-integrity-brief.md` (repo root), **Part A** scope. Part B (dashboard rendering) is the separate
`dashboard-instrument` feature and is out of scope here.

## Goal

Make the run ledger self-healing and enforced, and give it a time axis. After this feature: the engine
self-starts and resolves names so `/ai-sdd-run <name>` always lands in a valid run; `pipelineDir` is
stored repo-relative and legacy absolute paths auto-migrate so worktree-then-main runs aren't lost;
runs that still can't be reconciled are surfaced loudly (never silently dropped); the `/ai-sdd-run`
skill verifies "done" against the engine; a pre-commit tripwire refuses a slice commit with no
recorded submit; and every run event carries a UTC `at` timestamp plus a git-derived owner.

## In scope

- **Name resolver + self-start.** `next`/`submit`/`status` accept a feature slug, an existing runId,
  or a slice name; resolve slice→feature via `pipeline.yaml` slice lists; self-start a run when none
  exists. Ambiguous slice → `{"error":"ambiguous","candidates":[…]}`; unknown → `{"error":"unknown"}`;
  both exit non-zero. One resolver shared by all three verbs.
- **Repo-relative `pipelineDir` + legacy migration.** `start` writes `pipelineDir` relative to
  `git rev-parse --show-toplevel`; reads resolve against the current toplevel; a legacy absolute path
  that no longer resolves is healed by stripping to the trailing `.ai-sdd/…` and re-resolving, then
  rewritten relative on the next mutation. Round-trips idempotently.
- **Stale-run surfacing.** When reconciliation fails, `ai-sdd status` prints a `⚠ stale pipelineDir`
  line (recorded + expected path), and both `ProjectDashboardAssembler` and `ProgramDashboardAssembler`
  attach the run best-effort with a `⚠ stale run` marker rather than dropping it to all-pending.
- **`/ai-sdd-run` skill rewrite.** `skills/ai-sdd-run/SKILL.md` becomes the status-driven loop
  (`status` → `next` → sub-agent → `submit` → re-`status`), declaring done only when the engine says
  so; no manual `start`, no "if no run yet" caveats, no separate slice-name handling.
- **Pre-commit tripwire.** `ai-sdd-bootstrap` idempotently installs a POSIX-shell pre-commit hook:
  a `[<feature>] <slice>:` subject with no matching `nodeCompleted` event refuses the commit with a
  copy-pasteable error; `--no-verify` bypasses with a stderr warning; an existing hook is chained.
- **Timestamped events (keystone).** Every appended event carries a `Z`-suffixed UTC `at` (RFC 3339)
  stamped at append time; the log stays append-only/replayable; legacy un-timestamped events load
  without error and degrade (`at` absent) rather than breaking; no gate/check/pure function reads the
  wall clock — "now" is injected.
- **Owner-from-git capture.** Each slice's `owner` (git `user.name` + `user.email`, commit-author
  fallback) is recorded into the event at start/submit; no git identity → `unowned`.

## Out of scope

- All Part B dashboard *rendering* (four bands, charts, temporal metrics, graph-with-definition,
  slice-id-on-nodes). Only the stale-run *marker* in the assemblers is in scope here.
- Backfilling `at` onto historical events; assign-work-ahead owner flow; `runId`-as-identity;
  a composite `work` verb; git-log cross-check from the dashboard; multi-machine state.

## Acceptance

- `next <feature>` with no run self-starts + returns the first instruction; `next <slice>` (unique)
  same; ambiguous → structured `ambiguous` non-zero; unknown → structured `unknown` non-zero. Unit-tested.
- `start` writes a git-relative `pipelineDir`; reading from another cwd / sibling worktree resolves it.
- A legacy absolute `pipelineDir` whose path is gone but whose trailing `.ai-sdd/features/<name>/`
  resolves is healed on read and rewritten relative on next mutation; round-trip idempotent.
- `status` and both dashboard assemblers emit a `⚠ stale run` indicator when reconciliation fails;
  no existing-but-orphaned run renders as all-pending.
- `SKILL.md` drives `status→next→submit→re-status`, done only when the engine says so; no `start`
  step / "if no run yet" text remains.
- Bootstrapped repo has the hook; `[f] s:` commit without a `nodeCompleted` fails with the error;
  after `submit` it succeeds; `--no-verify` bypasses with a warning; existing hook chained;
  re-bootstrap idempotent.
- New events carry UTC `at`; legacy events load and degrade; a two-source-zone fixture orders correctly.
- Slice owner populated from git identity; no-git-identity fixture → `unowned`.
- `swift build` + `swift test` green; `ai-sdd validate .ai-sdd/features/run-integrity` passes.

## Constraints

- Swift 6; `.ai-sdd/conventions/swift.md`. Engine in `AISDDEngine` (`RunStore`/`RunState`,
  `DashboardProjection`), CLI shims in `AISDDCLI`; tests in `Tests/AISDDEngineTests` (Swift Testing,
  exact typed errors). Paths via `URL`, constants in `Layout.swift`. Pure resolver/migration/marker
  functions unit-tested without I/O; "now" injected. Reuse the shipped substrate — no second loader.

## Proposed slice decomposition (for approval)

Six thin slices; 1/2/3 are independent (parallel), 4 follows 2, 5 & 6 follow 3:

- **S1 `event-timestamps-and-owner`** — the keystone. UTC `at` on every event + owner-from-git capture;
  inject `now`; legacy degradation. (no deps)
- **S2 `pipelinedir-relative-and-migration`** — repo-relative write + read-resolve + legacy heal in
  `RunStore`. (no deps)
- **S3 `name-resolver-self-start`** — shared slice→feature resolver + self-start in `next`/`submit`/
  `status` + ambiguity/unknown errors. (no deps)
- **S4 `stale-run-surfacing`** — `⚠ stale run` in `status` + both dashboard assemblers, best-effort
  attach. (deps: S2)
- **S5 `run-skill-rewrite`** — status-driven `skills/ai-sdd-run/SKILL.md`. (deps: S3)
- **S6 `precommit-tripwire`** — bootstrap-installed POSIX hook + chaining + idempotence. (deps: S3)

## Decisions (closed 2026-06-24)

- **D1 — six-slice decomposition above**, with S1/S2/S3 parallel. Status: `closed`.
- **D2 — S1 fuses timestamps + owner-from-git** (both are event-ledger enrichment, one cohesive
  plan→implement→review). Status: `closed`.
- **D3 — S4 depends on S2** (stale-surfacing is the complement of migration — it flags what migration
  can't heal; both live around `matchedState`). Status: `closed`.
- **D4 — scope-gate caveat for S5/S6 (flagged, not resolved here).** Per the repo's known limitation,
  the factory's file manifest can't declare `.claude/` or `scripts/`; `skills/ai-sdd-run/SKILL.md`
  (S5) is declarable, but skill *surfacing* (symlinks) runs post-gate and the hook *install* happens
  at bootstrap runtime (not a committed file). S5/S6 may need a manual surface/install step after the
  gated slice. Status: `closed` (flagging the constraint; no scope change).
