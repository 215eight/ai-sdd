# ai-sdd

A software factory that turns a feature request into **a verifiable change a human reviews rather than redoes**.

A deterministic engine (`ai-sdd`) plans the work and gates every step; your coding agent (Claude Code,
Codex, …) does the work via skills. The loop is always:

```
ai-sdd next   → engine renders the runnable worker (role + its skill + inputs + gates)
   ↓  your agent does that work via the worker's skill
ai-sdd submit → engine validates the output, runs the gates, advances — or routes to rework
   ↺  repeat until the run reports ✓ done
```

The factory lives in a `.ai-sdd/` home in your repo — a pipeline, the worker roles, per-artifact
schemas compiled into deterministic gates, your learned conventions, and the worker skills. The engine
is a single copyable Swift binary (`ai-sdd`); it is provider-neutral and any agent drives it over a
shell. **New here? Start with [QUICKSTART.md](QUICKSTART.md)** — install the binary, seed the framework
skills, bootstrap your repo, then plan and build a feature.

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

## The `.ai-sdd/` home

`ai-sdd-bootstrap` scaffolds the factory in your repo and `ai-sdd validate .ai-sdd` checks it:

```text
.ai-sdd/
  pipeline.yaml      the build pattern (e.g. architect → implementer → reviewer)
  workers/           the roles (signature + which skill each runs)
  schemas/           per-artifact structure + rules + judge  (makes gates deterministic)
  conventions/       your house style, learned from the codebase
  skills/            worker skills + the copied framework skills
  checks/            the compiled gates (generated from schemas)
  features/          planned features — requirements.md + the slice graph (per feature)
  programs/          planned programs — the master graph (features sequenced by milestones)
  runs/ artifacts/   runtime — gitignored
```

Plan and build with the framework skills (run from your repo root):

```sh
/ai-sdd-bootstrap                              # stand up (or refresh) the factory in this repo
/ai-sdd-plan "<your feature brief>"            # → requirements + slice graph in .ai-sdd/features/<slug>
ai-sdd start .ai-sdd/features/<slug> --id <slug>
/ai-sdd-run <slug>                             # the agent loops next → work → submit until ✓ done
```

For multi-feature, multi-person work, plan a **program** (`/ai-sdd-plan-program`) — a master graph of
whole features sequenced by milestone gates with owners, driven by the same engine. See
[QUICKSTART.md](QUICKSTART.md) for the full walkthrough.

## Engine command reference

| Command | What it does |
|---|---|
| `ai-sdd cheatsheet` | print the diagram-driven workflow cheatsheet (travels with the binary) |
| `ai-sdd validate <dir>` | load + check a workspace (refs, edge types, acyclicity) |
| `ai-sdd start <dir> --id <id>` | begin a run |
| `ai-sdd next <id>` | render the runnable worker (`--json` for drivers) |
| `ai-sdd submit <id>` | validate output, run gates, advance or rework |
| `ai-sdd status <id>` | run state + what's runnable (nested for slices) |
| `ai-sdd check <schema> <artifact>` | run a Tier-1 structure/verdict gate standalone |
| `ai-sdd scope --plan <plan> --repo <dir>` | run the Tier-2 scope gate standalone |
| `ai-sdd cover --plan <plan> --review <review>` | check the review judged every acceptance item |
| `ai-sdd graph <dir>` | render the dependency graph as Mermaid (`--project`, `--plant`, `--dashboard`, `--html`) |

## Build and test

The engine is a single Swift package (`AISDDModels` + `AISDDEngine` libraries, `ai-sdd` executable).
To work on it from source:

```sh
swift test                                     # run the engine test suite
swift build -c release                         # compile the release binary
./scripts/install.sh                           # macOS: build + put ai-sdd on your PATH (idempotent)
ai-sdd --version                               # → ai-sdd 0.5.0
```

Using ai-sdd in another repo doesn't require Swift — build the binary once and copy it onto your PATH.
See [QUICKSTART.md](QUICKSTART.md) Step 1 for details.
