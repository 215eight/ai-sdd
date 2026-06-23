# Slice: readme-showcase

**Stack:** swift · **Depends on:** fixture-integration-tests

## Delivers
A README showcase of the `graph` command's modalities, driven by the committed `demo-factory` fixture,
with a fixed regenerable example output.

- Add a concise "Visualizing the factory" (or similarly named) section to `README.md` demonstrating
  each modality with the FIXTURE-based commands so a reader can copy-paste and reproduce:
  - single graph (plain Mermaid) for a feature and for the program (+ `--html`);
  - whole-repo `ai-sdd graph docs/examples/demo-factory/.ai-sdd --project --dashboard --out <file>`
    (features + programs in one dashboard);
  - per-program `ai-sdd graph docs/examples/demo-factory/.ai-sdd/programs/<slug> --dashboard --out <file>`;
  - mention `--plant` for the multi-repo aggregate (point at `docs/examples/sdlc-plant`).
- Commit a regenerable example OUTPUT: at least one generated dashboard `.html` snapshot (and/or a PNG
  screenshot) under the fixture (e.g. `docs/examples/demo-factory/expected/…`), produced deterministically
  by `build-fixture.sh` + the graph command, and link/embed it from the README. State how to regenerate
  it (the script + the command).
- Honest self-contained wording (mirror QUICKSTART): the dashboard charts are inline SVG; the Mermaid
  graph renders via a CDN ESM import (parity across all tiers — not fully offline). New-model framing
  only; NO legacy ai-sdd references.
- Docs-only slice — no engine/CLI/test changes. (Editing the fixture's committed example output and the
  fixture README is allowed since they are the showcase artifact.)

## Acceptance
- `README.md` has the showcase section with the fixture-based commands for every modality, accurate and
  copy-pasteable.
- A committed, regenerable example output exists under the fixture and is referenced from the README;
  the regeneration path (`build-fixture.sh` + the documented graph command) is stated.
- Wording is honest about self-containment and uses new-model framing only.
- `swift build` + `swift test` + `swift run ai-sdd validate .ai-sdd` still green; the documented
  commands work as written.
