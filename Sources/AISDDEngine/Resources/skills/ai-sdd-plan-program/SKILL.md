---
name: ai-sdd-plan-program
description: Turn a complete PROGRAM brief into a runnable master plan — a decision-closed program requirements doc and a master orchestration graph whose nodes are whole sub-features (kind:pipeline) sequenced by milestone validation gates with owners. The program tier above ai-sdd-plan. Requires a real program brief (refuses a one-liner) and human approval of the program requirements draft before emitting the graph. Use when planning a multi-feature, multi-person project in a bootstrapped repo (run ai-sdd-bootstrap first); each sub-feature is then planned with ai-sdd-plan. Re-run on an existing program to amend it in place (create-vs-amend is auto-detected from disk): append sub-features/milestones and rewire pending nodes; a started node (completed or in-flight) is immutable and corrected forward with a downstream `<node>-revert` node.
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

## 0. Create or amend? — detect from disk

Before anything else, check whether `.ai-sdd/programs/<program-slug>/` already has `requirements.md`
**and** `pipeline.yaml`:

- **Neither exists → create.** Follow Steps 1–5 below.
- **Both exist → amend.** Skip to [Amending an existing program](#amending-an-existing-program) — do
  **not** restate the whole program brief or regenerate the graph.

Mode is inferred from the artifacts on disk; the user runs the same command either way and never
declares which mode they're in — fewer commands to remember.

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

## Amending an existing program

Re-running this skill on a program that already has artifacts **amends** it — the same command, no
separate verb. Planning is idempotent: the artifacts live on disk and the engine re-reads the graph on
every `ai-sdd next`, so an amendment to a running program is picked up automatically (no restart).

The governing rule is **forward-only correction**: amendment may freely add and rewire **pending**
nodes, but a node that has **started — completed or in-flight — is immutable**. You never rewrite
history; you append a correction to it.

### A1. Require a complete description of the *change* — not a new program brief

The Step 1 brief gate is delta-scoped here. Do **not** demand a full program brief again; require a
complete description of the change, and refuse a one-liner with the same rigor (no inventing scope,
owners, or sequencing on the user's behalf):

```md
## Change — what's being added or resequenced, and why (one paragraph).
## New sub-features (if any) — for each: id (slug), one-line goal, owner/lead.
## New milestones (if any) — for each: id, what it validates, manual | automated, owner, what it gates.
## Rewiring — which existing edges change; which nodes the new work depends on / unblocks.
## Open questions — anything the change leaves unresolved (closed WITH the human in A3).
```

### A2. Reconcile against run state — refuse touching a started node

Read the existing `pipeline.yaml`, then run `ai-sdd status <program-slug>` to learn each node's state.
Classify every node the change touches:

- **Appends a new node, or edits/rewires a node that is still `pending`** → proceed.
- **Touches a node that has started — `completed` or in-flight (running / mid-rework)** → **STOP and
  refuse.** Its work is committed; the plan must not change under it. Recommend the forward-only fix: a
  new node named `<node>-revert` that `depends_on: [<node>]` and undoes or adjusts what it produced
  (plus any milestone that should re-validate afterward). A `<node>-revert` node is an ordinary
  feature/milestone node — the engine schedules it by readiness with no special mechanism.

> Started ≡ immutable. **In-flight is treated exactly like completed** — both have committed work, so
> both refuse. Only nodes the engine has not yet scheduled (`pending`) are editable in place.

### A3. Approve the delta — keep closed decisions closed

Read the existing `requirements.md`. Every decision already `closed` **stays closed** — do not reopen
the program. Draft only the decisions the change introduces (new sub-feature boundaries, new milestone
manual/automated calls, new owners, rewiring), mark them `proposed`, and **STOP for human approval over
the delta only** — same skill-level gate as Step 2, mandatory regardless of autonomy.

### A4. Apply the amendment

After approval, **edit `pipeline.yaml` in place** — append the new feature/milestone nodes and the
approved edges, adjust only `pending`-node wiring, and carry `owner` on every new node. **Append** the
newly-closed decisions to `requirements.md` (don't rewrite the existing record). If you added a
milestone node, wire its `workers/` + `checks/` exactly as Step 3 describes.

### A5. Validate — same gate as create

```sh
ai-sdd validate .ai-sdd/programs/<program-slug>
ai-sdd validate .ai-sdd/features/<each-new-feature>
```

Referential integrity + acyclicity must pass. A running program picks up the amendment on the next
`ai-sdd next`; `ai-sdd graph .ai-sdd/programs/<slug>` renders the new sequencing to eyeball it.

## Honest edges (first iteration)

- **Program requirements are markdown** (like feature requirements); a structured, gated schema is later.
- **The master graph is hand-emitted here** by the planner; the engine only validates + executes it
  (it never infers topology — architecture §5).
- **Milestone workers/checks are copied into the program dir by convention** (loaded relative to the
  pipeline). A shared/inherited worker library across tiers is a later refinement.
- **A failed milestone self-reworks** (re-validate) — it does not yet route rework into the specific
  upstream feature that fell short (cross-feature routing is future work; see ADR-0028).
- **Amendment is forward-only** — a started node (completed or in-flight) is immutable; its outcome is
  changed by a downstream `<node>-revert` node, never by rewriting it. The started/pending boundary is
  read from `ai-sdd status` — a skill-level check; no engine mechanism enforces immutability yet.
