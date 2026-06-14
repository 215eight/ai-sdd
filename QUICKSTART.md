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

The framework skills live, provider-neutral, in `ai-sdd/skills/`. Surface them to your agent so it
can run them by name:

- **Claude Code** — symlink them into your skills dir:
  ```sh
  for s in factory-bootstrap factory-compile-schema factory-run; do
    ln -s "$PWD/skills/$s" ~/.claude/skills/$s
  done
  ```
- **Codex** — point it at `ai-sdd/skills/` (reference them from your `AGENTS.md` or Codex prompts).

After Step 3 your repo carries its own copies + per-agent links, so this is only for the first run.

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

## Step 4 — Build a feature

Give the factory the feature requirement — this is the **input** the architect plans from (a short
brief; the factory decides the files/decisions/tests). Then ask your agent to run **`factory-run`**:

```
/factory-run <run-id>          # the agent loops next → work → submit for you
```

Run `factory` **from your repo root** so the gates (`swift build`, `swift test`, scope) and the run
store resolve against your codebase. As it goes:

- a worker's output is checked by its **compiled gates**; a failure prints the exact reason and
  routes to **rework** (the next `next` re-renders that worker with the failures as context);
- when every node passes, the run reports **✓ done**. You review a change that already cleared its
  gates.

---

## How the gates work (why you can trust "done")

A schema describes each artifact; the compiler turns it into gates in three tiers:

- **Tier 1 — structure** (`factory check`): the artifact's required shape/invariants, e.g. "every
  decision is closed", "files are under `Sources/`/`Tests/`". Deterministic.
- **Tier 2 — semantics** (`factory scope`, build, test): e.g. **changed files ⊆ the plan's declared
  files** (catches out-of-scope edits, including new files), the project compiling, the suite
  passing. Deterministic.
- **Tier 3 — judgement** (judge checks): the irreducibly qualitative ("is the approach sound?").
  Advisory until validated against labeled examples; never a fake deterministic gate.

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
| `factory check <schema> <artifact>` | run a Tier-1 structure gate standalone |
| `factory scope --plan <plan> --repo <dir>` | run the Tier-2 scope gate standalone |

Skills (agent-run): **`factory-bootstrap`** (stand up a factory), **`factory-compile-schema`**
(schema → gates), **`factory-run`** (drive the loop).

---

## Status & caveats (honest)

This is an early, from-source tool. What's solid: the engine loop (validate/start/next/submit/
status), schema + scope gates, the orchestration graph (slices), and provider-neutral surfacing.
Known rough edges:

- **Run from the target repo root** — the engine doesn't yet separate workspace / target / run-store
  (all keyed off the current directory).
- **Artifacts** live at the interim path `.factory/artifacts/<name>.v<ver>.<fmt>` (no artifact store yet).
- **Judge checks** are advisory — the LLM Adapter that runs them isn't wired yet.
- **Traits / resources / permissions** specs are authored but not yet enforced by the engine.
- **No MCP server** yet — drive via the CLI.
- **Symlinks** assume macOS/Linux (Windows needs `git config core.symlinks true`).
