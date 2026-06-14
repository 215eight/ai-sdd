---
name: factory-compile-schema
description: Compile a factory Schema (.factory/schemas/*.schema.yaml) into the deterministic CheckSpecs the engine runs, and wire them onto the worker that produces that schema. Bootstrap-time authoring — the output is committed and frozen, not regenerated per run. Use when a schema is added or changed, or while bootstrapping a repo's factory.
---

# Compiling a Schema into gates

A Schema describes an artifact; this skill turns that description into the gates the engine runs.
The principle: **you author the checks once, at bootstrap; the engine executes them deterministically
on every run.** Generated checks are committed and reviewed — never regenerated mid-run (that would
break reproducibility).

Input:  `.factory/schemas/<name>.schema.yaml`
Output: `.factory/checks/<name>.<id>.check.yaml` (one per gate) + the ids added to the worker that
        `produces: <name>.vN`.

## Artifact-location convention (interim)

Until a real artifact store exists, a produced artifact lives at a stable, gitignored path:

```
.factory/artifacts/<name>.v<version>.<format>     # e.g. .factory/artifacts/feature-plan.v1.yaml
```

The producing worker's skill writes there; compiled checks read from there. (`.factory/artifacts/`
and `.factory/runs/` are gitignored; the rest of `.factory/` is committed.)

## Compile each tier

Read the schema's `fields`, `rules`, and `judge`. Emit checks tier by tier.

### Tier 1 — `fields` → one deterministic structural check (mechanical)

If the schema has any `fields`, emit exactly one check that runs the validator. This is a fixed
template — no judgement:

```yaml
# .factory/checks/<name>.structure.check.yaml
apiVersion: factory/v1
kind: Check
metadata: { name: <name>.structure }
spec:
  checkKind: deterministic
  command: "factory check .factory/schemas/<name>.schema.yaml .factory/artifacts/<name>.v<version>.<format>"
  required: true
```

### Tier 2 — `rules` → one deterministic command check each

For each rule:
- **explicit `command`** → copy it verbatim into a check (mechanical):
  ```yaml
  metadata: { name: <name>.<rule.id> }
  spec: { checkKind: deterministic, command: "<rule.command>", required: <rule.severity == blocking> }
  ```
- **intent-based** (no `command`) → author the command. Map known intents to known executors;
  only hand-write a script when none fits, and then **eval-gate it** (below). Known mapping:
  - `intent: "changed files ⊆ <plan>.files"` → `command: "factory scope --plan .factory/artifacts/<plan>.v<ver>.<fmt> --repo ."`
  - else: write the smallest deterministic command that decides the rule, reading only the fields
    in `over:`; prefer existing tools over bespoke scripts.

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

Find the worker that `produces: <name>.vN` (read `.factory/pipeline.yaml` + `.factory/workers/`).
Append every generated check id to that worker's `checks: [...]`. Deterministic structural + Tier-2
checks attach as blocking; judge checks attach (advisory until eval'd).

## Eval-gate the authored gates (don't trust them blindly)

The mechanical checks (Tier-1 template, explicit-command rules) are trusted by construction. Any
gate you *authored* — an intent-based Tier-2 command or a Tier-3 judge — must prove itself before
it's promoted to `required: true`:

- Keep fixtures under `.factory/evals/<check-id>/` with known-good and known-bad cases.
- The check must pass the good and fail the bad (for a judge: agree with the human labels above its
  `threshold`). A scope check's bad fixture is "an undeclared file was touched — does it fail?"
- Until a gate clears its eval, leave it `required: false` (advisory). Promote it only when it does.

## Freeze + regenerate intentionally

Commit the generated checks and the worker edits. Re-run this skill only when the schema changes;
mechanical output is stable, so a re-run should produce no diff unless the schema changed. Never
regenerate during a run.

## Worked example

`feature-plan.schema.yaml` (fields + a `plan-sound` judge) compiles to:
- `feature-plan.structure.check.yaml` — deterministic (`factory check …`), blocking.
- `feature-plan.plan-sound.check.yaml` — judge, advisory until eval'd.
…both wired onto the `architect` worker (it `produces: feature-plan.v1`).

`changeset.schema.yaml` (rules: build, unit, diff-in-scope; judge: review) compiles to:
- `changeset.build.check.yaml` / `changeset.unit.check.yaml` — explicit commands, blocking.
- `changeset.diff-in-scope.check.yaml` — `factory scope --plan …feature-plan.v1.yaml --repo .`, blocking after eval.
- `changeset.review.check.yaml` — judge, advisory until eval'd.
…wired onto the `implementer` worker.
