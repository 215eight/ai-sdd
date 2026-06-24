# Feature brief — Run integrity + the dashboard as a management instrument

> Hand this to `ai-sdd-plan` as the brief. It is intentionally decision-rich so the planner does not
> have to invent scope. If anything here is ambiguous, STOP and ask before generating slices.
>
> **This brief spans two themes joined by one shared slice:**
> - **Part A — Run integrity:** engine self-heals, skill enforces, git tripwires (the ledger stops
>   lying about *what is done*).
> - **Part B — Dashboard as a management instrument:** the dashboard answers an EM/CTO's real
>   questions (trajectory, triage, critical path, trust), not just "what is the graph shape".
> - **Shared keystone:** *timestamped run events* — Part A's ledger gains a time axis, which Part B's
>   temporal metrics depend on.
>
> **Planner note — drive this through `ai-sdd-plan-program`, not `ai-sdd-plan`.** This is a
> **2-feature program** (program slug suggestion: `run-integrity-and-dashboard`):
> - **Sub-feature 1 — `run-integrity`** (Part A): name resolver, repo-relative `pipelineDir`,
>   stale-run surfacing, skill rewrite, pre-commit tripwire, **and the timestamped-events keystone**
>   (events are Part A's ledger, so the time axis is owned here).
> - **Sub-feature 2 — `dashboard-instrument`** (Part B): the four-band dashboard.
>
> **Milestone wiring between them:** `dashboard-instrument`'s **temporal band** depends on
> `run-integrity`'s timestamped-events slice (a milestone gate). `dashboard-instrument`'s
> **no-new-data band** (verdict/attention/portfolio/critical-path) has NO such dependency and runs in
> parallel with the rest of Part A. Plan each sub-feature with `ai-sdd-plan` after the program graph
> is approved.

## Problem

The dashboard quietly diverges from reality whenever the user's real workflow deviates from "stay
in one workspace, call `next` and `submit` for every slice". Two failure modes seen on
`llm-self-model-capstone`:

- **Bypass:** the agent skill `/ai-sdd-run <feature>` is the only entry point most users touch, but
  it leaves "start the run if missing" to the agent's judgment. Agents (codex, claude) plan, branch,
  implement, PR, merge — and never call `start`/`submit`. The journal stays empty; the dashboard
  reports 0/N done for features that are fully merged on main (parts-catalog-grammar,
  ros2-align-to-tag).
- **Worktree drift:** `run.json` records `pipelineDir` as an absolute path captured at `start` time.
  Starting a run in a worktree then continuing on `main` leaves the run pointer aimed at a path that
  doesn't exist; the project dashboard's path-equality match silently drops the run state and
  re-renders the feature as all-pending (adapter-interfaces, whose events log clearly shows
  `nodeCompleted`).

Root cause is one disease in both cases: **the engine assumes the user is disciplined and reports
its assumptions as if they were measurements.** The fix is a posture shift — engine self-heals,
skill verifies against the engine, git surfaces drift it can't reconcile.

## Goal

Make `/ai-sdd-run <name>` the only command the user needs to remember. From that one verb, the
framework starts the run if missing, drives next→work→submit, verifies "done" by reading the engine,
and refuses to let a slice land in git without a recorded submit. Every drift case is either
auto-reconciled or surfaced loudly — never silently dropped.

## In scope

### Engine — `ai-sdd next` self-starts and resolves names

- `ai-sdd next <name> --json` works whether or not a run exists for `<name>`. Resolution order:
  1. `<name>` matches an existing `runId` → use that run.
  2. `<name>` matches a feature dir under `.ai-sdd/features/<name>/` → start a run with
     `runId=<name>`, then advance.
  3. `<name>` matches a slice name appearing in exactly one feature's `pipeline.yaml` slice list →
     start a run for that feature with `runId=<feature>`, then advance.
  4. `<name>` matches a slice in multiple features → fail with a disambiguation error listing the
     candidates (`{ "error": "ambiguous", "candidates": [ ... ] }` in `--json`).
  5. No match → fail with a clear "no such feature or slice" error.
- `ai-sdd start <name>` remains as an explicit verb (no-op alias when a matching run already
  exists; same name resolver as `next`).
- The slice→feature resolver lives in the engine, not the CLI shim — `ai-sdd submit`, `ai-sdd
  status`, and the skill all use it.

### Engine — `run.json` stores `pipelineDir` as repo-relative

- On `start`, write `pipelineDir` as a path relative to `git rev-parse --show-toplevel`
  (e.g. `.ai-sdd/features/adapter-interfaces`).
- On read, resolve against the current `git rev-parse --show-toplevel`. A worktree and its parent
  share the same logical tree shape, so a run started in one resolves cleanly in the other.
- **Legacy migration on read:** if the recorded `pipelineDir` is absolute and doesn't resolve, strip
  the prefix up to `.ai-sdd/` and resolve as relative against the current git root. If that
  resolves, treat as healed and rewrite on the next `start`/`submit`/`next` (no new file mtime
  unless an actual mutation happens).
- The engine accepts either absolute or relative `pipelineDir` and round-trips cleanly through
  read → mutate → write.

### Engine — surface unreconciled runs (no silent drops)

- `ai-sdd status <name>` prints a `⚠ stale pipelineDir` line when the recorded path doesn't resolve
  and migration didn't heal it. The line includes the recorded path and the expected feature dir.
- `ai-sdd graph --project --dashboard` renders a `⚠ stale run` badge on any feature whose `runs/`
  entry exists but cannot be matched to its `features/<name>/` dir. The badge shows the recorded
  path so the user can hand-edit if needed. The feature is rendered with its run state attached
  best-effort (using the slice events directly) instead of being dropped to all-pending.
- The same badge appears in `ProgramDashboardAssembler` output for symmetry.

### Skill — `/ai-sdd-run` becomes the imperative loop, status-driven

- Every invocation begins with `ai-sdd status <name> --json`. The skill never assumes the run
  exists; the engine self-starts on the first `next` call (above).
- The loop is strictly: `next` → dispatch sub-agent → `submit` → re-read `status`. The skill
  declares "done" only when `status` returns `{"status":"done"}`. Likewise for `{"status":"idle"}`,
  it stops and reports exactly what the engine said it's waiting on.
- The skill never tracks slice progress in its own head — the engine's ledger is the single source
  of truth. (This kills the "agent thought it finished but the journal disagrees" class of bug.)
- Ambiguity errors from name resolution are surfaced verbatim to the user with the candidate list.
- The `/ai-sdd-run` SKILL.md is rewritten to reflect the new contract: no "if no run yet" caveats,
  no manual `start` step, no separate slice-name handling.

### Bootstrap — pre-commit tripwire for the bypass case

- `ai-sdd-bootstrap` installs (idempotently) a pre-commit hook that inspects the commit message.
- If the subject line matches `[<feature>] <slice>:`, the hook checks for a corresponding
  `nodeCompleted` event for `<slice>` in `.ai-sdd/runs/<feature>/events/`.
- No match → the hook refuses the commit with a single-line, copy-pasteable error:
  `slice "<slice>" of feature "<feature>" was not submitted — run \`ai-sdd submit <feature>\` first`
  (the engine submit will auto-start via the resolver if needed).
- `git commit --no-verify` still works as the explicit escape hatch. The hook is loud about being
  bypassed (one-line warning to stderr on `--no-verify`) so it shows up in logs.
- The hook is shell, not Swift — must run cleanly on a stock macOS/Linux git install with no extra
  deps. It calls `ai-sdd` via `$PATH`; if `ai-sdd` is missing, the hook prints a clear "install
  ai-sdd or use --no-verify" message and exits non-zero.
- Bootstrap-time install respects an existing `pre-commit` hook by chaining to it (rename existing
  → `.pre-commit.local`, new hook runs the integrity check then delegates).

### Engine — timestamp every run event (the shared keystone)

- Every event appended to `.ai-sdd/runs/<feature>/events/` carries a wall-clock `at` timestamp,
  stamped at append time. Applies to `nodeStarted`, `nodeCompleted`, rework, and escalation events.
- **Timezone — store UTC, render local.** `at` is written as RFC 3339 / ISO-8601 **normalized to
  UTC with a `Z` suffix** (e.g. `2026-06-24T19:30:00Z`). This makes events stamped on different
  machines or in different timezones totally ordered and directly comparable — no ambiguity, no
  per-machine offset to reconcile. Human-facing rendering converts to the viewer's local zone at
  display time (against the injected `now`); the stored value is always UTC.

### Engine — derive a slice owner from git identity (interim)

- Capture an `owner` on each slice from **git identity** — `git config user.name` (display) +
  `user.email` (stable key) of whoever drives the slice — recorded into the event at `nodeStarted`
  / `submit` time. When reconciling a merged-but-not-submitted slice, fall back to the slice
  commit's author.
- This is an **interim** source. The intended end state is work assigned ahead of time (an explicit
  owner four-tag / planning-time assignment); that flow is **deferred** and explicitly out of scope
  here. For now git identity is the single source so the dashboard's people view is non-empty.
- When no git identity is resolvable, the slice renders `unowned` (honest gap, not a guess).
- The event log stays **append-only and replayable**: given a timestamped log you can reconstruct
  cumulative state at any past instant (this is what unlocks burndown and the "what changed since
  T-7d" diff — see Part B). Keep the format flat enough that a point-in-time replay is cheap.
- **Determinism boundary:** timestamps are recorded in the journal (an observed fact), but no gate,
  schema check, or pure renderer may read wall-clock time. Anything that needs "now" (relative ages,
  velocity windows, the freshness badge) takes an **injected** generation-timestamp parameter so the
  functions stay reproducible and unit-testable without I/O.
- **Backward compatibility:** existing un-timestamped events remain valid. A run whose events
  predate this change has `at` absent; every temporal metric degrades to `—` for that run rather
  than guessing or zeroing.

### Dashboard — verdict & attention bands (Part B, no new data)

Restructure `ai-sdd graph --project --dashboard` from a flat scroll of equal-weight feature blocks
into an **inverted pyramid** (verdict → attention → portfolio → detail). **The project surfaces
first; features are progressive disclosure.** The landing view is the whole-project rollup — a
reader sees project health before any single feature's internals, then drills into a feature on
demand. This band needs only the DAG + status the engine already has — no timestamps:

- **Verdict band (top):** one project-level trajectory line (`on track` / `slipping` / `stalled`,
  derived from blockers + escalations + — once available — velocity, NOT the raw % done), the
  generation timestamp, and the **freshness/trust badge** (reuse the Part A `⚠ stale run` signal —
  do NOT build a second trust mechanism).
- **Attention band:** the 3–6 items that need a human — escalations, rework loops, and the runnable
  slices that unblock the most downstream work. Renders **nothing** when there is nothing to act on.
- **Portfolio band:** one **health row per feature** (status + slice-count % + owner + current
  blocker), each expanding into the per-feature detail band below.
- **Detail band — graph paired with feature definition.** A feature's dependency graph is the
  execution driver, but on its own it lacks context. Pair each feature's graph with its **definition
  pulled from the master requirements** (the feature's requirement summary / acceptance) so a reader
  — or a coding agent — has the "why" next to the "what depends on what".
- **Slice identifiers on every node.** Each graph node must display the **slice identifier** the
  coding agent references (e.g. `s1-protocols-and-exports`), not just a prettified label. Today the
  agent names a slice but the graph doesn't carry that id visibly — close that gap so the graph and
  the agent's vocabulary line up exactly.
- **Critical-path highlighting:** compute the longest dependency chain per feature and mark it;
  rank "runnable now" by downstream-unblock count instead of treating all runnable nodes as equal.
- **Honest gaps:** when `owner` is absent, render an explicit "unowned" marker rather than implying
  coverage. Headline count is labelled **slices** (not effort).

### Dashboard — temporal metrics (Part B, depends on the timestamp slice)

Once events carry `at`, add the time axis. Every metric here self-suppresses (renders `—` / hides)
when a run lacks enough timestamped history — no false precision:

- **Per-slice cycle time** (`completed − started`) and **WIP aging** (`now − started` for in-progress
  slices; flag slices in-progress beyond a threshold).
- **Throughput / velocity** (completions per day/week over a trailing window) feeding the verdict
  band's trajectory.
- **ETA as a band, not a date** — `remaining ÷ recent velocity`, shown as a range with a confidence
  note; suppressed entirely when history is too thin.
- **Burndown** (cumulative done over time, reconstructed by replaying the timestamped log).
- **"What changed since T-7d"** — replay the log to a prior instant and diff: what completed, what
  newly blocked, what newly escalated.

## Out of scope (do NOT build)

- A composite `ai-sdd work` verb. `next`/`submit` stay as the only engine verbs; composition lives
  in the skill. (Rejected: muddies the mental model; the skill is the right place for choreography.)
- Identifying runs purely by `runId` and dropping `pipelineDir` entirely. (Rejected as too
  aggressive for this slice; `pipelineDir` becoming repo-relative + the stale-run badge cover the
  observed failure modes.)
- Self-healing `pipelineDir` by silently rebasing whenever a feature dir matches the `runId`.
  Migration of legacy absolute paths is in scope; ongoing auto-rebase by name is not.
- Cross-checking `git log` for `[feature] slice:` patterns from the dashboard side. The pre-commit
  hook prevents the divergence at the source; the dashboard does not need to retroactively
  reconcile.
- Multi-machine / shared state plane (ADR-0025 territory).
- Auto-resuming or rolling back in-progress runs found in stale state.
- Changing the `ai-sdd-plan` skill or the planning flow.
- **Effort / story-point weighting of progress.** No data source exists; progress stays a slice
  count, honestly labelled.
- **A false-precision ETA date.** ETA is a confidence-banded range or it is suppressed — never a
  single committed date.
- **Any wall-clock read inside a gate, schema check, or pure renderer.** "Now" is always injected.
- **Server / auto-refresh / live multi-machine status.** The dashboard stays a self-contained static
  file (carried over from the original dashboard brief).
- **Backfilling timestamps onto historical events.** Old events stay un-timestamped; metrics degrade
  gracefully instead.
- **Assign-work-ahead / planning-time owner assignment.** Deferred. Owner is derived from git
  identity for now; the explicit-assignment flow is a future feature.

## Acceptance (the bar — must all hold)

- `ai-sdd next <feature> --json` on a feature with no run starts the run and returns the first
  worker instruction. `ai-sdd next <slice>` on a slice name in exactly one feature does the same.
  Ambiguous slice name → structured `{"error":"ambiguous","candidates":[...]}` exit non-zero.
  Unknown name → structured `{"error":"unknown"}` exit non-zero. All branches unit-tested.
- A fresh `ai-sdd start <feature>` writes `pipelineDir` as a path relative to the git toplevel.
  Reading the same `run.json` from a different cwd inside the same repo (including from a sibling
  worktree) resolves the run correctly.
- A `run.json` with a legacy absolute `pipelineDir` whose path no longer exists, but whose
  trailing `.ai-sdd/features/<name>/` resolves under the current git root, is auto-healed on next
  read and rewritten relative on the next mutation. Round-trip is idempotent.
- `ai-sdd status <name>` and `ai-sdd graph --project --dashboard` BOTH emit a `⚠ stale run`
  indicator when reconciliation fails. The dashboard never silently renders an existing-but-orphaned
  run as all-pending.
- The `/ai-sdd-run` SKILL.md drives the run via `status` → `next` → sub-agent → `submit` →
  re-`status`, declaring "done" only when the engine says so. The skill no longer mentions a manual
  `start` step or contains "if no run yet" caveats.
- A repo bootstrapped via `ai-sdd-bootstrap` has the pre-commit hook installed. Committing with
  `[<feature>] <slice>: msg` when no `nodeCompleted` event exists fails with the specified error.
  Committing the same message after `ai-sdd submit` succeeds. `--no-verify` bypasses with a stderr
  warning. Existing `pre-commit` hooks are chained, not overwritten.
- Re-running `ai-sdd-bootstrap` on an already-bootstrapped repo is idempotent (hook is not
  duplicated; chained-local hook is preserved).
- Regenerating the dashboard for `llm-self-model-capstone` after the migration heals
  `adapter-interfaces` (its run.json's legacy absolute path → relative; events get credited; the
  feature renders 1/1 done). The fixture for this scenario is captured as a test.
- New events written after this change carry an ISO-8601 `at` timestamp; old events without one load
  without error and every temporal metric renders `—` for their run. Round-trip is unit-tested.
- The project dashboard renders the four bands (verdict, attention, portfolio, detail). The
  attention band is **empty when nothing needs action** and lists escalations / rework / top
  unblockers when they exist. Critical path is marked per feature; runnable nodes are ranked by
  downstream-unblock count. All exercised by fixtures with no I/O.
- Temporal metrics (cycle time, WIP age, velocity, burndown, ETA band, "what changed since T-7d")
  render from a **fixed injected `now`** so output is deterministic; a thin-history fixture shows
  them self-suppressing rather than emitting false precision.
- An `unowned` slice renders an explicit marker; the headline progress is labelled as a slice count.
- `at` timestamps are stored UTC (`Z`-suffixed RFC 3339); a fixture with events stamped in two
  different source zones orders them correctly, and rendering localizes against the injected `now`.
- Slice owner is populated from git identity (name + email); a no-git-identity fixture renders
  `unowned`. (The assign-ahead flow is explicitly NOT built.)
- The project rollup renders **before** any per-feature detail (project-first / progressive
  disclosure). Each per-feature detail pairs the dependency graph with the feature's
  master-requirements definition, and **every graph node shows its slice identifier**. Verified by a
  fixture that asserts the slice id text appears on nodes.
- `swift build` + `swift test` green; `ai-sdd validate` passes for both resulting feature dirs
  (e.g. `.ai-sdd/features/run-integrity` and `.ai-sdd/features/dashboard-instrument`).

## Decisions log (so the planner doesn't relitigate)

- **Drop the `work` verb (option 1.d).** `next`/`submit` stay as the only engine verbs. The skill
  composes them.
- **Repo-relative `pipelineDir` over runId-as-identity (option 2.b over 2.a).** Less aggressive, in
  line with the existing model, fixes the observed worktree case.
- **No silent self-heal on path mismatch (option 2.c).** Legacy absolute-path migration is the only
  auto-rewrite. Anything else surfaces a `⚠ stale run` badge so the user sees it.
- **Pre-commit tripwire is in scope (option 1.c).** It's the only mechanism that catches the case
  where the user invokes an agent outside the skill entirely.
- **Engine handles slice→feature resolution, not the skill.** A single resolver shared by `next`,
  `submit`, `status`, and the skill — so the same name lookup logic applies everywhere.
- **Timestamped events are the shared keystone, owned by Part A.** They land once, in the engine;
  Part B's temporal band depends on them. Part B's no-new-data band does not.
- **Inverted-pyramid layout (verdict → attention → portfolio → detail).** The existing flat
  per-feature blocks become the detail band; the verdict/attention/portfolio bands are added above.
- **Trajectory verdict is derived, not the raw %.** Blockers + escalations + velocity, because
  slice-% answers no management question on its own.
- **One trust signal, reused.** The Part A `⚠ stale run` badge IS the dashboard's freshness signal —
  not a second mechanism.
- **Determinism via injected `now`.** No temporal function reads the wall clock; tests pin the
  generation timestamp.
- **Graceful degradation over guessing.** Missing owner → "unowned"; missing timestamps → `—`;
  thin history → ETA/velocity suppressed.
- **2-feature program, driven by `ai-sdd-plan-program`.** `run-integrity` (owns the timestamped
  events) + `dashboard-instrument`, wired by a milestone gate on the timestamp slice.
- **UTC storage, local rendering for timestamps.** Removes timezone ambiguity across machines; the
  stored value is canonical, the displayed value is localized.
- **Owner from git identity (interim).** Name + email of the slice driver, commit-author fallback.
  The assign-ahead flow is deferred, not designed here.
- **Project-first, progressive disclosure.** The whole-project rollup is the landing; features drill
  down. Each feature's graph is paired with its master-requirements definition and carries the slice
  identifiers agents speak in.

## Constraints (repo conventions)

Swift 6, Swift Testing (`@Test`/`#expect`/`#require`, assert exact typed errors), all on-disk paths
via `URL`. Engine-side changes land in `Sources/AISDDEngine/` with thin CLI shims in
`Sources/AISDDCLI/`. Pure renderer / resolver functions are unit-tested without I/O (the
name-resolver, the `pipelineDir` migration helper, the stale-run badge serialization). Skill rewrite
is in `skills/ai-sdd-run/SKILL.md`; bootstrap hook install lives in the `ai-sdd-bootstrap` skill.
Schema changes (if any to `run.json`) must round-trip through existing fixtures. No new runtime
deps; the pre-commit hook is POSIX shell.
