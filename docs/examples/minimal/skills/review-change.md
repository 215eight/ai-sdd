# Skill: review-change

Review the change against the plan's acceptance checklist and produce a **verdict** (`review.v1`).

Illustrative example skill — in a real repo this is the repo's review skill, specialized by the
worker's `stack`. The driver invokes it when `factory next` renders the `reviewer` worker (a
required-gate node). The reviewer is a **real gate**, not advisory notes: its verdict blocks.

Do:
1. Read `code.v1` against `plan.v1` (both are consumed inputs) and the `stack`'s conventions.
2. Review for correctness, scope adherence, and convention conformance. You read only — a reviewer
   never edits or pushes.
3. Return a **verdict per acceptance item** plus an **overall verdict**:
   - one `items` entry per plan acceptance id — `verdict: pass | fail`, with `notes`;
   - overall `verdict: approve | reject`.
   - **You MUST `reject` if any acceptance item is unmet or any convention is violated.** An approve
     with a failed item, or a missing item, fails the gate too (the verdict + coverage gates enforce
     this) — so judge every item honestly.
4. On `reject`, name where the rework goes in a **`rework`** list: `target` is the indicted input
   schema — `changeset.v1` (the implementation is wrong → routes to the implementer) or
   `feature-plan.v1` (the plan/contract is wrong → routes to the planner). The engine reads this to
   route the rework; a reject with no target escalates to a human.
5. Record `review.v1` and `factory submit`.

```yaml
# review.v1 — a reject that routes to the implementer
items:
  - { id: parse-fixture,  verdict: pass, notes: "maps all fields" }
  - { id: persist-result, verdict: fail, notes: "reads back the wrong race on id collision" }
verdict: reject
rework:
  - { target: changeset.v1, reason: "persist-result: lookup keys on name, not race id" }
```
