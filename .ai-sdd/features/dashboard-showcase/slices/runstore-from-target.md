# Slice: runstore-from-target

**Stack:** swift · **Depends on:** portable-run-matching

## Delivers
The dashboard finds the run store relative to the TARGET dir, so a self-contained fixture resolves its
OWN runs — with the repo-root/cwd case byte-identical to today. No new CLI flag (derivation only).

- Add a pure resolver (engine, `Sources/AISDDEngine/`, path literals from `Layout.swift`) that, given a
  target dir, locates its `Layout.homeDir` (`.ai-sdd`) ANCESTOR and returns `<base>` = the directory
  just above that `.ai-sdd` (the value to pass to `RunStore.local(under:)`). Examples:
  - target `.ai-sdd` → base `.` (cwd)  → store `./.ai-sdd/runs`  (today's behavior)
  - target `.ai-sdd/programs/<slug>` → base `.` (cwd) → `./.ai-sdd/runs`  (today's behavior)
  - target `docs/examples/demo-factory/.ai-sdd[/programs/<slug>]` → base `docs/examples/demo-factory`
    → `docs/examples/demo-factory/.ai-sdd/runs`  (fixture's own runs)
  - target with NO `.ai-sdd` ancestor → fall back to cwd (preserve current behavior).
- In `Sources/AISDDCLI/main.swift` `Graph.dashboardDoc()`, build the run store for BOTH the project and
  program dashboard paths from this resolver applied to the target `dir`, instead of the cwd-rooted
  `runStore()` helper. Do NOT add a `--runs` flag. `status`/`next`/`submit` are unchanged.
- Together with portable-run-matching, this lets `ai-sdd graph docs/examples/demo-factory/.ai-sdd
  --project --dashboard` render the fixture's committed statuses.

## Acceptance
- Unit tests for the resolver: repo-root/cwd cases return the cwd base (today's behavior); a nested
  `docs/examples/demo-factory/.ai-sdd[/programs/x]` target returns the fixture base; a target without a
  `.ai-sdd` ancestor falls back to cwd.
- Regression: `ai-sdd graph .ai-sdd --project --dashboard` and `ai-sdd graph .ai-sdd/programs/guardrails
  --dashboard` still resolve the repo's `.ai-sdd/runs` and render unchanged (statuses identical to
  before).
- `swift build` + `swift test` green; existing CLI/dashboard behavior unchanged.
