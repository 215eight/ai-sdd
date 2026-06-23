# ai-sdd

Enterprise Spec-Driven Development workflow tooling.

This repository is the Swift implementation for the `ai-sdd` framework. The
current MVP is CLI-first and builds toward a shared `SDDCore` used by sibling CLI
and MCP interfaces.

## Visualizing the factory

The dependency graph is the one place the flow lives, and `ai-sdd graph` renders it across every
tier — a single feature or program graph, a whole-repo project dashboard, a per-program dashboard,
or a multi-repo plant aggregate. Every command below is copy-pasteable and runs against the
committed [`docs/examples/demo-factory/`](docs/examples/demo-factory/) fixture, so you can try each
modality without standing up a factory of your own.

**Single graph (plain Mermaid).** Render one feature's slice graph or a program's master graph to
stdout (drops straight into GitHub, VS Code, and most Markdown viewers):

```sh
ai-sdd graph docs/examples/demo-factory/.ai-sdd/features/auth     # one feature's slice graph
ai-sdd graph docs/examples/demo-factory/.ai-sdd/programs/demo     # the program's master graph
```

Add `--html` to wrap the same graph in a self-contained page you can open locally or host anywhere:

```sh
ai-sdd graph docs/examples/demo-factory/.ai-sdd/features/auth --html --out auth.html
ai-sdd graph docs/examples/demo-factory/.ai-sdd/programs/demo --html --out demo-program.html
```

**Whole-repo project dashboard.** One page covering every feature plus the `Program · demo` section,
with each node's status overlaid from the fixture's own `.ai-sdd/runs` store:

```sh
ai-sdd graph docs/examples/demo-factory/.ai-sdd --project --dashboard --out whole-repo-dashboard.html
```

A committed snapshot of exactly that output lives at
[`docs/examples/demo-factory/expected/whole-repo-dashboard.html`](docs/examples/demo-factory/expected/whole-repo-dashboard.html)
— every `Feature ·` section and the `Program · demo` section with the fixture's committed status mix
(auth `done`, billing `in-progress`), rendered with inline-SVG charts. Regenerate it byte-stably with
the command above (point `--out` at that path), which `build-fixture.sh` also emits when `ai-sdd` is
on `PATH`.

**Per-program dashboard.** The same overlay one tier up — a program's master graph as a status
dashboard, each sub-feature a single node with its status rolled up and the milestone validation
gates styled distinctly:

```sh
ai-sdd graph docs/examples/demo-factory/.ai-sdd/programs/demo --dashboard --out demo-program-dashboard.html
```

**Multi-repo plant aggregate.** Across repos, `ai-sdd graph --plant <plant.yaml>` aggregates fragment
locations into one program view grouped by milestone — see
[`docs/examples/sdlc-plant`](docs/examples/sdlc-plant), which carries its own committed `plant.yaml`.

A note on self-containment: the dashboard's status donut and grouped-bar charts are inline SVG with no
external assets, but the Mermaid dependency graph renders via a CDN ESM import — parity across all
tiers, so a generated page is not fully offline. For the run-store overlay semantics and caveats
(these dashboards are a snapshot of your local `.ai-sdd/runs` store, not a shared live team
dashboard), see QUICKSTART's [Visualize the work (for you and your team)](QUICKSTART.md#visualize-the-work-for-you-and-your-team).

## MVP Shape

- `SDDModels`: public domain contracts and JSON shapes.
- `SDDCore`: Swift workflow graph, OpenSpec artifact adapter, local telemetry
  sink, and workflow operations.
- `SDDCLI`: `sdd` command with JSON output.
- `SDDMCP`: placeholder package for the future MCP server.

The durable workflow source of truth is OpenSpec:

```text
openspec/changes/<feature_slug>/
```

Local MVP telemetry is written to:

```text
.sdd/telemetry/events.jsonl
```

Workspace configuration can be supplied at `.sdd/config.json`:

```json
{
  "openspec_root": "openspec",
  "telemetry_path": ".sdd/telemetry/events.jsonl",
  "repo_id": "org/repo",
  "workspace_id": "local-workspace",
  "stack": "swift",
  "machine_id": "developer-machine",
  "organization_id": "optional-org",
  "secrets": {
    "telemetry_api_key": "env:SDD_TELEMETRY_API_KEY"
  }
}
```

## Build And Test

```bash
swift test
swift run sdd capabilities --json
swift run sdd validate-workspace --json
swift run sdd validate-secrets --json
```

Useful MVP commands:

```bash
swift run sdd validate-workspace --json
swift run sdd validate-secrets --json
swift run sdd run --feature checkout-flow --owner agent-session --actor-type agent --json
swift run sdd start --feature checkout-flow --owner agent-session --actor-type agent --json
swift run sdd start --intake-file docs/intake/checkout.md --json
swift run sdd normalize-intake --file docs/intake/checkout.md --json
swift run sdd list-artifacts --feature checkout-flow --json
swift run sdd get-artifact --feature checkout-flow --type openspec_design --json
swift run sdd validate-artifacts --feature checkout-flow --json
swift run sdd next --run-id <run_id> --json
swift run sdd prepare-execution --run-id <run_id> --json
swift run sdd reject-gate --run-id <run_id> --phase plan --reason "Plan needs changes." --json
swift run sdd clear-lock --run-id <run_id> --json
swift run sdd mark-blocked --run-id <run_id> --reason missing_input --message "Waiting for input." --json
swift run sdd retry-action --run-id <run_id> --json
swift run sdd get-run-summary --run-id <run_id> --json
swift run sdd list-run-events --run-id <run_id> --json
```
