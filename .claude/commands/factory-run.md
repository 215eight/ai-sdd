---
description: Drive a software-factory run in interactive mode (next → work → submit, until done).
argument-hint: <run-id> [workspace-dir]
---

Drive a factory run to completion using the **factory-run** skill (`.claude/skills/factory-run/`).

Arguments: `$ARGUMENTS` — the run id, optionally followed by a workspace directory to `start`
first if the run does not exist yet.

Follow the skill exactly: the engine owns control flow (`next` picks the node and renders it,
`submit` gates and advances); you only do each Worker's work via its skill. Loop until the run
reports `done`, then report what completed and any gates that needed rework.
