---
name: ai-sdd-compile-schema
description: Compile a factory Schema (.ai-sdd/schemas/*.schema.yaml) into the deterministic CheckSpecs the engine runs, and wire them onto the worker that produces that schema. Bootstrap-time authoring — the output is committed and frozen, not regenerated per run. Use when a schema is added or changed, or while bootstrapping a repo's factory.
---

# Compiling a Schema into gates

A Schema describes an artifact; this skill turns that description into the gates the engine runs.
The principle: **you author the checks once, at bootstrap; the engine executes them deterministically
on every run.** Generated checks are committed and reviewed — never regenerated mid-run (that would
break reproducibility).

Input:  `.ai-sdd/schemas/<name>.schema.yaml`
Output: `.ai-sdd/checks/<name>.<id>.check.yaml` (one per gate) + the ids added to the worker that
        `produces: <name>.vN`.

## Artifact-location convention (interim)

Until a real artifact store exists, a produced artifact lives at a stable, gitignored path:

```
.ai-sdd/artifacts/<name>.v<version>.<format>     # e.g. .ai-sdd/artifacts/feature-plan.v1.yaml
```

The producing worker's skill writes there; compiled checks read from there. (`.ai-sdd/artifacts/`
and `.ai-sdd/runs/` are gitignored; the rest of `.ai-sdd/` is committed.)

## Compile each tier

Read the schema's `fields`, `rules`, and `judge`. Emit checks tier by tier.

### Tier 1 — `fields` → one deterministic structural check (mechanical)

If the schema has any `fields`, emit exactly one check that runs the validator. This is a fixed
template — no judgement:

```yaml
# .ai-sdd/checks/<name>.structure.check.yaml
apiVersion: ai-sdd/v1
kind: Check
metadata: { name: <name>.structure }
spec:
  checkKind: deterministic
  command: "ai-sdd check .ai-sdd/schemas/<name>.schema.yaml .ai-sdd/artifacts/<name>.v<version>.<format>"
  required: true
```

**The structural check IS the verdict gate.** When a schema encodes its accept/reject decision as
field invariants — a `review` schema whose `items[].verdict` must all be `pass` and whose overall
`verdict` must `eq: approve` — the Tier-1 structural check enforces that decision. It is mechanical
and trusted, so it is **`required: true`** like any structural check: a `reject`, or any failed item,
fails the gate and triggers rework. There is no separate judge-runner to wait on — the reviewer *is*
the judge, and its verdict is captured structurally and enforced deterministically.

### Tier 2 — `rules` → one deterministic command check each

A rule's check is `required: true` when its command is **trusted by construction**, and advisory
until eval'd only when you **hand-authored** a bespoke command. Trusted means: an `ai-sdd` engine
subcommand (`ai-sdd check` / `ai-sdd scope` / `ai-sdd cover`), verified by the engine's own
tests — not something to re-prove per repo. For each rule:

- **explicit `command`** → copy it verbatim; `required: <rule.severity == blocking>` (mechanical).
- **intent mapped to a trusted executor** → emit the mapped command **`required: true` immediately**
  (no eval gate — the executor is already verified). Known mappings:
  - `intent: "changed files ⊆ <plan>.files"` → `ai-sdd scope --plan .ai-sdd/artifacts/<plan>.v<ver>.<fmt> --repo .`
  - `intent: "review items ⊇ <plan>.acceptance"` → `ai-sdd cover --plan .ai-sdd/artifacts/<plan>.v<ver>.<fmt> --review .ai-sdd/artifacts/<name>.v<ver>.<fmt>`
- **intent with no trusted executor** (you hand-write a script) → emit it **`required: false`** and
  **eval-gate it** (below); promote to `required: true` only once it clears its eval. Write the
  smallest deterministic command that decides the rule, reading only the fields in `over:`.

### Tier 3 — `judge` → a judge check (carries its own validation contract)

For each judge item emit:
```yaml
metadata: { name: <name>.<judge.id> }
spec:
  checkKind: judge
  required: false        # advisory until its eval set proves it (see below)
  # rubric: "<judge.rubric>"   (and eval/threshold/samples from the schema, if present)
```

## Wire to the producer

Find the worker that `produces: <name>.vN` (read `.ai-sdd/pipeline.yaml` + `.ai-sdd/workers/`).
Append every generated check id to that worker's `checks: [...]`. Deterministic structural + Tier-2
checks attach as blocking; judge checks attach (advisory until eval'd).

## Eval-gate the authored gates (don't trust them blindly)

Two things are **trusted by construction** and ship `required: true` with no eval: the mechanical
checks (Tier-1 structural template, explicit-command rules) and any intent that maps to a **trusted
`ai-sdd` executor** (`ai-sdd check` / `ai-sdd scope` / `ai-sdd cover`) — those executors are
verified by the engine's own tests, so re-proving them per repo is redundant. What must prove itself
is anything you **hand-authored** — a bespoke (non-executor) Tier-2 command, or a Tier-3 judge:

- Keep fixtures under `.ai-sdd/evals/<check-id>/` with known-good and known-bad cases.
- The check must pass the good and fail the bad (for a judge: agree with the human labels above its
  `threshold`).
- Until such a gate clears its eval, leave it `required: false` (advisory). Promote it only when it
  does. (A trusted-executor intent like `ai-sdd scope` is **not** in this set — it is blocking now.)

## Freeze + regenerate intentionally

Commit the generated checks and the worker edits. Re-run this skill only when the schema changes;
mechanical output is stable, so a re-run should produce no diff unless the schema changed. Never
regenerate during a run.

## Worked example

`feature-plan.schema.yaml` (fields + a `plan-sound` judge) compiles to:
- `feature-plan.structure.check.yaml` — deterministic (`ai-sdd check …`), blocking.
- `feature-plan.plan-sound.check.yaml` — judge, advisory until eval'd.
…both wired onto the `architect` worker (it `produces: feature-plan.v1`).

`changeset.schema.yaml` (fields: summary, satisfies; rules: build, unit, diff-in-scope) compiles to:
- `changeset.structure.check.yaml` — deterministic (`ai-sdd check …`), blocking.
- `changeset.build.check.yaml` / `changeset.unit.check.yaml` — explicit commands, blocking.
- `changeset.diff-in-scope.check.yaml` — `ai-sdd scope --plan …feature-plan.v1.yaml --repo .`,
  **blocking** (trusted executor — no eval gate; this was the bug: scope was being left advisory).
…wired onto the `implementer` worker.

`review.schema.yaml` (fields encode the verdict; rule: coverage) compiles to:
- `review.structure.check.yaml` — deterministic (`ai-sdd check …`) — **this is the verdict gate**,
  blocking (a reject or any failed item fails it → rework).
- `review.coverage.check.yaml` — `ai-sdd cover --plan …feature-plan.v1.yaml --review …review.v1.yaml`,
  blocking (trusted executor): the review must judge every acceptance item.
…wired onto the `reviewer` worker. The reviewer is a real gate, not advisory notes.
