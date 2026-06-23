---
name: ai-sdd-bootstrap
description: Stand up (or refresh) an ai-sdd factory for a repository so any coding agent — claude-code, codex, … — can drive it. Discovers the repo's conventions, scaffolds the .ai-sdd/ home, authors worker skills + schemas, compiles the deterministic gates, and wires provider-neutral skill surfacing (AGENTS.md + per-agent symlinks). Use when onboarding a repo to ai-sdd or re-bootstrapping after the codebase/conventions drift.
---

# Bootstrapping a repo's factory

Stand up everything a repo needs to be built by ai-sdd, **provider-neutrally**. The output is a
committed `.ai-sdd/` home plus per-agent pointers — one source of truth, many agent front-ends.
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
3. **Verify groundedness, flag the rest.** Every convention must **cite its evidence** as **typed,
   machine-readable tokens** so drift can re-check it later with **zero heuristics**. Record citations
   in the Evidence cell as backticked tokens whose content begins with a known prefix immediately
   followed by a colon — `` `path:<concrete-repo-relative-path>` `` (drift checks the path exists) and
   `` `cmd:<command>` `` (drift checks the command exits 0). A parser collects **only** known-prefix
   tokens; every other backticked token is convention **vocabulary** (e.g. `@Test`, `swiftlint`,
   `env:`) and is ignored, as is all surrounding prose. Use **concrete paths only — no globs** (a glob
   is not existence-checkable; name one concrete existing file instead). Commit SHAs and any other
   evidence stay **ordinary prose** — not tokenized, not drift-checked (a historical SHA existing is
   not a staleness signal). Check tokens mechanically (the path exists, the command exits 0). Any
   change-type with **no evidence**, or any claim not traceable to evidence, is **flagged and confirmed
   with the user** (or filled from ecosystem priors) — never silently written. "No clear convention
   found" is a valid, expected outcome — surface it, don't guess.

Cover this **checklist** of change-types — don't skip one for lack of an obvious example; flag it:
build / test / lint / run commands · add a **module/feature** · a **model/entity** · a **migration**
· a **test** · an **endpoint** · **config/secrets** · **a dependency / new package** (read the
manifest + any existing local packages) · naming + layering · CI/release.

Record, per change-type, a Discovery Record table row: the **evidence** (as typed `path:`/`cmd:`
tokens in the Evidence cell), the **convention**, and whether it was **confirmed** or left an **open
gap**. A confirmed row carries at least one `path:`/`cmd:` token; an **open-gap row carries no typed
token** (zero tokens ⇒ nothing to verify ⇒ drift skips it) — it keeps its descriptive prose and `open
gap` status. That record seeds the discovery eval set (see *Discovery quality* below).

## 2. Scaffold the `.ai-sdd/` home

```
.ai-sdd/
  pipeline.yaml          the build pattern (e.g. architect → implementer → reviewer)
  workers/               role specs (signature + task.skill + stack); no inline prompts
  schemas/               per-artifact schema-metadata (fields/rules/judge) — see ai-sdd-compile-schema
  conventions/<stack>.md the house style, bootstrapped FROM the codebase (not hand-invented)
  skills/                worker skills + the copied framework skills (below)
  stacks/ traits/ resources/   design-only specs (engine ignores today) if modeling the full factory
  runs/  artifacts/       runtime — gitignored
```

## 3. Author worker skills + schemas

- Write the per-role **worker skills** into `.ai-sdd/skills/` (e.g. `plan-feature`,
  `implement-feature`, `review-feature`), specialized to the repo's conventions.
- Write a **schema** per produced artifact in `.ai-sdd/schemas/` — its structure, `rules`, and
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
**deterministic, blocking gate** — see [ai-sdd-compile-schema](../ai-sdd-compile-schema/SKILL.md);
the reviewer *is* the judge, captured and enforced structurally, no judge-runner required.

## 4. Copy the framework skills (provider-neutral source)

Copy the framework skills from the ai-sdd install's `skills/` into `.ai-sdd/skills/`:
`ai-sdd-plan` (the feature planner), `ai-sdd-plan-program` (the program planner — multi-feature graphs
with milestones + owners), `ai-sdd-run` (the driver), `ai-sdd-compile-schema` (the gate compiler), and
`ai-sdd-bootstrap` itself (so re-bootstrap needs no external clone). They live alongside the worker
skills — one neutral home. Copying (not symlinking to the install) is what makes the repo self-contained.

## 5. Compile the gates

For each schema, run **ai-sdd-compile-schema**: it emits `.ai-sdd/checks/*.check.yaml` and wires
the ids onto the worker that produces that schema. Eval-gate any authored (intent/judge) checks
before promoting them to blocking.

## 6. Surface the skills to every agent — `ai-sdd surface`

