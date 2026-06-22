# Slice: diff-source

## Delivers

A deterministic way to list the factory artifact files that changed under `.ai-sdd/` between the git
working tree and a baseline ref. This is the input the classifier consumes — kept separate so the
classifier can be tested with synthetic change-lists, no git required.

- A new engine type in `Sources/AISDDEngine` (e.g. `ArtifactChange` + a `changedArtifacts(...)` function)
  that returns the changed paths with a status: **added / modified / deleted**.
- Shell out to git via `Process`: `git diff --name-status <baseline> -- .ai-sdd/`. Baseline defaults to
  `HEAD`; accept an override ref (the `--since` value the CLI passes later).
- Scope strictly to `.ai-sdd/` and **exclude runtime paths** that are gitignored by the factory
  (`.ai-sdd/runs/`, `.ai-sdd/artifacts/`) so they never appear as changes.
- Return paths relative to the repo root, normalized, with their change status.
- Shell execution must be injectable (a function/closure that runs the command) so tests can feed canned
  `git diff --name-status` output without a real repo — follow the repo's "injectable shell execution"
  convention.

## Acceptance

- Given canned `--name-status` output, returns the expected `(path, status)` set for added/modified/deleted.
- Paths under `.ai-sdd/runs/` and `.ai-sdd/artifacts/` are excluded from the result.
- A non-`.ai-sdd/` change is not returned.
- An override baseline ref is threaded into the git invocation.
- No file is written or staged (read-only).
- `swift build` + `swift test` green.

## Stack

swift — `Sources/AISDDEngine`, tests in `Tests/AISDDEngineTests` (Swift Testing). Keep any path constants
in `Layout.swift` (naming/layering convention).

## depends_on

(none — first slice)
