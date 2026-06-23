# Demo factory — a portable dashboard fixture

A tiny, self-contained ai-sdd factory that doubles as the end-to-end **dashboard** fixture. It is
fully portable: no absolute machine paths, so it renders the same on any clone.

## Topology

One **program** (`demo`) over three **features**, all descending into one shared minimal **build
pattern**:

```
.ai-sdd/
  pipeline.yaml                 umbrella pipeline (one slice → build); the dashboard's "Build pattern"
  build/                        the shared minimal build pattern
    pipeline.yaml               one node `w`
    workers/w.worker.yaml       transform worker, task: { command: "true" }
  features/
    auth/pipeline.yaml          slices: signup → login
    billing/pipeline.yaml       slice:  invoices
    search/pipeline.yaml        slices: index → query
  programs/demo/
    pipeline.yaml               auth, billing → m1-core-integrated → search
    requirements.md             decision-closed program requirements (approved)
    workers/milestone-gate.worker.yaml     manual milestone gate (validation-result.v1)
    checks/validation-result.structure.check.yaml
  runs/demo-program-run/        committed PORTABLE program run state
    run.json                    RunMeta — pipelineDir RELATIVE: .ai-sdd/programs/demo
    events/NNNNNN.json          hand-authored RunEvent log
```

The program wires the two parallel features into a milestone gate, then unlocks the third:

```
auth     ─┐
          ├─▶ m1-core-integrated ─▶ search
billing  ─┘
```

## Committed status mix

The committed event log folds to a realistic mix (not all-pending):

| Node                 | Status      | Why                                                |
|----------------------|-------------|----------------------------------------------------|
| `auth`               | done        | top-level `nodeCompleted`                          |
| `billing`            | in-progress | `scoped` event starts sub-node `invoices`          |
| `m1-core-integrated` | pending     | upstream not all done; no events                   |
| `search`             | pending     | gated behind the milestone; no events              |

## Regenerating the run state

The run state is hand-authored (no `ai-sdd start`, so `pipelineDir` stays relative and portable).
Regenerate it deterministically from anywhere:

```sh
bash docs/examples/demo-factory/build-fixture.sh
```

The script rewrites `run.json` + `events/NNNNNN.json` byte-for-byte to match the engine's Codable
encoding. It is idempotent — re-running reproduces identical files.

## Dashboard commands

```sh
# Validate the factory (build pattern + features + program all load and wire up):
ai-sdd validate docs/examples/demo-factory/.ai-sdd

# Project dashboard — a Feature section per feature + a Program · demo section, with statuses
# resolved from this fixture's own runs/:
ai-sdd graph docs/examples/demo-factory/.ai-sdd --project --dashboard --out /tmp/demo.html

# Program master graph — the three feature nodes + the milestone node, with the committed mix:
ai-sdd graph docs/examples/demo-factory/.ai-sdd/programs/demo --dashboard
```

Both dashboards derive the run-store base from the target (`RunStore.base(forTarget:)` → resolves to
`docs/examples/demo-factory`) and resolve the relative `pipelineDir` against it, so the committed
statuses surface on any clone.
