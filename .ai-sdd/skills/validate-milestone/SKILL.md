---
name: validate-milestone
description: Run a milestone's validation and record the verdict as a validation-result.v1 artifact.
---

# Validate a milestone

A milestone is the integration gate between features (ADR-0028). Run the validation for **this**
milestone node and record the verdict — never fabricate a pass.

Write `.ai-sdd/artifacts/validation-result.v1.yaml`:

- `milestone`: this milestone node's id.
- `criteria`: one `{ id, status }` per check the milestone runs (`status: pass | fail`).
- `outcome`: `pass` iff **every** criterion passed, else `fail`.
- `evidence`: optional — the commands run, a CI link, or sign-off notes.

**Automated milestone** (`workerKind: transform`): the milestone's deterministic check(s) — e.g.
`m1.integration` — are the hard gate the engine re-runs on `submit`. Run those same command(s) yourself
to determine each criterion's status, and record one criterion per command. Because the engine re-runs
the deterministic check, a fabricated `pass` is caught and rejected — so report honestly; a `fail`
outcome correctly fails the gate and the milestone re-validates after the work is fixed.

**Manual milestone** (`workerKind: human`): a person performs the validation (exercises the system,
brings a client) and records the result with the same fields.
