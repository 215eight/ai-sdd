# Skill: implement-change

Implement the plan into a **change** (`code.v1`), making the worker's gates pass.

Illustrative example skill — in a real repo this is the repo's implementation skill, specialized
by the worker's `stack`. The driver invokes it when `ai-sdd next` renders the `coder` worker.

Do:
1. Read `plan.v1` (the consumed input) and the `stack`'s conventions.
2. **Address every acceptance item** in the plan. Make the change within the worker's write scope
   only — do not touch other slices' scope.
3. Record which acceptance items the change addresses in `code.v1`'s **`satisfies`** list (the ids
   from the plan's `acceptance`). This threads the checklist forward to the reviewer.
4. Ensure the declared gates pass locally (`checks`: typecheck, lint, unit, diff-in-scope), then
   `ai-sdd submit`. If submit reports rework, the next render lists the failed gates under `rework`
   — fix exactly those and resubmit.

```yaml
# code.v1 (excerpt)
summary: "Add HyroxResultsService: parse fixture JSON and persist by race id."
satisfies: [ parse-fixture, persist-result ]
```

Produce `code.v1`. Do not expand scope beyond the plan. If a required item cannot be met without
out-of-scope work, leave it unsatisfied and say so — the reviewer will reject and route rework back,
rather than silently shipping a half-met checklist.
