---
name: ai-sdd-plan
description: Turn a complete feature brief into a runnable plan for a bootstrapped repo — a decision-closed requirements doc and an orchestration graph (slices + depends_on) the engine executes. Requires a real brief (refuses a bare one-liner — asks for one) and human approval of the requirements draft before generating slices. The planning layer between an idea and ai-sdd-run. Use when starting a new feature in a repo that already has a .ai-sdd/ (run ai-sdd-bootstrap first).
---

# Planning a feature

Turn a brief into the two things the engine needs to build it: **requirements** (what & why,
decision-closed) and an **orchestration graph** (the slices and their dependencies). This is the
bridge between an idea and `ai-sdd-run`. Prereq: the repo is bootstrapped (`.ai-sdd/` exists).

Per-feature output layout:

```
.ai-sdd/features/<slug>/
  requirements.md     the master requirements — scope, acceptance, closed decisions
  pipeline.yaml       the orchestration graph: slices (kind: pipeline) wired by depends_on
  slices/<id>.md      each slice's brief — the intake its architect plans from
```

## 1. Require a real brief — never invent scope

Planning starts from a **complete brief**, not a one-liner. Complete = it states the **goal**,
**in-scope / out-of-scope**, the **acceptance bar**, and **constraints**. If the input is a one-liner
or missing any of these, **STOP and get a real brief** — ask the user for one (point them at the
template below) or co-author it *with them, interactively*. **Do not synthesize the scope and
decisions on the user's behalf and proceed.** Scoping an idea from a one-liner guarantees
misinterpretation, and a wrong line in the plan becomes hundreds of wrong lines of code. This is a
hard gate **even for an autonomous agent**: producing a plan from an underspecified brief is a
failure, not a convenience.

Brief template (what "complete" means):

```md
# <feature>
## Goal — one paragraph: the behavior/outcome.
## In scope / Out of scope — explicit lists.
## Acceptance — the verifiable bar (each item testable).
## Constraints — stack/conventions/non-negotiables.
## Milestones (optional) — phase the slices into checkpoints: each an id, what it validates, manual | automated, owner.
## Open questions — anything unresolved (closed WITH the user in Step 2).
```

## 2. Draft requirements — then STOP for human approval

From the brief, write `requirements.md` as a **draft**: goal, in/out scope, acceptance, constraints,
and a **Decisions** list. For each open question, propose a resolution and mark it `proposed` (not
`closed`). Then **STOP and present the draft for explicit human approval** — list every decision you
propose to close and ask the user to confirm or change each.

**Do not proceed to slices (Step 3) until the human has approved `requirements.md` in this session.**
This is the planning gate: the human approves the *plan* (cheap to fix) before any slices or code
(expensive to fix) — *review the plan, not the diff*. Only approved decisions become `closed`;
repeatability depends on a closed, human-confirmed input.

> Enforcement note: today this gate is skill-level (the agent must honor it) — no engine mechanism
> blocks slice generation on approval yet. Treat the STOP as mandatory regardless of how autonomous
> the host agent is.

## 3. Decompose into slices  *(only after the human approved requirements.md)*

Break the feature into the smallest independently-buildable work items (slices). For each:
- an **id** + a one-paragraph **brief** (what it delivers + its acceptance) → `slices/<id>.md`;
- its **stack** (which conventions apply);
- its **depends_on** (which slices must finish first). Keep it acyclic — the engine enforces it.

Prefer thin slices: each is one coherent plan→implement→review cycle. Too big → split. Discovered
out-of-scope work becomes a *new* slice (a graph amendment), never an inline change.

## 4. Emit the orchestration graph

Write `pipeline.yaml` — slice nodes that descend into the repo's per-slice build pattern
(`.ai-sdd/`), wired by `depends_on` edges (no artifact):

```yaml
apiVersion: ai-sdd/v1
kind: Pipeline
metadata: { name: <slug>, version: 1 }
spec:
  semantics: enabler
  nodes:
    - { id: <slice-a>, kind: pipeline, pipeline: ../.., stack: <stack> }
    - { id: <slice-b>, kind: pipeline, pipeline: ../.., stack: <stack> }
  edges:
    - { from: <slice-a>, to: <slice-b> }     # depends_on: b needs a
```

`pipeline: ../..` resolves from `.ai-sdd/features/<slug>/` back to `.ai-sdd/` — the
architect → implementer → reviewer pattern with its workers, checks, and skills.

## 4b. Optional: milestones (slice phases)

If the brief has a `## Milestones` section, phase the slices into validation checkpoints. A milestone is
a validation node (manual or automated) that depends on all the slices in its phase; the next phase's
slices depend on the milestone — so a phase can't proceed until its checkpoint passes. This is the same
milestone primitive the program tier uses (ADR-0028), one level down.

For each milestone:
- assign the phase's slices to it;
- add a node `{ id: <milestone>, worker: milestone-gate, owner: [<owner>] }`;
- add edges from every slice in the phase → the milestone, and from the milestone → each slice of the
  next phase.

Because the feature graph now has a worker node, the feature dir needs the milestone convention loaded
relative to it — copy in `workers/milestone-gate.worker.yaml` (← `.ai-sdd/workers/…`) and
`checks/validation-result.structure.check.yaml` (← `.ai-sdd/checks/…`). For an **automated** milestone,
add the `transform` worker variant + a per-milestone deterministic check (e.g. `docker compose up …`)
per [docs/milestones.md](../../docs/milestones.md); manual ↔ automated swaps only the node's kind/checks.

```yaml
  nodes:
    - { id: schema, kind: pipeline, pipeline: ../.., stack: core }
    - { id: api,    kind: pipeline, pipeline: ../.., stack: api-go }
    - { id: m1-integration, worker: milestone-gate, owner: [bob] }   # phase-1 checkpoint
    - { id: ui,     kind: pipeline, pipeline: ../.., stack: web }
  edges:
    - { from: schema, to: api }
    - { from: schema, to: m1-integration }
    - { from: api,    to: m1-integration }
    - { from: m1-integration, to: ui }   # phase-2 slice waits on the checkpoint
```

## 5. Validate

```sh
ai-sdd validate .ai-sdd/features/<slug>
```

Referential + acyclicity must pass. Fix and re-emit until clean.

## Then: execute

Hand off to **ai-sdd-run** (start the run id == the slug so slice briefs resolve):

```sh
ai-sdd start .ai-sdd/features/<slug> --id <slug>
/ai-sdd-run <slug>
```

The engine schedules slices by `depends_on`; each descends into plan→implement→review with the
gates the schemas compiled. Rework loops on a failed gate; when every slice completes, the feature
is done. Each slice's **architect** plans from its brief — read `slices/<slice>.md` for the slice
the engine renders (the instruction carries the slice id; the run id is the feature slug).

## Amending the plan

When a slice surfaces out-of-scope work, add a new slice (brief + `depends_on`) and re-validate —
the graph is amendable and stays acyclic. Don't fold it into the current slice.

## Honest edges (first iteration)

- **Per-slice intake is by convention** — the architect reads `slices/<id>.md` by path; the engine
  doesn't yet feed it as a typed artifact.
- Requirements/briefs are **markdown** today; a structured, gated `requirements.v1` schema is later.
- The orchestration graph is hand-emitted here by the planning agent; the engine only **validates +
  executes** it (it never infers topology — architecture §5).