The factory must be drivable by any agent, so the *framework* skills a human/agent invokes (`ai-sdd-*`:
`ai-sdd-bootstrap`, `ai-sdd-plan`, `ai-sdd-plan-program`, `ai-sdd-run`, `ai-sdd-compile-schema`) are
surfaced through each agent's **native skill mechanism** — a symlink into the agent's skill dir, **not**
prose in AGENTS.md (each agent matches on `SKILL.md` frontmatter). Surfacing is purely mechanical, so it
is a **deterministic command**, never a step to hand-follow:

```sh
ai-sdd surface           # idempotently reconcile every agent's skill dir — re-run anytime
ai-sdd surface --check   # report drift without writing (exit 1 if any link is missing) — for CI / drift
```

`surface` symlinks every `ai-sdd-*` skill into each configured agent dir. The **agent→dir map is data**
in the engine (`.agents/skills` for Codex, `.claude/skills` for Claude, …) — adding an agent is a
one-line data edit, not new prose. The symlink target is uniformly `../../.ai-sdd/skills/<name>` (each
agent dir sits two levels below the repo root), so the operation is identical for every agent — only the
parent folder differs. **Both surfaces are committed and team-shared** (§7), so a fresh clone has the
skills/slash-commands with no re-bootstrap, and re-running `surface` reconciles the *full* set so they
can't drift.

- **`AGENTS.md`** stays a **general repo guide** (what the project is, how to build/test, the
  `ai-sdd-run` loop) — useful context, but it is **not** the skill-discovery mechanism. Still upsert
  it idempotently so a re-bootstrap doesn't duplicate or clobber a repo's own guidelines:

  ```md
  <!-- ai-sdd:begin — managed by ai-sdd-bootstrap; edits between these markers are overwritten on re-bootstrap -->
  ## AI Software Factory (`.ai-sdd/`)
  …how to drive: the ai-sdd-run loop; skills are surfaced via each agent's skill dir…
  <!-- ai-sdd:end -->
  ```

  Upsert algorithm (same for any marker-managed file): if both markers exist, replace everything
  between them; else append the marked block (to a new file if none exists). The content between
  markers is regenerated each run, so it must be self-contained — never put hand-edited prose there.

  **Worker skills** (`plan-feature`, …) need *no* agent skill-dir symlink — the driver resolves them
  by path (`task.skill: X` → `.ai-sdd/skills/X.md`).

The engine itself is already neutral: `ai-sdd` is a CLI any agent calls over a shell.

## 7. Ignore runtime + per-agent surfacing, then validate

The `.gitignore` is the **one place** that declares what stays out of git — so a commit never has to
*ask* what to include. The managed block ignores the factory runtime and each agent's **local** state
folder — but **not** each agent's `skills/` subfolder (`.agents/skills/`, `.claude/skills/`), the
committed repo-level skill surfaces (§6). Ignore `.claude/`'s contents but **re-include**
`.claude/skills/` (a parent-dir exclude can't be undone, so exclude `.claude/*` and negate the
subfolder):

```gitignore
# ai-sdd:begin — managed by ai-sdd-bootstrap; edits between these markers are overwritten on re-bootstrap
# Software factory runtime (the rest of .ai-sdd/ is committed)
.ai-sdd/runs/
.ai-sdd/artifacts/
# Agent-local state — EXCEPT each agent's committed repo-level skill surface (.agents/skills/, .claude/skills/)
.claude/*
!.claude/skills/
.codex/
# ai-sdd:end
```

- Write this with the **same marker upsert** as AGENTS.md (`# ai-sdd:begin` / `# ai-sdd:end`,
  `#` comments) so an existing `.gitignore` is extended, not clobbered, and a re-run doesn't
  duplicate the block. The committed set is therefore `.ai-sdd/` (minus runtime) + `.agents/skills/`
  + `.claude/skills/` + `AGENTS.md` + `.gitignore` + any tool config a gate needs — decided by
  `.gitignore`, not by prompting per commit.
- Run `ai-sdd validate .ai-sdd` — referential + edge-type + acyclicity must pass before any run.

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

- **Symlinks**: the per-agent surfacing symlinks are committed (`.agents/skills/`, `.claude/skills/`)
  and created/reconciled by **`ai-sdd surface`** (which re-bootstrap runs) over the full
  framework-skill set — so a newly-added framework skill reaches *every* agent, not just the one that
  authored it. Clean on macOS/Linux, Windows needs `core.symlinks=true`.
- **Re-bootstrap** is how conventions stay fresh (architecture §8): re-run to refresh
  `conventions/` + `schemas/` from the evolved codebase, then recompile gates. Mechanical output is
  stable, so a no-change re-run produces no diff — this holds for the generated `.ai-sdd/` specs
  **and** for the marker-managed edits to shared files (`AGENTS.md`, `.gitignore`), because they are
  upserted between `ai-sdd:begin`/`ai-sdd:end` rather than appended. Files outside those markers
  are never touched.
- **Don't commit secrets**; surface required env/secrets in the repo's docs, not git.
