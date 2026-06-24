# Slice: name-resolver-self-start (S3)

## Delivers
One shared name resolver used by `next`, `submit`, and `status`, plus self-start so a run never has to
be created by hand. Given `<name>`, resolve in order: (1) existing `runId`; (2) a feature dir
`.ai-sdd/features/<name>/` → start a run `runId=<name>` then advance; (3) a slice name appearing in
exactly one feature's `pipeline.yaml` slice list → start that feature's run (`runId=<feature>`) then
advance; (4) a slice in multiple features → `{"error":"ambiguous","candidates":[…]}`, exit non-zero;
(5) no match → `{"error":"unknown"}`, exit non-zero. The resolver lives in the engine, not the CLI
shim, and is the single lookup path for all three verbs.

## Why
Most users only ever touch `/ai-sdd-run <name>` and forget the explicit `start`; agents bypass it
entirely. Self-start makes the engine forgiving so any `next` lands in a valid state, killing the
"never started, so the journal stays empty" divergence.

## Acceptance
- `next <feature>` with no run starts the run and returns the first worker instruction.
- `next <slice>` where the slice name is unique across features does the same (resolves to its feature).
- Ambiguous slice → structured `ambiguous` with the candidate list, non-zero exit.
- Unknown name → structured `unknown`, non-zero exit.
- `submit` and `status` use the same resolver (a feature/slice/runId name works on all three).
- `start <name>` remains an explicit verb — a no-op alias when a matching run already exists.
- Resolver is unit-tested without I/O across all five branches.
- `swift build` + `swift test` green.

## Notes
Foundational for S5 (skill rewrite relies on `next` self-starting) and S6 (the hook's error tells the
user to `ai-sdd submit`, which auto-starts via this resolver).
