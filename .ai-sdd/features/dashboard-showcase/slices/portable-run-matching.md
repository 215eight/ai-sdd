# Slice: portable-run-matching

**Stack:** swift · **Depends on:** (none — source slice)

## Delivers
Machine-independent dashboard run-matching so committed fixtures (and CI on any clone) match their
runs regardless of absolute path.

In `Sources/AISDDEngine/DashboardProjection.swift`, change `matchedState` (and its `standardizedPath`
helper) so that when a stored `RunMeta.pipelineDir` is a RELATIVE path it is resolved against the run
store's base directory before standardizing/comparing to the queried pipeline dir:
- The run store base = the directory that contains the store root's `.ai-sdd/runs` (i.e. derivable from
  `RunStore.root` — read how `RunStore.local(under:)` composes `<base>/.ai-sdd/runs` and invert it; add
  a small accessor if needed, e.g. `RunStore.base`/`homeBase`, kept in the engine with path literals
  from `Layout.swift`).
- An ABSOLUTE stored `pipelineDir` keeps today's exact standardized-absolute-path comparison (existing
  local runs are absolute and on one machine) — fully backward compatible.
- A RELATIVE stored `pipelineDir` (e.g. `.ai-sdd/programs/<slug>`) is resolved to
  `<runStoreBase>/<relative>` then standardized and compared. This is what makes a committed fixture
  portable.

Keep it pure/testable. No change to how `ai-sdd start` WRITES runs (still absolute) — only matching
gains relative resolution.

## Acceptance
- Swift Testing unit tests (temp-dir RunStore + inline RunMeta) prove:
  - an absolute `pipelineDir` still matches exactly as today (regression guard);
  - a relative `pipelineDir` resolves against the run-store base and matches the corresponding
    absolute pipeline dir under that base;
  - a non-matching relative path does NOT match.
- Existing dashboard run-matching tests still pass unchanged.
- `swift build` + `swift test` green.
