# Quickstart — adopting ai-sdd in your repo

ai-sdd turns a feature request into a **verifiable change a human reviews rather than redoes**.
A deterministic engine (`ai-sdd`) plans and gates; your coding agent does the work via skills.
The loop is always:

```
ai-sdd next   → engine renders the runnable Worker (role + its skill + inputs + gates)
   ↓  your agent does that work via the worker's skill
ai-sdd submit → engine validates output, runs the gates, advances — or routes to rework
   ↺  repeat until done
```

The engine is provider-neutral: it's a CLI any agent (Claude Code, Codex, …) drives over a shell.

---

## Prerequisites

- **git**, and a **coding agent** — Claude Code or Codex.
- Your project in a git repo (the "target" the factory builds).
- A recent **Swift toolchain** — needed **once** to produce the `ai-sdd` binary. After that you copy
  the binary around; using ai-sdd does not require Swift.

---

## Step 1 — Install the engine (a copyable binary)

Build the **release** binary once, then put it on your PATH. The binary is self-contained — copy it to
any machine or repo; no Swift needed afterward:

```sh
git clone <ai-sdd> && cd ai-sdd
swift build -c release                              # produces .build/release/ai-sdd
cp .build/release/ai-sdd /usr/local/bin/ai-sdd     # or any dir on your PATH
```

**Confirm `ai-sdd` resolves from any directory** — compiled gates invoke `ai-sdd check` / `ai-sdd
scope`, so this must succeed anywhere:

```sh
ai-sdd --version        # → ai-sdd 0.3.0   (if "command not found", fix your PATH)
ai-sdd guide            # the built-in getting-started guide — travels with the binary
```

> Building from source is the only path today; a published binary (GitHub Releases / Homebrew) is a
> later convenience. `ai-sdd guide` carries the essential steps with the binary, so you don't need this
> file at hand once installed.

---

## Step 2 — Make the framework skills available to your agent (one-time)

`ai-sdd-bootstrap` is itself a **skill**, so it can't install itself — something must make it
discoverable first. That's this one-time seed. The framework skills (`ai-sdd-bootstrap`, `ai-sdd-plan`,
`ai-sdd-plan-program`, `ai-sdd-compile-schema`, `ai-sdd-run`) are a **toolkit you point at a repo** —
not part of any one project. Seed them so your agent discovers them through **its own native skill
mechanism** (not via prose in a docs file). Each agent has a skill dir; symlink the framework skills in:

**Copy** the skills *into* the repo (under `.ai-sdd/skills/`) and point the agent dirs at that in-repo
copy — so once committed, the links resolve for everyone, not just on the setter-upper's machine:

```sh
AISDD=/path/to/ai-sdd          # the toolkit source — ONLY whoever sets up needs this clone
TARGET=/path/to/your-repo      # the repo you want to bootstrap

mkdir -p "$TARGET/.ai-sdd/skills" "$TARGET/.agents/skills" "$TARGET/.claude/skills"
for s in ai-sdd-bootstrap ai-sdd-plan ai-sdd-plan-program ai-sdd-compile-schema ai-sdd-run; do
  cp -R "$AISDD/skills/$s" "$TARGET/.ai-sdd/skills/$s"            # vendor INTO the repo (committed)
  ln -sfn "../../.ai-sdd/skills/$s" "$TARGET/.agents/skills/$s"   # Codex → in-repo (committed)
  ln -sfn "../../.ai-sdd/skills/$s" "$TARGET/.claude/skills/$s"   # Claude Code → in-repo (local)
done
```

This makes `$TARGET` **self-contained**: the skills live in `.ai-sdd/skills/` and the agent dirs link to
them *inside the repo* (relative links). Commit `.ai-sdd/` and `.agents/skills/` and anyone who clones
the repo has the skills with **no ai-sdd clone of their own** — they only install the `ai-sdd` binary on
PATH (a tool, like git). `ai-sdd-bootstrap` (Step 3) then adds the generated factory (schemas, workers,
checks) and the per-role worker skills alongside, and validates.

- **Self-hosting** (bootstrapping the ai-sdd repo itself)? `$AISDD` and `$TARGET` are the same repo and
  the skills already live in `./skills`, so the `.agents/skills` symlinks are already committed — skip
  this step and go to Step 3.
- **Machine-wide instead** (across many repos)? Symlink into your user skill dirs:
  `~/.agents/skills/` (Codex) and `~/.claude/skills/` (Claude Code).

---

## Step 3 — Bootstrap your repo's factory

From **your project**, ask your agent to run the **`ai-sdd-bootstrap`** skill (e.g. `/ai-sdd-bootstrap`).
It is repeatable and does the whole stand-up:

