---
name: factory-run
description: Drive a software-factory run in interactive mode — the deterministic `factory` engine plans (next), you do each Worker's work via its skill, the engine gates and advances (submit). Use when asked to run, drive, continue, or advance a factory run / pipeline / orchestration in this repo, or when the user mentions `factory next` / `factory submit`.
---

# Driving a factory run (interactive / Mode B)

The `factory` engine is a **deterministic planner**. It decides what is runnable, runs the
gates, and advances state. **You do the work; you never decide control flow.** This is the
contract — obey it exactly:

- Always go through `factory next` → work → `factory submit`. Never skip either.
- Never choose which node to work on. Do exactly the node `next` renders.
- Never bypass a failing gate. A failed gate routes to rework; fix it and resubmit.
- Do exactly the rendered work for exactly the rendered node — nothing outside its scope.

## Setup (once)

```sh
swift build                      # binary lands at .build/debug/factory
```

Call `.build/debug/factory` directly (not `swift run`) so `--json` output is clean. If there
is no run yet, start one on a workspace directory (a folder with `pipeline.yaml`):

```sh
.build/debug/factory start <workspace-dir> --id <run-id>
```

## The loop

Repeat until the run is done:

### 1. Ask the engine what's next

```sh
.build/debug/factory next <run-id> --json
```

- `{"status":"done"}` → the run is complete. Stop and report.
- `{"status":"idle"}` → nothing runnable (waiting on a gate/input). Stop and report why.
- Otherwise you get a **Worker instruction** (JSON):

```jsonc
{
  "runId": "...", "slice": "foundation", "stack": "core",   // slice/stack present inside an orchestration run
  "node": "coder", "worker": "coder", "workerKind": "transform",
  "task": { "skill": "implement-change" },                  // OR "command": "/x"
  "model": "deep-reasoning", "reasoning": "high",
  "consumes": [ { "schema": "plan.v1", "required": true, "ready": true } ],
  "produces": [ "code.v1" ],
  "checks":  [ "typecheck", "lint", "unit" ],               // the gates submit will run
  "rework":  [ ]                                            // non-empty ⇒ fix these gates this attempt
}
```

### 2. Do the work via the named skill

Resolve `task.skill` to its instructions and follow them:

- **Example workspaces** resolve `task.skill: X` → `<workspace-dir>/skills/X.md`.
- **A real repo** resolves it to the repo skill of that name, surfaced via `AGENTS.md` /
  `CLAUDE.md` (ADR-0021).

Honor the `stack` (its conventions), read the `consumes` inputs, and produce every schema in
`produces`. If `rework` is non-empty, your previous attempt failed those gates — address them
specifically this time.

### 3. Submit

```sh
.build/debug/factory submit <run-id> --json
```

Add `--produced <schema> [<schema>…]` only if you produced a different set than the declared
`produces`. The outcome:

```jsonc
{ "node": "coder", "slice": "foundation", "advanced": true, "sliceCompleted": false,
  "produced": ["code.v1"], "checks": [ {"check":"unit","status":"passed","required":true} ],
  "failed": [], "runnable": ["foundation"] }
```

- `advanced: true` → the node was accepted; continue the loop.
- `advanced: false` → a required gate failed (`failed` lists which; `checks[].output` has the
  detail). Do **not** try to force it through — just loop: the next `next` re-renders this node
  with `rework` set. Fix and resubmit.
- `sliceCompleted: true` → that slice's whole sub-pipeline finished; its dependents unlock.

### 4. Go back to step 1.

## Reporting

When the run reaches `done`, summarize: which nodes/slices completed, any gates that needed
rework, and where the run ended. Use `.build/debug/factory status <run-id>` for the full
picture at any time.
