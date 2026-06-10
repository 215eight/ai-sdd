# Designing a Stripe-Style Software Factory (for `ai-sdd`)

> How to evolve the current `plan → implement → review` engine into a **configurable
> factory** where every role is data, the topology is a typed DAG, and quality is
> enforced by in-loop gates + an eval harness.
>
> Companion to [software-factory-research.md](software-factory-research.md). Types are
> written in Swift to match the existing `SDDModels` / `SDDCore` packages and reuse
> their names (`ArtifactRef`, `ArtifactState`, `RunSummary`, `IdentityAttribution`,
> `CompletionContract`, `AgentAdapter`, `ApprovalRecord`, `BlockerRecord`, …).

---

## Canonical vocabulary (LOCKED · 2026-06-09)

| Concept | **Name** | Notes / borrowed from | In your code today |
|---|---|---|---|
| The platform / product / vision | **Factory** | the plant | — |
| One pattern's typed DAG (CRUD, Integration…) | **Pipeline** | dataflow | (new) |
| One execution of a Pipeline for one feature; also *the work item itself* | **Run** | universal | ✅ `RunSummary` |
| The parameterized unit that performs a role (architect, coder, reviewer…) | **Worker** | factory floor; absorbs Operator+Role+Node | ↔ `agentRole` |
| How the Scheduler treats a worker | **WorkerKind** = `transform · check · human · fanout · join` | — | ↔ `StationKind` |
| The compute/body a Worker runs on | **Adapter** | hexagonal; *what muscle* vs *what job* | ✅ `AgentAdapter` |
| Wire between Workers; carries an Artifact | **Edge** | graph | ✅ `DependencyEdge` |
| Typed payload flowing on Edges | **Artifact** | CI | ✅ `ArtifactRef` |
| An Artifact's type | **Schema** | type systems | ✅ `ArtifactSchema` |
| Assertion — *blocking or scoring* | **Check** | Dagster Asset Check / GH required check | ↔ gate+eval |
| The single executor for all Checks | **CheckRunner** | — | (new) |
| A Check's output | **CheckResult** | — | ↔ `Verdict` |
| Offline Check corpus (the "evals") | **Check suite** | — | (new) |
| Planner — which Workers are runnable | **Scheduler** | orchestrators | ↔ `WorkflowEngine` |
| Pure event→state fold | **Reducer** | Redux/FP | ↔ `evaluate` |
| Append-only event | **RunEvent** | event sourcing | (new) |

