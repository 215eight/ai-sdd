# Quickstart — adopting ai-sdd in your repo

ai-sdd turns a feature request into a **verifiable change a human reviews rather than redoes**.
A deterministic engine (`factory`) plans and gates; your coding agent does the work via skills.
The loop is always:

```
factory next   → engine renders the runnable Worker (role + its skill + inputs + gates)
   ↓  your agent does that work via the worker's skill
factory submit → engine validates output, runs the gates, advances — or routes to rework
   ↺  repeat until done
```

The engine is provider-neutral: it's a CLI any agent (Claude Code, Codex, …) drives over a shell.

---

## Prerequisites

- A recent **Swift toolchain** (the engine builds with `swift build`).
- **git**, and a **coding agent** — Claude Code or Codex.
- Your project in a git repo (the "target" the factory builds).

---

## Step 1 — Install the engine

Build from source and put the binary on your PATH:

```sh
git clone <ai-sdd> && cd ai-sdd
swift build                                   # builds .build/debug/factory
export PATH="$PWD/.build/debug:$PATH"         # so `factory` (and compiled gates) resolve
```

**Confirm `factory` is on your PATH** — compiled gates invoke `factory check` / `factory scope`, so
this must succeed from any directory:

```sh
factory --version        # → ai-sdd factory 0.0.1   (if "command not found", fix your PATH)
```

> **Future install (roadmap).** Building from source is the only path today. Planned, in order of
> convenience: a **precompiled release binary** committed to the repo (copy it onto your PATH, no
> Swift toolchain needed), and ultimately **Homebrew** (`brew install ai-sdd/tap/factory`).

Then take the bundled example for a spin (a complete win in ~30s):

```sh
factory validate docs/examples/minimal
factory start    docs/examples/minimal --id demo
factory next     demo        # renders the architect worker
factory submit   demo        # runs its gates, advances
factory status   demo        # repeat next/submit until "✓ done"
```

---

## Step 2 — Make the framework skills available to your agent (one-time)

The framework skills (`factory-bootstrap`, `factory-plan`, `factory-compile-schema`, `factory-run`)
are a **toolkit you point at a repo** — not part of any one project. Install them so your agent can
run them in the repo you want to build. Set two paths, then link the skills in (Claude Code reads
`<repo>/.claude/skills/`):

```sh
AISDD=/path/to/ai-sdd          # where you cloned ai-sdd (the toolkit source)
TARGET=/path/to/your-repo      # the repo you want to bootstrap

mkdir -p "$TARGET/.claude/skills"
for s in factory-bootstrap factory-plan factory-compile-schema factory-run; do
  ln -sfn "$AISDD/skills/$s" "$TARGET/.claude/skills/$s"
done
ls -l "$TARGET/.claude/skills" | grep factory      # verify the links resolve
```

This scopes the toolkit to `$TARGET`. It's only a **seed**: when you run `/factory-bootstrap`
(Step 3) it vendors the skills into the repo's own `.factory/skills/` and re-points these links
there — so the repo becomes self-contained (only the `factory` binary stays external, until
Homebrew).

