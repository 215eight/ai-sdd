# Architecture Decision Record

> Status legend: **Accepted** (decided), **Open** (not yet resolved).
> Companion to [architecture.md](architecture.md). Newest decisions reference earlier ones.
> Dates are when the decision was recorded.

---

## ADR-0001 — Specs are data; the engine is the only code
**Status:** Accepted · 2026-06-09

**Context.** Hardcoding a workflow in source is not sustainable — proven by OpenSpec's
OPSX, which moved from a TypeScript-embedded flow (immutable, all-or-nothing,
one-size-fits-all) to externalized YAML schemas. Teams need to change the flow without
recompiling.

**Decision.** Every structural element (Plant, Factory, Pipeline, Worker, Check) is a
declarative, forkable, versioned spec. The engine is a fixed interpreter that knows
nothing about specific phases or domains; it only loads specs, resolves dependencies,
runs work, evaluates checks, and folds events.

**Consequences.** Changing the flow = editing a spec, never recompiling. Specs need a
loader, validator, and versioning. The engine must be domain-agnostic.

**Alternatives rejected.** Hardcoded phase machine (OPSX's abandoned legacy model).

---

## ADR-0002 — The model is self-similar (Plant → Factory → Pipeline → Worker)
**Status:** Accepted · 2026-06-09

**Context.** Modeling the whole SDLC as one Pipeline becomes unreadably complex.

**Decision.** Decompose recursively using the *same* primitives at every altitude. A
Worker is a unit of work; a Pipeline is a DAG of Workers; a Factory is a domain-bounded
unit of Pipelines exposing a typed contract; the Conductor coordinates Factories and is
itself a Pipeline; the Plant is the whole.

**Consequences.** Decomposition needs **no new primitives** — typed Artifacts on Edges,
Checks at boundaries, Scheduler/Reducer, RunEvent log work at every level. Subsumes the
earlier "sub-Pipeline" idea (a sub-Pipeline is an in-process Factory).

---

## ADR-0003 — Canonical vocabulary (Hybrid anchor)
**Status:** Accepted · 2026-06-09

**Context.** Coined terms (Station, Port, Gate, Operator) collided with established
engineering vocabulary and with the existing codebase.

**Decision.** Anchor naming to a hybrid of dataflow + CI vocabulary:
**Plant · Factory · Conductor · Pipeline · Run · Worker · WorkerKind · Adapter ·
Resource · Edge · Artifact · Schema · Check · CheckRunner · CheckResult · Scheduler ·
Reducer · RunEvent.**
**Dropped:** Port/Socket, Gate, Operator/Role/Node/Station (→ Worker), Phase as a control concept.

**Consequences.** Harmonizes with existing `ArtifactRef`/`RunSummary`/`AgentAdapter`.
"Adapter" keeps its existing meaning (LLM backend).

**Alternatives rejected.** Pure compiler vocabulary (LLVM) — elegant but less broadly
fluent; pure CI vocabulary — too thin for the DAG.

---

## ADR-0004 — Worker = data; one engine runs any role
**Status:** Accepted · 2026-06-09

**Context.** The current engine hardcodes roles per phase (`agentRole: "sdd-planner"`).

**Decision.** A `Worker` is fully described by a spec (kind, typed signature, adapter,
resources, context policy, checks, retry, template). The engine never branches on which
role it is. "Worker" absorbs the would-be Operator + Role + Node; its `role`/name
(architect, coder…) is just its identity.

**Consequences.** Adding a role = adding a spec, not a code change. Re-parameterizing per
product (Go vs Python) = a different spec/overlay, same engine.

---

## ADR-0005 — The flow lives in one place; Workers declare only a type signature
**Status:** Accepted · 2026-06-09

**Context.** Concern that per-node dependency declarations scatter the flow definition.

**Decision.** Topology (nodes + edges) lives **centrally in the Pipeline spec**. A Worker
declares only its typed `consumes`/`produces` Schemas, not its wiring. Edges are
**authored**, and **type-checked** against Worker signatures at load — not inferred by
type-matching.

**Consequences.** The Pipeline is the single readable definition of a flow (renders 1:1
to the DAG). Workers stay reusable across Pipelines. Mis-wired edges fail at load.

**Alternatives rejected.** Emergent/auto-wired graph (pure Dagster/Make style) — would
scatter the flow, the exact failure mode to avoid.

---

## ADR-0006 — Dependencies are enablers; Checks are gates
**Status:** Accepted · 2026-06-09

**Context.** OPSX: "dependencies are enablers, not gates… work isn't linear."

**Decision.** Separate two concerns. Dependency Edges express **readiness only**
(enablers) — any node may be revisited/edited/re-run anytime. **Checks** (`required: true`)
are the **gates** — the explicit, auditable places the flow blocks. "Phase" is therefore
**not** a control concept (cosmetic label at most).

**Consequences.** The flow is fluid and non-linear *and* gates are explicit/auditable —
good for both iteration speed and SOC2/HIPAA.

---

## ADR-0007 — A gate and an eval are the same Check (two modes)
**Status:** Accepted · 2026-06-09

**Decision.** Unify gates and evals into one `Check` run by one `CheckRunner`:
`inline` mode blocks a live Run; `offline` mode scores fixtures (an eval). Same
definition, same executor, same `CheckResult`.

**Consequences.** A verification gate written once *is* a regression eval — zero drift
between what gates the line and what evals measure. Promotion gates and "judge-the-judge"
fall out naturally. Compliance checks must be deterministic, never judge.

---

## ADR-0008 — Adapter (LLM) is separate from Resource (system integration)
**Status:** Accepted · 2026-06-09

**Context.** The scenario needs Figma, GitHub, AWS/EKS, Aurora, Statsig — not just LLMs.
The existing `AgentAdapter` means LLM compute only.

**Decision.** **Adapter = the brain** (LLM backend: claude-code, codex). **Resource = the
hands** (external system integration, with credentials via the existing `SecretResolving`
boundary). A Worker binds one Adapter and several Resources.

**Consequences.** Clean "model + tools" split; per-Factory credential scoping.

---

## ADR-0009 — Artifacts are typed handles, not just files
**Status:** Accepted · 2026-06-09

**Context.** A design is a Figma node; a rollout is a k8s ref; an experiment is a Statsig
id; a gRPC contract lives in another repo. `ArtifactRef.path` assumed a filesystem.

**Decision.** Generalize `Artifact` to a typed **handle**: `file · figma · git-ref ·
k8s · statsig · url`. Content-addressed; carries producing identity; has a state.

---

## ADR-0010 — Event-sourced state with bidirectional ingest
**Status:** Accepted · 2026-06-09

**Decision.** The `RunEvent` append-only log is the source of truth; the run summary is a
projection (the `Reducer` is pure). External systems (Statsig webhooks, alert managers)
can **ingest** events into the log.

**Consequences.** Free audit, resume, and eval replay from one log. Enables sensors
(ADR-0014). Requires an ingest boundary.

---

## ADR-0011 — Rework is runtime re-execution, not a topology cycle
**Status:** Accepted · 2026-06-09

**Context.** "Review fails → back to implement" looked like it needed cycles in the DAG.

**Decision.** Keep the DAG acyclic (it models dependencies). Rework = a failing Check
routes back to the producing Worker as a **bounded** re-execution with the `CheckResult`
as added (optional, delayed) input. Terminate explicitly (bounded rounds → escalate to
human); invalidate **scope** (only affected Worker + downstream dependents); carry state
across attempts.

**Consequences.** No cyclic dependencies; iteration is auditable per `RunEvent`. The
review→implement loop is just the human/judge-grade case of the general rule.

---

## ADR-0012 — Decompose by domain/ownership, not by repo
**Status:** Accepted · 2026-06-09

**Context.** A single mega-Pipeline is too complex; but over-decomposition (a Factory per
repo) yields a distributed monolith.

**Decision.** Decompose the Plant into domain-bounded Factories aligned to SDLC phase
**and** team ownership (Conway's law) — e.g., Requirements/Design/Code/Deployment.
Repo/service-level fan-out stays **inside** a Factory via `map`.

**Consequences.** Bounded complexity per Factory; independent ownership/versioning;
inter-factory contracts must be versioned (see Open ADR-0017).

---

## ADR-0013 — Coordination = orchestrated saga backbone + event signals
**Status:** Accepted · 2026-06-09

**Decision.** The **Conductor** (a saga orchestrator) explicitly drives the forward path,
so the macro-flow is one readable definition. Asynchronous long-range feedback
(Deployment → upstream) flows as a **classified signal** the Conductor catches, not
through the synchronous backbone.

**Consequences.** Macro-flow stays consolidated (no scattering). A correlation Run id
threads all Factories for tracing. The Conductor needs an explicit owner.

**Alternatives rejected.** Pure choreography (event-only) — would make the end-to-end
flow implicit/emergent.

---

## ADR-0014 — Adopt four scaling primitives: map, sub-pipeline, sensor, resource
**Status:** Accepted · 2026-06-09

**Context.** Stress-testing the real SDLC (multi-repo, Figma, rollout/observe) broke the
flat model in four specific, well-understood ways.

**Decision.** Add `map` (dynamic fan-out), `pipeline` (hierarchy), `sensor` (external +
time signals), and `Resource` (system integration). Each lives where its domain needs it;
all are standard orchestration concepts (Argo/Airflow/Dagster/Temporal).

**Consequences.** `map` preserves the consolidated flow (one authored node materializes N
at runtime). Updates `WorkerKind`. Honest correction to an earlier "the model is enough"
claim.

---

## ADR-0015 — Build on the existing `ai-sdd` Swift packages
**Status:** Accepted · 2026-06-09

**Decision.** Generalize rather than rewrite: `WorkflowEngine` → `Scheduler` + `Reducer`;
add a `RunEvent` log with `RunSummary` as projection; reuse `ArtifactRef`/`ArtifactState`,
`IdentityAttribution`, `TokenAttribution`, telemetry, `SecretResolving`, and
`AgentAdapter` (as `Adapter`).

---

## ADR-0020 — Spec format (YAML) and layered validation
**Status:** Accepted (implementation pending) · 2026-06-09

**Context.** Specs are authored in YAML, which forfeits the compile-time type safety
Swift would give if they were code. We considered switching to JSON/JSONL to use a
serialization step as the validation mechanism. But: (a) decoding YAML into strict Swift
`Codable` types already provides a serialization-time validation gate, independent of
format; (b) JSONL is for append-only *record streams* (the `RunEvent` log), not nested
config documents, and would kill comments; (c) compile-time safety on external data is
impossible by construction once specs are data (ADR-0001) — validation is the
compensating control. Crucially, the checks that matter most (referential/graph) are not
provided by any format or serializer.

**Decision.** Keep **YAML** on disk for specs (human-authored, commentable, forkable).
Validate in three layers:
1. **Structural / type** — decode into Swift `Codable` types (via Yams). The Swift types
   are the source of truth; a decode failure means the spec is invalid.
2. **Constraints / schema** — a **JSON Schema** per spec kind, for in-editor feedback
   (`yaml-language-server`: autocomplete + inline errors) and CI. Kept in sync with the
   Swift types (generated from them, or round-trip-tested against the example specs).
3. **Referential / graph** — a custom **`ai-sdd validate`** pass over the decoded model:
   worker/check id resolution, Edge-vs-Worker signature type-compatibility, DAG
   acyclicity, and contract coverage.

Run all three **on every update** (editor + pre-commit/CI) and as a **boot gate** before
any Factory starts a Run — no Run proceeds against an invalid Plant. Reserve **JSONL** for
the `RunEvent` log, not for specs.

**Consequences.** Type safety is re-imposed at load time rather than compile time
(inherent to spec-as-data). Implementation needs: a Yams dependency, a JSON Schema set
plus a sync/test mechanism, and the `ai-sdd validate` command.

**Escape hatch.** If authoring-time type safety proves necessary, adopt **Pkl** (Apple's
typed configuration language — renders YAML/JSON, has `pkl-swift`, generates Swift types)
for typed, validated authoring without embedding specs in the engine.

**Alternatives rejected.** Switch specs to JSON/JSONL (no validation benefit; JSONL is the
wrong shape for config and loses comments). Embed specs in Swift source for compile-time
safety (the hardcoded model rejected in ADR-0001).

---

## ADR-0021 — Framework-agnostic Workers via a Model Catalog
**Status:** Accepted (implementation pending) · 2026-06-09

**Context.** In `ai-sdd` a Worker's unit of work is a repo-defined **skill** (or a command
that runs a skill), surfaced via `AGENTS.md` / `CLAUDE.md` — not a bespoke prompt. The work
must specify a model and reasoning level, be configurable per AI company, and survive model
churn (today's best is `claude-opus-4-8`; tomorrow it is something else). The first draft
hardcoded `adapter: claude-code` + `model: claude-opus-4-8` + an inline `template` in each
Worker — provider-locked and churn-fragile.

**Decision.**
- A Worker's work is a **skill/command reference** (portable; the Adapter invokes it per
  provider via AGENTS.md/CLAUDE.md), not an inline prompt.
- A Worker declares a model **tier** (capability alias, e.g. `deep-reasoning`) and a
  **reasoning level** (`minimal/low/medium/high`) — **never a provider or concrete model id.**
- A **Model Catalog** spec (one per AI company, selected by the workspace `config`) maps
  tiers → `(provider, model, reasoning)` and providers → adapters. It is the single place
  concrete model ids live.
- The **Adapter is resolved from the catalog**, not named by the Worker. **Workers always
  go through the catalog; pinning a provider/model on a Worker is disallowed** (decided).

**Consequences.**
- Retargeting the whole Plant to a different AI company = swap the active catalog; zero
  Worker edits.
- Model churn = a one-line catalog edit; being a versioned spec change it trips the
  promotion gate (ADR-0007), so a new model goes live only if its eval suite does not regress.
- Refines ADR-0008 (Adapter stays the brain, now provider-abstract and catalog-resolved);
  rides on ADR-0004 (it is all Worker spec data) and ADR-0007 (model swaps are eval-gated).

**Alternatives rejected.** Per-Worker provider/model pinning (re-introduces provider
lock-in and churn fragility; defeats the catalog swap). Inline prompt templates as the unit
of work (loses the repo-skill indirection `ai-sdd` relies on — a template may still be the
*content* of a skill, but the Worker references the skill, not a file).

---

## ADR-0022 — Worker capability guardrails, Resources, and scope confinement
**Status:** Accepted (implementation pending) · 2026-06-09

**Context.** `ai-sdd` Workers had guardrails — read-only vs edit, allowed tools, stack
conventions. The draft Worker had none, and its "hands" were an undifferentiated
`resources: [github]`. We also must forbid one Worker from making cross-cutting changes
across the multi-repo microservice fleet.

**Decision.**
- **Resource as a spec** (`kind: Resource`, reusable). A Resource is a Worker's hands and
  resolves to either an **MCP server** or **CLI tools** with a specific configuration;
  credentials come from the `SecretResolving` boundary. It declares a `defaultAccess` and a
  `scope`.
- **Capability guardrails** via a Worker `permissions` block: access mode per Resource
  (`read-only`/`read-write`), tool **allow/deny**, and **filesystem scope**. Default-deny.
  The engine translates this into the Adapter's sandbox — **runtime-enforced, not
  prompted** — and every tool use is attributed (`IdentityAttribution`) for audit.
- **Convention guardrails** reuse the ADR-0006 split: inject via `context` (soft) + enforce
  via `checks` (hard).
- **Scope confinement / no cross-cutting:** a Worker instance's write scope is bound to its
  assigned repo/stack (from `StackAssignment`). One instance = one repo's scope; it cannot
  edit another service by construction. Cross-service change is decomposed at the Pipeline
  level via `map` + a shared typed Artifact (the gRPC contract). Architectural cross-cutting
  is caught by a `judge` Check.

**Consequences.** Least-privilege, auditable execution; cross-cutting is impossible by
write-scope rather than by policy. Refines ADR-0008 (Adapter/Resource split).

---

## ADR-0023 — Late-bound stack resolution with pinned snapshots
**Status:** Accepted (implementation pending) · 2026-06-09

**Context.** Per-stack specialization could be **pre-generated** (a command emitting
concrete per-stack worker configs) or **resolved live** per run. Generated specs drift and
are one step from the hardcoding rejected in ADR-0001.

**Decision.** Resolve the stack **late, at run start** — a generic role Worker plus the
node's stack (known from `StackAssignment`) → resolved conventions/checks/resources. **No
pre-generated per-stack specs.** The fully-resolved binding (traits, convention/check
versions, resolved model tier) is **snapshotted into the `RunEvent` log**, giving
static-config inspectability and reproducible replay without materialized files.

**Consequences.** Single source of truth; conventions are always current (good for evolving
brownfield codebases); adding a stack = adding its trait files, no regeneration. Rides on
ADR-0010 (event log) and ADR-0007 (versioned trait/convention changes are eval-gated).

**Alternatives rejected.** Config-generation command (derived specs drift; codegen-of-specs
is one step from hardcoding).

---

## ADR-0024 — A Stack is a composition of Traits
**Status:** Accepted (implementation pending) · 2026-06-09

**Context.** Real stacks are not scalars. An Apple multi-platform app is
`apple + ios + macos + combine + swiftui + <ui-package>` simultaneously; a single `stack`
value cannot express it.

**Decision.** Split into **Trait** (an atomic, composable convention/capability module —
conventions + checks + resources, with transitive `requires`) and **Stack** (a named bundle
of Traits). A Worker carries `stack: <name>` (or inline `traits: [...]`); one role serves
all stacks. At resolution (ADR-0023) the engine expands transitive `requires`, unions
conventions (ordered), unions and de-dupes checks, and unions resources. Name chosen:
**Trait** (native to Rust/Scala and Swift Package Manager).

**Consequences.** Multi-dimensional / multi-platform stacks are expressible and DRY;
generalizes `ai-sdd`'s scalar `StackAssignment` to a trait-set. Same composability principle
as the model itself (ADR-0002).

**Alternatives rejected.** Scalar `stack` (cannot express multi-platform); names
"Layer"/"Capability" (Trait is more ecosystem-resonant).

---

## ADR-0025 — Shared state plane; Git-as-control-plane backend
**Status:** Accepted · 2026-06-09

**Context.** The async-resumption design (architecture §10) implied a Run's event log could
live on a local machine. That breaks any multi-user handoff: if a designer on machine A records
the handoff event on A's laptop, a coder on machine B never sees it.

**Decision — plane separation.** The **state plane** (the `RunEvent` log + artifact store, the
single source of truth) lives in a **shared, durable store** reachable by every participant,
machine, webhook, and CI runner. The **compute plane** (the engine that folds events and runs
Workers) is a transient *client* and may run anywhere (laptop, CI, cron, server), one-shot. "No
always-on process" applies to compute, **not** state; a purely local log is valid only for a
single-user loop.

**Decision — backend: Git-as-control-plane (starting solution).** The shared store is a Git repo
(the direct evolution of `ai-sdd`'s `openspec/` persistence): lowest-ops, reuses existing GitHub
infra, gives audit + per-ref ordering for free. It sits behind a `StateStore` / `ArtifactStore`
abstraction, so a control-plane **service** is a later swap with **no flow-spec change**. The
backend is selected in `config.yaml` (`stateStore.backend`) — the *only* place it is chosen;
flow specs stay backend-agnostic.

**Concurrency — optimistic, conflict-free by construction.**
- **One file per event** (`runs/<runId>/events/<ulid>.json`): concurrent writes touch disjoint
  paths → git auto-merges with no conflict. (Never a shared append-only `events.jsonl`.)
- **Optimistic CAS:** a losing simultaneous push is rejected (non-fast-forward; or GitHub Git
  Data API SHA precondition → 409); the writer re-pulls (rebase) and retries — clean because the
  paths are disjoint.
- **Ordering from event ids** (ULID), not commit order → stable under rebase; truly-concurrent
  events commute, causally-dependent ones are already ordered by DAG readiness.
- **Idempotent event ids** → at-least-once delivery becomes effectively-once.
- **Ref-per-Run** (cross-run never contends) + `ai-sdd`'s one-active-run lock for the same-node race.

**Write cadence & failure model.**
- **Completion = append.** Emitting a `RunEvent` *is* the commit; an event that was not pushed
  did not happen. The store records **transitions + artifact handles**, not the work itself
  (work stays in Figma / a branch / a doc). So there is no "did the work but forgot to push" gap.
- **Cadence** is event-granular (per node boundary) — tens of small appends per run, not
  continuous. Consumers read via a push-webhook or a poll interval. Batch a node's events into
  one commit; funnel a run's writes through its one advancing engine to cut churn.
- **A late/missing push degrades safely, never to lost coordination:** crash mid-write → node
  looks unfinished → idempotent re-run; stale reader → CAS rejection → re-pull; offline machine →
  pending-until-reconnect, or timed-out-and-reassigned. The residual risk is **latency/stall**
  (a human or offline machine not acting), mitigated by `sensor`/`human` timeouts + escalation +
  shared-log visibility.

**When to switch to the service backend.** High write contention — giant simultaneous fan-outs,
or many concurrent runs hammering one ref — causes retry churn. Flip `stateStore.backend` to
`service`; same abstraction, no flow-spec change.

**Consequences.** File artifacts need a shared artifact store (git-lfs / s3 / service); cloud
handles (figma/url/git-ref) are already shared. Corrects the local-state implication in §10.

---

## ADR-0017 — Inter-factory contract versioning & compatibility
**Status:** Accepted · 2026-06-09 *(resolved from Open)*

**Context.** The inter-factory contracts (`locked-spec.v1`, `approved-design.v1`,
`release-candidate.v1`, `rollout-outcome.v1`) are APIs between independently-deployed Factories
(ADR-0012). They must evolve without flag-day coordination — the biggest tax of decomposition.

**Decision — semver with a hard additive rule.** A contract Schema carries a version
`MAJOR.MINOR`. The `.vN` in the contract name **is the major** (what edges reference, e.g.
`locked-spec.v1`); minors evolve within it.
- **PATCH** — wording/clarification, no shape change. Always compatible.
- **MINOR** — **additive only** (new *optional* fields). Backward- *and* forward-compatible:
  old consumers ignore new fields; new consumers tolerate their absence.
- **MAJOR** — any breaking change (remove/rename/retype a field, or make an optional field
  required). Produces a **new contract** (`.v2`) — never an in-place break.

**Decision — producer-satisfies-consumer, checked at load.** A consumer Factory declares a
caret range per input (`requires: locked-spec ^1.3` = `>=1.3.0 <2.0.0`); a producer declares
what it emits (`provides: locked-spec 1.4`). The wiring is valid iff **major matches and
producer.minor ≥ the consumer's required minor**. This extends the load-time `SpecValidator`
(architecture §5) — incompatible Factories fail to load, before any run. A consumer that needs
a field added in 1.3 bumps its range to `^1.3`; the loader then forces the producer to be ≥1.3.

**Decision — breaking changes use expand-contract (parallel change).** To cross a major without
a flag day, the producer **dual-publishes** both `vN` and `vN+1` during a deprecation window;
consumers migrate at their own pace; once all are on `vN+1`, the producer drops `vN`. A version
may be marked `deprecated` with a sunset; the registry warns during the window. (Optional: an
**upcaster** Worker that translates `vN→vN+1` so the producer need not hand-maintain two
emitters.) The same expand-contract / parallel-change pattern applies to any shared interface
that spans repos (the cross-repo *ordering* is just dependency edges — see ADR-0018, dropped).

**Decision — the change itself is gated.** A `contract-compat` Check diffs a changed contract
Schema against its registered predecessor and enforces the rule (additive ⇒ MINOR, breaking ⇒
new MAJOR). A bump that violates the declared compatibility level cannot be promoted (ties to
the promotion gate, ADR-0007). Confluent-schema-registry-style enforcement.

**Consequences.** Most evolution is free (additive minors, no consumer changes). Breaking
changes are explicit, dual-published, and bounded by a deprecation window. The Conductor's
contract list carries each contract's `version` + `compatibility`; `requires`/`provides` live
on the Factories.

**Alternatives rejected.** Unversioned contracts (silent cross-Factory breakage). In-place
breaking changes (flag-day coordination across independently-deployed Factories — exactly what
decomposition is meant to avoid).

---

## ADR-0026 — Execution model: deterministic planner + skills, two modes
**Status:** Accepted · 2026-06-10

**Context.** How does the factory run, and who owns control flow — the engine or the LLM?
Legacy `ai-sdd` used a deterministic Swift engine for transitions plus agent-executed skills,
invoked as registered commands inside Claude Code / Codex.

**Decision (Option 3 — hybrid).**
- **The deterministic engine is the planner.** `Scheduler` / `Reducer` / validator own control
  flow (what's runnable, did the gate pass, advance state). **Gating is engine-enforced** (the
  engine runs the check command and reads the result) — never agent-reported.
- **The LLM does the work via skills.** A *driver* skill runs the loop (`next` → work →
  `submit`); *worker* skills do the per-node work. "Don't use prompts for control flow."
- **Dynamism is in the spec, not the LLM.** The declarative DAG already makes flows dynamic;
  the engine interpreting it deterministically gives reliability. LLM-as-planner would add
  nondeterminism without adding capability.
- **Two modes, one engine.** *Interactive* (Mode B): the engine is a registered command / MCP
  tool inside Claude Code / Codex; the host session is the Adapter; human-in-the-loop — the
  legacy methodology and the **MVP**. *Autonomous* (Mode A): `factory run` spawns headless
  agents (`claude -p` / `codex exec`) per Worker for CI/batch. The Adapter has **host** vs
  **headless** realizations (ADR-0008).

**Consequences.** Matches legacy methodology; reliable, auditable control flow; reuses the host
agent's LLM/tools/sandbox/HITL in Mode B (smallest MVP).

**Alternatives rejected.** LLM-as-planner (nondeterministic control flow — the BMAD/Ralph
failure mode the project exists to avoid). The engine as an LLM wrapper (it has no LLM logic).

---

## ADR-0016 — Durable, resumable rollout (DROPPED)
**Status:** Dropped · 2026-06-10

Was: how a long-lived, monitored rollout resumes (not restarts) after an upstream fix, plus
compensation/rollback. **Dropped — not a committed use case, and mostly not an engine feature.**
A rollout flow is a Pipeline with `sensor` nodes; resume is the §10 async-resumption mechanism +
the shared state plane (ADR-0025); "issue → fix → resume" is rework / scoped re-entry (ADR-0011).
The one residual — compensation/rollback (a stage's inverse action) — is just a compensating
Worker on a conditional edge, to be designed if/when the factory ever manages deployments.
Like gRPC (ADR-0018), it came from the stress-test SDLC scenario, not a committed requirement.

---

## ADR-0018 — Cross-repo atomicity (DROPPED)
**Status:** Dropped · 2026-06-10

Was: "how does a gRPC-contract change land across repos atomically." **Dropped — not an engine
concern.** Cross-repo ordering ("def repo before consumers") is just dependency edges in the
**planning-skill-produced dependency graph**, sequenced by the engine like any other (§5, "two
kinds of DAG"). gRPC was a stress-test example, not a feature. Contract *compatibility* (the
separate, real concern) stays covered by ADR-0017.

---

## ADR-0019 — Name for the Conductor
**Status:** Accepted · 2026-06-10

**Decision.** Keep **Conductor** (the cross-factory saga orchestrator) — clear, on the orchestra
metaphor, already used throughout. (Rejected: "Production Control" — heavier; the factory
metaphor is already carried by Plant/Factory/Worker.) No Conductor in the MVP (single Factory).

---

## ADR-0027 — Dependency-graph rendering & multi-repo Plant aggregation (observability)
**Status:** Accepted · 2026-06-19

**Context.** Adopters need a shared, drill-downable view of the work — per feature and across a whole
program — as a team grows past a single developer. The worked example is a fintech BNPL program: ~24
repos (mobile ×5; a GQL gateway + 2 subgraphs + their deps; 1 integration + 3–5 product microservices
+ 3 gRPC-contract repos; a 3rd-party gateway), 9 people (PM, designer, frontend, gql, 5 backend), and
5 milestones, each running PRD → design → RFC → implement → test → rollout → monitor. That is the §13
four-Factory Plant (Requirements/Design/Code/Deployment) threaded by a single correlation id (§11).
The workflow that worked single-dev was **Mermaid-in-markdown** rendered in a browser; the architecture
already states the Pipeline "renders 1:1 to the DAG diagram" (§5, ADR-0005) and uses Mermaid as the
house medium — but **no command renders it, and nothing aggregates across repos.** This was a gap, not
a recorded decision (a memory sweep found no prior decision; the only "observability" note concerns
eval quality, a different axis).

**Decision.**

- **A deterministic `ai-sdd graph` renderer over committed specs.** Rendering a DAG is a pure transform
  of spec data (no LLM) — *specs are data; the engine is the only code* — so it is an engine subcommand
  beside `validate`/`status`. It emits **portable static artifacts**: Mermaid-in-`.md` for in-repo/IDE
  viewing and a self-contained static site (HTML + inline SVG/Mermaid, no server) for an
  "anyone-with-a-link" view. **Publishing is a separate, pluggable step** — GitHub Pages is *one*
  adapter; GitLab Pages, S3, internal nginx, or `open index.html` are equals — so the engine stays
  git-host-agnostic, mirroring the `stateStore.backend`-in-config pattern (ADR-0025).

- **Three orthogonal node dimensions, not one "lane".** A node carries `factory` (the discipline lane —
  requirements/design/code/deploy), `stack` (the tech — backend/gql/ios; already a node field), and
  `owner` (the people). `owner` is a **list, per-node, inherited from the feature lead and overridable
  per slice by the IC**, so a feature's lead and its per-task ICs both surface without flattening the
  hierarchy. Views are filterable **projections** of one tagged graph (by milestone / lane / stack /
  owner / status); zoom follows the self-similar levels (§3): Plant → per-milestone Conductor backbone
  → Factory → Pipeline → per-repo slice graph → build pattern.

- **Self-describing fragments; the join key is the correlation id.** A feature pipeline gains additive,
  optional metadata: `origin` (repo + git tag + commit hash + path), `correlation` (the milestone/program
  key), `factory`, and `owner`. Because a milestone spans many repos, fragments are aggregated **by
  `correlation`, not by repo** — the architecture's single-id-threads-all-factories (§11). The fields are
  additive and namespaced so they never collide with existing artifacts.

- **Single-repo first; a configurable, thin Plant layer for multi-repo.** The MVP renders one repo's
  features with no extra config. Multi-repo uses the *same* renderer pointed at a thin **`plant.yaml`**
  in a thin control/Plant repo that owns only the program-level + non-code factories + the published
  site — the narrow, correct slice of "one central repo", **not** centralizing all development (the
  distributed-monolith trap, ADR-0012). At ~24 repos, fragments are **push-published** (each repo's CI
  renders its fragment + a small machine-readable manifest to the shared location) rather than
  central-fetched (which would need read creds to every repo + clone-at-render cost). Output lives in
  its own namespace (`.ai-sdd/graph/`, `plant.yaml`) — never under `features/`, `runs/`, or `artifacts/`.

- **Contracts generalized and git-versioned.** Any model-defining artifact (a gRPC contract, an iOS
  models/API package, a shared schema package, an OpenAPI doc) is a versioned cross-repo edge, identified
  by a **git tag (semver → semantic compatibility) plus the commit hash (exact identity + staleness)**.
  The tag lets the renderer compare versions semantically (consumer requires `^2.0`, producer provides
  `2.1` → compatible); the hash shows drift ("pinned 3 commits behind"). Both are git-native, no bespoke
  registry. Enforcing that a tag is *honest* (a breaking change really bumped major) is deferred to
  ADR-0017's `contract-compat` check — the view is fully useful without it.

- **Upstream (PM/Design) is an adoption path, gated only on git.** A non-code workspace is just a **git
  repo with a `.ai-sdd/`** — durability comes from git (ADR-0025), so no bespoke storage is needed. If
  the PM/Designer adopt ai-sdd (in a terminal or via an agent) their phases become **real fragments**
  reusing the existing schemas; if they don't, the phase renders as a **placeholder external/human node**
  (a typed handle + a human gate, ADR-0009/§10) so the milestone's correlation chain never breaks.

- **The Conductor stays optional and pluggable.** Human-driven coordination is the default and is already
  the MVP execution model (interactive Mode B, ADR-0026). The graph only needs to **represent** the
  cross-factory flow (read-only); the cross-factory **seam** — declared edges + contracts + the
  correlation id — is present so an automatic Conductor can plug in later, but is never required to run.

- **Static structure now; live overlay later.** The static structure view ships first (committed specs,
  no shared state needed). A **live progress overlay** — coloring nodes by `done/in-progress/runnable/
  rework/escalated` from the run log — is a planned **expansion** behind the shared state plane (ADR-0025);
  at this fan-out it likely wants the **service backend**, since many tiny event commits to one git ref
  contend.

**Consequences.** The whole-program view becomes the first concrete use of the **Plant** level even
before the execution Conductor exists (§14/§19) — read-only aggregation needs only the Plant index +
published fragments. Adopters keep their Mermaid-in-markdown workflow, now generated from live specs and
shared. Specs stay next to their code (ADR-0012); the thin Plant repo owns only program-level/non-code
concerns + state + site. New work: the `ai-sdd graph` renderer; the additive fragment metadata + manifest
format; a `plant.yaml` aggregator; and (later) the live-state overlay + a shared-state backend at scale.

**Alternatives rejected.** Coupling to GitHub Pages (one git host of many; the renderer must stay
host-agnostic). One central repo for *all* development (distributed-monolith trap, ADR-0012; specs would
drift from the code they describe) — only the *thin* program/state/site layer is centralized.
Central-fetch of every repo at render time (permissions + clone cost at scale) over push-published
fragments. A bespoke version registry (git tag + hash already give semantic intent + identity).
LLM-rendered graphs (rendering is a deterministic transform; an LLM there adds nondeterminism without
capability — the ADR-0026 reasoning).

**Implementation status (2026-06-19).** Built and committed — the `GraphRenderer`/`Contracts` engine
+ the `ai-sdd graph` CLI (Swift Testing coverage):

- ✅ **Slice 1** — `ai-sdd graph <dir>`: a Pipeline → Mermaid (both DAG kinds).
- ✅ **Slice 2** — `--project`: a repo index (build pattern + every feature, one file + TOC).
- ✅ **Slice 3** — the four-tag fragment metadata (`origin`/`correlation`/`factory`/`owner`) + per-node
  `owner` (inherits the feature lead), surfaced in headers + node labels.
- ✅ **Slice 4** — `--plant`: multi-repo aggregation grouped by `correlation` (milestone). **Reads
  fragments by LOCAL path only** (single machine / local checkouts).
- ✅ **Slice 5** — contract-version overlay: `provides`/`requires` cross-referenced, semver caret skew
  flagged (✓ / ⚠ skew / ?).
- ✅ **Slice 6** — `--html`: a self-contained page rendering Mermaid client-side (CDN; first load needs
  network).

Pending (designed above, **not yet built** — start here on resumption):

- ⬜ **Live progress overlay** — color nodes by run state (`done`/`in-progress`/`runnable`/`rework`/
  `escalated`). Blocked on the **shared state plane** (ADR-0025); local runs (`.ai-sdd/runs/`,
  gitignored) aren't visible cross-machine, so a team-live view needs the service backend at scale.
- ⬜ **Remote / push-published fragments** — today `FragmentRef` is `{ path }` (local). The ADR's
  push model needs (a) a machine-readable **fragment manifest** (nodes/edges/status as JSON) each
  repo's CI publishes, and (b) the `--plant` aggregator reading manifests / fetching by `origin`
  (repo + ref) instead of local paths.
- ⬜ **Publish adapter** — `--html` emits a file; the pluggable publish step (GitHub Pages / GitLab
  Pages / S3 / nginx) is a thin CI convention, intentionally outside the engine.
- ⬜ **Contract-tag honesty** — that a tag truly reflects additive-vs-breaking; deferred to ADR-0017's
  `contract-compat` check (the overlay uses the declared tag as-is today).

---

## ADR-0028 — Program-tier coordination: recursive pipeline execution + milestones-as-validation
**Status:** Accepted · 2026-06-20

**Context.** A team planning a multi-person project needs a **master plan** that sequences several
sub-features with **milestones and owners**, with validation/integration checkpoints between stages —
not a single feature whose tests all run at the end. The model already promises this: it is self-similar
(ADR-0002), a node with `kind: pipeline` is a sub-pipeline, `PipelineNode.owner` exists, and the run
**state** layer is already recursive (`RunState.slices` is a nested dict, `RunEvent.scoped` nests, the
`Reducer.scoped` fold recurses). But execution only descended **one level** (feature → build pattern):
`dispenseSlice`/`submitSlice` handled a single slice tier and then dispatched to a worker without
recursing. There was also no first-class **milestone** and no **program-tier planning**. The temptation
was to reach for the Conductor (ADR-0013/0019) — but that is a cross-*domain* saga
(requirements→design→code→deploy with async signals), much heavier than, and orthogonal to, recursive
*Pipeline* composition. This is **not** the Conductor.

**Decision.**

- **Reuse `Pipeline` for the program tier — no new top-level kind.** A "program" is a Pipeline whose
  nodes are feature Pipelines (which themselves contain slice Pipelines). One `Scheduler`/`Reducer`/
  `CheckRunner` at every level — the self-similarity is the point; a parallel `Program` primitive would
  fork the engine.

- **Recursive descent to arbitrary depth, via nested `.scoped` events.** `next` (`dispense`) and `submit`
  (`submitDescend`) recurse through `kind: pipeline` nodes to the leaf worker, composing a `scope`
  closure so a leaf's event nests as `.scoped(program, .scoped(feature, …))`. The Reducer already
  *consumes* nested `.scoped`, so no state/Reducer/Scheduler change was needed — only the CLI dispatch.
  A flat path-list event was rejected: it would duplicate a representation the Reducer already folds.

- **Completion cascades on the unwind.** When a sub-pipeline becomes `isComplete`, the engine emits
  `nodeCompleted(sliceNode)` **at the parent's scope**, post-order, cascading to the program root so
  dependents unlock at every level. Emitting at the wrong scope is the one subtle failure mode (it would
  fold completion into the wrong `slices` bucket and break resume), so it is guarded by depth-2 tests.

- **A milestone is a validation worker node, not an empty gate.** It consumes upstream output and produces
  a validation-result, reusing existing primitives: **manual** = `workerKind: human` gated by the
  structural `verdict == approve` check (the reviewer pattern); **automated** = an attached deterministic
  check running e.g. `docker compose up && <integration-client>`, gated on exit code. Maturing
  manual→automated swaps only the `workerKind`/checks on the *same* node — inputs/outputs are unchanged.

- **Program-tier planning has two front-ends emitting the same master pipeline.** An interactive
  *program mode* (sub-features + milestones + owners, same draft-then-approve gate as `ai-sdd-plan`) and
  *milestones-in-brief* (the planner groups generated slices into milestones + inter-milestone validation
  gates). Both produce one master `pipeline.yaml`; `owner` is already a `PipelineNode` field. *(Phases 2–3;
  this ADR's shipped scope is the recursive-execution keystone.)*

**Consequences.** The "multiple levels of coordination" the self-similar model promised is now executable
through the same `next`/`submit` loop — a program runs end-to-end with the engine enforcing cross-feature
sequencing and per-stage gates. The change was confined to `Sources/AISDDCLI/main.swift` (`dispense`,
`submitDescend`, `report`) plus an additive `WorkerInstruction.scopePath`; no engine-core change. Resume
stays sound because every nested event replays through the unchanged Reducer. New work (Phases 2–3): the
milestone validation schema/check/worker convention, and the two program-planning front-ends.

**Alternatives rejected.** A new `Program`/`MasterFeature` primitive (forks the engine; defeats
self-similarity). A flat `pathIds` event representation (parallel to the nested `.scoped` the Reducer
already folds; needs migration, strictly worse). Building on the Conductor (cross-domain saga, unbuilt,
orthogonal to recursive composition — explicitly out of scope). Milestone as an empty check-only gate
node (the team's framing is a validation *flow* with inputs/outputs; a validation worker fits the pipeline
concept and reuses the human/deterministic check duality with no new node kind).

**Implementation status (2026-06-20).** Phase 1 (keystone) built and committed:

- ✅ Recursive `next`/`submit`/`report` in the CLI; arbitrary-depth descent + completion cascade.
- ✅ Additive `WorkerInstruction.scopePath` (full lineage `program › feature › slice`).
- ✅ Depth-2 tests (nested `.scoped` fold; completion cascade unlocks a dependent) + a worked
  `docs/examples/program-nested/` fixture driven to `✓ done`.

Phase 2 (milestone-as-validation-node) built and committed:

- ✅ `validation-result` schema + `validation-result.structure` gate (the milestone verdict gate;
  `outcome == pass`, every criterion pass). Field is `outcome`, not `verdict`, so a failed checkpoint
  **self-reworks** (re-validate) rather than triggering §9 upstream routing.
- ✅ Manual `milestone-gate` worker (`workerKind: human`) + the convention doc
  [docs/milestones.md](milestones.md) (manual ↔ automated swap; maturity transition; wiring).
- ✅ Worked `docs/examples/program-milestone/` (featA → milestone → featB) driven through a failing
  verdict (gate blocks, featB held) and a passing one (featB unlocks → `✓ done`).
- 🐞 Fixed a latent bug surfaced by milestones: `submit` looked up the leaf worker by **node id**, but
  the worker map is keyed by **worker name** — equal in every prior example (`{id: x, worker: x}`), so a
  milestone node (`{id: m1, worker: milestone-gate}`) ran with an empty worker (no checks). Now looks up
  by `node.worker`.

Phase 3 (program-tier planning) built and committed:

- ✅ `ai-sdd-plan-program` skill (program mode): program brief template, draft+approve gate, emits the
  master graph (`.ai-sdd/programs/<slug>/` — feature nodes `kind: pipeline` → `../../features/<feat>` +
  milestone nodes + per-node `owner`), then plans each sub-feature with `ai-sdd-plan`.
- ✅ `ai-sdd-plan` extended with an optional `## Milestones` front-end: phase a feature's slices into
  checkpoints, inserting milestone gate nodes + inter-phase edges (the same primitive, one tier down).
- ✅ Both surfaced in `skills/` + `.ai-sdd/skills/` + `.agents/skills/` (Codex symlink); convention doc
  [docs/milestones.md](milestones.md); worked program brief [docs/examples/program-brief.md](examples/program-brief.md).
- ✅ Verified the prescribed `.ai-sdd/programs/<slug>/` layout (feature nodes → `../../features/<feat>`)
  validates, renders with owners, and runs end-to-end (program → feature → build → worker, milestone
  gating between features).

---

## ADR-0029 — Greenfield bootstrap: brief + stack as the evidence substitute, then hand off to discovery
**Status:** Accepted (implementation pending) · 2026-06-20

**Context.** `ai-sdd-bootstrap` is brownfield-only by construction. Its discovery contract is
**evidence-first** (the manifest, the file tree, and *how it was last done* — git history of a
representative change), and every convention must **cite its evidence**; synthesis may only abstract a
pattern a real exemplar supports. A greenfield repo has no exemplars, no representative change, no
established manifest patterns — so for essentially every change-type discovery hits the same branch
("no evidence → flag → fill from ecosystem priors") and bootstrap degenerates into hand-authoring
conventions, which the skill explicitly warns against ("bootstrapped FROM the codebase, not
hand-invented"). The target case that forces the issue is a **monorepo with multiple verticals, each on
its own stack** — there is no single repo convention to discover even in principle, and nothing to
discover *from* on day zero. The temptation is a bespoke greenfield path that invents conventions from a
brief; but the model already owns the abstraction that replaces code-evidence — **Traits/Stacks**
(ADR-0024): conventions + checks + resources as composable, repo-independent, versioned modules.

**Decision.**

- **Add a bootstrap `seed` mode, engaged only when there is no buildable evidence and a brief is
  supplied.** It is the *same* three-step contract (deterministic input → synthesis → grounded-or-flagged)
  with a **different evidence source**, not a parallel mechanism. The substitution is exact: the **project
  brief** replaces "git history of a representative change"; **resolving a Stack → Trait composition** from
  the trait library replaces "discover conventions from exemplars"; a **stack manifest** (verticals ×
  stacks) replaces the brownfield repo's single stack.

- **Conventions are *resolved*, never invented.** Each vertical's declared stack expands to its Trait
  composition (ADR-0024: union conventions ordered, union/de-dupe checks, union resources). Conventions
  come from the Traits — curated, eval-gated ecosystem priors — not from per-run synthesis. Anything the
  trait library does not cover is **flagged and confirmed with the user**, identically to §1 of the skill.
  This keeps "grounded, not guessed" meaningful: the grounding is a versioned library, not a guess.

- **One Factory per vertical; the monorepo is the Plant.** Each vertical is a domain-bounded Factory
  (ADR-0012: decompose by domain/ownership, not by repo); the monorepo Plant aggregates them, reusing the
  multi-repo/Plant aggregation already built for observability (ADR-0027).

- **Seed a walking skeleton, then hand off to brownfield discovery.** Seed mode scaffolds the minimal
  exemplar per vertical (one module / model / endpoint / test / migration) from brief + traits and commits
  it. The **next** bootstrap is ordinary brownfield: discovery now finds real evidence. Greenfield mode is
  a one-time *seed*, not a permanent replacement for discovery — which restores the code-grounded
  guarantee on the very next run.

- **Do not freeze per-stack specs (ADR-0023 still holds).** Seed mode scaffolds *code*, but conventions
  stay **late-bound and trait-resolved at run time**. The brief and the resolved trait selections are
  recorded as snapshot inputs (the brief also becomes the first `ai-sdd-plan` input); no pre-generated
  per-stack convention files. This is the line that keeps seed mode from being the codegen-of-specs
  ADR-0023 rejected.

**Consequences.** Greenfield (and the multi-vertical monorepo specifically) becomes bootstrappable through
one added mode, no new primitive. **Gating dependency:** this is unbuildable until Traits are real —
ADR-0024 is "Accepted (implementation pending)" and `.ai-sdd/{traits,stacks,resources}/` are empty
placeholders today; a minimal trait library (even one stack's traits) is the prerequisite, and without it
seed mode degrades straight back to invention. The grounding is weaker than brownfield's (the trait
library + brief, not the user's own code), mitigated two ways: the trait library is curated and eval-gated
(conventions are versioned modules, not per-run inventions), and the walking-skeleton handoff converts the
factory to code-grounded discovery immediately after seeding. Re-bootstrap semantics are unchanged: it is
brownfield from the second run on.

**Alternatives rejected.** Invent conventions from the brief with no trait library (reintroduces the
"guessed, not grounded" failure the skill exists to prevent). Pre-generate per-stack specs from the brief
(the codegen-of-specs path ADR-0023 rejected — derived specs drift). A permanent standalone greenfield
path that never hands off to discovery (keeps the factory on weaker priors-only grounding forever instead
of converging to the user's real, evolving conventions). A new top-level "greenfield" primitive (defeats
the self-similar model, ADR-0002 — seed mode is a mode of bootstrap, not a new kind).

---

## ADR-0030 — `ai-sdd plan`: risk-tiered preview of factory-artifact changes before commit
**Status:** Accepted (implementation pending) · 2026-06-21

**Context.** Bootstrap/re-bootstrap (ADR-0029) and hand-edits to `.ai-sdd/` change artifacts of wildly
different blast radius — refreshing a `conventions/<stack>.md` is local and safe, but editing a schema is
a **contract change that ripples to every consumer worker** (ADR-0009: artifacts are typed handles on
edges). The framework surfaces none of this. The CLI is `cheatsheet · validate · start · status · next ·
submit · check · scope · cover · graph` — **no `plan`, no `diff`, no `lock`, no drift**. The only safety
net is `git diff` plus operator discipline, which carries **no blast-radius semantics**: an adopter
re-bootstrapping or editing cannot tell a safe convention refresh from a contract break, and nothing
flags an unintended high-blast change before it is committed. Idempotent mechanical output (the skill's
re-bootstrap note) keeps a *no-op* re-run clean, but that does nothing when changes are actually present.
The adopter is left holding the entire "what's fragile" discipline in their head — the framework does not
help prevent unintended modification.

**Decision.**

- **Add a deterministic `ai-sdd plan [<dir>]`** that diffs the working tree of `.ai-sdd/` against the
  committed baseline (`HEAD`; `--since <ref>` to override) and **classifies every changed artifact by
  blast radius computed from the spec graph** — not guessed. This is the IaC `terraform plan` for the
  factory: see the classified impact *before* you commit.

- **Tiers, low → high:** **refresh** (conventions, worker skills — prose specialization, no consumer
  contract; regenerable) · **local** (worker specs, pipeline edits, recompiled checks — change execution
  inside one factory) · **contract** (schema changes — the blast radius is **every worker that consumes
  that schema, listed explicitly**) · plus a reserved **frozen** tier for artifacts a future lock declares
  protected (enforced locks are a separate decision; `plan` renders a change to a frozen artifact as a
  hard ✗).

- **Classification is engine logic over the loaded specs (ADR-0001), grounded and reproducible.** A schema
  change resolves its consumers through the edge graph; a convention/check change resolves the workers
  that reference it. No model in the loop — blast radius is a graph computation the engine owns, reusing
  the existing spec loader/validator.

- **Output + exit code drive approval.** Changes are grouped by tier with the computed blast radius per
  item; `plan` exits **non-zero when any change is `contract` or higher**, so an agent or CI must obtain
  explicit human acknowledgement before committing. `--require-ack <tier>` sets the threshold. A changed
  **judge/intent check** is additionally flagged as needing re-eval before it can block again (ADR-0007),
  even though its tier is `local`.

- **Re-bootstrap and hand-edits both route through it.** The bootstrap skill's final step changes from
  "review the diff" to "run `ai-sdd plan`, approve, commit." Because `plan` works off the git working
  tree, it is **agnostic to how the change was produced** (agent re-bootstrap or manual edit) and
  provider-neutral — the safety layer lives in the **engine**, not the skill or a prompt.

**Consequences.** Adopters get the `plan` experience — classified blast radius in front of them at commit
time — instead of carrying the fragility map in their heads; this is the direct answer to "the framework
doesn't help prevent unintended modification." It adds a command, not a subsystem (it rides the existing
loader). It gates on **commit, not write** — the meaningful boundary, since `.gitignore` commit-scope is
what marks team adoption (ADR-0029 §7); a true no-write dry-run is unnecessary and would couple the safety
layer to the agent-driven skill. It leaves a clean seam for the follow-on guardrails the adopter also
needs: **enforced freeze/locks** (the reserved `frozen` tier) and **drift detection** (`conventions` no
longer matching code; a fixture violating a frozen contract). For marker-managed shared files
(`AGENTS.md`/`.gitignore`) `plan` reports only the managed block, consistent with the upsert contract.

**Alternatives rejected.** Status quo — `git diff` + operator discipline (no blast-radius semantics; the
gap this ADR closes). A no-write dry-run baked into the bootstrap skill (agent/skill-specific, misses
hand-edits, not provider-neutral — the engine-owned git classifier covers every change source).
Prohibiting schema changes outright (schemas must evolve; the goal is **informed approval + versioning**
per ADR-0017, not prohibition). Putting classification in the skill/prompt (non-deterministic and
ungrounded — violates ADR-0001; blast radius must be an engine graph computation).

---

## ADR-0031 — Enforced freeze/locks: the `frozen` tier made real
**Status:** Accepted (implementation pending) · 2026-06-22

**Context.** ADR-0030 shipped `ai-sdd plan` — it *previews* a change's blast radius and reserves a
**`frozen`** tier, but the shipped `Tier` enum (`Sources/AISDDEngine/ChangePlan.swift`) is only
`refresh < local < contract`; `frozen` was omitted as a dead case. So `plan` makes an unintended change
*visible and ack-gated* but cannot *refuse* one. The adopter's original pain — "the framework doesn't
prevent unintended modification of my frozen contracts" — is still open: a contract a team froze (e.g. the
three frozen schemas in a contract-first repo) can be edited and committed with only an acknowledgement,
no enforced protection. `plan` is the `terraform plan`; this ADR adds the `prevent_destroy`.

**Decision.**

- **Declare locks in a committed `.ai-sdd/locks.yaml` manifest** — a list of path globs under `.ai-sdd/`,
  each with a `reason`. One greppable, diffable source of truth that covers *any* artifact (schemas,
  conventions, pipeline, checks), not just schemas. The manifest is itself a factory artifact (committed,
  refreshable). Chosen over per-artifact `frozen: true` metadata (only reaches artifacts that have a
  metadata block; scatters the policy) and in-file markers (don't generalize to whole files).

- **Make `frozen` the top `Tier`.** Add `frozen` above `contract` to the enum's `Comparable` order. After
  `ChangePlan` computes a change's base tier, a path matching a `locks.yaml` glob is **promoted to
  `frozen`**, carrying a `locked` flag with the lock's `reason`.

- **`frozen` is not ack-able by the threshold — it requires an explicit unlock.** `plan` renders a frozen
  change as a hard ✗ and exits a **distinct code (`3`)**, *regardless of* `--require-ack` (so you cannot
  wave a frozen change through by lowering the threshold the way `contract` allows). `--unlock <path>`
  downgrades a frozen change to its underlying base tier **for that one invocation** (a genuine,
  deliberate contract change then flows through the normal `contract` ack path); the lock itself is
  unchanged. Permanently unfreezing means editing `locks.yaml` — a visible, reviewed diff.

- **Enforcement is `plan`-owned (commit-time), provider-neutral.** The mechanism is the `frozen` tier +
  exit code in the engine, surfaced by the `ai-sdd plan` adopters run pre-commit / in CI — not a hidden
  hook. A git `pre-commit` hook that runs `plan` is offered as an *optional convenience*, never the
  mechanism (ADR-0001: the engine is the only code).

**Consequences.** A team can finally mark artifacts the factory will *refuse* to silently change — the
three frozen contracts in a contract-first repo go in `locks.yaml` and a re-bootstrap or hand-edit that
touches them fails `plan` with exit 3 until explicitly unlocked. Builds entirely on the shipped substrate:
`ChangePlan` (add the promote-to-frozen pass), `PlanReport` (render + exit), `Layout` (the `locks.yaml`
path). Enforcement is still **commit-gated, not write-gated** (consistent with ADR-0030) — `plan` is the
checkpoint; the optional hook tightens it. Composes with provenance (ADR-0032) and drift (ADR-0033): a
change can be reported as both *hand-edited since generated* and *frozen*.

**Alternatives rejected.** Per-artifact `frozen:` metadata (scatters policy, misses metadata-less files).
A separate `ai-sdd lock` state store (a manifest is simpler and reviewable). Write-time enforcement as the
primary mechanism (a git hook is host-specific and bypassable; the engine gate is the neutral source of
truth — the hook merely *invokes* it). Making `frozen` overridable by `--require-ack` (defeats the point;
freezing must be deliberate to undo).

---

## ADR-0032 — Provenance: generated vs hand-edited, so re-bootstrap never clobbers
**Status:** Accepted (implementation pending) · 2026-06-22

**Context.** Re-bootstrap (ADR-0029) and the compilers regenerate factory artifacts (`conventions/`,
`schemas/`, worker skills, `checks/`). Today the framework cannot tell **what it generated** from **what
the adopter hand-edited afterward** — so a re-bootstrap can silently overwrite a human's deliberate edit
to a generated convention or schema, and `plan` cannot mark a change as "this diverged from what the
generator would produce." The marker upsert (`ai-sdd:begin/end`) solves this only for the two shared files
(`AGENTS.md`/`.gitignore`); whole generated artifacts have no such protection. This is the guardrail that
makes the other two trustworthy: locks decide what *may* change, provenance records who *did*.

**Decision.**

- **Record provenance in a committed `.ai-sdd/provenance.json` manifest** mapping each generated artifact
  path → `{ generator, generatedAt, contentHash }` (the generator id — `bootstrap` / `compile-schema`;
  the timestamp **passed in**, never read from the clock — see the determinism note; the hash of the
  bytes the generator emitted).

- **Generators write provenance; consumers read it.** `ai-sdd-bootstrap` and `ai-sdd-compile-schema`
  record an entry per artifact they emit. On **re-bootstrap**, before overwriting an artifact, compare its
  current on-disk hash to the recorded `contentHash`: **equal ⇒ regenerate freely; different ⇒ it was
  hand-edited — do not silently overwrite.** Flag it and require explicit confirmation (or a three-way
  merge), exactly as the planning gate treats a human edit as authoritative.

- **`plan` surfaces provenance as an annotation.** A changed artifact whose pre-change content already
  diverged from its recorded generated baseline is marked `hand-edited` in the `PlanReport` output — so
  the adopter sees they're editing something they'd previously customized, not pristine generated output.

- **Determinism is mandatory.** Hashes are content-addressed and the timestamp is an input, so a no-op
  re-bootstrap produces an identical `provenance.json` (no spurious diff) — the same idempotency contract
  ADR-0029 relies on. (Engine code cannot read the clock anyway; the generator is handed the time.)

**Consequences.** Re-bootstrap stops being a potential silent clobber — the framework defends a human's
edits the way it defends prose outside the `ai-sdd:begin/end` markers, but for whole generated artifacts.
`plan` gets richer (the `hand-edited` annotation). Adds one manifest + content hashing; generators gain a
write step, `plan`/re-bootstrap a read step. Reuses `Layout` (the manifest path) and the existing artifact
write paths. Generalizes the marker-upsert idea (ADR-0029 §6/§7) from two shared files to every generated
artifact. Feeds drift (ADR-0033): "hand-edited since generated" is one drift signal among several.

**Alternatives rejected.** Marker regions in every generated file (works for partial files like
`AGENTS.md`, not for a wholly-generated `conventions/<stack>.md` or schema). Git history as the provenance
source (conflates generator output with normal commits; can't distinguish a hand-edit from a re-bootstrap
in the log). No provenance, rely on the adopter to not re-bootstrap over edits (the status quo that makes
re-bootstrap feel unsafe — the whole point is to make it safe).

---

## ADR-0033 — Drift detection: tell the adopter *when* to act
**Status:** Accepted (implementation pending) · 2026-06-22

**Context.** ADR-0030/0031/0032 handle a change the adopter is *making* (preview, prevent, attribute).
None answer the opposite question: **when has reality moved out from under the committed factory, so the
adopter should act?** A `conventions/<stack>.md` can silently fall out of date as the code evolves
(ADR-0029's whole reason to re-bootstrap); a schema can change without its compiled `checks/` being
recompiled, leaving a **stale gate**; a fixture can drift to violate a frozen contract. Today this
knowledge is tribal — you re-bootstrap on a hunch. This is the missing *pull-based* guidance the
maintenance story needs: a command that says "these artifacts no longer match reality."

**Decision.**

- **Add `ai-sdd drift [<dir>]`** that reports divergence between committed factory artifacts and the
  reality they describe, **deterministically wherever possible** (ADR-0001), across three kinds:
  - **Stale gate (schema ↔ compiled check).** Re-run the `ai-sdd-compile-schema` compilation in-memory
    and diff against the committed `checks/*.check.yaml`; a difference means the gate is stale w.r.t. its
    schema. Fully deterministic.
  - **Fixture ↔ schema.** Validate known fixtures against the current schemas via the existing
    `SchemaValidator`; a failure is contract drift (e.g. a fixture that no longer satisfies a frozen
    contract). Deterministic.
  - **Convention ↔ code.** Re-check each convention's **evidence citations** — the `conventions/<stack>.md`
    Discovery Record already records, per change-type, the *evidence* (a file path, a commit, a command)
    behind each rule. Mechanically verify those citations still hold (path exists, cited command exits 0);
    a broken citation flags an ungrounded/outdated convention. This applies the house "grounded
    non-deterministic" pattern: the deterministic citation check finds *candidates*, the adopter (or a
    re-bootstrap) judges the fix.

- **Pull-based, non-blocking by default.** `drift` is a report the adopter runs (or wires into CI as a
  warning), not a gate — it tells you *to* re-bootstrap/recompile, it doesn't block. Each finding names
  the remedy (`recompile <schema>`, `re-bootstrap <stack>`, `fix fixture <path>`).

- **Provenance-aware.** A drift finding on a `hand-edited` artifact (ADR-0032) is annotated as such, so
  "the convention drifted" is distinguished from "you customized it on purpose."

**Consequences.** Closes the maintenance loop the four guardrails form: **plan** (preview a change),
**locks** (prevent one), **provenance** (attribute one), **drift** (detect when the artifacts themselves
went stale). Converts "re-bootstrap on a hunch" into "re-bootstrap because `drift` flagged
`conventions/operator.md`." Reuses shipped/most-existing machinery — the compile-schema compiler,
`SchemaValidator`, `SpecLoader`, and the convention Discovery Record's citations — so the deterministic
kinds need little new code. The convention-citation check is the one non-deterministic edge, deliberately
scoped to *flagging* (deterministic citation breakage), not *judging*.

**Alternatives rejected.** A blocking drift gate (drift is advisory by nature — reality moving is not a
defect to reject; forcing a block would stall every run on stale prose). LLM-judging convention-vs-code
wholesale (ungrounded, non-reproducible — violates ADR-0001; the citation check keeps it deterministic).
Folding drift into `plan` (different question — `plan` is about a *pending change*, drift is about
*standing staleness*; conflating them muddies both exit semantics).

---

## Open decisions

_None — all decisions above are resolved. New questions will be appended here as they arise._