**Dropped / merged:** ~~Socket/Port~~ (a Worker just has a typed input/output **signature** of Schemas; the Edge carries the Artifact) · ~~Gate~~ (it's a required **Check**) · ~~Operator / Role / Node / Station~~ (all → **Worker**) · `WorkflowPhase` → demoted to a **tag/lane** label, not control flow.

### High-level diagram

```mermaid
flowchart TB
    RUN["📥 Run<br/>(a feature spec enters)"]

    subgraph FACTORY["🏭 FACTORY"]
        direction TB
        subgraph CONTROL["Control plane · deterministic"]
            SCHED["Scheduler<br/>which Workers are runnable?"]
            RED["Reducer<br/>fold RunEvents → state"]
        end
        subgraph PIPE["Pipeline · typed DAG of Workers"]
            direction LR
            W1["Worker: architect"] -->|"Artifact : Schema"| W2["Worker: coder"]
            W2 -->|"Artifact : Schema"| W3["Worker: reviewer"]
            W3 --> CHK["Worker: check<br/>(required)"]
        end
        ADP["Adapters · compute<br/>claude-code · codex"]
        CRUN["CheckRunner"]
        SCHED --> PIPE
        PIPE --> RED
        PIPE -. "Workers run on" .- ADP
        CHK --> CRUN
    end

    RUN --> SCHED
    CRUN -->|pass| PR["📦 Artifact: pull-request"]
    PR --> HUMAN["🧑‍⚖️ Human approval"]
    RED -->|RunEvent log| STORE["🗄️ Run store<br/>audit · resume"]
    STORE -->|harvest fixtures| SUITE["🧪 Check suite · evals"]
    SUITE -->|"promotion gate<br/>(no regression?)"| CATALOG["📚 Worker catalog<br/>versioned configs"]
    CATALOG --> PIPE

    style HUMAN fill:#fff3cd,stroke:#d39e00
    style CHK fill:#e7f5ff,stroke:#1971c2
    style CRUN fill:#e7f5ff,stroke:#1971c2
```

The one diagram to remember the model by: a **Run** enters → the **Scheduler** runs **Workers** down a **Pipeline**, passing typed **Artifacts** along **Edges**, each Worker running on an **Adapter** → a required **Check** (via the **CheckRunner**) gates the **PR** → a human approves. The **Reducer** writes **RunEvents** to the store, which feed offline **Check suites** (evals); their **promotion gate** decides which **Worker** versions go back into the catalog. Same `CheckRunner` serves the inline check and the offline suite — *a gate is an eval*.

> Sections 1–9 below were drafted with earlier working names (Station, Operator, Port, Gate…).
> The table above is authoritative; a full propagation pass through the prose is pending.

---

## 0. The one principle

> **Role = data. Engine = fixed.**
> The engine is a small deterministic interpreter of a typed DAG. *Roles, gates, edges,
> and contracts are declarative config.* The LLM only ever runs **inside a station**,
> sandboxed, behind a gate. This is the Stripe pattern: a creative agentic core wrapped
> in deterministic guardrails.

Everything below is a consequence of that sentence. The same binary runs an "architect,"
a "migrator," a "reviewer," or a "test author" by loading a different `RoleDefinition`.
Adding a role is a config file, not a code change.

Where you are today vs. where this goes:

| Today (`ai-sdd`) | This design |
|---|---|
| Fixed `WorkflowPhase` enum: plan/implement/review | Phase becomes a *tag*; control flow is a typed DAG of stations |
| Role hardcoded in `WorkflowEngine` (`agentRole: "sdd-planner"`) | Role is a loaded `RoleDefinition`; engine is role-agnostic |
| `dependencyGraph: [DependencyEdge]` exists but isn't enforced | DAG readiness *is* the scheduler |
| `ArtifactRef { type, path }` — untyped blob | `ArtifactEnvelope` carries a `schemaId`; edges are type-checked |
| Approval gates exist (`approveGate`/`rejectGate`) | Generalized to any station with `kind: .human` |
| No eval harness for output quality | 4-tier eval harness (contract → gate → role → end-to-end) |

---

## 1. Overall architecture: five layers

```mermaid
flowchart TB
    subgraph DEF["1 · DEFINITION (declarative, versioned)"]
        D1["FactoryDefinition<br/>roles + stations + edges + schemas"]
    end
    subgraph ENG["2 · ENGINE (pure, deterministic)"]
        E1["reduce(state, event) → state"]
        E2["runnable(state, def) → [Station]"]
    end
    subgraph EXEC["3 · EXECUTION (nondeterministic, sandboxed)"]
        X1["Adapters: claude-code / codex"]
        X2["Context assembly · tools · LLM"]
    end
    subgraph PERS["4 · PERSISTENCE & AUDIT (event-sourced)"]
        P1["FactoryEvent log → RunSummary"]
        P2["Telemetry · TokenAttribution · IdentityAttribution"]
    end
    subgraph EVAL["5 · EVALS (offline + inline)"]
        V1["contract · gate · role · end-to-end"]
    end

    DEF --> ENG
    ENG -->|"dispatch runnable station"| EXEC
    EXEC -->|"emit events (artifacts, verdicts)"| PERS
    PERS -->|"replay event log"| ENG
    PERS --> EVAL
    DEF --> EVAL
```

- **Definition** is the only thing that changes per role/product. Content-addressed and versioned so a run pins the exact factory + role versions it used (reproducibility, eval attribution).
- **Engine** is a pure reducer (this *is* `WorkflowEngine`, generalized). Pure → trivially testable, replayable, and the substrate for evals.
- **Execution** is your existing `AgentAdapter` + `ExecutionAdapterInvocation`. It is the *only* nondeterministic part, and it is always sandboxed and gated.
- **Persistence** becomes event-sourced: `RunSummary` is a *projection* of an append-only `FactoryEvent` log. You already persist `RunSummary` to `openspec/changes/<slug>/run-summary.json`; add the event log beside it. This gives you free resume, audit (SOC2/HIPAA), and eval replay.
- **Evals** consume the same artifacts/events the engine produces.

---

## 2. The core abstraction: a Station is a parameterized Role

A **`RoleDefinition`** fully determines a station's behavior. The engine reads it; it never branches on "is this the planner?". This is the heart of "multiple roles by configuring parameters."

```swift
public struct RoleDefinition: Codable, Equatable {
    public var id: String              // "architect", "coder.api", "migrator", "reviewer"
    public var version: String         // pinned per run for reproducibility
    public var kind: StationKind       // how the ENGINE treats this node
    public var phaseTag: WorkflowPhase // keep existing enum as a *label* for UI/telemetry

    // Typed boundary — the contract this role honors
    public var inputs: [PortSpec]
    public var outputs: [PortSpec]

    // How the role thinks (all data, no code)
    public var prompt: PromptRef           // template id + variable bindings
    public var context: ContextPolicy      // codebase-intelligence retrieval spec
    public var tools: ToolPolicy           // allowed tools + filesystem scope + secret refs
    public var binding: AdapterBinding      // adapter + model, or .any

    // Guardrails
    public var verification: [String]      // GateDefinition.ids run on outputs before accept
    public var retry: RetryPolicy          // self-repair budget
    public var completion: CompletionContract  // REUSE: submitPhase + requiresHumanApproval
    public var budget: Budget              // token / time ceiling
}

public enum StationKind: String, Codable, CaseIterable {
    case transform   // LLM produces artifacts (architect, coder, test-author, reviewer)
    case gate        // deterministic check, NO LLM (typecheck, unit, lint, schema)
    case human       // approval / input  (generalizes approveGate/rejectGate)
    case fanout      // split one input into N parallel children (per-table, per-endpoint)
    case join        // merge children back (assemble PR)
}
```

The catalog roles (architect, migrator, API coder, frontend coder, test author, reviewer,
integrator) are **all `RoleDefinition` instances of `kind: .transform`** that differ only in
their `inputs`/`outputs` schemas, `prompt`, `context`, and `verification`. Two examples,
same engine, same `coder.api` role id, re-parameterized per product:

```yaml
# roles/coder.api.payments.yaml
id: coder.api
version: 3
kind: transform
phaseTag: implement
binding: { adapter: claude-code, model: claude-opus-4-8 }
inputs:
  - { name: contract, schemaId: openapi.v1, required: true }
  - { name: migration, schemaId: sql-migration.v1, required: true }
outputs:
  - { name: handlers, schemaId: go-source.v1, cardinality: many }
context:
  retrieve: [ "siblings:api/**/*.go", "conventions:.sdd/conventions/go.md" ]
verification: [ typecheck.go, lint.go, unit.go, judge.api-conventions ]
prompt: { template: coder.api, vars: { language: go } }

# roles/coder.api.healthtech.yaml  → SAME role, different params
id: coder.api
version: 3
binding: { adapter: claude-code, model: claude-opus-4-8 }
outputs:
  - { name: handlers, schemaId: py-source.v1, cardinality: many }
context:
  retrieve: [ "siblings:app/api/**/*.py", "conventions:.sdd/conventions/python.md" ]
verification: [ typecheck.py, lint.py, unit.py, judge.api-conventions, gate.hipaa-phi ]
prompt: { template: coder.api, vars: { language: python } }
```

Nothing in `SDDCore` changes between these. That is the test of a real factory.

### Station anatomy (what happens when the engine dispatches one)

```mermaid
flowchart LR
    IN["Typed inputs<br/>(ready artifacts)"] --> CTX["Context assembly<br/>ContextPolicy → retrieve siblings,<br/>conventions, contracts"]
    CTX --> LLM["LLM (adapter, sandboxed)<br/>tools scoped by ToolPolicy"]
    LLM --> OUT["Candidate outputs"]
    OUT --> GATE{"verification gates<br/>typecheck · lint · test · judge"}
    GATE -->|pass| ACCEPT["Accept → mark artifacts .ready<br/>checkpoint"]
    GATE -->|fail & budget left| REPAIR["Self-repair<br/>feed verdict back to LLM"]
    REPAIR --> LLM
    GATE -->|budget exhausted| BLOCK["BlockerRecord → human"]
```

The station is a closed loop: an LLM step is *never* trusted until its own gates pass. Self-repair happens **inside** the station, before any human is asked.

---

## 3. Data structures (typed, reusing your models)

### 3.1 Schemas & typed artifacts

The missing primitive today is *type*. `ArtifactRef { type, path }` is a blob; add a schema registry so edges can be checked.

```swift
public struct ArtifactSchema: Codable, Equatable {
    public var id: String        // "openapi.v1", "sql-migration.v1", "task-list.v1", "go-source.v1"
    public var version: String
    public var mediaType: String // "application/json", "application/sql", "text/x.go"
    public var jsonSchema: Data? // optional JSON Schema for *structured* artifacts (plans, specs)
}

// Runtime envelope around an artifact (wraps existing ArtifactRef + ArtifactState)
public struct ArtifactEnvelope: Codable, Equatable {
    public var ref: ArtifactRef              // REUSE { type, path }
    public var schemaId: String
    public var state: ArtifactState          // REUSE: missing/empty/placeholder/ready
    public var producedBy: String            // station id
    public var contentHash: String           // content-addressed → caching + eval keys
    public var identity: IdentityAttribution // REUSE: who/what produced it (audit)
}
```

### 3.2 Ports, stations, edges, factory

```swift
public struct PortSpec: Codable, Equatable {
    public var name: String          // "contract", "migration", "handlers"
    public var schemaId: String      // must exist in FactoryDefinition.schemas
    public var cardinality: Cardinality
    public var required: Bool
}
public enum Cardinality: String, Codable { case one, many }

public struct Station: Codable, Equatable {
    public var id: String                  // node id in THIS graph: "api", "ui", "migrate"
    public var role: String                // RoleDefinition.id
    public var roleVersion: String
    public var params: [String: String]    // per-station overrides (table name, product slug)
}

public struct PortAddress: Codable, Equatable {
    public var stationId: String
    public var port: String
}
public struct Edge: Codable, Equatable {
    public var from: PortAddress   // producer station + output port
    public var to: PortAddress     // consumer station + input port
}

public struct FactoryDefinition: Codable, Equatable {
    public var id: String          // "crud-ui.v1"
    public var version: String
    public var schemas: [ArtifactSchema]
    public var roles: [RoleDefinition]
    public var stations: [Station]
    public var edges: [Edge]
}
```

### 3.3 Gates & verdicts

```swift
public struct GateDefinition: Codable, Equatable {
    public var id: String          // "unit.go", "typecheck.py", "judge.api-conventions"
    public var kind: GateKind
    public var command: String?    // deterministic: CI selector / shell (selective tests)
    public var rubric: PromptRef?  // judge: rubric template
    public var thresholds: [String: Double]  // e.g. ["tests.failed": 0, "judge.score": 0.8]
    public var blocking: Bool      // false = advisory (surfaced, doesn't stop the line)
}
public enum GateKind: String, Codable { case deterministic, judge }

public struct Verdict: Codable, Equatable {
    public var gate: String
    public var status: GateStatus            // pass / fail / error
    public var metrics: [String: Double]     // "tests.failed": 0, "coverage": 0.86
    public var evidenceRef: ArtifactRef?     // log artifact (audit trail)
    public var detail: String
}
public enum GateStatus: String, Codable { case pass, fail, error }
```

### 3.4 Run state as an event log

```swift
public enum FactoryEvent: Codable, Equatable {
    case runStarted(runId: String, factory: String, factoryVersion: String, intake: ArtifactRef)
    case stationStarted(station: String, attempt: Int, identity: IdentityAttribution)
    case artifactProduced(ArtifactEnvelope)
    case gateEvaluated(station: String, Verdict)
    case repairRequested(station: String, attempt: Int, reason: String)
    case stationBlocked(station: String, BlockerRecord)     // REUSE BlockerRecord
    case approvalRequested(station: String, gateId: String)
    case approvalRecorded(ApprovalRecord)                   // REUSE ApprovalRecord
    case approvalRejected(station: String, reason: String)  // REUSE reject semantics
    case stationCompleted(station: String, outputs: [ArtifactRef])
    case runCompleted(runId: String)
    case runFailed(runId: String, FailedReason)             // REUSE FailedReason
}
```

`RunSummary` (which you already persist) becomes a **projection** of this log — same fields,
now derived. The log is your audit ledger and your eval replay tape.

---

## 4. DAG transitions with typed inputs/outputs

### 4.1 The two pure functions (this generalizes `WorkflowEngine.evaluate`)

```swift
public protocol FactoryEngine {
    /// Fold an event into state. Pure → replayable, testable, deterministic.
    func reduce(_ state: RunState, _ event: FactoryEvent) -> RunState

    /// Which stations can run right now? Pure planner over the DAG.
    func runnable(_ state: RunState, _ def: FactoryDefinition) -> [Station]
}
```

A station is **runnable** iff:
1. every `required` input port is satisfied by an `ArtifactEnvelope` in `state` whose `state == .ready` and whose `schemaId` **satisfies** the port's `schemaId`, and
2. it is not already completed/blocked.

That readiness predicate *is* the scheduler. There is no `plan → implement → review`
hardcoding anymore; that ordering simply *emerges* because the API station's input port
requires the migration's output schema. Independent branches (e.g. `config`) run in parallel.

### 4.2 Two kinds of type-checking

- **Static (at definition load):** for every `Edge`, assert `producer.outputPort.schemaId`
  satisfies `consumer.inputPort.schemaId`. A factory with a mismatched edge fails to load —
  you catch wiring errors before any token is spent. (Extend your existing JSON contract tests
  to cover this.)
- **Runtime (at production):** when a station emits an artifact, validate it against its
  `ArtifactSchema.jsonSchema` (for structured artifacts) before marking it `.ready`. A
  malformed plan never reaches the coder.

### 4.3 The CRUD + UI factory as a typed DAG

This is the Athena v1 — and it's an almost-deterministic, fixed graph:

```mermaid
flowchart LR
    INTAKE["intake<br/>(NormalizedIntake)"] -->|"feature-spec.v1"| SPEC["architect"]
    SPEC -->|"plan.v1"| PLAN{{"plan approved?<br/>kind: human"}}
    PLAN -->|"plan.v1"| MIG["migrate"]
    PLAN -->|"plan.v1"| CFG["config"]

    MIG -->|"sql-migration.v1"| API["api"]
    API -->|"openapi.v1"| UI["frontend"]
    API -->|"openapi.v1"| TEST["test-author"]
    MIG -->|"sql-migration.v1"| TEST
    UI -->|"component.v1"| TEST

    API --> ASM["assemble<br/>kind: join"]
    UI --> ASM
    MIG --> ASM
    CFG --> ASM
    TEST --> ASM

    ASM -->|"changeset.v1"| CI{{"CI gate<br/>kind: gate"}}
    CI -->|"pass"| PR["pull-request.v1"]
    PR --> REVIEW{{"human review<br/>kind: human"}}

    style PLAN fill:#fff3cd,stroke:#d39e00
    style REVIEW fill:#fff3cd,stroke:#d39e00
    style CI fill:#e7f5ff,stroke:#1971c2
```

Edge labels are the artifact **schemas** carried across — that's the "typed inputs/outputs."
`test-author` depends on migration + api + ui (it can't write meaningful tests until the
contract exists — research finding: separate the test author from the coder so tests aren't
tautological).

### 4.4 Per-station state machine (incl. mid-pipeline failure recovery)

```mermaid
stateDiagram-v2
    [*] --> Pending
    Pending --> Ready: all required inputs .ready
    Ready --> Running: engine dispatches (adapter)
    Running --> Gating: outputs produced
    Gating --> Done: all blocking gates pass
    Gating --> Repairing: gate fails, budget remains
    Repairing --> Running: feed verdict back to LLM
    Gating --> Blocked: retry budget exhausted
    Running --> Blocked: adapter error / timeout
    Blocked --> Ready: human resolves (intervene + re-run)
    Done --> [*]

    state Human {
        [*] --> AwaitingApproval
        AwaitingApproval --> Approved: approveGate
        AwaitingApproval --> Rejected: rejectGate
    }
```

Failure recovery rules (deterministic, in the engine):
- **Gate fail, budget left** → `Repairing`: re-invoke the *same* station with the verdict
  injected. Self-heal before escalating.
- **Budget exhausted** → emit `stationBlocked(BlockerRecord)`; the run pauses at that node
  only. Downstream waits; independent branches keep running.
- **Checkpointing:** a `Done` station's outputs are content-addressed and cached. Re-running
  a sibling never regenerates an already-green migration.
- **Human reject** (`rejectGate`) → `Blocked` with the reason, exactly as today; the human
  edits inputs/plan and re-runs from that node, not from scratch.

---

## 5. The factory role catalog

All of these are `RoleDefinition` configs over **one** engine. "Configure different
parameters → different role" is the whole point.

| Role id | kind | Inputs (schema) | Outputs (schema) | Verification gates |
|---|---|---|---|---|
| `intake.normalizer` | transform | `intake-doc.v1` | `feature-spec.v1`, `dependency-graph.v1` | `schema`, `judge.spec-complete` |
| `architect` | transform | `feature-spec.v1` | `plan.v1` (DAG of tasks + typed contracts) | `schema`, `judge.plan-sound` |
| `plan.gate` | human | `plan.v1` | `plan.v1` (approved) | — |
| `migrate` | transform | `plan.v1` | `sql-migration.v1` | `migrate.dryrun`, `gate.no-data-loss` |
| `coder.api` | transform | `openapi.v1`*, `sql-migration.v1` | `*-source` | `typecheck`, `lint`, `unit`, `judge.api-conventions` |
| `coder.frontend` | transform | `openapi.v1` | `component.v1` | `typecheck`, `lint`, `a11y`, `judge.ui-conventions` |
| `test.author` | transform | `sql-migration.v1`, `openapi.v1`, `component.v1` | `test-suite.v1` | `tests.compile`, `coverage`, `mutation` |
| `reviewer` | transform | `changeset.v1` | `review-notes.v1` | `judge.security`, `judge.convention-drift` |
| `assemble` | join | all branch outputs | `changeset.v1` → `pull-request.v1` | `ci.selective` |
| `human.review` | human | `pull-request.v1` | approved PR | — |

Two re-parameterization axes make this scale to 7 products × 4 patterns **without** N systems:
- **Per-product overlay:** swap `binding` (model), `context.retrieve` (where siblings live),
  and add product gates (`gate.hipaa-phi`). Same role id.
- **Per-pattern factory:** Integration / Workflow / Analytics are *new `FactoryDefinition`s*
  reusing the *same roles* with different wiring (e.g. Integration adds an `adapter.client`
  role between `architect` and `api`).

---

## 6. Evals

Four tiers, cheapest/fastest first. They all consume the same artifacts the engine emits, and
they all key off `contentHash` + `roleVersion` so results are attributable and cacheable.

```mermaid
flowchart TB
    T1["TIER 1 · Contract evals (ms, every commit)<br/>artifact validates against schema · every edge type-checks"]
    T2["TIER 2 · Gate evals (seconds, in-loop)<br/>the verification gates themselves: typecheck/lint/unit/judge"]
    T3["TIER 3 · Role evals (offline, golden)<br/>one role under test: input fixture → output passes gates + matches golden"]
    T4["TIER 4 · End-to-end factory evals (north star)<br/>replay real features through the full DAG"]
    T1 --> T2 --> T3 --> T4
```

### Tier 1 — Contract evals (you already have the seed)
Your `SDDModelJSONContractTests` are exactly this. Extend to: (a) every produced artifact
validates against its `ArtifactSchema`; (b) every `Edge` in every `FactoryDefinition` passes
the static type check. Pure, deterministic, run on every commit. **Gate: 100% pass.**

### Tier 2 — Gate evals (in-loop "backpressure")
The verification gates *are* evals that run during production. Track per gate: pass rate,
mean repair attempts to green, false-pass rate (sampled by humans). The judge gates
(`judge.api-conventions`) need their own meta-eval against a labeled set so the judge itself
doesn't drift.

### Tier 3 — Role evals (golden, offline)
The workhorse. One role, isolated, fixtures in → outputs scored.

```swift
public struct EvalCase: Codable, Equatable {
    public var id: String
    public var roleUnderTest: String          // "coder.api" — or "factory:crud-ui.v1" for Tier 4
    public var inputs: [ArtifactRef]          // fixture artifacts
    public var golden: [ArtifactRef]?         // optional reference outputs
    public var gates: [String]                // gate ids that MUST pass
    public var rubric: PromptRef?             // judge rubric for subjective quality
}

public struct EvalResult: Codable, Equatable {
    public var caseId: String
    public var roleVersion: String            // attribution: which prompt/model produced this
    public var gateVerdicts: [Verdict]
    public var judgeScore: Double?            // 0…1 from rubric
    public var editDistanceToGolden: Double?  // proxy for "human cleanup"
    public var firstRunGreen: Bool            // ← Athena's ≥80% target
    public var humanCleanupMinutes: Double?   // ← Athena's <30 min target
    public var tokenUsage: TokenAttribution   // REUSE: cost per case
    public var passed: Bool
}
```

Scoring combines **deterministic** signals (gates pass? diff size vs golden?) with a
**judge** for style/convention. Because roles are versioned, you get regression detection for
free: bump `coder.api` from v3→v4, re-run its suite, compare `firstRunGreen` and
`humanCleanupMinutes` distributions before promoting. Anti-tautology rule: the `test.author`
role is evaluated by whether its tests *catch injected mutations*, not by whether they pass.

### Tier 4 — End-to-end factory evals (the north star)
Replay a corpus of real, already-shipped features (you have ~100 in the Athena framing)
through the full `FactoryDefinition`. Headline metrics, mapped straight to the brief:

| Metric | Source | Target |
|---|---|---|
| First-run CI green | Tier-2 CI gate on the assembled PR | **≥ 80%** |
| Human cleanup time | `editDistanceToGolden` → calibrated minutes | **< 30 min** |
| Convention drift | `judge.convention-drift` on `changeset.v1` | trending ↓ |
| Cost per feature | sum of `TokenAttribution` over the run | tracked / budgeted |
| Blocked-node rate | count of `stationBlocked` events | trending ↓ |

Run Tier 4 nightly and as a pre-promotion gate on any role/factory version bump. This is the
number that tells you the factory is actually working, not just that the code compiles.

---

## 7. What to reuse vs. build (mapping to current code)

| Need | Reuse from `ai-sdd` | Build new |
|---|---|---|
| Deterministic engine | `WorkflowEngine.evaluate` | Generalize to `reduce` + `runnable` over a DAG |
| Run state | `RunSummary` persistence | Add `FactoryEvent` append-log; make `RunSummary` a projection |
| Roles | `agentRole` strings | `RoleDefinition` config loader + registry |
| Phases | `WorkflowPhase` enum | Demote to `phaseTag`; DAG readiness drives control flow |
| Dependencies | `dependencyGraph: [DependencyEdge]` | Make it the scheduler; add typed ports/edges |
| Artifacts | `ArtifactRef`, `ArtifactState` | `ArtifactSchema` registry + `ArtifactEnvelope` |
| Approvals | `approveGate` / `rejectGate` | Generalize to `kind: .human` stations |
| Identity/audit | `IdentityAttribution`, telemetry, `TokenAttribution` | Attach to every event |
| Secrets | `SecretResolving` boundary | Wire into `ToolPolicy` per role |
| Execution | `AgentAdapter`, `ExecutionAdapterInvocation` | `AdapterBinding` resolution per role |
| Evals | `SDDModelJSONContractTests` | Tiers 2–4 harness + golden corpus |

### Suggested build order
1. **Schema registry + `ArtifactEnvelope`** (typing is the foundation everything else needs).
2. **`RoleDefinition` loader** + convert the existing 3 roles to config (prove no engine change).
3. **`reduce`/`runnable` engine** over a hardcoded CRUD+UI graph; keep the linear path first.
4. **Static edge type-check** at load; **runtime schema validation** on produce.
5. **Gates as post-conditions** + self-repair loop + `BlockerRecord` escalation.
6. **Event log + projection**; resume from log.
7. **Eval Tiers 1→4**, golden corpus from real features.
8. **Fanout/join** for per-endpoint parallelism; then new pattern factories.

---

## 8. Gates & evals, in depth

### 8.1 What a gate id actually resolves to

`RoleDefinition.verification` holds a list of **gate ids** (`[String]`). Those ids are keys
into a **`GateRegistry`** — loaded from config exactly like roles are. So a gate id is a
late-bound reference; the role says *what* must hold, the registry says *how* to check it.
This is what lets the same role run against Go or Python: the role lists `typecheck`, and the
per-product overlay binds `typecheck` → `typecheck.go` vs `typecheck.py`.

```swift
public struct GateRegistry: Codable, Equatable {
    public var gates: [GateDefinition]
    public func resolve(_ id: String) -> GateDefinition?  // id → definition
}
```

Gate ids are **namespaced** `family.specifier`, so they read as a taxonomy and overlays can
remap a whole family:

```yaml
# gates/typecheck.go.yaml
id: typecheck.go
kind: deterministic
command: "go build ./..."          # run in the sandboxed checkout
parser: go-build                   # maps stderr → metrics
thresholds: { "compile.errors": 0 }
blocking: true

# gates/judge.api-conventions.yaml
id: judge.api-conventions
kind: judge
rubric: { template: rubric.api-conventions }   # LLM rubric prompt
inputs: [ "*-source", openapi.v1 ]             # what the judge reads
thresholds: { "judge.score": 0.8 }
blocking: true

# gates/gate.hipaa-phi.yaml  → a compliance policy gate
id: gate.hipaa-phi
kind: deterministic
command: "sdd-policy scan --policy hipaa-phi"
parser: policy-json
thresholds: { "phi.unredacted": 0, "auth.bypassed": 0 }
blocking: true
```

### 8.2 The gate catalog (the ids themselves)

| Family | Example ids | Kind | What it asserts |
|---|---|---|---|
| `schema.*` | `schema.plan`, `schema.openapi`, `schema.migration` | deterministic | artifact validates against its `ArtifactSchema` |
| `typecheck.*` | `typecheck.go`, `typecheck.ts`, `typecheck.py` | deterministic | it compiles / type-checks |
| `lint.*` | `lint.go`, `lint.ts`, `lint.py` | deterministic | style + static analysis clean |
| `unit.*` | `unit.go`, `unit.py` | deterministic | unit tests pass |
| `integration.*` | `integration.api` | deterministic | service-level tests pass |
| `coverage` / `mutation` | `coverage`, `mutation` | deterministic | ≥ threshold; tests *catch* injected bugs |
| `sec.*` | `sec.sast`, `sec.secrets`, `sec.deps` | deterministic | no SAST findings / secret leaks / vuln deps |
| `judge.*` | `judge.api-conventions`, `judge.ui-conventions`, `judge.plan-sound`, `judge.security`, `judge.convention-drift` | judge | subjective quality via LLM rubric |
| `policy.*` / `gate.*` | `gate.hipaa-phi`, `gate.no-data-loss`, `migrate.dryrun`, `gate.auth-check` | deterministic | compliance/safety invariants (SOC2/HIPAA) |
| `ci.*` | `ci.selective` | composite | the bundled CI run on the assembled changeset |

Two design rules worth calling out:
- **Compliance gates are deterministic, never judge.** "No PHI leak / no auth bypass / no
  data-loss migration" must be a hard, auditable command — not an LLM opinion. (Research:
  black-box judgment isn't certifiable; deterministic checks are.)
- **`ci.selective` is the Stripe move.** It's a composite gate that picks only the tests
  touching the changed files and caps repair rounds (e.g. 2), so the integration bottleneck
  stays bounded against a huge suite.

### 8.3 How a gate executes — one `GateRunner`

Every gate, deterministic or judge, is run by the same interface and returns the same
`Verdict`. This uniformity is what makes evals possible (next section).

```swift
public struct GateContext {
    public var artifacts: [ArtifactEnvelope]   // candidate outputs to check
    public var workspace: URL                  // sandboxed checkout
    public var station: String
    public var params: [String: String]
    public var secrets: SecretResolving        // REUSE the secret boundary
}

public protocol GateRunner {
    func run(_ gate: GateDefinition, _ ctx: GateContext) throws -> Verdict
}

// Deterministic: run command in sandbox → parse stdout/stderr → metrics → threshold check
public struct DeterministicGateRunner: GateRunner { /* exec + parse + compare */ }

// Judge: render rubric over artifacts → LLM → structured score → threshold check
public struct JudgeGateRunner: GateRunner { /* prompt + adapter + parse */ }
```

A `Verdict` is `status` + a **`metrics` dictionary** compared against the gate's
`thresholds`. Metrics (not just pass/fail) are what evals trend over time, and the
`evidenceRef` (the log artifact) is what the audit trail and the self-repair loop both read.

### 8.4 How gates attach to the DAG

Two attachment points, both resolved from the `GateRegistry` at load:

1. **As a station post-condition** (`RoleDefinition.verification: [gateId]`). These run
   *inside* the station before its outputs are marked `.ready`. Failure → self-repair loop.
2. **As a standalone gate station** (`StationKind.gate`) — a node in the graph with no LLM,
   e.g. the `ci.selective` gate between `assemble` and the PR.

At definition-load you **statically validate** that every referenced gate id exists in the
registry (same spirit as the edge type-check) — a role pointing at a missing gate fails to
load, not at runtime. `blocking: false` gates are *advisory*: their verdict is surfaced and
logged but doesn't stop the line (useful while a new judge gate is being calibrated).

### 8.5 The key idea: a gate **is** an eval

A gate and an eval call the **same `GateRunner` over the same `GateDefinition`**. The only
difference is the *driver*:

```mermaid
flowchart TB
    subgraph SHARED["shared core"]
        REG["GateRegistry"] --> GR["GateRunner → Verdict"]
    end

    subgraph INLINE["INLINE mode · live run (blocks)"]
        ST["station produced artifacts"] --> GR
        GR --> DEC{"verdict"}
        DEC -->|pass| ACC["mark .ready, advance"]
        DEC -->|fail + budget| REP["self-repair"]
        DEC -->|exhausted| BLK["BlockerRecord"]
    end

    subgraph OFFLINE["OFFLINE mode · eval (scores)"]
        EC["EvalCase fixtures"] --> RUN["EvalRunner"]
        RUN -->|same gates| GR
        RUN --> GOLD["+ golden diff + judge rubric"]
        GR --> RES["EvalResult"]
        GOLD --> RES
    end
```

Practical payoff: you write a verification gate **once** and get a regression eval for free —
and your eval suite tests *exactly* the checks production runs, so there's no drift between
"what we measure" and "what gates the line."

### 8.6 How evals plug in — the wiring

```swift
public enum EvalTarget: Codable, Equatable {
    case role(String)      // "coder.api"            — Tier 3
    case gate(String)      // "judge.api-conventions"— Tier 2 meta-eval (judge-the-judge)
    case factory(String)   // "crud-ui.v1"           — Tier 4 end-to-end
}

public struct EvalSuite: Codable, Equatable {
    public var id: String
    public var target: EvalTarget
    public var cases: [EvalCase]   // EvalCase defined in §6
}

public enum EvalMode: String, Codable {
    case replay      // score already-produced artifacts against gates/golden (fast, deterministic-ish)
    case regenerate  // re-execute the role/factory, THEN score (measures the model+prompt today)
}

public protocol EvalRunner {
    func run(_ suite: EvalSuite, mode: EvalMode) throws -> EvalReport
}

public struct EvalReport: Codable, Equatable {
    public var suiteId: String
    public var results: [EvalResult]                 // EvalResult defined in §6
    public var summary: [String: Double]             // firstRunGreen_rate, cleanup_p50, cleanup_p90, judge_mean, cost_total
    public var baseline: [String: Double]?           // prior version, for regression deltas
}
```

Four concrete integration points:

1. **Production feeds the corpus (closed loop).** Every live run appends `FactoryEvent`s with
   content-addressed artifacts and `Verdict`s. A successful, human-approved run is *harvested*
   into golden `EvalCase`s — its inputs become fixtures, its accepted outputs become `golden`.
   Your eval set grows from real shipped features instead of being hand-authored.

2. **Where each tier runs:**
   - Tier 1 (contract) + Tier 2 (gate) + Tier 3 (role, `mode: .replay`) → on every commit in
     `swift test` / CI. Fast, mostly deterministic.
   - Tier 3 `mode: .regenerate` + Tier 4 (factory) → nightly and as a **pre-promotion gate**.

3. **The promotion gate (evals gate the factory's own development).** Bumping
   `RoleDefinition.version` (or a prompt/model `binding`) triggers that role's `EvalSuite` in
   `.regenerate` mode. The new version is **blocked from promotion** unless `EvalReport.summary`
   doesn't regress vs `baseline` — e.g. `firstRunGreen_rate` not down, `cleanup_p90` not up.
   This is the same gate machinery turned on yourselves.

```mermaid
flowchart LR
    PROD["live runs"] -->|FactoryEvent log| HARVEST["harvest golden cases"]
    HARVEST --> CORPUS["EvalSuites"]
    CORPUS --> EVAL["EvalRunner"]
    NEWVER["new role/prompt/model version"] --> EVAL
    EVAL --> PROMO{"regression vs baseline?"}
    PROMO -->|no regression| SHIP["promote version"]
    PROMO -->|regressed| REJECT["block promotion"]
    SHIP --> PROD
```

4. **Judge-the-judge (Tier 2 meta-eval).** Judge gates drift, so each `judge.*` gate has its
   own `EvalSuite` (`target: .gate`) over a human-labeled set: does the judge's verdict match
   the human label? A judge whose agreement drops below threshold is itself blocked from
   promotion. Without this, your subjective gates silently rot.

**Anti-tautology, concretely:** the `test.author` role's eval doesn't ask "do the tests
pass?" — it runs the `mutation` gate: inject known faults into the implementation and assert
the generated tests *fail*. A test suite that stays green under mutation scores zero.

---

## 9. TL;DR

- **One deterministic engine, roles are data.** A station does whatever its `RoleDefinition`
  says; the engine never knows "planner" from "coder."
- **The DAG is typed.** Ports carry `schemaId`; edges are checked at load and artifacts at
  produce-time. Control flow *emerges* from readiness — phases disappear as a hardcoded enum.
- **Gates live inside stations.** LLM output is never trusted until its own checks pass; the
  agent self-repairs before any human is involved. This is the Stripe guardrail pattern.
- **Everything is event-sourced** → audit, resume, and eval replay come from one log.
- **Evals are 4 tiers** culminating in end-to-end replay measured against Athena's bar
  (≥80% first-run green, <30 min cleanup).
- You already have ~70% of the primitives. The work is *generalizing* the phase machine into
  a typed DAG and making roles loadable config.