1. **Discovers** your stack and real build/test commands and conventions.
2. **Scaffolds** the factory home:
   ```
   .ai-sdd/
     pipeline.yaml      the build pattern (e.g. architect → implementer → reviewer)
     workers/           the roles (signature + which skill each runs)
     schemas/           per-artifact structure + rules + judge  (makes gates deterministic)
     conventions/       your house style, learned from the codebase
     skills/            worker skills + the copied framework skills
     checks/            the compiled gates (generated, see below)
     runs/ artifacts/   runtime — gitignored
   ```
3. **Compiles the gates** (via `ai-sdd-compile-schema`): each schema becomes deterministic
   `ai-sdd check` / `ai-sdd scope` / build-test checks, wired onto the worker that produces it.
4. **Wires provider-neutral surfacing**: symlinks the framework skills into each agent's native skill
   dir — `.agents/skills/*` (Codex, committed) and `.claude/skills/*` (Claude Code, local) → the
   `.ai-sdd/skills/*` source. Skill discovery is the agent's own mechanism, not AGENTS.md prose;
   AGENTS.md stays a general repo guide.
5. **Validates**: `ai-sdd validate .ai-sdd` must pass before any run.

Review the generated `.ai-sdd/` and commit it.

---

## Step 4 — Plan and build a feature

Start from a **brief** (a short description of what you want). Two skills carry it from idea to done.

**Plan** — `/ai-sdd-plan` works with you to drive out decisions and emit a `requirements.md` plus
the **orchestration graph** of slices at `.ai-sdd/features/<slug>/`:

```
/ai-sdd-plan "<your brief>"
```

**Run** — `/ai-sdd-run` executes that graph: it schedules slices by `depends_on` and descends into
plan→implement→review for each, gating every step:

```
ai-sdd start .ai-sdd/features/<slug> --id <slug>
/ai-sdd-run <slug>             # the agent loops next → work → submit for you
```

Run `ai-sdd` **from your repo root** so the gates (`swift build`, `swift test`, scope) and the run
store resolve against your codebase. As it goes:

- a worker's output is checked by its **compiled gates**; a failure prints the exact reason and
  routes to **rework** (the next render carries the failures as context);
- when every slice completes, the run reports **✓ done** — a change that already cleared its gates.

---

## Step 5 — Plan a program (multiple features + milestones)

When the work is bigger than one feature — several sub-features, a few people, checkpoints between
stages — plan a **program**: a master graph whose nodes are whole features, sequenced by **milestone**
gates, with **owners**. The same engine runs it: it descends `program → feature → slice → worker` through
the very same `next`/`submit` loop, so a milestone blocks downstream features the way a gate blocks
downstream slices (ADR-0028). This is **not** a separate orchestrator — it is the self-similar model.

**Plan the program** — `/ai-sdd-plan-program` takes a *program brief* (sub-features + milestones +
owners + sequencing; see [docs/examples/program-brief.md](docs/examples/program-brief.md)), gets your
approval, and emits the master graph at `.ai-sdd/programs/<slug>/`:

```
/ai-sdd-plan-program "<your program brief>"
```

**Plan each sub-feature** — with `/ai-sdd-plan` as usual (each lands in `.ai-sdd/features/<feature>/`).

**Run the whole program** — point the run at the program dir; the engine drives every feature and gates
each milestone in between:

```
ai-sdd start .ai-sdd/programs/<slug> --id <slug>
/ai-sdd-run <slug>
ai-sdd graph .ai-sdd/programs/<slug>          # see the master graph (features, milestones, owners)
```

**Milestones** are validation nodes — a flow with inputs and outputs, *manual or automated*:

- **Manual:** a person validates (e.g. connects a client to the running system) and records the verdict.
- **Automated:** a deterministic check brings the system up and runs the client, e.g.
  `docker compose -f tests/integration/compose.yaml up --abort-on-container-exit`, gated on exit code.

Maturing manual → automated swaps only the node's kind/checks — inputs and outputs are unchanged. A
milestone with a `fail` verdict blocks its downstream features until re-validated. Full guide:
[docs/milestones.md](docs/milestones.md). You can also phase a *single feature's* slices with the
optional `## Milestones` section of `/ai-sdd-plan`.

---

## Visualize the work (for you and your team)

The dependency graph is the *one* place the flow lives — and `ai-sdd graph` renders it as **Mermaid**
(it shows in GitHub, VS Code, and most Markdown viewers), so the whole team sees the plan in one place:

```sh
ai-sdd graph .ai-sdd/features/<slug>            # one feature's slice graph
ai-sdd graph .ai-sdd --project                  # the repo: build pattern + every feature, one index
ai-sdd graph .ai-sdd --project --out .ai-sdd/graph/index.md   # committed, browsable in the tree
ai-sdd graph .ai-sdd --project --dashboard --out dashboard.html   # self-contained local status dashboard
ai-sdd graph .ai-sdd/features/<slug> --html --out graph.html   # a self-contained page (any host / open locally)
```

