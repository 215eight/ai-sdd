# Slice: Dashboard CLI Integration

Wire the dashboard renderer into `ai-sdd graph`.

## Brief

Add `--dashboard` to the `Graph` command. For the first version, dashboard mode is project-scoped:
`ai-sdd graph .ai-sdd --project --dashboard --out <file>`. The command loads the build pattern,
discovers features, scans local runs, matches runs by `RunMeta.pipelineDir`, and writes dashboard
HTML to `--out` or stdout.

## Acceptance

- `Graph` exposes a `--dashboard` flag.
- `ai-sdd graph .ai-sdd --project --dashboard --out <file>` writes the dashboard HTML.
- Dashboard mode requires `--project`; unsupported combinations such as `--plant --dashboard` fail
  with clear errors.
- The command handles no features and no local runs gracefully.
- Matching by `RunMeta.pipelineDir` works when run ids do not equal feature slugs.
- Existing graph modes remain unchanged.
- Tests cover CLI-adjacent assembly behavior where practical, with pure loading/projection logic
  covered in engine tests.

## Stack

swift

## Depends On

- dashboard-html-renderer
