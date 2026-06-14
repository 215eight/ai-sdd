---
name: factory-bootstrap
description: Stand up (or refresh) an ai-sdd factory for a repository so any coding agent — claude-code, codex, … — can drive it. Discovers the repo's conventions, scaffolds the .factory/ home, authors worker skills + schemas, compiles the deterministic gates, and wires provider-neutral skill surfacing (AGENTS.md + per-agent symlinks). Use when onboarding a repo to ai-sdd or re-bootstrapping after the codebase/conventions drift.
---

# Bootstrapping a repo's factory

Stand up everything a repo needs to be built by ai-sdd, **provider-neutrally**. The output is a
committed `.factory/` home plus per-agent pointers — one source of truth, many agent front-ends.
Repeatable: re-running refreshes conventions/schemas and regenerates gates intentionally.

## 1. Discover the repo

Inspect the target: language/stack, the real **build/test/lint commands**, the module/persistence/
test layout, and the house conventions. Capture this — it becomes the conventions doc and the
deterministic check commands. (Reuse before adding: prefer existing models/patterns.)

## 2. Scaffold the `.factory/` home

```
.factory/
  pipeline.yaml          the build pattern (e.g. architect → implementer → reviewer)
  workers/               role specs (signature + task.skill + stack); no inline prompts
  schemas/               per-artifact schema-metadata (fields/rules/judge) — see factory-compile-schema
  conventions/<stack>.md the house style, bootstrapped FROM the codebase (not hand-invented)
  skills/                worker skills + the copied framework skills (below)
  stacks/ traits/ resources/   design-only specs (engine ignores today) if modeling the full factory
  runs/  artifacts/       runtime — gitignored
```

## 3. Author worker skills + schemas

- Write the per-role **worker skills** into `.factory/skills/` (e.g. `plan-feature`,
  `implement-feature`, `review-feature`), specialized to the repo's conventions.
- Write a **schema** per produced artifact in `.factory/schemas/` — its structure, `rules`, and
  `judge` (the schema-metadata vocabulary). This is what makes gates deterministic.

## 4. Copy the framework skills (provider-neutral source)

Copy the framework skills from the ai-sdd install's `skills/` into `.factory/skills/`:
`factory-run` (the driver) and `factory-compile-schema` (the gate compiler). They live alongside
the worker skills — one neutral home.

## 5. Compile the gates

For each schema, run **factory-compile-schema**: it emits `.factory/checks/*.check.yaml` and wires
the ids onto the worker that produces that schema. Eval-gate any authored (intent/judge) checks
before promoting them to blocking.

## 6. Wire provider-neutral surfacing  ← the copy-then-symlink step

The factory must be drivable by any agent, so skills are surfaced, not duplicated:

- **`AGENTS.md`** (repo root) — point at `.factory/skills/` and how to drive (the `factory-run`
  loop). This is the **cross-agent surface**; Codex reads it natively, and so do others.
  **Never overwrite an existing AGENTS.md.** Wrap the factory section in idempotent markers and
  **upsert** it — replace the existing managed block in place, or append it if absent — so a repo's
  own guidelines are preserved and a re-bootstrap doesn't duplicate the section:

  ```md
  <!-- factory:begin — managed by factory-bootstrap; edits between these markers are overwritten on re-bootstrap -->
  ## AI Software Factory (`.factory/`)
  …pointer to .factory/skills/ + the factory-run loop…
  <!-- factory:end -->
  ```

  Upsert algorithm (same for any marker-managed file): if both markers exist, replace everything
  between them; else append the marked block (to a new file if none exists). The content between
  markers is regenerated each run, so it must be self-contained — never put hand-edited prose there.
- **Per-agent symlinks** for the *framework* skills a human/agent invokes (`factory-run`,
  `factory-compile-schema`, `factory-bootstrap`):
  - Claude Code: `.claude/skills/<name>` → `../../.factory/skills/<name>`
  - add other agents' folders the same way as they're supported.
- **Worker skills** (`plan-feature`, …) need *no* agent-folder symlink — the driver resolves them
  by path (`task.skill: X` → `.factory/skills/X.md`).

The engine itself is already neutral: `factory` is a CLI any agent calls over a shell.

## 7. Ignore runtime + validate

- Add `.factory/runs/` and `.factory/artifacts/` to `.gitignore` (commit the rest of `.factory/`).
  Use the **same marker upsert** as AGENTS.md (`# factory:begin` / `# factory:end`, `#` comments)
  so an existing `.gitignore` is extended, not clobbered, and a re-run doesn't duplicate the block.
- Run `factory validate .factory` — referential + edge-type + acyclicity must pass before any run.

## Notes

- **Symlinks**: clean on macOS/Linux (git stores them); Windows needs `core.symlinks=true`.
- **Re-bootstrap** is how conventions stay fresh (architecture §8): re-run to refresh
  `conventions/` + `schemas/` from the evolved codebase, then recompile gates. Mechanical output is
  stable, so a no-change re-run produces no diff — this holds for the generated `.factory/` specs
  **and** for the marker-managed edits to shared files (`AGENTS.md`, `.gitignore`), because they are
  upserted between `factory:begin`/`factory:end` rather than appended. Files outside those markers
  are never touched.
- **Don't commit secrets**; surface required env/secrets in the repo's docs, not git.
