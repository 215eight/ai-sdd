# Skill: plan-change

Produce an implementation **plan** (`plan.v1`) for the slice/requirement.

Illustrative example skill — in a real repo this is the repo's planning skill, specialized by
the worker's `stack`. The driver invokes it when `factory next` renders the `architect` worker.

Do:
1. Read the slice's intent (its `stack`, and any provided requirement context).
2. Decompose the work: the files/components to change, the approach, and the acceptance bar.
3. Record the plan as the run's `plan.v1` artifact (write it where the workspace expects, e.g.
   `.work/plan.md`), then `factory submit` — the engine records `plan.v1` as ready.

Keep the plan small and concrete; downstream `implement-change` depends only on `plan.v1`.
