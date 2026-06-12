# Skill: implement-change

Implement the plan into a **change** (`code.v1`), making the worker's gates pass.

Illustrative example skill — in a real repo this is the repo's implementation skill, specialized
by the worker's `stack`. The driver invokes it when `factory next` renders the `coder` worker.

Do:
1. Read `plan.v1` (the consumed input) and the `stack`'s conventions.
2. Make the change within the worker's write scope only — do not touch other slices' scope.
3. Ensure the declared gates pass locally (`checks`: typecheck, lint, unit), then `factory
   submit`. If submit reports rework, the next render lists the failed gates under `rework`;
   fix exactly those and resubmit.

Produce `code.v1`. Do not expand scope beyond the plan.
