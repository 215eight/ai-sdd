---
name: plan-feature
description: Produce a decision-closed ai-sdd feature plan with a verifiable acceptance checklist.
---

# Plan an ai-sdd feature

Read `AGENTS.md`, `docs/architecture.md`, `docs/decisions.md`, and `.ai-sdd/conventions/swift.md`
before planning. Ground the plan in existing source, tests, docs, and examples.

Write the artifact to `.ai-sdd/artifacts/feature-plan.v1.yaml`.

The artifact must contain:

- `summary`: a concise description of the intended change.
- `scope`: a mapping with at least `in` and `out` lists.
- `acceptance`: one verifiable item per outcome, each with stable `id` and `description`.
- `decisions`: every planning decision, each with `status: closed`.
- `files`: exact repo-relative files or directory prefixes the implementation may touch.
- `tests`: build, test, validation, or inspection commands the implementer must run.

Do not leave open architecture questions inside the artifact. If the work requires a new
architecture decision, stop and surface the options to the maintainer instead of guessing.
