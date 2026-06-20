# Feature Parity — `ai-sdd` capabilities the new system must support

> An inventory of what the original `ai-sdd` did, mapped to where each capability lives in
> the new model ([architecture.md](architecture.md)). This is a parity backlog, not a set of
> decisions — design rationale lives in [decisions.md](decisions.md).

**Status legend:** ✅ covered by an existing concept · 🟡 partial — needs a specific
Worker/skill/command · 🆕 new capability to add · ⚪ optional (explicitly not a must-have)

| # | `ai-sdd` capability | Where it lives in the new model | Status | Notes |
|---|---|---|---|---|
| 1 | Close a **vague idea → requirements** (master-requirements artifacts) to start implementation | **Requirements Factory**. Intake is a **union** of sources (`intake-bundle.v1`): a `map` routes each by **transport** (gdoc / repo-file / PDF) to a **loader** → `intake-source.v1`, then `intake.normalizer` runs as a **join** that synthesizes the whole set (by **semantic type**) → canonical `normalized-intake.v1`; → `requirements-author` → `locked-spec.v1` | 🟡 | Compiler "many front-ends → one IR" + a synthesis join. Generalizes `ai-sdd`'s `IntakeType`; axes are add-only, sources unbounded. Specs in `examples/sdlc-plant/`. Workers/skills/loaders remain to build. |
| 2 | Skill to **drive out ambiguity → closed decision document** (for repeatability) | `decision-closer` Worker → `decisions.v1` (closed decisions; maps to `NormalizedIntake.closedDecisions`), gated by the `no-open-decisions` Check at the Requirements-Factory exit | 🟡 | See `checks/no-open-decisions.check.yaml`. Repeatability = closed decisions (deterministic *input*) + engine determinism (pinned snapshots, ADR-0010 / ADR-0023). Bounded clarification loop routes unresolved questions to a human. |
| 3 | Tooling to **create architecture & verification docs** for a codebase/stack | A `bootstrap` Worker/command (onboarding/periodic, **not per-run**) that authors a stack's **conventions** (→ a Trait) and **verification** (→ Checks) | 🆕 | Cold-start codebase intelligence. Splits by freshness: **executable Checks** wired to live tooling (self-fresh) + a **small prose conventions layer** (stale-prone, managed by drift-detection + re-bootstrap). Feeds Traits (ADR-0024) + the Check registry. See architecture.md §8 "Bootstrapping a stack". |
| 4 | **Create agent (role) per stack** | One Worker per role + Traits for the stack; `ai-sdd worker init/fork` scaffolding | ✅ | Covered by concept #2 (ADR-0021 / 0022 / 0024). |
| 5 | Command to **run one cycle** | Engine CLI `run` — one **Run** of a Pipeline/Factory (generalizes `runLoop`) | ✅ | A "cycle" = one Run. Maps to today's `swift run sdd run`. |
| 6 | Command to **run multiple cycles serially** | CLI batch runner over a queue of Runs (or the Conductor processing them in order) | 🟡 | Straightforward serial batch of Runs. |
| 7 | Command to **run multiple cycles in parallel** | Concurrent Runs via the Scheduler (plus intra-Run `map`) | ⚪ | Known-problematic in `ai-sdd`; **not a must-have**. The DAG scheduler + `map` make it possible later, but deprioritized. |

## Implied CLI surface

The inventory implies these engine commands (the engine is the only code — ADR-0001):

- `ai-sdd run <feature>` — run one cycle (one Run). *(#5)*
- `ai-sdd run --batch [--serial]` — run multiple cycles serially. *(#6; parallel is #7, optional)*
- `ai-sdd worker init | fork` — scaffold role Workers. *(#4)*
- `ai-sdd bootstrap <repo>` — generate a stack's conventions (Trait) + verification (Checks). *(#3)*
- `ai-sdd validate` — validate all specs (structural + schema + referential). *(ADR-0020)*

Requirements/decision capture (#1, #2) run *inside* the Requirements Factory as Workers/skills,
not as standalone CLI commands.

## Gaps surfaced by this pass

- **#3 (bootstrap conventions + verification) is the one genuinely new capability** — the
  cold-start side of the "codebase intelligence" problem and the feeder for Traits + Checks. The
  freshness strategy (prefer executable verification; manage prose-convention drift) is now
  captured in architecture.md §8 "Bootstrapping a stack"; still to build: the `bootstrap` Worker
  spec itself.
- **#1 and #2** are now spelled out as example specs — the Requirements Factory, its pipeline
  (`intake.normalizer → decision-closer ↔ ask-stakeholder → requirements-author`), and the
  `no-open-decisions` exit gate. The Workers/skills themselves remain to build.
- **#7** is explicitly optional and deprioritized.
