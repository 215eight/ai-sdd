# Milestones — validation flows that gate a program

> Companion to [decisions.md](decisions.md) (ADR-0028) and [mental-model.md](mental-model.md).

A **milestone** in ai-sdd is not a date or a label — it is a **validation node**: a flow with inputs
and outputs that *gates* the work after it. Because it is just a worker node, it composes into a program
graph like any other node, and the recursive engine schedules it by `depends_on` and blocks downstream
features until it passes (ADR-0028).

A milestone always has the same shape:

- **Inputs** — the upstream work it validates (the features whose completion it depends on).
- **Output** — a `validation-result.v1` artifact recording the verdict (`outcome: pass | fail`) and the
  per-criterion status. The schema lives at
  [.ai-sdd/schemas/validation-result.schema.yaml](../.ai-sdd/schemas/validation-result.schema.yaml).
- **Gate** — the deterministic `validation-result.structure` check: a `fail` outcome, or any failed
  criterion, fails the gate, so the milestone **re-validates** (self-rework) until it passes. It does
  not route rework upstream (a checkpoint has no single indictable input); the team fixes the work, then
  the gate re-runs. (Cross-feature rework routing is a possible future enhancement.) When the fix lands
  in an *already-completed* upstream feature, follow forward-only correction — append a downstream
  `<feature>-revert` node via the [ai-sdd-plan-program](../skills/ai-sdd-plan-program/SKILL.md) amend
  path rather than rewriting the finished feature — then let the milestone re-validate.

Only **one thing changes** between a manual and an automated milestone: `workerKind` and the checks.
Inputs and outputs stay identical, so a milestone can start manual and be automated in place as the
system matures — without touching the graph around it.

## Manual milestone (a person validates)

```yaml
# workers/milestone-gate.worker.yaml  (shipped in .ai-sdd/workers/)
spec:
  workerKind: human
  produces: [{ schema: validation-result.v1 }]
  task: { skill: validate-milestone }
  checks: [validation-result.structure]
```

Example: *Validate the server implementation.* A person brings a client, connects to the running system,
exercises the functionality, and records the verdict:

```yaml
# .ai-sdd/artifacts/validation-result.v1.yaml
milestone: m1-integration
outcome: pass
criteria:
  - { id: api-contract, status: pass }
  - { id: e2e-smoke,    status: pass }
evidence: "client session 2026-06-20; notes in PR #1234"
```

## Automated milestone (a process validates)

Same node, matured. Swap the kind and add a deterministic check that brings the system up and runs the
client, gated on exit code:

```yaml
# workers/milestone-gate.worker.yaml  (the automated variant)
spec:
  workerKind: transform
  produces: [{ schema: validation-result.v1 }]
  task: { skill: run-integration-suite }       # writes validation-result.v1 from the run
  checks: [validation-result.structure, m1.integration]
```

```yaml
# checks/m1.integration.check.yaml  (authored per milestone — the command is environment-specific)
spec:
  checkKind: deterministic
  command: "docker compose -f tests/integration/compose.yaml up --abort-on-container-exit && tests/integration/client.sh"
  required: true
```

Example: *Validate the server implementation.* A process launches Docker to bring the server up, spins a
client, runs the suite, and gates on exit code — no human in the loop. The `validation-result.v1` artifact
is still produced, so the audit trail and the program graph are unchanged.

## Wiring a milestone into a program

A milestone is a plain worker node sitting between feature (sub-pipeline) nodes; downstream features
depend on it, so they unlock only once it passes:

```yaml
# program/pipeline.yaml
spec:
  semantics: enabler
  nodes:
    - { id: featA, kind: pipeline, pipeline: ../feature, owner: [alice] }
    - { id: m1-integration, worker: milestone-gate, owner: [bob] }   # the milestone
    - { id: featB, kind: pipeline, pipeline: ../feature, owner: [carol] }
  edges:
    - { from: featA, to: m1-integration }   # validate after featA completes
    - { from: m1-integration, to: featB }   # featB waits on the milestone passing
```

See the worked, runnable example at
[docs/examples/program-milestone/](examples/program-milestone/).
