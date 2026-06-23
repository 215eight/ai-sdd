# Feature brief: dashboard-showcase

## Problem / the gap
After shipping the program-tier dashboard, ai-sdd has four `graph` modalities but no single
"whole-repo" view and no reproducible example to showcase them:
- `ai-sdd graph .ai-sdd --project --dashboard` indexes the build pattern + every feature under
  `.ai-sdd/features/*` as a flat set, but it NEVER reads `.ai-sdd/programs/*` — so a repo that has
  both features and programs has no single command that shows everything together.
- Any dashboard rendered against real run state is non-reproducible: `.ai-sdd/runs/` and
  `.ai-sdd/artifacts/` are gitignored, and `RunMeta.pipelineDir` is stored/matched as an ABSOLUTE
  filesystem path — so a committed run won't match its pipeline on another clone/CI machine. There is
  no committed example factory with run state, so the README can't show a fixed, regenerable example
  of the modalities, and there are no end-to-end CLI integration tests over a realistic factory.

## Goal
1. Make `ai-sdd graph .ai-sdd --project --dashboard` the true WHOLE-REPO view: it keeps every
   `Feature · <name>` section AND adds a `Program · <slug>` section per `.ai-sdd/programs/*`
   (status-rolled-up, reusing the program dashboard built in `program-status-dashboard`).
2. Ship a COMMITTED, PORTABLE demo fixture under `docs/examples/<demo>/` — a small self-contained
   factory (a couple of features + one program with a milestone gate) WITH committed run state — that
   (a) regenerates the dashboards byte-stably on any clone, and (b) is the fixture for end-to-end CLI
   integration tests of the graph modalities (+ validate/status).
3. Showcase the modalities in the README with fixed, regenerable examples driven by the fixture.

## Closed decisions (decision-closed brief)

### A. Whole-repo dashboard (`--project` includes programs)
- Extend `ProjectDashboardAssembler.assemble(factoryDir:runStore:)` to ALSO enumerate
  `<factoryDir>/programs/*` (use `Layout.programsDir`) and append one `Program · <slug>`
  `DashboardSection` per program, reusing the program rollup + section logic from
  `ProgramDashboardAssembler` (extract a shared `programSection(programDir:runStore:)` helper if
  clean). Features still render exactly as today (additive; ordering: features first, then programs,
  or a clearly-documented stable order). No CLI change — `--project` already routes here.
- Graceful degradation unchanged: a program with no run → static statuses; a broken program dir →
  skip/degrade, never crash. The summary/donut/bar aggregate across feature + program sections.

### B. Portable run state (so committed fixtures + CI work on any machine)
- **Run-store resolution from the target dir.** Stop hardcoding the dashboard's run store to
  `<cwd>/.ai-sdd/runs`. Derive the run-store base from the target `<dir>` by finding its
  `Layout.homeDir` (`.ai-sdd`) ancestor: root the store at `<base>/.ai-sdd/runs` where `<base>` is the
  path component just above `.ai-sdd`. For `.ai-sdd` / `.ai-sdd/programs/<slug>` the base is `.` (cwd)
  — identical to today (NO regression). For `docs/examples/<demo>/.ai-sdd[/...]` the base is
  `docs/examples/<demo>` — so a self-contained fixture resolves its OWN runs. Also accept an explicit
  `--runs <dir>` override on `graph` as an escape hatch (defaults to the derived base). Keep `status`
  /`next`/`submit` behavior unchanged unless trivially consistent.
