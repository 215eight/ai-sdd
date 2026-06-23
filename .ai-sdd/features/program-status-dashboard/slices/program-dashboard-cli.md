# Slice: program-dashboard-cli

**Stack:** swift · **Depends on:** program-dashboard-assembler

## Delivers
Wire the program dashboard onto the `graph` command by relaxing the existing gate — no new flag.

In `Sources/AISDDCLI/main.swift`, in `Graph.dashboardDoc()`:
- Keep: reject `--html` + `--dashboard`; reject `--plant` + `--dashboard` (existing errors verbatim).
- When `--dashboard` is set, a `dir` is present, and `--project` is NOT set → route to
  `ProgramDashboardAssembler.assemble(programDir:runStore:)` and render with
  `GraphRenderer.dashboardPage(title:sections:)`.
- When `--dashboard --project <dir>` → unchanged (`ProjectDashboardAssembler`).
- When `--dashboard` with no `dir` and no `--project` → keep a clear error telling the user to pass a
  program dir or `--project <factoryDir>`.
- Update the `--dashboard` flag's help text to mention it accepts a program dir (or `--project` for the
  factory).

## Acceptance
- `ai-sdd graph .ai-sdd/programs/guardrails --dashboard --out /tmp/prog.html` writes a self-contained
  HTML program dashboard (manually confirmed in the verification slice).
- `ai-sdd graph .ai-sdd --project --dashboard --out /tmp/proj.html` still works unchanged.
- `--html`+`--dashboard`, `--plant`+`--dashboard`, and `--dashboard` with no dir still error as before.
- All other graph modes (single, `--project`, `--plant`, `--html`, plain Mermaid) unchanged.
- `swift build` + `swift test` green.
