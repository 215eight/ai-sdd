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
3. **Referential / graph** — a custom **`factory validate`** pass over the decoded model:
   worker/check id resolution, Edge-vs-Worker signature type-compatibility, DAG
   acyclicity, and contract coverage.

Run all three **on every update** (editor + pre-commit/CI) and as a **boot gate** before
any Factory starts a Run — no Run proceeds against an invalid Plant. Reserve **JSONL** for
the `RunEvent` log, not for specs.

**Consequences.** Type safety is re-imposed at load time rather than compile time
(inherent to spec-as-data). Implementation needs: a Yams dependency, a JSON Schema set
plus a sync/test mechanism, and the `factory validate` command.

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
emitters.) Same pattern ADR-0018 uses at the gRPC/code level.

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

## Open decisions

### ADR-0016 — Durable, resumable rollout sub-pipeline
**Status:** Open

The Deployment Factory's rollout is long-lived, sensor-driven, pausable, and must
*resume* (not restart) after an upstream fix. This implies durable-execution semantics
(Temporal-style). The **general** async-resumption mechanism — durable event-sourced runs +
suspension at a `sensor`/`human` node with a correlation key + idempotent ingest + re-invoke
to resume — is now described in architecture.md §10 ("Asynchronous, durable resumption"), and
covers MR-approval / CI-completion / webhook triggers including on a local machine. **Still
open:** the rollout-*specific* durability — resuming a partially-applied, monitored rollout and
its compensation/rollback — which layers on top of that mechanism.

### ADR-0018 — Cross-repo atomicity for gRPC-contract changes
**Status:** Open

A gRPC-def repo change must land before its consumer impl repos, across multiple repos,
with back-compat. Atomicity/sequencing strategy across repos is unresolved.

### ADR-0019 — Name for the Conductor
**Status:** Open

Working name "Conductor" (orchestra) vs "Production Control" (factory metaphor) vs other.
Defer until structure is stable.
