# ai-sdd — mental model

> How to think about ai-sdd: the concepts and the flow. Companion to
> [architecture.md](architecture.md) (the full model) and [../QUICKSTART.md](../QUICKSTART.md)
> (the steps).

## What ai-sdd is

A system that turns a feature brief into a **verifiable change you review rather than rewrite**. A
deterministic **engine** plans the work and enforces the quality gates; your coding agent does the
work via **skills**. The flow, roles, conventions, and gates aren't hardcoded — they're **data** in
your repo's `.factory/` folder. (Specs are data; the engine is the only code.)

## The core idea: separate *deciding* from *doing*

- **The engine decides control flow** — what's runnable next, did the gate pass, advance or send
  back for rework. This is deterministic and reproducible.
- **The agent does the work** — planning, implementing, reviewing — by following skills.
- **Verification is gates** — assertions on each output. That's why "done" means *already passed its
  checks*, not "the agent says it's done."

Dynamism comes from the data (the graph of work); reliability comes from the engine interpreting it
the same way every time. The agent never decides the flow, and the engine never does the work.

## The building blocks (the nouns)

- **Worker** — a role (e.g. architect, implementer, reviewer): a typed input/output signature plus
  the skill it runs.
- **Pipeline** — a typed graph (DAG) of workers: the build pattern, e.g. plan → implement → review.
- **Artifact** + **Schema** — a worker's typed output and the structure/rules it must satisfy.
  Schemas are what make gates deterministic.
- **Check (gate)** — an assertion on an output: *deterministic* (a command, exit 0/1) or *judge*
  (an LLM rubric, advisory). A failed required gate triggers rework. The **reviewer is a real gate,
  not advisory notes**: its verdict is captured as a structured artifact (per-item pass/fail + an
  overall approve/reject) whose schema invariants make it a deterministic gate — a reject blocks.
- **Slice** — an independently-buildable unit of a feature. Slices form an **orchestration graph**
  wired by `depends_on`.
- **Run** — one execution: the engine computes what's runnable, folds events into state, and
  advances.

## Two graphs, one engine

1. **The build pattern** (per repo) — the reusable plan → implement → review pipeline a single unit
   of work flows through.
2. **The orchestration graph** (per feature) — the slices and their dependencies. Each slice
   **descends** into the build pattern.

The same engine runs both: a node is runnable when its dependencies are complete; gates enforce
quality at each step.

## How to think about using it

Three layers, each with one job — **stand it up once, then plan and run per feature**:

| Layer | What it is | When | Command |
|---|---|---|---|
| **Toolkit** | the engine + the skills | once per machine | `factory --version` |
| **Repo factory** (`.factory/`) | build pattern, roles, conventions, schemas, gates | once per repo | `/factory-bootstrap` |
| **Feature plan** (`.factory/features/<slug>/`) | requirements + the orchestration graph | per feature | `/factory-plan "<brief>"` |
| **Execution** | run the graph to done | per feature | `/factory-run <slug>` |

## What a run feels like

`factory next` hands you the next runnable worker — its role, the skill to run, the inputs it
consumes, and the gates its output must pass. You do that work via the skill. `factory submit` runs
the gates: **pass → advance**, **fail → rework**. Rework routes by *what failed* (architecture §9):

- a worker whose **own output** is wrong (a failing build/test) re-runs **itself** with the failure
  as context;
- a **verdict** failure (a reviewer's reject) routes back to the **producer of the input it indicts** —
  the implementer for a code defect, the planner for a plan/contract defect — re-running that worker
  (and invalidating its downstream) so review→implement→review is a real loop, not a re-review of
  unchanged code. The reviewer names the indicted input (`rework.target`) and the engine resolves it
  against the pipeline edges.

Rework is **bounded**: after a few rounds the engine **escalates to a human** rather than looping
forever. Slices unlock as their dependencies finish. When every node is complete, you review a
change that has already cleared its gates.

## Seeing the work

The graph is the *one* place the flow lives, so the engine can **render** it — `factory graph` emits
it as **Mermaid** (shows in any Markdown viewer), per feature or for the whole repo (`--project`),
and across repos (`--plant`, grouped by milestone, flagging contract-version skew). It's a
deterministic render of your committed specs, so the whole team reads the same plan from one place
and drills down. A *live* progress overlay (who's on what right now) is a planned expansion — it
needs shared run state, which is still local today.

## Where things live

- `.factory/` — your repo's factory (committed).
- `.factory/features/<slug>/` — a feature's requirements + orchestration graph.
- `.factory/graph/` — generated dependency graphs (`factory graph … --out`), browsable in the tree.
- `.factory/runs/`, `.factory/artifacts/` — runtime state (gitignored).
- The skills — `factory-bootstrap`, `factory-plan`, `factory-compile-schema`, `factory-run`.

- `.factory/` — your repo's factory (committed).
- `.factory/features/<slug>/` — a feature's requirements + orchestration graph.
- `.factory/runs/`, `.factory/artifacts/` — runtime state (gitignored).
- The skills — `factory-bootstrap`, `factory-plan`, `factory-compile-schema`, `factory-run`.

## Current limits (first iteration)

Free-form *judge* checks are advisory (the LLM gate-runner isn't wired yet) — but the reviewer's
verdict is **not** a judge check: it's a structured artifact gated deterministically, so it blocks
today. A slice's brief is passed to its
architect by convention rather than as a typed artifact; requirements are markdown today; you run
`factory` from the repo root; there's no MCP server yet (drive via the CLI). These are unbuilt
pieces, not different intentions — the flow above is the model.
