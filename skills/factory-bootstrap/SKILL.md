---
name: factory-bootstrap
description: Stand up (or refresh) an ai-sdd factory for a repository so any coding agent — claude-code, codex, … — can drive it. Discovers the repo's conventions, scaffolds the .factory/ home, authors worker skills + schemas, compiles the deterministic gates, and wires provider-neutral skill surfacing (AGENTS.md + per-agent symlinks). Use when onboarding a repo to ai-sdd or re-bootstrapping after the codebase/conventions drift.
---

# Bootstrapping a repo's factory

Stand up everything a repo needs to be built by ai-sdd, **provider-neutrally**. The output is a
committed `.factory/` home plus per-agent pointers — one source of truth, many agent front-ends.
Repeatable: re-running refreshes conventions/schemas and regenerates gates intentionally.

## 1. Discover the repo — evidence first, flag the rest

Discovery is the one non-deterministic step where the agent could *invent* conventions. Constrain it
to a three-step contract so the output is **grounded, not guessed**:

1. **Collect evidence (deterministic).** For each change-type in the checklist below, gather facts
   from the repo — the manifest, the file tree, `grep`, and *how it was last done* (git history of a
   representative change). Confirm commands by running them (`build`, `test`). Record where each fact
   came from.
2. **Synthesize the convention (AI).** Generalize each change-type's pattern **from that evidence** —
   abstract the pattern from a real exemplar. Faithful abstraction is fine; introducing a step **no
   exemplar supports** is not.
3. **Verify groundedness, flag the rest.** Every convention must **cite its evidence** (a file, a
   commit, a manifest entry). Check citations mechanically where possible (the path exists, the
   command exits 0). Any change-type with **no evidence**, or any claim not traceable to evidence, is
   **flagged and confirmed with the user** (or filled from ecosystem priors) — never silently
   written. "No clear convention found" is a valid, expected outcome — surface it, don't guess.

Cover this **checklist** of change-types — don't skip one for lack of an obvious example; flag it:
build / test / lint / run commands · add a **module/feature** · a **model/entity** · a **migration**
· a **test** · an **endpoint** · **config/secrets** · **a dependency / new package** (read the
manifest + any existing local packages) · naming + layering · CI/release.

Record, per change-type: the **evidence**, the **convention**, and whether it was **confirmed** or
left an **open gap**. That record seeds the discovery eval set (see *Discovery quality* below).

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

**Thread an acceptance checklist through the three roles** — this is what turns the reviewer into a
real gate instead of advisory notes:

- `plan-feature` emits an **`acceptance`** checklist in its plan artifact — one verifiable item per
  outcome, each `{ id, description }`.
- `implement-feature` addresses every item and records the ids it covers in the changeset's
  **`satisfies`** list.
- `review-feature` returns a **per-item verdict** (`items[].verdict: pass|fail`) plus an **overall
  `verdict: approve|reject`**, and **must `reject`** if any item is unmet or a convention is
  violated. On reject it names the indicted input in a **`rework`** list (`target: <consumed
  schema>`) so the engine routes the rework to that input's producer — the implementer for a code
  defect, the planner for a plan/contract defect.

The review schema's invariants (all items `pass`, overall `verdict == approve`) make this verdict a
**deterministic, blocking gate** — see [factory-compile-schema](../factory-compile-schema/SKILL.md);
the reviewer *is* the judge, captured and enforced structurally, no judge-runner required.

## 4. Copy the framework skills (provider-neutral source)

Copy the framework skills from the ai-sdd install's `skills/` into `.factory/skills/`:
`factory-plan` (the planner), `factory-run` (the driver), and `factory-compile-schema` (the gate
compiler). They live alongside the worker skills — one neutral home.

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
- **Per-agent symlinks** for the *framework* skills a human/agent invokes (`factory-plan`,
  `factory-run`, `factory-compile-schema`, `factory-bootstrap`):
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

## Discovery quality — evals + observability

Discovery is the riskiest AI step, so make its quality **measurable**, and more so as adoption grows.
The per-change-type record from §1 (evidence → convention → confirmed / gap) is a labeled example —
the user's confirmations are the ground truth, harvested for free. Across repos, track and surface:

- **faithfulness rate** — conventions grounded in cited evidence;
- **gap-detection rate** — real gaps correctly flagged (vs silently invented);
- **false-invention rate** — ungrounded claims that slipped through.

Watch these **per model version**, so a model swap that degrades discovery is caught — the same
"judge-the-judge" eval-gating used for judge checks, pointed at discovery itself. This three-step
contract (deterministic evidence → AI synthesis → grounded-or-flagged) is the house pattern for
**every** non-deterministic step here — planning and implementation included, not just discovery.

## Notes

- **Symlinks**: clean on macOS/Linux (git stores them); Windows needs `core.symlinks=true`.
- **Re-bootstrap** is how conventions stay fresh (architecture §8): re-run to refresh
  `conventions/` + `schemas/` from the evolved codebase, then recompile gates. Mechanical output is
  stable, so a no-change re-run produces no diff — this holds for the generated `.factory/` specs
  **and** for the marker-managed edits to shared files (`AGENTS.md`, `.gitignore`), because they are
  upserted between `factory:begin`/`factory:end` rather than appended. Files outside those markers
  are never touched.
- **Don't commit secrets**; surface required env/secrets in the repo's docs, not git.
