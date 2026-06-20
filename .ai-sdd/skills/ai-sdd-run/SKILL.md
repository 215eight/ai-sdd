---
name: ai-sdd-run
description: Drive a software-factory run by dispatching a sub-agent per worker — the deterministic `ai-sdd` engine plans (next), a fresh sub-agent does each worker's work via its skill, the engine gates and advances (submit), and each completed slice is committed. Agent-agnostic (claude-code or codex). Use when asked to run, drive, continue, or advance a factory run / pipeline / orchestration, or when the user mentions `ai-sdd next` / `ai-sdd submit`.
---

# Driving a factory run

The `ai-sdd` engine is a **deterministic planner**: it decides what's runnable, runs the gates,
and advances state. You **orchestrate** the loop and **dispatch a sub-agent to do each worker's
work** — you never decide control flow and never do the work inline. The contract:

- Always `next` → dispatch a sub-agent → `submit`. Never skip a step.
- Never choose the node, never bypass a failing gate, never touch files outside the rendered node's
  scope.
- The engine's **gate result** — not the sub-agent's say-so — decides pass/fail.

## Why a sub-agent per worker (the preferred dispatch)

Each worker is a bounded, typed, scoped unit (`consumes` → `produces`, write-scoped). Run it in its
**own sub-agent** so the heavy work (reading, reasoning, editing, rework) lives in that sub-agent's
context and only a **brief structured summary** returns — the driver session stays lean and a long
run won't deplete it. **Sub-agents are the preferred dispatch, over inline work or anything else.**

**Agent-agnostic:** dispatch via the host's sub-agent facility — Claude Code's sub-agent, Codex's
equivalent — whichever you're running under. A sub-agent **cannot see this conversation**, so pass
it everything explicitly (below). State flows through **artifacts + the run store, never the chat.**

## Setup

```sh
swift build                                          # → .build/debug/ai-sdd (call directly for clean --json)
.build/debug/ai-sdd start <workspace> --id <slug>   # if no run yet
```

**Start from a clean working tree** (everything committed). This is required — see *Scope
discipline*.

## The loop (repeat until done)

### 1. Ask the engine what's next
```sh
.build/debug/ai-sdd next <slug> --json
```
`{"status":"done"}` → stop, report. `{"status":"idle"}` → stop, report what it waits on. Otherwise a
Worker instruction: `slice`, `node`, `task.skill`, `consumes`, `produces`, `checks`, `rework`.

### 2. Dispatch a sub-agent to do the work
Spawn **one** sub-agent for this worker. Its **input** is everything it needs, explicitly:
- the rendered instruction — role, `slice`/`stack`, `consumes` inputs, `produces`, `checks`, and any
  `rework` failures to fix this attempt;
- its skill — `task.skill: X` → `<workspace>/skills/X.md` (or the repo skill of that name);
- its scope — it may write only the files this slice declares.

The sub-agent does the work and **writes each produced artifact to `.ai-sdd/artifacts/<schema>.<fmt>`**
(e.g. `feature-plan.v1` → `.ai-sdd/artifacts/feature-plan.v1.yaml` — the path the gates read).

It then returns a **brief structured summary** — enough for you to know what happened and carry the
run forward, *not* a transcript and *not* a yes/no. The shape (a handful of lines; omit a section
only if truly empty, but always state Caveats):

- **Outcome** — one line: what this worker accomplished.
- **Produced** — the artifact(s) / files written, with paths.
- **Decisions** — 2–4 notable choices made while doing the work (what a reader or the next worker
  needs to know — e.g. "used AsyncHTTPClient over URLSession", "modeled results as a child of race").
- **Caveats** — stubs, assumptions, deferrals, or **out-of-scope work discovered**; write `none` if
  there are none. (Discovered out-of-scope work is flagged here for a new slice — never fixed inline.)

That's the middle ground: skip the full reasoning, keep the context.

