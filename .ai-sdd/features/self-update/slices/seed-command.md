# Slice: seed-command

**Phase:** m1 (distribution foundation) · **Stack:** swift · **Depends on:** embedded-skills, tag-derived-version

## Delivers
`ai-sdd seed` — the binary-native successor to `scripts/bootstrap.sh`. It reconciles a repo entirely
**from the binary** (no clone), idempotently. It materializes the framework into the target repo and
installs every surface the framework needs.

`ai-sdd seed [TARGET]` (default: cwd) performs, idempotently:
1. Write framework skills → `.ai-sdd/skills/<skill>/` from the embedded accessor; link
   `.agents/skills/<skill>` and `.claude/skills/<skill>` → the in-repo copy (clean refresh; drop
   removed files; never clobber non-managed entries).
2. Write the pre-commit hook source → `.ai-sdd/hooks/pre-commit`, and install/refresh
   `.git/hooks/pre-commit` (chain a foreign hook exactly once via the existing managed-hook marker).
3. Install **SessionStart hooks for both agents**, each running `ai-sdd update --check`:
   `.claude/settings.json` (Claude) and `.codex/hooks.json` (Codex, `matcher: "startup|resume"`).
   Idempotent: merge into existing config, don't duplicate, don't clobber unrelated keys.
4. Write `.ai-sdd/VERSION` = the running binary's release version (the `.ai-sdd/VERSION` stamp).
5. Update onboarding docs that referenced `scripts/bootstrap.sh` to `ai-sdd seed` (QUICKSTART.md /
   README.md — repo-root markdown, factory-declarable).

## Acceptance
- On a fresh repo with **no ai-sdd clone on disk**, `ai-sdd seed` reproduces what `bootstrap.sh` did
  (vendored skills + `.agents`/`.claude` links + chained pre-commit hook) **plus** both SessionStart
  hooks and `.ai-sdd/VERSION`.
- Re-running `ai-sdd seed` is a no-op-shaped refresh: skills refreshed, links/hook/config not
  duplicated, a foreign pre-commit hook chained exactly once.
- The installed `.codex/hooks.json` and `.claude/settings.json` each invoke `ai-sdd update --check` at
  session start; JSON shape matches each tool's schema (Codex hooks.json per its docs; Claude
  settings.json).
- Tests over a temp-dir fixture (not the real repo): seed writes the four artifact groups; a second seed
  doesn't duplicate; a pre-existing foreign pre-commit hook is preserved (chained once).
- `swift build` / `swift test` / `swift run ai-sdd validate .ai-sdd` green.

## Notes
- The actual **deletion of `scripts/bootstrap.sh`** is on the manual checklist (outside factory scope);
  this slice makes `ai-sdd seed` the working replacement and updates the docs that point at it.
- `update-apply` re-invokes this command after swapping the binary, so keep `seed` independently
  runnable and side-effect-scoped to the target repo.
