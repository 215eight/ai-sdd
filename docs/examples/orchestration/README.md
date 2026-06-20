# Orchestration example — a dependency graph of slices

This is the **second kind of DAG** (architecture §5): an *orchestration graph* whose nodes are
**slices** (work items) wired by pure `depends_on` edges, where each slice descends into its own
plan→implement→review **pipeline**. The same engine runs it — the Scheduler schedules a slice once
its dependencies complete, and `next`/`submit` transparently drive the active slice's sub-pipeline.

```
foundation ──▶ api
      │
      └──────▶ ui
```

Each slice here reuses the runnable [`../minimal`](../minimal) cycle (architect → coder → reviewer),
specialized by a different `stack`. That is the point of composition: one pattern pipeline, many
slices.

## Walk it

```sh
ai-sdd validate docs/examples/orchestration          # referential + acyclicity check
ai-sdd start    docs/examples/orchestration --id app
ai-sdd next     app        # → descends into slice `foundation`, renders its architect
ai-sdd submit   app        # advance the slice's sub-pipeline; repeat next/submit…
                            # when foundation's sub-pipeline finishes, the slice completes
                            # and `api` + `ui` become runnable.
ai-sdd status   app        # shows top-level slices and the active slice's sub-progress
```

The engine owns control flow (which slice is runnable, did the gate pass, advance); the agent does
each Worker's work via its skill (ADR-0026).
