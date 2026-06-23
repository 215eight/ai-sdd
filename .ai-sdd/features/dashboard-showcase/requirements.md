# Requirements: dashboard-showcase

> Status: **APPROVED** (human-confirmed 2026-06-22; all decisions closed).

## Goal
Turn the `graph` command into a fully showcaseable, reproducible surface: (1) make
`ai-sdd graph .ai-sdd --project --dashboard` the true WHOLE-REPO view by adding a `Program · <slug>`
section per `.ai-sdd/programs/*` alongside the existing `Feature · <name>` sections; (2) ship a
COMMITTED, PORTABLE demo fixture under `docs/examples/` (a small factory with features + one program
with a milestone gate, plus committed run state) that regenerates the dashboards byte-stably on any
clone and doubles as the fixture for end-to-end CLI integration tests; (3) showcase all modalities in
the README with fixed, regenerable examples. This requires two small backward-compatible engine/CLI
changes so committed run state is portable: resolve the dashboard's run store from the target dir, and
match runs by a path that tolerates a relative `pipelineDir`.

## In scope
- Extend `ProjectDashboardAssembler` so `--project --dashboard` also enumerates `<factoryDir>/programs/*`
  and appends a `Program · <slug>` section per program (reusing the program rollup/section logic).
- Portable run state: derive the dashboard run-store base from the target `<dir>`'s `.ai-sdd` ancestor
  (cwd-equivalent for the repo root; the fixture's own runs for a nested fixture), plus an optional
  `--runs <dir>` override on `graph`; and make `DashboardProjection` run-matching resolve a relative
  `RunMeta.pipelineDir` against the run-store base before comparing (absolute paths keep today's
  behavior).
- A committed demo fixture: `docs/examples/<demo>/.ai-sdd/` (valid factory: build pattern + workers +
  checks + a couple features with slices + one program with a milestone gate) WITH committed, portable
  run state seeded to a realistic status mix, plus a committed deterministic builder to regenerate it.
- End-to-end CLI/assembler integration tests over the fixture (Swift Testing), machine-independent.
- README "Visualizing the factory" showcase section with fixture-based commands and a committed,
  regenerable example output.

## Out of scope
- Changing how `ai-sdd start` stores REAL runs (still absolute paths) — only matching gains relative
  resolution, and only the fixture-builder writes relative pipelineDirs.
- Any change to `--plant`, `--html`, single-graph, plain Mermaid, or the per-program `--dashboard`
  behavior, beyond `--project --dashboard` gaining program sections (additive).
- Live overlay, server, CDN removal, remote fragments, auth (ADR-0027 pending items stay out).
- A new top-level command; reworking RunStore storage, recursive execution, or the milestone-gate
  worker.
- Making `status`/`next`/`submit` fixture-aware beyond what is trivially consistent (the fixture is for
  read-only showcase + dashboard/validate/graph integration tests, not for driving new runs).

## Acceptance
1. `swift build`, `swift test`, `swift run ai-sdd validate .ai-sdd` green; `ai-sdd validate
   docs/examples/<demo>/.ai-sdd` green.
2. `ai-sdd graph .ai-sdd --project --dashboard --out /tmp/all.html` shows every `Feature ·` section AND
   a `Program · guardrails` section; existing feature rendering unchanged (no regression).
3. The committed fixture renders reproducibly and machine-independently: `ai-sdd graph
   docs/examples/<demo>/.ai-sdd --project --dashboard --out /tmp/demo.html` resolves the fixture's OWN
   runs and shows its features + program with the committed statuses — identically on a fresh clone.
4. The single-graph, `--html`, plain-Mermaid, and per-program `--dashboard` modalities all work against
   the fixture.
5. Machine-independent integration tests over the fixture pass. Unit tests cover: project dashboard
   includes program sections; relative-pipelineDir matching; run-store-base derivation (repo-root/cwd
   case unchanged + nested-fixture case resolved).
6. README has the showcase section with fixture-based commands and a committed regenerable example.

## Constraints
- Swift 6 + SwiftPM. Engine in `Sources/AISDDEngine/`, CLI in `Sources/AISDDCLI/`, specs in
  `Sources/AISDDModels/`, path literals in `Sources/AISDDEngine/Layout.swift` (no inline path strings).
  Swift Testing (`@Test`/`#expect`/`#require`, exact typed errors). Tests in `Tests/AISDDEngineTests/`.
  Per `.ai-sdd/conventions/swift.md`.
- Additive only: all existing graph modes unchanged except `--project --dashboard` gaining program
  sections; no existing test regresses.
- Reuse `ProgramDashboardAssembler`, `DashboardProjection`, `GraphRenderer`, `DashboardCharts`,
  `RunStore`/`RunState`/`RunMeta`, `SpecLoader`, `Layout`. Keep logic pure/unit-testable; the fixture
  enables the end-to-end layer.

## Decisions
1. **(closed) Whole-repo dashboard — `--project` includes programs.** `ProjectDashboardAssembler`
   enumerates `<factoryDir>/programs/*` (via `Layout.programsDir`) and appends a `Program · <slug>`
   section per program using a shared `programSection(programDir:runStore:)` helper extracted from
   `ProgramDashboardAssembler`. Order: existing `Feature ·` sections first, then `Program ·` sections,
   each alphabetically. Summary/charts aggregate across both. No CLI change.
2. **(closed) Run-store resolution from the target dir — derivation only, NO new flag.** The dashboard
   run store is rooted at `<base>/.ai-sdd/runs` where `<base>` is the path component above the target
   dir's `.ai-sdd` ancestor; for `.ai-sdd` and `.ai-sdd/programs/<slug>` `<base>` is `.` (cwd) —
   identical to today (no regression). No `--runs` flag is added (derivation only). `status`/`next`/
   `submit` unchanged.
3. **(closed) Portable pipelineDir matching.** `DashboardProjection.matchedState` resolves a RELATIVE
   `RunMeta.pipelineDir` against the run-store base before standardizing/comparing; absolute stored
   paths keep today's exact-match behavior. Additive + backward compatible.
4. **(closed) Committed portable fixture at `docs/examples/demo-factory/`.** A small valid factory under
   `docs/examples/demo-factory/.ai-sdd/` with committed run state whose `pipelineDir` is RELATIVE to the
   fixture base, seeded to a realistic status mix, plus a committed deterministic builder SHELL SCRIPT
   under the fixture (e.g. `docs/examples/demo-factory/build-fixture.sh`) that regenerates the run state
   reproducibly. `.gitignore` is anchored to repo-root `.ai-sdd`, so it commits without force-add; if a
   negation is ever needed, use an explicit `!docs/examples/**` outside the bootstrap markers.
5. **(closed) Fixture-backed integration tests + honest README showcase.** End-to-end tests assert
   validate + all graph modalities against the fixture, machine-independently. README showcases each
   modality with fixture commands and a committed regenerable output; honest self-contained wording
   (inline-SVG charts; Mermaid graph uses a CDN ESM import, parity across tiers); new-model framing
   only.
6. **(closed) Additive, no regression.** Every existing graph mode and test is preserved; the only
   behavior change to an existing command is `--project --dashboard` gaining program sections.

## Proposed milestones
None — single coherent feature; sliced as a normal dependency graph.
