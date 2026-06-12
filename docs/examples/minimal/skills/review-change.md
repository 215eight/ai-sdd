# Skill: review-change

Review the change and produce **review notes** (`review.v1`).

Illustrative example skill — in a real repo this is the repo's review skill, specialized by the
worker's `stack`. The driver invokes it when `factory next` renders the `reviewer` worker (a
required-gate node).

Do:
1. Read `code.v1` against `plan.v1` and the `stack`'s conventions.
2. Review for correctness, scope adherence, and convention conformance. You read only — a
   reviewer never edits or pushes.
3. Record `review.v1` and `factory submit`. The reviewer's own gate (`judge.review-quality`)
   is a deferred judge check today; deterministic gates still bind.
