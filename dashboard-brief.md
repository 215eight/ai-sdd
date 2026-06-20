# Feature brief — Project status dashboard (`ai-sdd graph --dashboard`)

> Hand this to `ai-sdd-plan` as the brief. It is intentionally decision-rich so the planner does not
> have to invent scope. If anything here is ambiguous, STOP and ask before generating slices.

## Goal
A single self-contained **HTML dashboard** that gives a PM / CTO / eng-manager a quick glimpse of a
project's status — built on the existing `GraphRenderer` / `ai-sdd graph` (same deterministic,
specs-in render). It augments the dependency graph with **status, progress, owners, and charts**.

## In scope
- A `--dashboard` mode for `ai-sdd graph` (project view: `ai-sdd graph .ai-sdd --dashboard --out <file>`).
- **Summary header:** totals (features, slices) + an overall **progress bar** (done / total).
- **Status-annotated graph** — each node colored by run status, with a **legend**. Color scheme:
  done = green, in-progress = blue, rework = amber, escalated = red, runnable = outline, pending = gray.
- **Charts (inline SVG — no CDN, works offline / `file://`):** a status **donut** (distribution) AND a
  **bar chart** (slices per owner; fall back to per-feature / per-stack when `owner` tags are absent).
- **Status source:** the local run log (`RunStore` / `RunState`) — a node with no run renders as pending.
- Owners surfaced from the `owner` four-tag when present; degrade gracefully when absent.
- Working navigation + a legend. HTML-escape all names/ids/metadata.

## Out of scope (do NOT build)
- Team-wide / multi-machine live status (needs the shared state plane, ADR-0025) — read LOCAL run state only.
- Auto-refresh / any server / HTTP / DB / auth; it's a static generated file.
- Remote fragment fetch / `--plant --dashboard`.
- Replacing the existing Mermaid Markdown/HTML graph output (`--project`, `--html` keep working).

## Acceptance (the bar — must all hold)
- `ai-sdd graph .ai-sdd --project --dashboard --out <path>` writes a self-contained HTML file, no server.
- Lists the build pattern + every feature under `.ai-sdd/features/*`.
- **Nodes are colored by status and a legend explains the scheme.**
- **A progress bar, a status donut, AND a per-owner (or per-feature) bar chart render — all inline SVG.**
- No-run feature → slices show pending/runnable from the static graph; a feature whose run id matches
  its slug → reflects done/in-progress/runnable/rework/escalated from the folded run state.
- Existing modes still work: single graph, `--project`, `--plant`, `--html`.
- Pure renderer functions (status rollup, chart SVG, dashboard HTML) are unit-tested without I/O;
  `swift build` + `swift test` green; `ai-sdd validate .ai-sdd/features/project-status-dashboard` passes.

## Constraints (repo conventions)
Swift 6, Swift Testing (`@Test`/`#expect`/`#require`, assert exact typed errors), all on-disk path
names in `Layout.swift`, no design-doc jargon in code comments, pure/testable renderer functions,
"engine is the only code." Reuse `GraphRenderer` + `RunStore`/`RunState`; thread run state into the
renderer (it's currently spec-only).

## Decisions to confirm WITH the human before closing (do not assume)
1. Command surface: `--dashboard` flag on `graph` (preferred) vs a `dashboard` subcommand.
2. Charts: inline SVG (preferred — offline) vs a CDN chart lib. (Mermaid graph keeps its CDN; charts inline.)
3. Slice→status mapping (sub-pipeline completion) + the no-run default.
4. Exact color hex values + legend placement.
5. Owner fallback when specs lack `owner` tags.
