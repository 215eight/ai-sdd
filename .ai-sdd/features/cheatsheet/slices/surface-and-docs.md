# Slice: surface-and-docs

## Delivers

The `ai-sdd-cheatsheet` skill (so the command is invokable from Claude Code and Codex)
plus completion of the `guide` → `cheatsheet` rename across the docs.

- New `skills/ai-sdd-cheatsheet/SKILL.md` with valid frontmatter (`name:
  ai-sdd-cheatsheet` + a one-line `description:`), matching the shape of the other five
  framework skills. Body — a **thin shell**:
  - Instruct the agent to run `ai-sdd cheatsheet` from the repo root (prefer the on-PATH
    binary; fall back to `.build/debug/ai-sdd cheatsheet`, exactly as the `ai-sdd-run`
    skill documents the fallback) and **relay the output verbatim**.
  - All content lives in the CLI; the skill must not re-derive or reformat it.
  - **Optional light touch:** if the conversation already makes the user's current
    workflow step obvious, prepend a single line `You're here: <step> → <command>` before
    the relayed output; otherwise add nothing. No CLI state detection.
- Update `ai-sdd guide` → `ai-sdd cheatsheet` everywhere it refers to the command:
  - `QUICKSTART.md` (the `ai-sdd guide` invocation lines and the command-table row).
  - `docs/decisions.md` (the `guide · validate · …` CLI command list).
  - After this slice, `grep -rn "ai-sdd guide" .` (outside `.build/`) returns nothing.
- Naming the skill `ai-sdd-cheatsheet` (the `ai-sdd-` framework prefix) means
  `ai-sdd surface` picks it up automatically; this slice does **not** modify surfacing
  logic.

## Acceptance

- `skills/ai-sdd-cheatsheet/SKILL.md` exists, parses (valid frontmatter), and documents
  running `ai-sdd cheatsheet` + verbatim relay (+ the optional one-line pointer).
- `ai-sdd surface` (or `ai-sdd surface --check`, whichever the repo uses) recognizes
  `ai-sdd-cheatsheet` and links it into both `.agents/skills/` and `.claude/skills/`.
- `grep -rn "ai-sdd guide" .` outside `.build/` is empty; QUICKSTART.md and
  docs/decisions.md reference `cheatsheet` instead.
- `swift build`, `swift test`, and `ai-sdd validate .ai-sdd/features/cheatsheet` green.

## Stack

swift — skill markdown under `skills/`, doc edits under repo root + `docs/`. Mirror the
existing `skills/ai-sdd-run/SKILL.md` for frontmatter + the binary-fallback wording.

## depends_on

cli-cheatsheet