- **Portable pipelineDir matching.** Make the dashboard run-matching machine-independent:
  `DashboardProjection.matchedState` must treat a `RunMeta.pipelineDir` that is a RELATIVE path as
  resolved against the run-store base before standardizing/comparing (absolute stored paths keep
  today's behavior, so existing local runs still match). The committed fixture stores its
  `pipelineDir` RELATIVE to the fixture base (e.g. `.ai-sdd/programs/<slug>`), so it matches on any
  clone. This is additive + backward compatible (real local runs are absolute and on one machine).
- Do NOT change how `ai-sdd start` stores real runs (still absolute) — only (i) add relative-path
  resolution to matching, and (ii) have the fixture-builder write portable relative pipelineDirs.

### C. Committed demo fixture
- Location: `docs/examples/<demo>/.ai-sdd/` — a minimal but real factory (build pattern + workers +
  checks + a couple features with slices + one program wiring those features through a
  `milestone-gate`), valid under `ai-sdd validate`. Choose a clear name (e.g. `demo-factory`).
- Committed run state: `docs/examples/<demo>/.ai-sdd/runs/<runId>/{run.json,events/*}` with a PORTABLE
  relative `pipelineDir`, seeded to a realistic mix of statuses (some done, some in-progress, a
  milestone passed or pending) so the dashboards show a meaningful, non-trivial picture. Provide a
  committed, deterministic builder (a script or a documented command sequence) that regenerates the
  run state from the fixture so it's reproducible and reviewable — not hand-forged opaque JSON.
- `.gitignore` is anchored to the repo-root `.ai-sdd` (verified via `git check-ignore`), so the
  fixture's nested `.ai-sdd/runs` commits without force-add. If a force-add or a gitignore negation is
  needed, prefer an explicit `!docs/examples/**` negation managed outside the bootstrap markers.

### D. Integration tests + README showcase
- End-to-end tests in `Tests/AISDDEngineTests/` (Swift Testing) that exercise the real surface against
  the committed fixture (via the engine/assembler APIs and/or the built CLI) and assert on output:
  `validate` passes; single-graph Mermaid for a feature and for the program; whole-repo
  `--project --dashboard` shows BOTH `Feature ·` and `Program ·` sections with the fixture's statuses;
  per-program `--dashboard` renders the master graph; charts are inline SVG; everything HTML-escaped.
  Tests must be machine-independent (rely on the portable fixture, no absolute paths).
- README: add a concise "Visualizing the factory" section showcasing each modality with the
  fixture-based commands and a committed, regenerable example output (HTML snapshot and/or screenshot),
  new-model framing only (no legacy ai-sdd references). Mirror the honest self-contained wording from
  QUICKSTART (inline-SVG charts; the Mermaid graph uses a CDN ESM import — parity across all tiers).

## Constraints / conventions
- Swift 6 + SwiftPM. Engine logic in `Sources/AISDDEngine/`, CLI in `Sources/AISDDCLI/`, shared specs
  in `Sources/AISDDModels/`, path literals in `Sources/AISDDEngine/Layout.swift` (no inline path
  strings). Swift Testing (`@Test`/`#expect`/`#require`, exact typed errors). Per
  `.ai-sdd/conventions/swift.md`.
- Additive only: every existing graph mode (single, `--project` features, `--plant`, `--html`, plain
  Mermaid, the per-program `--dashboard`) stays unchanged except `--project --dashboard` GAINS program
  sections. No regression to existing tests.
- Keep projection/assembler/matching logic pure and unit-testable where possible; the fixture enables
  the end-to-end layer.

## Acceptance (verifiable)
1. `swift build`, `swift test`, `swift run ai-sdd validate .ai-sdd` green; `ai-sdd validate
   docs/examples/<demo>/.ai-sdd` green.
2. `ai-sdd graph .ai-sdd --project --dashboard --out /tmp/all.html` shows every `Feature ·` section AND
   a `Program · guardrails` section (the repo has the guardrails program); existing feature behavior
   unchanged.
3. The committed fixture renders reproducibly: `ai-sdd graph docs/examples/<demo>/.ai-sdd --project
   --dashboard --out /tmp/demo.html` resolves the fixture's OWN runs and shows the fixture's
   features + program with their committed statuses — identically on a fresh clone (portable
   pipelineDir; no machine-specific path).
4. `ai-sdd graph docs/examples/<demo>/.ai-sdd/programs/<slug> --dashboard` and the single/`--html`/
   plain-Mermaid modalities all work against the fixture.
5. Integration tests over the fixture pass and are machine-independent. Unit tests cover: project
   dashboard now includes program sections; portable (relative) pipelineDir matching; runstore-base
   derivation (cwd case unchanged + fixture case resolved).
6. README has the showcase section with the fixture-based commands and a committed regenerable example.

## Reference (grounding)
- `.gitignore` lines ~69–77 anchor `.ai-sdd/runs/`, `.ai-sdd/artifacts/` to repo root (fixture under
  `docs/examples/` is committable).
- `Sources/AISDDCLI/main.swift` `runStore()` (cwd-rooted) + `Graph` command; `RunStore.local(under:)`.
- `Sources/AISDDEngine/DashboardProjection.swift` `ProjectDashboardAssembler`, `ProgramDashboardAssembler`,
  `matchedState`/`standardizedPath`; `Run.swift`/`RunStore.swift` (RunMeta absolute pipelineDir,
  `scoped` nested events, on-disk run layout); `Layout.swift` (`homeDir`, `runsDir`, `programsDir`).
- Existing examples: `docs/examples/{minimal,orchestration,program-milestone,program-nested,sdlc-plant}`
  (factories without committed runs) — model the fixture on these, adding committed portable run state.