### 3. Log input + output (one ASCII block per invocation)
For **every** invocation, surface both — the **input** (the rendered instruction handed to the
sub-agent) and the **output** (its structured summary) — to the user as a single plain-ASCII block.
This is the run's observable trail (and the raw material for evals). Plain ASCII, nothing fancy: a
banner line identifying the work, then an `INPUT` section and an `OUTPUT` section.

```
================================================================
 SLICE <slice> · NODE <node> · WORKER <worker>   (rework round N, if any)
================================================================
--- INPUT ------------------------------------------------------
role / slice / stack · consumes (ready?) · produces · checks · rework (if any)
<the rendered instruction, verbatim enough to scan>
--- OUTPUT -----------------------------------------------------
Outcome:   <one line — what this worker accomplished>
Produced:  <artifact(s) / files written, with paths>
Decisions: <2–4 notable choices>
Caveats:   <none | stubs / assumptions / out-of-scope work discovered>
================================================================
```

Keep it scannable — a reader skims the banners to follow the run, and drops into a block's INPUT/
OUTPUT only when they want detail. If a **Caveat** flags out-of-scope work, note it for a plan
amendment (a new slice via `ai-sdd-plan`) — don't act on it now.

### 4. Submit
```sh
.build/debug/ai-sdd submit <slug> --json
```
- `advanced: true` → continue.
- `advanced: false` → a required gate failed (`failed` + `checks[].output`). Loop: the next `next`
  re-renders this node with `rework` set; dispatch a **fresh sub-agent with the failure context**,
  fix exactly that, resubmit. Never force a gate through.
- `sliceCompleted: true` → go to step 5.

### 5. Snapshot the slice's artifacts, then commit on slice completion
When `submit` reports `sliceCompleted: true`, first **snapshot the slice's produced artifacts** into
a committed per-slice directory, then **commit the slice's work** before starting the next.

The working artifacts live at `.ai-sdd/artifacts/<schema>.<fmt>` — a single fixed path the gates
read, **overwritten by the next slice**. So copy this slice's artifacts into a durable, browsable
per-slice home (under `.ai-sdd/features/<slug>/`, which is committed — only `runs/` and `artifacts/`
are gitignored):

```sh
DEST=.ai-sdd/features/<slug>/slices/<slice>
mkdir -p "$DEST"
cp .ai-sdd/artifacts/plan.v1.yaml   "$DEST"/      # each artifact this slice produced …
cp .ai-sdd/artifacts/review.v1.yaml "$DEST"/      # … (plan, review, changeset, …)
git add -A && git commit -m "[<slug>] <slice>: <one-line summary>"   # or the repo's commit convention
```

The gates still read the working path (`.ai-sdd/artifacts/`); the per-slice copy is the **durable
record** — every slice's plan and review stay inspectable in the tree, committed with the slice,
without git archaeology. One commit per slice — reviewable history, **and** it resets the baseline
(next section).

### 6. Back to step 1.

## Scope discipline (a clean baseline per slice)

The `diff-in-scope` gate compares the working tree against the **last commit** — so it only enforces
scope when each slice starts from a **clean tree**:

- **Commit after every slice** (step 5) → the next slice diffs against that commit → its gate sees
  **only that slice's changes**, and out-of-scope files are actually caught.
- **Never start a slice on another slice's uncommitted changes.** If the tree is dirty when a new
  slice begins (a prior slice wasn't committed), **STOP and report it** — in that state the scope
  gate is blind and changes leak across slices. (This is the failure to avoid: no commits → dirty
  tree → scope never enforced.)
- `.ai-sdd/runs/` and `.ai-sdd/artifacts/` are gitignored, so the architect's plan artifact never
  dirties the tracked tree — only real code changes do.

## Reporting

At `done`, summarize per slice from the logged input/output: what each worker produced, which gates
needed rework (and whether any escalated to a human), and the commit made. Each slice's plan and
review are browsable at `.ai-sdd/features/<slug>/slices/<slice>/`. `.build/debug/ai-sdd status
<slug>` shows the nested state any time.
