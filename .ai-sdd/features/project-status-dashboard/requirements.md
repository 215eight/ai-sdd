# Project Status Dashboard

## Source Brief

`dashboard-brief.md`

## Goal

Build a single self-contained HTML dashboard for PMs, CTOs, and engineering managers that gives a
quick project-status view from committed ai-sdd specs plus local run state. The dashboard is exposed
as `ai-sdd graph --dashboard` and builds on the existing deterministic `GraphRenderer`/`ai-sdd graph`
surface.

## In Scope

- Add a `--dashboard` mode to `ai-sdd graph`.
- Support project view:

  ```sh
  ai-sdd graph .ai-sdd --project --dashboard --out <file>
  ```

- List the build pattern and every feature under `.ai-sdd/features/*`.
- Render a self-contained HTML file with no server, database, authentication, auto-refresh, or CDN
  dependency for dashboard charts.
- Include a summary header with feature count, slice count, and a progress bar.
- Render a status-annotated graph where each node is styled by status and explained by a legend:
  done, in-progress, rework, escalated, runnable, pending.
- Render inline SVG charts:
  - status donut chart showing status distribution;
  - bar chart grouped by owner, falling back to feature and then stack when owner tags are absent.
- Read local run state from `.ai-sdd/runs/` through `RunStore`/`RunState`.
- Match feature runs robustly by scanning runs and comparing `RunMeta.pipelineDir` to feature
  pipeline directories.
- Degrade gracefully when no local run matches a feature: source slices are runnable from the static
  graph; dependent slices are pending.
- HTML-escape all names, ids, metadata, status labels, check names, and generated text.
- Preserve existing graph modes: single graph, `--project`, `--plant`, and `--html`.
- Unit-test pure renderer/projection behavior without file I/O where possible.

## Out Of Scope

- Team-wide or multi-machine live status. Shared live status waits for the shared state plane
  described by ADR-0025.
- `--plant --dashboard`, remote fragment fetching, or push-published fragment manifests.
- Publish adapters for GitHub Pages, GitLab Pages, S3, nginx, or any other host.
- Auto-refresh, server mode, HTTP endpoints, databases, or authentication.
- Replacing Mermaid Markdown/HTML graph output.
- Adding a CDN chart library.
- LLM/judge checks.

## Acceptance

- `ai-sdd graph .ai-sdd --project --dashboard --out <path>` writes a self-contained HTML file.
- The dashboard lists the build pattern plus every feature under `.ai-sdd/features/*`.
- Nodes are colored or styled by status, and a legend explains the scheme.
- The header includes totals and an overall progress bar.
- A status donut chart and per-owner/per-feature/per-stack bar chart render as inline SVG.
- A feature with no matching local run shows static graph-derived statuses: runnable roots and
  pending dependents.
- A feature with a local run matching its `pipelineDir` reflects done, in-progress, runnable,
  rework, and escalated statuses from folded run state.
- Owner tags are surfaced when present; missing owners use the confirmed fallback order:
  feature, then stack.
- Existing graph modes still work.
- `swift build`, `swift test`, and `swift run ai-sdd validate .ai-sdd/features/project-status-dashboard`
  pass.

## Closed Decisions

- **Command surface:** use `--dashboard` on the existing `graph` command, not a new top-level
  `dashboard` command.
- **Required invocation:** dashboard is a project view and requires `--project` in the first version.
- **Charts:** use inline SVG charts with no CDN dependency.
- **Status source:** read local run state only.
- **Run matching:** scan available runs and match by `RunMeta.pipelineDir` instead of relying only
  on run id.
- **No-run default:** derive static statuses from the pipeline graph: source nodes are runnable and
  dependent nodes are pending.
- **Colors:** expose semantic CSS variables with default values:
  - done: `#2e7d32`
  - in-progress: `#1565c0`
  - rework: `#f9a825`
  - escalated: `#c62828`
  - runnable: `#616161` outline
  - pending: `#9e9e9e`
- **Owner fallback:** group chart bars by owner when present, otherwise by feature, otherwise by stack.
- **Architecture boundary:** shared live dashboards and plant dashboards remain future work.

## Constraints

- Swift 6 and Swift Package Manager.
- Swift Testing (`@Test`, `#expect`, `#require`) with exact typed errors where applicable.
- Keep on-disk path names centralized in `Layout.swift` when new conventional paths are introduced.
- Keep renderer/status projection functions pure and testable.
- Reuse `GraphRenderer`, `RunStore`, `RunState`, `Scheduler`, and existing spec loaders.
- Avoid design-doc jargon in code comments.

## Evidence

- `Sources/AISDDCLI/main.swift` already implements `graph`, `--project`, `--plant`, `--html`,
  `status`, and local `RunStore` use.
- `Sources/AISDDEngine/GraphRenderer.swift` already contains pure graph/HTML rendering helpers.
- `Sources/AISDDEngine/Run.swift` exposes the state needed for status classification:
  `completedNodes`, `inProgressNodes`, `failedChecks`, `escalatedNodes`, and nested slice state.
- `Sources/AISDDEngine/RunStore.swift` exposes run ids, metadata, events, and folded state.
- `docs/decisions.md` ADR-0027 marks live progress overlay as pending behind shared state, so this
  feature remains local/static.
- `.ai-sdd/conventions/swift.md` confirms build/test conventions and lack of an established lint/CI
  convention.
