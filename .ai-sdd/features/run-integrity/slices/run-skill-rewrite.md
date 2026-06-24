# Slice: run-skill-rewrite (S5 — depends on S3)

## Delivers
Rewrite `skills/ai-sdd-run/SKILL.md` into the status-driven loop. Every invocation: `ai-sdd status
<name> --json` → `next` → dispatch sub-agent → `submit` → re-read `status`. The skill declares "done"
only when `status` returns `{"status":"done"}`; on `{"status":"idle"}` it stops and reports exactly
what the engine says it waits on. The skill never tracks slice progress in its own head — the engine's
ledger is the single source of truth. Name-resolution `ambiguous` errors are surfaced verbatim with
the candidate list. Remove all "if no run yet" caveats, the manual `start` step, and any separate
slice-name handling (S3's self-start + resolver make them unnecessary).

## Why
The skill currently leaves "start the run if missing" to the agent's judgment and trusts its own sense
of progress — the two habits that let agents finish work the journal never recorded. Verifying against
the engine closes the "agent thought it finished but the journal disagrees" class of bug.

## Acceptance
- `SKILL.md` drives `status → next → sub-agent → submit → re-status`, declaring done only when the
  engine says so; idle reported with the engine's wait reason.
- No `start` step and no "if no run yet" / slice-name-special-case text remains.
- Ambiguity errors are surfaced verbatim to the user.

## Notes
**Scope-gate caveat (D4):** `skills/ai-sdd-run/SKILL.md` is committed and declarable, but its surfacing
into per-agent dirs (`.claude/skills`, `.agents/skills`) runs post-gate via `ai-sdd surface` — a manual
step after this slice's gated commit. No engine/CLI code changes here; this slice is documentation.
