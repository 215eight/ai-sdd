# Schema example — the acceptance checklist threaded through the gates

These schemas + artifacts show the thread that holds a slice to a verifiable bar — an **acceptance
checklist** authored by the planner, addressed by the implementer, and judged item-by-item by the
reviewer — and how the reviewer's verdict is a **real, blocking gate** (not advisory notes), whose
reject **routes rework to the producer of the input it indicts** (architecture §8–§9).

## The three schemas

| Schema | File | Carries |
|---|---|---|
| `feature-plan.v1` | [feature-plan.schema.yaml](feature-plan.schema.yaml) | `acceptance` — the checklist (`{ id, description }` per item) |
| `changeset.v1` | [changeset.schema.yaml](changeset.schema.yaml) | `satisfies` — the acceptance ids the change addresses |
| `review.v1` | [review.schema.yaml](review.schema.yaml) | per-item `items[].verdict` + overall `verdict` + `rework` routing |

The gates are all **deterministic** — the schema invariants compile to an `ai-sdd check`, so no
judge-runner is needed; the reviewer *is* the judge, captured structurally.

## Walk the thread

```sh
# 1. The plan declares an acceptance checklist (and is decision-closed, in-scope).
ai-sdd check feature-plan.schema.yaml plan-good.yaml      # ✓
ai-sdd check feature-plan.schema.yaml plan-bad.yaml       # ✗ incl. acceptance[0].id empty

# 2. The changeset records which acceptance ids it satisfies.
ai-sdd check changeset.schema.yaml changeset-good.yaml    # ✓ satisfies: [parse-fixture, persist-result]

# 3. The reviewer returns a verdict per item + overall. This IS the gate:
ai-sdd check review.schema.yaml review-approve.yaml       # ✓ every item passes, verdict approve
ai-sdd check review.schema.yaml review-reject.yaml        # ✗ a failed item + a reject — BLOCKS the slice

# 4. The review must judge EVERY acceptance item (no silent skips):
ai-sdd cover --plan plan-good.yaml --review review-approve.yaml   # ✓ all items judged
```

## The reject routes rework — to the implementer or the planner

[review-reject.yaml](review-reject.yaml) fails the gate **and** names where the rework goes:

```yaml
verdict: reject
rework:
  - { target: changeset.v1, reason: "persist-result: lookup keys on name, not race id" }
```

The engine reads `rework[].target`, maps it to the producer via the reviewer's incoming edges, and
re-runs that worker with the failure as context (scope-invalidating its downstream):

- `target: changeset.v1` → the **implementer** re-runs (the implementation is wrong);
- `target: feature-plan.v1` → the **planner** re-runs (the plan / contract is wrong).

Rework is **bounded** — after a few rounds the engine escalates to a human rather than looping. See
[../minimal](../minimal) for the runnable pipeline whose reviewer consumes both inputs (the two
routable producers), and `Rework` / the §9 tests in the engine for the routing itself.
