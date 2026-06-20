# Skill: plan-change

Produce an implementation **plan** (`plan.v1`) for the slice/requirement.

Illustrative example skill — in a real repo this is the repo's planning skill, specialized by
the worker's `stack`. The driver invokes it when `ai-sdd next` renders the `architect` worker.

Do:
1. Read the slice's intent (its `stack`, and any provided requirement context).
2. Decompose the work: the files/components to change, the approach, and the acceptance bar.
3. Write an **`acceptance` checklist** — the verifiable bar, one item per outcome, each with a
   stable `id` and a `description`. This is the thread the whole slice is held to: the implementer
   addresses each item and the reviewer returns a verdict per item. Keep ids short and stable.
4. Record the plan as the run's `plan.v1` artifact (write it where the workspace expects, e.g.
   `.ai-sdd/artifacts/plan.v1.yaml`), then `ai-sdd submit` — the engine records `plan.v1` as ready.

```yaml
# plan.v1 (excerpt)
acceptance:
  - { id: parse-fixture,  description: "Parse a fixture JSON race result into the model" }
  - { id: persist-result, description: "Persist a parsed result and read it back by race id" }
```

Keep the plan small and concrete; downstream `implement-change` depends only on `plan.v1`, and the
reviewer judges against this checklist — so a missing or vague item weakens the gate.
