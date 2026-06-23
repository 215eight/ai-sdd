# Slice: fixture-integration-tests

**Stack:** swift · **Depends on:** demo-fixture

## Delivers
Machine-independent end-to-end tests that exercise the real command surface against the committed
`docs/examples/demo-factory` fixture and assert on output — locking in the showcase behavior.

- Add Swift Testing tests in `Tests/AISDDEngineTests/` that, using the committed fixture (located via a
  repo-relative path resolved from the test's working directory — NO absolute machine paths), assert:
  - the fixture factory validates (engine validation entry point, or the assembler loads it cleanly);
  - the whole-repo `ProjectDashboardAssembler.assemble` over the fixture returns BOTH `Feature ·` and
    `Program ·` sections with the fixture's committed statuses (run resolved via the
    target-derived run store + relative pipelineDir matching);
  - `ProgramDashboardAssembler.assemble` over the fixture's program returns the master-graph section
    with the committed statuses;
  - single-graph Mermaid renders for a fixture feature and for the program;
  - charts are inline SVG and every dynamic value is HTML-escaped.
- Prefer driving via the engine/assembler APIs (deterministic, fast) and/or the built CLI; either way
  the test must resolve the fixture by a repo-relative path and be portable (pass in CI on a fresh
  clone). If a repo-root anchor is needed, derive it from `#filePath`/known relative offset — document
  the approach.
- Tests only — no engine/CLI/fixture changes. If a real defect surfaces, STOP and report it (it belongs
  in the relevant prior slice / a revert slice), do not fold a fix in here.

## Acceptance
- New integration tests pass via `swift test`, and are machine-independent (no absolute paths; would
  pass on a fresh clone / CI).
- They assert the combined whole-repo sections, the per-program section, single-graph Mermaid, inline
  SVG charts, and escaping — all against the committed fixture's statuses.
- `swift build` + `swift test` green; existing tests unaffected.
