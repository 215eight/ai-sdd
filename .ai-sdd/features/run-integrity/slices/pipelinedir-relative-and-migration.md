# Slice: pipelinedir-relative-and-migration (S2)

## Delivers
Make a run's `pipelineDir` survive worktrees and repo moves. `start` writes `pipelineDir` as a path
relative to `git rev-parse --show-toplevel` (e.g. `.ai-sdd/features/adapter-interfaces`); reads
resolve it against the *current* git toplevel. A legacy absolute `pipelineDir` that no longer resolves
is auto-healed on read — strip the prefix up to the trailing `.ai-sdd/…`, re-resolve against the
current toplevel, and if it resolves, treat as migrated and rewrite relative on the next mutation
(no new file mtime unless an actual mutation happens). The store accepts either absolute or relative
forms and round-trips cleanly.

## Why
The observed worktree-drift bug: a run started in a sibling worktree records an absolute path that dies
when the worktree is torn down, so the run is silently lost. Repo-relative storage + legacy migration
fixes it without the more aggressive runId-as-identity change.

## Acceptance
- A fresh `start` writes a git-relative `pipelineDir`; reading the same `run.json` from a different cwd
  inside the repo (including a sibling worktree) resolves the run correctly.
- A `run.json` with a legacy absolute `pipelineDir` whose path is gone, but whose trailing
  `.ai-sdd/features/<name>/` resolves under the current toplevel, is healed on read and rewritten
  relative on the next mutation; the round-trip is idempotent (re-reading a healed file is a no-op).
- A legacy absolute path that resolves nowhere is left untouched for S4 to surface (this slice heals
  what it can; it does not invent a match).
- `swift build` + `swift test` green.

## Notes
Lives in `RunStore` (read/write) + `Layout.swift` path handling. Pure path-migration helper is
unit-tested without I/O. Pairs with S4 (stale-run-surfacing), which flags what this slice can't heal.
