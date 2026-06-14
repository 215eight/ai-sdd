---
name: factory-plan
description: Turn a feature brief into a runnable plan for a bootstrapped repo — a decision-closed requirements doc and an orchestration graph (slices + depends_on) the engine executes. The planning layer between an idea and factory-run. Use when starting a new feature in a repo that already has a .factory/ (run factory-bootstrap first).
---

# Planning a feature

Turn a brief into the two things the engine needs to build it: **requirements** (what & why,
decision-closed) and an **orchestration graph** (the slices and their dependencies). This is the
bridge between an idea and `factory-run`. Prereq: the repo is bootstrapped (`.factory/` exists).

Per-feature output layout:

```
.factory/features/<slug>/
  requirements.md     the master requirements — scope, acceptance, closed decisions
  pipeline.yaml       the orchestration graph: slices (kind: pipeline) wired by depends_on
  slices/<id>.md      each slice's brief — the intake its architect plans from
```

## 1. Draft requirements (decision-closed)

Work with the user from the brief. Capture: the **goal**, **in-scope / out-of-scope**, the
**acceptance bar** (how we'll know it's done), and constraints. **Drive out ambiguity** — list the
open questions, resolve them *with the user*, and record them as closed decisions. Do not proceed
with open decisions; repeatability depends on a closed input. Write `requirements.md`.

## 2. Decompose into slices

Break the feature into the smallest independently-buildable work items (slices). For each:
- an **id** + a one-paragraph **brief** (what it delivers + its acceptance) → `slices/<id>.md`;
- its **stack** (which conventions apply);
- its **depends_on** (which slices must finish first). Keep it acyclic — the engine enforces it.

Prefer thin slices: each is one coherent plan→implement→review cycle. Too big → split. Discovered
out-of-scope work becomes a *new* slice (a graph amendment), never an inline change.

## 3. Emit the orchestration graph

Write `pipeline.yaml` — slice nodes that descend into the repo's per-slice build pattern
(`.factory/`), wired by `depends_on` edges (no artifact):

```yaml
apiVersion: factory/v1
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

`pipeline: ../..` resolves from `.factory/features/<slug>/` back to `.factory/` — the
architect → implementer → reviewer pattern with its workers, checks, and skills.

## 4. Validate

```sh
factory validate .factory/features/<slug>
```

Referential + acyclicity must pass. Fix and re-emit until clean.

## Then: execute

Hand off to **factory-run** (start the run id == the slug so slice briefs resolve):

```sh
factory start .factory/features/<slug> --id <slug>
/factory-run <slug>
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
