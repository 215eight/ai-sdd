---
name: review-feature
description: Review an ai-sdd changeset against the feature plan and emit a blocking verdict artifact.
---

# Review an ai-sdd feature

Read `.ai-sdd/artifacts/feature-plan.v1.yaml`, `.ai-sdd/artifacts/changeset.v1.yaml`, and
`.ai-sdd/conventions/swift.md`. Inspect the diff and relevant source/tests.

Write `.ai-sdd/artifacts/review.v1.yaml` with:

- `items`: one entry for every plan acceptance id, each `{ id, verdict, notes }` where `verdict` is
  `pass` or `fail`.
- `verdict`: `approve` only when every item passes and conventions are satisfied; otherwise `reject`.
- `rework`: required on reject, with entries naming the indicted input schema:
  - `target: changeset.v1` for implementation defects.
  - `target: feature-plan.v1` for plan or acceptance-contract defects.

Do not approve when an acceptance item is unjudged. The `review.coverage` check enforces that every
plan acceptance id appears in the review.
