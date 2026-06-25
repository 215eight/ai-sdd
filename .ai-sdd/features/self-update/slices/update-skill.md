# Slice: update-skill

**Phase:** m2 (detect + apply) · **Stack:** swift · **Depends on:** update-apply

## Delivers
`/ai-sdd-update` — the agent-facing, apply-on-confirm wrapper that teammates actually invoke — shipped
as a framework skill embedded in the binary (so `ai-sdd seed` delivers it to every adopter).

- New skill `skills/ai-sdd-update/SKILL.md` (and it joins the embedded resource set from
  `embedded-skills`, so `seed` materializes it into `.ai-sdd/skills/` + `.agents`/`.claude` links).
- Skill contract:
  1. Read current vs latest (`ai-sdd update --check`), show the teammate `vCURRENT → vLATEST`, and
     **proceed only on explicit confirmation** (apply-on-confirm — never auto-apply).
  2. Run `ai-sdd update`.
  3. Commit the reseed as its **own** commit: `chore(ai-sdd): update framework to vX.Y.Z` — a message
     that deliberately does **not** match the `[<feature>] <slice>:` pattern the integrity pre-commit
     hook guards, so it passes cleanly and never tangles with a teammate's feature work.
  4. Tell the teammate the next skill invocation / command picks up the new binary + skills (no hard
     restart needed).
- The skill is agent-agnostic (Claude Code or Codex), consistent with the other `ai-sdd-*` skills.

## Acceptance
- `/ai-sdd-update` with no newer release → reports up-to-date, makes no changes.
- With a newer release → asks for confirmation; on **decline** makes no changes; on **confirm** runs
  `ai-sdd update` and lands exactly one standalone `chore(ai-sdd): update framework to vX.Y.Z` commit
  that **passes** the integrity pre-commit hook.
- `ai-sdd seed` materializes `ai-sdd-update` alongside the other framework skills (surfaced in
  `.agents/skills` + `.claude/skills`).
- The skill description triggers correctly and matches the house style of the existing `ai-sdd-*`
  skills.
- `swift build` / `swift test` / `swift run ai-sdd validate .ai-sdd` green.

## Notes
- This closes the loop: detect (`update-check` + hooks) → confirm (`/ai-sdd-update`) → apply
  (`ai-sdd update`) → standalone reseed commit.