The project dashboard overlays the repo factory graphs with status from your local `.ai-sdd/runs`
store. It is a snapshot of the runs on your machine, not a shared live team dashboard. Plant-level
dashboards (`--plant --dashboard`) and live multi-user/team dashboards are out of scope for this
workflow today.

Across repos, a thin `plant.yaml` lists fragment locations and `ai-sdd graph --plant plant.yaml`
aggregates them into one program view, grouped by milestone, flagging cross-repo contract-version
skew (ADR-0027). It's a deterministic render of your committed specs — no separate source of truth.

---

## How the gates work (why you can trust "done")

A schema describes each artifact; the compiler turns it into gates in three tiers:

- **Tier 1 — structure** (`ai-sdd check`): the artifact's required shape/invariants, e.g. "every
  decision is closed", "files are under `Sources/`/`Tests/`". Deterministic. **This includes the
  reviewer's verdict**: a `review.v1` whose schema requires `verdict == approve` and every
  `items[].verdict == pass` makes the reviewer a *real, blocking gate* — a reject routes to rework,
  not advisory notes. The reviewer *is* the judge; its verdict is captured as data and gated
  deterministically (no LLM gate-runner needed).
- **Tier 2 — semantics** (`ai-sdd scope`, `ai-sdd cover`, build, test): e.g. **changed files ⊆ the
  plan's declared files** (catches out-of-scope edits, including new files), **the review covers every
  acceptance item** (`ai-sdd cover`), the project compiling, the suite passing. Deterministic.
- **Tier 3 — judgement** (judge checks): the irreducibly qualitative ("is the approach sound?").
  Advisory until validated against labeled examples; never a fake deterministic gate. (Distinct from
  the reviewer verdict above, which *is* deterministic.)

The discipline: structure the artifact so most checks are **deterministic**; keep the judge layer
small and honest.

---

## Command reference

| Command | What it does |
|---|---|
| `ai-sdd guide` | print the built-in getting-started guide (travels with the binary) |
| `ai-sdd validate <dir>` | load + check a workspace (refs, edge types, acyclicity) |
| `ai-sdd start <dir> --id <id>` | begin a run |
| `ai-sdd next <id>` | render the runnable worker (`--json` for drivers) |
| `ai-sdd submit <id>` | validate output, run gates, advance or rework |
| `ai-sdd status <id>` | run state + what's runnable (nested for slices) |
| `ai-sdd check <schema> <artifact>` | run a Tier-1 structure/verdict gate standalone |
| `ai-sdd scope --plan <plan> --repo <dir>` | run the Tier-2 scope gate standalone |
| `ai-sdd cover --plan <plan> --review <review>` | check the review judged every acceptance item |
| `ai-sdd graph <dir>` | render the dependency graph as Mermaid (`--project`, `--plant`, `--html`) |

Skills (agent-run): **`ai-sdd-bootstrap`** (stand up a factory), **`ai-sdd-compile-schema`**
(schema → gates), **`ai-sdd-plan`** (a feature), **`ai-sdd-plan-program`** (a multi-feature program
with milestones + owners), **`ai-sdd-run`** (drive the loop).

---

## Status & caveats (honest)

This is an early, from-source tool. What's solid: the engine loop (validate/start/next/submit/
status), the deterministic gates (structure + the reviewer **verdict gate**, scope, coverage,
build/test), **§9 bounded rework routing** (a reject re-runs the producer, then escalates), the
orchestration graph (slices), **recursive program-tier execution + milestone gates** (ADR-0028),
`ai-sdd graph` visualization, and provider-neutral surfacing. Known rough edges:

- **Run from the target repo root** — the engine doesn't yet separate workspace / target / run-store
  (all keyed off the current directory).
- **Artifacts** live at the interim path `.ai-sdd/artifacts/<name>.v<ver>.<fmt>` (no artifact store yet).
- **Judge checks** (free-form LLM rubrics) are advisory — the LLM gate-runner isn't wired. *The
  reviewer verdict is **not** one of these* — it's a structured artifact gated deterministically, so
  it blocks today.
- **Run state is local** (`.ai-sdd/runs/`, gitignored) — no shared state plane yet, so a *live*
  team graph overlay is a future expansion; the *structure* graph works for everyone today.
- **Program tier** runs today (recursive execution + milestone gates), but a failed milestone
  **self-reworks** (re-validate) rather than routing rework into the specific upstream feature, and the
  milestone worker/check are **copied into each program/feature dir by convention** (no shared library yet).
- **Traits / resources / permissions** specs are authored but not yet enforced by the engine.
- **No MCP server** yet — drive via the CLI.
- **Symlinks** assume macOS/Linux (Windows needs `git config core.symlinks true`).
