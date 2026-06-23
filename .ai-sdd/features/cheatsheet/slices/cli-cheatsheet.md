# Slice: cli-cheatsheet

## Delivers

The renamed, diagram-driven `ai-sdd cheatsheet` command — replacing `ai-sdd guide`
entirely.

- Rename the `Guide` `ParsableCommand` in `Sources/AISDDCLI/main.swift` to `Cheatsheet`
  (`commandName: "cheatsheet"`, **no alias**). Update the entry in the `subcommands:`
  list (`Guide.self` → `Cheatsheet.self`) and the `// MARK: - guide` section comment.
- Rewrite the printed body (pure `print(""" … """)`, no flags, no state reads, exit 0,
  no ANSI) as three scannable sections:
  1. **ONE-TIME SETUP** — 1–3 lines: build/install the binary, then `/ai-sdd-bootstrap`.
     Do **not** reproduce the detailed skill-vendoring block (that lives in QUICKSTART).
  2. **A FEATURE** — a left-to-right ASCII flow diagram with the exact command surfaced
     per stage: `/ai-sdd-plan "<brief>"` → `ai-sdd start <dir> --id ID` →
     `/ai-sdd-run ID` (the `next → work → submit ↺` loop) → done.
  3. **A PROGRAM** — a parallel ASCII flow diagram: `/ai-sdd-plan-program "<brief>"` →
     `/ai-sdd-plan` each sub-feature → `ai-sdd start <dir> --id ID` + `/ai-sdd-run ID`,
     with **milestone gates** named as blocking downstream features until they pass.
  - Commands visually marked so they're instantly identifiable: `$` prefix for shell
    commands, `/` for agent skills.
  - A one-line summary of the loop, and a footer pointing to `ai-sdd status <id>` /
    `ai-sdd graph <dir>` and `ai-sdd <command> --help` / QUICKSTART.md. Replace the old
    `COMMANDS: guide · …` line with one that does not mention `guide`.
- Diagrams must render correctly in a plain **80-column** terminal — box-drawing/Unicode
  only, fixed-width-safe, no line wrapping at 80 cols.

## Acceptance

- `swift run ai-sdd cheatsheet` exits 0 and prints the new content.
- `swift run ai-sdd guide` fails as an unknown subcommand (command removed).
- Output shows a distinct FEATURE flow and a distinct PROGRAM flow, each as an ASCII
  diagram with per-stage commands; the PROGRAM flow names milestones/gates.
- These commands appear verbatim and copy-pasteable: `/ai-sdd-bootstrap`, `/ai-sdd-plan`,
  `/ai-sdd-plan-program`, `ai-sdd start … --id …`, `/ai-sdd-run`, `ai-sdd status`,
  `ai-sdd graph`.
- Output is plain text (no ANSI) and materially shorter than the old prose guide.
- No diagram line exceeds 80 columns.
- `swift build` and `swift test` green.

## Stack

swift — command surface in `Sources/AISDDCLI/main.swift`. Pure print command; mirror the
existing `Guide`/`Status` command shape. No engine/behavior changes.

## depends_on

(none — first slice)
