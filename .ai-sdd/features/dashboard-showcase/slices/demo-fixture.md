# Slice: demo-fixture

**Stack:** swift · **Depends on:** project-dashboard-programs, runstore-from-target

## Delivers
A committed, portable demo factory under `docs/examples/demo-factory/` that regenerates the dashboards
byte-stably on any clone and serves as the integration-test fixture.

- `docs/examples/demo-factory/.ai-sdd/` — a small but VALID factory (passes `ai-sdd validate`):
  the build pattern (`pipeline.yaml` + `workers/` + `checks/` + any `schemas/`/`skills/` needed),
  a couple of features under `features/*` (each with `pipeline.yaml` + `slices/*.md`), and one program
  under `programs/<slug>/` wiring those features through a `milestone-gate` node + sequencing edges
  (mirror the real `guardrails` shape but minimal). Keep it self-contained — reuse/copy only what's
  needed from the repo's build pattern so it validates standalone.
- Committed PORTABLE run state under `docs/examples/demo-factory/.ai-sdd/runs/<runId>/`
  (`run.json` + `events/*.json`) whose `RunMeta.pipelineDir` is RELATIVE to the fixture base (e.g.
  `.ai-sdd/programs/<slug>` and/or `.ai-sdd/features/<feat>`), seeded to a realistic status MIX (some
  features done, one in-progress, the milestone passed or pending) so the dashboards show a meaningful
  picture. (`.gitignore` is anchored to the repo-root `.ai-sdd`, so this nested runs dir commits
  without force-add — verify with `git check-ignore`.)
- `docs/examples/demo-factory/build-fixture.sh` — a committed, deterministic shell script that
  regenerates the run state from the fixture reproducibly (drive `ai-sdd start`/`next`/`submit`, or
  synthesize the event log deterministically), writing PORTABLE relative `pipelineDir`. Document how to
  run it in a short `docs/examples/demo-factory/README.md`.
- This slice does NOT change engine/CLI code (those shipped in prior slices); it only adds fixture
  files + the script. Keep it OUT of `Sources/`/`Tests/` scope.

## Acceptance
- `ai-sdd validate docs/examples/demo-factory/.ai-sdd` passes.
- `ai-sdd graph docs/examples/demo-factory/.ai-sdd --project --dashboard --out /tmp/demo.html` exits 0
  and renders the fixture's `Feature ·` sections AND a `Program ·` section with the committed statuses
  (resolved via the fixture's own runs — derivation + relative matching from the prior slices).
- `ai-sdd graph docs/examples/demo-factory/.ai-sdd/programs/<slug> --dashboard` renders the program
  master graph with the committed statuses.
- The run state is portable: `run.json` contains a RELATIVE `pipelineDir` (no absolute machine path);
  re-running `build-fixture.sh` reproduces equivalent run state.
- `git check-ignore` confirms the fixture's runs dir is committable (not ignored).
- `swift build` + `swift test` still green (no source changes here).
