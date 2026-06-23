# Feature: `ai-sdd cheatsheet` — a diagram-driven workflow cheatsheet

Status: **approved** — decisions D1–D5 closed by human on 2026-06-22.

## Goal

Users forget which `ai-sdd` command to run during a regular workflow. Rename the
existing `ai-sdd guide` command to `ai-sdd cheatsheet` and replace its install-heavy
prose body with a terse, visual reference: ASCII flow diagrams for the **feature** path
and the **program** path, each step's exact command surfaced and easy to spot. Add a
thin `ai-sdd-cheatsheet` skill so it's invokable identically from Claude Code and Codex.
It's meant to be glanced at a few times until the workflow sticks.

## In scope

- Rename `Guide` → `Cheatsheet` (`commandName: "cheatsheet"`, **no alias**) in
  `Sources/AISDDCLI/main.swift`; update the `subcommands` registration and the `// MARK:`
  comment.
- Rewrite the printed body as three scannable sections — **one-time setup**, **A FEATURE**
  (ASCII diagram), **A PROGRAM** (ASCII diagram) — every command on its own line and
  visually marked (`$` = shell, `/` = skill), milestones called out in the program
  diagram, plus a one-line loop summary and a `status`/`graph` + `--help` footer. Pure
  `print`, no flags, no ANSI, no state reads.
- New `skills/ai-sdd-cheatsheet/SKILL.md` — thin wrapper: run `ai-sdd cheatsheet` from
  repo root (PATH binary, `.build/debug/ai-sdd` fallback), relay output verbatim;
  optionally prepend **one** `You're here: <step> → <command>` line when the conversation
  makes the current step obvious (no CLI state detection).
- Update `ai-sdd guide` → `ai-sdd cheatsheet` references in `QUICKSTART.md` and
  `docs/decisions.md`.

## Out of scope

- Any context-detection / state-reading logic in the CLI (the command is a static print).
- New flags on the command.
- Changing `Status`/`Next`/`Surface` or `ai-sdd surface` logic (it already picks up
  `ai-sdd-*` skills).
- Network, graph rendering, multi-repo aggregation.
- Detailed install / skill-vendoring instructions in the command body — those stay in
  `QUICKSTART.md`; the cheatsheet keeps only a 1–3 line setup pointer.

## Acceptance

1. `ai-sdd cheatsheet` exits 0 and prints the new diagram-driven content.
2. `ai-sdd guide` no longer exists (unknown subcommand); `grep -rn "ai-sdd guide"` is
   empty outside `.build/`.
3. Output contains a distinct **FEATURE** flow and a distinct **PROGRAM** flow, each an
   ASCII diagram with step commands surfaced; the program flow names milestones/gates.
4. Every workflow command appears verbatim and copy-pasteable: `/ai-sdd-bootstrap`,
   `/ai-sdd-plan`, `/ai-sdd-plan-program`, `ai-sdd start … --id …`, `/ai-sdd-run`,
   `ai-sdd status`, `ai-sdd graph`.
5. Output is plain text, no ANSI/color, materially shorter/more scannable than the old
   prose guide.
6. `skills/ai-sdd-cheatsheet/SKILL.md` exists with valid frontmatter; `ai-sdd surface`
   links it into both `.agents/skills/` and `.claude/skills/`.
7. The skill, when invoked, runs `ai-sdd cheatsheet` and relays its output (verbatim
   aside from the optional single "you're here" line).
8. `swift build` and `swift test` green; `ai-sdd validate .ai-sdd/features/cheatsheet`
   clean.

## Constraints

- `cheatsheet` is a pure `print` — no flags, no disk/state reads, exit 0, no ANSI.
- The skill is a thin shell; all content lives in the CLI; identical under Claude Code
  and Codex.
- Diagrams must render in a plain **80-col** terminal (box-drawing/Unicode only,
  fixed-width-safe).
- `guide` removal is complete across code and docs.
- Stack: `swift` (CLI surface in `Sources/AISDDCLI`; behavior is a pure print).

## Decisions

- **D1 — Remove `guide` entirely, no alias.** Only `cheatsheet` remains; all references
  updated across code + docs. _(closed)_
- **D2 — Two diagrams: a feature flow and a program flow**, left-to-right boxed stages
  with the command surfaced above/within each stage; the program flow names milestone
  gates. Plain Unicode box-drawing, validated at 80 cols. _(closed)_
- **D3 — Keep only a 1–3 line "one-time setup" pointer** (install + `/ai-sdd-bootstrap`)
  in the command; the detailed install/skill-vendoring steps stay in `QUICKSTART.md`
  (already documented there). _(closed)_
- **D4 — The skill may prepend one optional `You're here:` line** derived from the chat,
  but performs no CLI/state detection; default behavior is verbatim relay. _(closed)_
- **D5 — Two slices**, sequential: `cli-cheatsheet` (rename + rewrite body + remove
  guide) → `surface-and-docs` (add skill + update QUICKSTART/decisions references).
  _(closed)_

## Open questions

- None outstanding — all design decisions are captured in D1–D5 above and were
  pre-agreed in the approved plan; this draft exists to satisfy the planning approval
  gate.