- **Codex** — point it at `$AISDD/skills/` (referenced from the repo's `AGENTS.md`).
- **Machine-wide instead** (use across many repos)? Link into your user dir:
  `mkdir -p ~/.claude/skills && for s in factory-bootstrap factory-plan factory-compile-schema factory-run; do ln -sfn "$AISDD/skills/$s" ~/.claude/skills/$s; done`

---

## Step 3 — Bootstrap your repo's factory

From **your project**, ask your agent to run the **`factory-bootstrap`** skill (e.g. `/factory-bootstrap`).
It is repeatable and does the whole stand-up:

1. **Discovers** your stack and real build/test commands and conventions.
2. **Scaffolds** the factory home:
   ```
   .factory/
     pipeline.yaml      the build pattern (e.g. architect → implementer → reviewer)
     workers/           the roles (signature + which skill each runs)
     schemas/           per-artifact structure + rules + judge  (makes gates deterministic)
     conventions/       your house style, learned from the codebase
     skills/            worker skills + the copied framework skills
     checks/            the compiled gates (generated, see below)
     runs/ artifacts/   runtime — gitignored
   ```
3. **Compiles the gates** (via `factory-compile-schema`): each schema becomes deterministic
   `factory check` / `factory scope` / build-test checks, wired onto the worker that produces it.
4. **Wires provider-neutral surfacing**: writes `AGENTS.md` (the cross-agent surface) and symlinks
   `.claude/skills/*` → `.factory/skills/*`. Agent folders are gitignored; the canonical source is
   `.factory/`.
5. **Validates**: `factory validate .factory` must pass before any run.

Review the generated `.factory/` and commit it.

---

## Step 4 — Plan and build a feature

Start from a **brief** (a short description of what you want). Two skills carry it from idea to done.

**Plan** — `/factory-plan` works with you to drive out decisions and emit a `requirements.md` plus
the **orchestration graph** of slices at `.factory/features/<slug>/`:

```
/factory-plan "<your brief>"
```

**Run** — `/factory-run` executes that graph: it schedules slices by `depends_on` and descends into
plan→implement→review for each, gating every step:

```
factory start .factory/features/<slug> --id <slug>
/factory-run <slug>             # the agent loops next → work → submit for you
```

Run `factory` **from your repo root** so the gates (`swift build`, `swift test`, scope) and the run
store resolve against your codebase. As it goes:

- a worker's output is checked by its **compiled gates**; a failure prints the exact reason and
  routes to **rework** (the next render carries the failures as context);
- when every slice completes, the run reports **✓ done** — a change that already cleared its gates.

---

## Visualize the work (for you and your team)

The dependency graph is the *one* place the flow lives — and `factory graph` renders it as **Mermaid**
(it shows in GitHub, VS Code, and most Markdown viewers), so the whole team sees the plan in one place:

```sh
factory graph .factory/features/<slug>            # one feature's slice graph
factory graph .factory --project                  # the repo: build pattern + every feature, one index
factory graph .factory --project --out .factory/graph/index.md   # committed, browsable in the tree
factory graph .factory/features/<slug> --html --out graph.html   # a self-contained page (any host / open locally)
```

Across repos, a thin `plant.yaml` lists fragment locations and `factory graph --plant plant.yaml`
aggregates them into one program view, grouped by milestone, flagging cross-repo contract-version
skew (ADR-0027). It's a deterministic render of your committed specs — no separate source of truth.

---

## How the gates work (why you can trust "done")

A schema describes each artifact; the compiler turns it into gates in three tiers:

- **Tier 1 — structure** (`factory check`): the artifact's required shape/invariants, e.g. "every
  decision is closed", "files are under `Sources/`/`Tests/`". Deterministic. **This includes the
  reviewer's verdict**: a `review.v1` whose schema requires `verdict == approve` and every
  `items[].verdict == pass` makes the reviewer a *real, blocking gate* — a reject routes to rework,
  not advisory notes. The reviewer *is* the judge; its verdict is captured as data and gated
  deterministically (no LLM gate-runner needed).
- **Tier 2 — semantics** (`factory scope`, `factory cover`, build, test): e.g. **changed files ⊆ the
  plan's declared files** (catches out-of-scope edits, including new files), **the review covers every
  acceptance item** (`factory cover`), the project compiling, the suite passing. Deterministic.
- **Tier 3 — judgement** (judge checks): the irreducibly qualitative ("is the approach sound?").
  Advisory until validated against labeled examples; never a fake deterministic gate. (Distinct from
  the reviewer verdict above, which *is* deterministic.)

The discipline: structure the artifact so most checks are **deterministic**; keep the judge layer
small and honest.

---

## Command reference

| Command | What it does |
|---|---|
| `factory validate <dir>` | load + check a workspace (refs, edge types, acyclicity) |
| `factory start <dir> --id <id>` | begin a run |
| `factory next <id>` | render the runnable worker (`--json` for drivers) |
| `factory submit <id>` | validate output, run gates, advance or rework |
| `factory status <id>` | run state + what's runnable (nested for slices) |
| `factory check <schema> <artifact>` | run a Tier-1 structure/verdict gate standalone |
| `factory scope --plan <plan> --repo <dir>` | run the Tier-2 scope gate standalone |
| `factory cover --plan <plan> --review <review>` | check the review judged every acceptance item |
| `factory graph <dir>` | render the dependency graph as Mermaid (`--project`, `--plant`, `--html`) |

Skills (agent-run): **`factory-bootstrap`** (stand up a factory), **`factory-compile-schema`**
(schema → gates), **`factory-run`** (drive the loop).

---

## Status & caveats (honest)

This is an early, from-source tool. What's solid: the engine loop (validate/start/next/submit/
status), the deterministic gates (structure + the reviewer **verdict gate**, scope, coverage,
build/test), **§9 bounded rework routing** (a reject re-runs the producer, then escalates), the
orchestration graph (slices), `factory graph` visualization, and provider-neutral surfacing.
Known rough edges:

- **Run from the target repo root** — the engine doesn't yet separate workspace / target / run-store
  (all keyed off the current directory).
- **Artifacts** live at the interim path `.factory/artifacts/<name>.v<ver>.<fmt>` (no artifact store yet).
- **Judge checks** (free-form LLM rubrics) are advisory — the LLM gate-runner isn't wired. *The
  reviewer verdict is **not** one of these* — it's a structured artifact gated deterministically, so
  it blocks today.
- **Run state is local** (`.factory/runs/`, gitignored) — no shared state plane yet, so a *live*
  team graph overlay is a future expansion; the *structure* graph works for everyone today.
- **Traits / resources / permissions** specs are authored but not yet enforced by the engine.
- **No MCP server** yet — drive via the CLI.
- **Symlinks** assume macOS/Linux (Windows needs `git config core.symlinks true`).
