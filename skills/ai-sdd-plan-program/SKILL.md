---
name: ai-sdd-plan-program
description: Turn a complete PROGRAM brief into a runnable master plan — a decision-closed program requirements doc and a master orchestration graph whose nodes are whole sub-features (kind:pipeline) sequenced by milestone validation gates with owners. The program tier above ai-sdd-plan. Requires a real program brief (refuses a one-liner) and human approval of the program requirements draft before emitting the graph. Use when planning a multi-feature, multi-person project in a bootstrapped repo (run ai-sdd-bootstrap first); each sub-feature is then planned with ai-sdd-plan.
---

# Planning a program

A **program** sequences several sub-features with **milestones and owners** in one master graph. It is
the tier above a single feature: where `ai-sdd-plan` turns one brief into a slice graph, this turns a
program brief into a graph whose nodes are whole **features** (each its own slice graph) with
**milestone validation gates** between them. The model is self-similar (ADR-0028) — the same engine
descends `program → feature → slice → worker` through one `next`/`submit` loop, so a milestone gate at
the program tier blocks downstream features exactly the way a gate blocks downstream slices.

This is **not** the Conductor (cross-domain saga). It is recursive Pipeline composition — same engine,
same gates. Prereq: the repo is bootstrapped (`.ai-sdd/` exists).

Program output layout:

```
.ai-sdd/programs/<program-slug>/
  requirements.md     program goal, sub-features (+ owners), milestones, sequencing, closed decisions
  pipeline.yaml       the MASTER graph: feature nodes (kind: pipeline) + milestone nodes, wired by edges
  workers/            milestone-gate.worker.yaml (+ any automated milestone variants)
  checks/             validation-result.structure.check.yaml (+ any per-milestone integration checks)
```

Each sub-feature lives where it always does — `.ai-sdd/features/<feature>/` — planned separately with
`ai-sdd-plan`.

## 1. Require a real program brief — never invent scope

Planning starts from a **complete program brief**, not a one-liner. Complete = it states the **goal**,
the **sub-features** (the decomposition unit, each with an owner/lead), the **milestones** (the
validation checkpoints between sub-features), the **sequencing** (what depends on what), and shared
**constraints**. If the input is missing any of these, **STOP and get a real brief** — ask the user or
co-author it *with them, interactively*. **Do not synthesize the sub-features, owners, milestones, or
sequencing on the user's behalf and proceed.** A wrong line in a program plan becomes a wrong feature.
This is a hard gate **even for an autonomous agent**.

Program brief template (what "complete" means):

```md
# Program: <name>
## Goal — one paragraph: the program outcome.
## Sub-features — each becomes its own feature plan. For each: id (slug), one-line goal, owner/lead.
## Milestones — validation checkpoints between sub-features. For each: id, what it validates,
   manual | automated, owner, and which sub-features it gates (depends_on / unblocks).
## Sequencing — the master dependencies (feature → milestone → feature).
## Constraints — stack/conventions/non-negotiables shared across sub-features.
## Open questions — anything unresolved (closed WITH the human in Step 2).
```

## 2. Draft program requirements — then STOP for human approval

From the brief, write `requirements.md` as a **draft**: goal, the sub-feature list (with owners), the
milestones (with owners + manual/automated + what each gates), the sequencing, shared constraints, and a
**Decisions** list. For each open question, propose a resolution and mark it `proposed` (not `closed`).
Then **STOP and present the draft for explicit human approval** — list every decision you propose to
close (especially the milestone boundaries, the manual-vs-automated call per milestone, and the owners)
and ask the user to confirm or change each.

**Do not emit the master graph (Step 3) until the human has approved `requirements.md` in this session.**
This is the planning gate: the human approves the *plan* (cheap to fix) before any features or code
(expensive to fix). Only approved decisions become `closed`.

> Enforcement note: this gate is skill-level today (no engine mechanism blocks emission on approval).
> Treat the STOP as mandatory regardless of how autonomous the host agent is.

## 3. Emit the master graph  *(only after the human approved requirements.md)*

Write `.ai-sdd/programs/<program-slug>/pipeline.yaml`. Nodes are **feature** sub-pipelines and
**milestone** validation nodes; edges are the sequencing. Carry `owner` on every node.

```yaml
apiVersion: ai-sdd/v1
kind: Pipeline
metadata: { name: <program-slug>, version: 1 }
spec:
  semantics: enabler
  nodes:
    - { id: <feature-a>, kind: pipeline, pipeline: ../../features/<feature-a>, owner: [<lead>] }
    - { id: <milestone-1>, worker: milestone-gate, owner: [<owner>] }
    - { id: <feature-b>, kind: pipeline, pipeline: ../../features/<feature-b>, owner: [<lead>] }
  edges:
    - { from: <feature-a>, to: <milestone-1> }    # validate after feature-a completes
    - { from: <milestone-1>, to: <feature-b> }    # feature-b waits on the milestone passing
```

`pipeline: ../../features/<feature>` resolves from `.ai-sdd/programs/<slug>/` to the feature's own
graph; the engine descends into it (and into its build pattern) recursively.

**Wire the milestone convention.** A milestone node runs a worker, so the program dir needs its worker +
check (loaded relative to the pipeline dir). Copy the templates in:

- `workers/milestone-gate.worker.yaml` ← `.ai-sdd/workers/milestone-gate.worker.yaml` (manual, `human`).
- `checks/validation-result.structure.check.yaml` ← `.ai-sdd/checks/…` (the verdict gate).

For a milestone the brief marked **automated**, follow [docs/milestones.md](../../docs/milestones.md):
add a `workers/<milestone>.worker.yaml` (a `transform` variant) and a per-milestone
`checks/<milestone>.integration.check.yaml` (the deterministic command, e.g. `docker compose up …`),
and reference both from that node. Manual ↔ automated changes only the node's `workerKind`/checks — the
inputs and outputs (`validation-result.v1`) are unchanged, so a milestone can start manual and be
automated in place.

## 4. Plan each sub-feature

For every sub-feature node, produce its feature plan with **`ai-sdd-plan`** (its own brief →
`.ai-sdd/features/<feature>/`). A sub-feature may itself use the optional `## Milestones` section of
`ai-sdd-plan` to phase its own slices — milestones compose at both tiers.

## 5. Validate

```sh
ai-sdd validate .ai-sdd/programs/<program-slug>
ai-sdd validate .ai-sdd/features/<each-feature>
```

Referential integrity + acyclicity must pass at every level. `ai-sdd graph .ai-sdd/programs/<slug>`
renders the master graph to eyeball the sequencing and owners.

## Then: execute

```sh
ai-sdd start .ai-sdd/programs/<program-slug> --id <program-slug>
/ai-sdd-run <program-slug>
```

The engine descends recursively: it schedules a feature when its program-tier dependencies (upstream
features + milestones) are complete, runs that feature's slices through plan→implement→review, and on
a milestone node runs the validation gate — blocking the downstream features until it passes. When every
node in the master graph completes, the program is done. See the worked shape at
[docs/examples/program-milestone/](../../docs/examples/program-milestone/).

## Honest edges (first iteration)

- **Program requirements are markdown** (like feature requirements); a structured, gated schema is later.
- **The master graph is hand-emitted here** by the planner; the engine only validates + executes it
  (it never infers topology — architecture §5).
- **Milestone workers/checks are copied into the program dir by convention** (loaded relative to the
  pipeline). A shared/inherited worker library across tiers is a later refinement.
- **A failed milestone self-reworks** (re-validate) — it does not yet route rework into the specific
  upstream feature that fell short (cross-feature routing is future work; see ADR-0028).
