# Native Artifact Demo: Debit BNPL Launch

This is a simulated end-user walkthrough for the revised `ai-sdd` product
direction: a lightweight, Git-native control system for governed agentic
software delivery.

This demo intentionally does not use the current OpenSpec-centered MVP contract
as the product source of truth. It shows the proposed next requirements/design
direction where `ai-sdd` owns typed artifact semantics, workflow validation,
approval gates, attribution, telemetry, and multi-repo coordination. OpenSpec,
if supported later, would be optional import/export only.

## Scenario

FinCo is launching "Split Debit", a Buy Now Pay Later feature for existing
debit card transactions.

An eligible customer can select a settled debit transaction, convert it into a
short installment loan, receive disclosures, accept terms, and then repay over a
fixed schedule. The launch spans multiple repositories:

```text
finco/mobile-web
finco/graphql-orchestration
finco/debit-transactions
finco/lending-service
finco/payment-processing
finco/notifications
finco/accounting
finco/vendor-ledger-adapter
```

The enterprise concern is not just "can an agent implement code." Reviewers
need to see whether the product creates enforceable delivery control across
requirements, design, behavior specs, slicing, dependencies, gates, approvals,
review evidence, verification, telemetry, and blocked states.

## Simulated Commands

```bash
sdd init --native --project split-debit-bnpl
sdd project intake --file docs/intake/split-debit-bnpl.md
sdd project open split-debit-bnpl --tui
sdd slice create eligibility-quote --from project-requirements
sdd validate --project split-debit-bnpl
sdd gate request --slice eligibility-quote --gate implementation_ready
sdd agent prepare --slice eligibility-quote --role implementer
sdd review start --slice eligibility-quote --repos finco/graphql-orchestration,finco/lending-service
sdd verify submit --slice eligibility-quote --from ci/verification-results.json
sdd status --project split-debit-bnpl --json
```

The command names are demo names, not accepted CLI contracts. The important
product behavior is the typed workflow state and validation outcome.

## Proposed Native Artifact Layout

```text
.sdd/
  config.json
  telemetry/
    events.jsonl

sdd/
  projects/
    split-debit-bnpl/
      project.md
      dependency-graph.json
      decisions.md
      approvals.jsonl
      blockers.jsonl
      telemetry-summary.json
      slices/
        eligibility-quote/
          requirements.md
          design.md
          specs.md
          tasks.md
          review.md
          verification.json
          run-summary.json
          artifacts.json
        loan-booking/
          requirements.md
          design.md
          specs.md
          tasks.md
          review.md
          verification.json
          run-summary.json
          artifacts.json
        repayment-schedule/
          requirements.md
          design.md
          specs.md
          tasks.md
          review.md
          verification.json
          run-summary.json
          artifacts.json
```

## Project Intake

```bash
$ sdd project intake --file docs/intake/split-debit-bnpl.md
```

```text
ai-sdd project intake

Project: split-debit-bnpl
Status:  input_required
Reason:  ambiguous_policy

Extracted scope
  Product:       Buy Now Pay Later for settled debit transactions
  Customer:      Existing debit card customers
  Launch path:   Mobile and web
  Repos:         8
  Risk class:    regulated_financial_product
  Target phase:  requirements

Required clarification
  Q1: Is eligibility determined before or after transaction settlement?
  Q2: Which system owns APR and fee disclosure calculation?
  Q3: Can partial reversals happen after loan booking?
  Q4: Which vendor API is source of record for loan ledger state?

Next action
  Human product/legal owner must answer clarification before requirements can
  be marked ready for design.
```

TUI view:

```text
+------------------------------------------------------------------------------+
| ai-sdd  Project Intake                                          split-debit   |
+------------------------------------------------------------------------------+
| Status: INPUT REQUIRED       Risk: regulated_financial_product                |
| Owner: Card Platform         Program: Debit Modernization                     |
+------------------------------------------------------------------------------+
| Intake Summary                                                               |
|   Existing customers may convert settled debit transactions into fixed-term   |
|   installment loans. Launch requires frontend, orchestration, transaction,    |
|   lending, payment, notification, accounting, and vendor ledger changes.      |
|                                                                              |
| Open Questions                                                               |
|   [blocking] eligibility timing: pre-settlement or settled-only?              |
|   [blocking] disclosure owner: lending-service or vendor platform?            |
|   [blocking] reversal handling after loan booking                             |
|   [blocking] ledger source of record                                          |
|                                                                              |
| Actions                                                                      |
|   answer-clarification   revise-intake   export-summary                      |
+------------------------------------------------------------------------------+
```

### Human Clarification

```bash
$ sdd answer --project split-debit-bnpl --question eligibility-timing \
  --value "Settled debit transactions only. Pending auths are out of scope."
```

Artifact snippet:

```markdown
# Decisions

## DEC-001: Eligibility applies to settled debit transactions only

Status: closed
Owner: product/legal
Date: 2026-06-03

Pending authorizations are excluded from MVP. Eligibility evaluation starts
after transaction settlement and after transaction enrichment is available.

Implications:
- mobile/web must hide pending transactions from BNPL entry points
- debit-transactions must expose settled transaction metadata
- GraphQL must not call lending quote APIs for pending authorizations
```

## Product Requirements

Artifact snippet: `sdd/projects/split-debit-bnpl/project.md`

```markdown
# Split Debit BNPL

## Goal

Allow eligible existing debit card customers to convert a settled debit card
transaction into a fixed-term installment loan with clear disclosures,
repayment schedule visibility, and auditable ledger/accounting treatment.

## Non-goals

- Pending card authorizations
- Merchant-funded promotional plans
- New customer acquisition flows
- Fully autonomous cross-repo code execution
- Hosted management dashboard

## Required Controls

- Legal approval before customer-facing disclosure changes can enter
  implementation.
- Architecture approval before any slice touches more than two repos.
- Behavior specs are mandatory for implementation readiness.
- Verification evidence must include unit, contract, integration, and ledger
  reconciliation checks for affected repos.
- Every agent action must be attributed to an actor, role, adapter, model when
  available, duration, and resulting artifact changes.
```

TUI view:

```text
+------------------------------------------------------------------------------+
| ai-sdd  Project Requirements                                  split-debit     |
+------------------------------------------------------------------------------+
| Phase: REQUIREMENTS     Completion: 78%       Gates: 2 blocked / 5 total      |
+----------------------------+-------------------------------------------------+
| Required Artifact          | State                                           |
+----------------------------+-------------------------------------------------+
| project.md                 | ready                                           |
| decisions.md               | needs legal answer: disclosure ownership        |
| dependency-graph.json      | draft                                           |
| slice plan                 | draft, 6 slices proposed                        |
| approval policy            | ready                                           |
+----------------------------+-------------------------------------------------+
| Risk Notes                                                                    |
| - Reg Z / state lending disclosures may affect frontend and vendor adapter.    |
| - Reversal handling can invalidate loan principal after booking.               |
| - Ledger source-of-record must be settled before accounting design.            |
+------------------------------------------------------------------------------+
```

## Feature Slicing

```bash
$ sdd slice plan --project split-debit-bnpl
```

```text
Generated slices

1. eligibility-quote
   Outcome: customer can see whether a settled transaction is eligible and view
   a non-binding installment quote.
   Repos: mobile-web, graphql-orchestration, debit-transactions, lending-service
   Gate: legal disclosure owner required before implementation

2. loan-booking
   Outcome: customer accepts disclosures and books a loan with vendor ledger.
   Repos: mobile-web, graphql-orchestration, lending-service, vendor-ledger-adapter
   Gate: vendor source-of-record decision required

3. repayment-schedule
   Outcome: customer can view installment schedule and upcoming payment dates.
   Repos: mobile-web, graphql-orchestration, lending-service

4. autopay-collection
   Outcome: scheduled repayments debit the funding account and post results.
   Repos: payment-processing, lending-service, notifications

5. reversals-and-adjustments
   Outcome: merchant refunds or reversals adjust loan principal and ledger.
   Repos: debit-transactions, lending-service, accounting, vendor-ledger-adapter
   Gate: high-risk architecture review

6. accounting-and-reconciliation
   Outcome: finance can reconcile loan principal, fees, payments, and chargeoffs.
   Repos: accounting, lending-service, vendor-ledger-adapter
```

TUI view:

```text
+------------------------------------------------------------------------------+
| ai-sdd  Slice Board                                            split-debit    |
+------------------------------------------------------------------------------+
| Slice                         State              Repos   Blockers   Ready     |
+------------------------------+------------------+-------+----------+----------+
| eligibility-quote             design             4       1          no        |
| loan-booking                  requirements       4       2          no        |
| repayment-schedule            requirements       3       0          no        |
| autopay-collection            not_started        3       0          no        |
| reversals-and-adjustments     blocked            4       2          no        |
| accounting-and-reconciliation not_started        3       1          no        |
+------------------------------------------------------------------------------+
| View: dependencies | gates | blockers | telemetry | approvals | review        |
+------------------------------------------------------------------------------+
```

## Multi-Repo Dependency Graph

Artifact snippet: `dependency-graph.json`

```json
{
  "schema_version": "sdd.native.dependency_graph.v1",
  "project": "split-debit-bnpl",
  "nodes": [
    {
      "id": "repo:finco/mobile-web",
      "kind": "repository",
      "owners": ["consumer-experience"]
    },
    {
      "id": "repo:finco/graphql-orchestration",
      "kind": "repository",
      "owners": ["api-platform"]
    },
    {
      "id": "api:lending.quote.installmentOptions",
      "kind": "contract",
      "repo": "finco/lending-service"
    },
    {
      "id": "event:debit.transaction.settled.v2",
      "kind": "event",
      "repo": "finco/debit-transactions"
    }
  ],
  "edges": [
    {
      "from": "repo:finco/mobile-web",
      "to": "repo:finco/graphql-orchestration",
      "reason": "frontend queries BNPL eligibility and quote fields"
    },
    {
      "from": "repo:finco/graphql-orchestration",
      "to": "api:lending.quote.installmentOptions",
      "reason": "GraphQL resolver orchestrates quote"
    },
    {
      "from": "api:lending.quote.installmentOptions",
      "to": "event:debit.transaction.settled.v2",
      "reason": "eligibility requires settled transaction facts"
    }
  ],
  "gates": [
    {
      "id": "gate:multi_repo_architecture",
      "required_when": "slice.repo_count > 2",
      "approvers": ["staff-engineer", "service-owner"]
    },
    {
      "id": "gate:regulated_disclosure",
      "required_when": "artifact.tags contains customer_disclosure",
      "approvers": ["legal", "compliance"]
    }
  ]
}
```

TUI graph view:

```text
+------------------------------------------------------------------------------+
| ai-sdd  Dependency Graph                                      eligibility     |
+------------------------------------------------------------------------------+
| mobile-web                                                                  |
|    | GraphQL query: debitTransaction.bnplEligibility                         |
|    v                                                                         |
| graphql-orchestration                                                        |
|    | calls quote API                                                         |
|    v                                                                         |
| lending-service                                                              |
|    | requires settled transaction facts                                      |
|    v                                                                         |
| debit-transactions                                                           |
|                                                                              |
| Cross-repo gates                                                             |
|   [required] staff architecture approval: 4 repos touched                     |
|   [required] contract tests: GraphQL <-> lending-service                     |
|   [required] event fixture: transaction.settled.v2                            |
+------------------------------------------------------------------------------+
```

## Technical Design / RFC

Artifact snippet: `slices/eligibility-quote/design.md`

```markdown
# Eligibility And Quote Design

## Scope

Expose BNPL eligibility and quote terms for settled debit transactions.

## Proposed Flow

1. mobile-web requests BNPL fields for a settled transaction detail screen.
2. GraphQL validates transaction ownership and settlement state.
3. GraphQL calls lending-service quote API with transaction ID, amount,
   settlement date, merchant category, and customer risk segment reference.
4. lending-service calculates eligibility and quote options.
5. GraphQL returns display-safe eligibility reason codes and quote terms.

## Interfaces

- GraphQL field: `debitTransaction.bnplEligibility`
- Lending API: `POST /internal/bnpl/installment-quote`
- Debit transaction dependency: `transaction.settlementStatus == settled`

## Failure Behavior

- If lending-service is unavailable, GraphQL returns `temporarilyUnavailable`.
- If transaction is pending, GraphQL returns `notEligible.pendingTransaction`.
- If customer is ineligible, GraphQL returns display-safe reason code only.

## Verification

- GraphQL schema snapshot test
- lending-service quote calculation unit tests
- contract test for GraphQL to lending-service request/response
- integration test with settled and pending transaction fixtures
```

## Behavior Specs

Artifact snippet: `slices/eligibility-quote/specs.md`

```markdown
# Behavior Specs

## SPEC-EQ-001: Settled eligible transaction returns quote options

Given an existing debit customer
And the customer owns a settled debit transaction for 240.00 USD
And the transaction merchant category is eligible
When the customer opens the transaction detail screen
Then the response includes BNPL eligibility status `eligible`
And the response includes at least one installment quote option
And each quote includes term length, payment amount, APR, fees, and total cost

## SPEC-EQ-002: Pending transaction cannot be quoted

Given an existing debit customer
And the customer owns a pending debit card authorization
When the customer opens the transaction detail screen
Then the response includes BNPL eligibility status `notEligible`
And the reason code is `pendingTransaction`
And GraphQL does not call lending-service quote APIs

## SPEC-EQ-003: Quote service outage is non-fatal

Given lending-service quote APIs are unavailable
When GraphQL resolves BNPL eligibility for a settled transaction
Then the transaction detail response still succeeds
And BNPL eligibility is `temporarilyUnavailable`
And the outage is recorded in telemetry without customer PII
```

## Missing Artifact Validation

This is the core behavior the demo is meant to validate: implementation is
blocked when required specs are missing or invalid.

```bash
$ rm sdd/projects/split-debit-bnpl/slices/loan-booking/specs.md
$ sdd gate request --slice loan-booking --gate implementation_ready
```

```text
ai-sdd gate: implementation_ready

Result: BLOCKED
Code:   missing_required_artifact

Slice:  loan-booking
Gate:   implementation_ready

Required artifacts
  requirements.md       present     valid
  design.md             present     valid
  specs.md              missing     blocks implementation
  tasks.md              present     stale: generated before design approval
  dependency-graph.json present     valid
  decisions.md          present     unresolved: DEC-004 ledger source of record

Policy violations
  - behavior_specs_required:
      Implementation cannot start without behavior specs.
  - closed_decisions_required:
      DEC-004 must be closed because loan booking writes ledger state.
  - stale_tasks:
      tasks.md must be regenerated after design changes.

Next action
  Generate or author specs.md, close DEC-004, regenerate tasks, then request
  implementation_ready again.
```

TUI validation view:

```text
+------------------------------------------------------------------------------+
| ai-sdd  Gate Validation                                      loan-booking     |
+------------------------------------------------------------------------------+
| Gate: implementation_ready                         Result: BLOCKED           |
+------------------------------+------------+----------------------------------+
| Requirement                  | State      | Detail                           |
+------------------------------+------------+----------------------------------+
| requirements artifact        | pass       | version 3 approved               |
| design artifact              | pass       | RFC approved                     |
| behavior specs               | fail       | specs.md missing                 |
| task plan freshness          | fail       | generated from design version 2  |
| ledger source decision       | fail       | DEC-004 unresolved               |
| legal disclosure approval    | pass       | approval LEGAL-2026-018          |
| architecture approval        | pass       | staff-engineer approved          |
+------------------------------+------------+----------------------------------+
| Implementation command unavailable until blocking failures are resolved.       |
+------------------------------------------------------------------------------+
```

This is deliberately stricter than an artifact store that only checks for a
task checklist. The product rule is semantic: for regulated slices, approved
requirements, approved design, behavior specs, fresh tasks, required closed
decisions, and gate approvals are all prerequisites.

## Task Generation

```bash
$ sdd tasks generate --slice eligibility-quote
```

Artifact snippet: `slices/eligibility-quote/tasks.md`

```markdown
# Tasks

## finco/debit-transactions

- [ ] Add fixture for settled debit transaction with merchant category,
      settlement timestamp, amount, and customer ownership fields.
- [ ] Expose settlement state to GraphQL data access layer.

## finco/lending-service

- [ ] Add internal quote request/response models.
- [ ] Implement quote eligibility policy for settled debit transaction input.
- [ ] Add unit tests for eligible, pending, ineligible, and service-failure
      paths mapped to SPEC-EQ-001 through SPEC-EQ-003.

## finco/graphql-orchestration

- [ ] Add `bnplEligibility` GraphQL field.
- [ ] Implement resolver guard that does not call lending-service for pending
      transactions.
- [ ] Add contract tests against lending-service quote API.

## finco/mobile-web

- [ ] Render entry point only for display-safe eligible or unavailable states.
- [ ] Add screen state tests for eligible, ineligible, pending, and unavailable.

## Verification

- [ ] `finco/lending-service`: unit test quote policy
- [ ] `finco/graphql-orchestration`: contract test lending quote API
- [ ] `finco/mobile-web`: UI state snapshot tests
- [ ] cross-repo integration fixture: settled debit transaction quote
```

## Approval And Rejection

```bash
$ sdd gate request --slice eligibility-quote --gate design_approval
```

```text
Gate: design_approval
Result: REJECTED
Reviewer: staff-engineer

Reason
  GraphQL resolver currently owns too much lending policy. Move eligibility
  policy details into lending-service and keep GraphQL orchestration limited to
  ownership, settlement-state guard, and response mapping.

Required changes
  - Update design.md ownership section.
  - Update specs.md to assert GraphQL does not infer ineligibility except for
    pending transaction guard.
  - Regenerate tasks for GraphQL and lending-service.
```

TUI approval history:

```text
+------------------------------------------------------------------------------+
| ai-sdd  Approvals                                             eligibility     |
+------------------------------------------------------------------------------+
| Gate                  State      Actor            Time           Notes        |
+-----------------------+-----------+----------------+--------------+------------+
| requirements_ready    approved   product-owner    2026-06-03     v2          |
| legal_disclosure      approved   legal            2026-06-03     LEGAL-018   |
| design_approval       rejected   staff-engineer   2026-06-03     policy move |
| architecture          pending    service-owner    -              4 repos     |
+------------------------------------------------------------------------------+
| Current next action: revise design and regenerate tasks.                      |
+------------------------------------------------------------------------------+
```

## Implementation Readiness

After the design rejection is addressed:

```bash
$ sdd gate request --slice eligibility-quote --gate implementation_ready
```

```text
Gate: implementation_ready
Result: APPROVED

Inputs locked
  requirements.md       version 4
  design.md             version 5
  specs.md              version 3
  tasks.md              version 6
  dependency graph      version 2
  decisions             DEC-001, DEC-002, DEC-003

Execution packet
  role: implementer
  adapter: codex
  repos:
    - finco/debit-transactions
    - finco/lending-service
    - finco/graphql-orchestration
    - finco/mobile-web

Constraints
  - do not modify loan booking flows
  - do not implement vendor ledger calls
  - map code changes to SPEC-EQ-001 through SPEC-EQ-003
  - submit verification evidence before review
```

TUI readiness view:

```text
+------------------------------------------------------------------------------+
| ai-sdd  Implementation Ready                                eligibility      |
+------------------------------------------------------------------------------+
| Ready: yes       Risk: medium       Repos: 4       Specs: 3       Tasks: 12   |
+------------------------------------------------------------------------------+
| Locked Inputs                                                               |
|   requirements.md v4     design.md v5     specs.md v3     tasks.md v6        |
|                                                                              |
| Agent Execution Boundary                                                     |
|   Role: implementer                                                          |
|   Allowed repos: debit-transactions, lending-service, graphql, mobile-web    |
|   Forbidden: loan booking, payment collection, vendor ledger mutation        |
|                                                                              |
| Expected Evidence                                                            |
|   unit: lending quote policy                                                 |
|   contract: GraphQL to lending quote API                                     |
|   integration: settled transaction quote fixture                             |
|   UI: mobile/web transaction detail states                                   |
+------------------------------------------------------------------------------+
```

## Review Phase

```bash
$ sdd review start --slice eligibility-quote
```

Artifact snippet: `slices/eligibility-quote/review.md`

```markdown
# Review

## Verdict

Changes requested

## Findings

### R-001: GraphQL pending guard is correct

SPEC-EQ-002 is covered. GraphQL returns `notEligible.pendingTransaction` and
does not call lending-service.

### R-002: Missing telemetry assertion for quote outage

SPEC-EQ-003 requires outage telemetry without customer PII. The implementation
records an error counter but does not include slice/run attribution.

Required fix:
- Add telemetry event with run ID, slice ID, repo, phase, reason code, and no
  customer identifiers.

### R-003: Contract fixture does not include APR and total cost

SPEC-EQ-001 requires APR, fees, and total cost in each quote option. The current
contract fixture only asserts payment amount and term length.
```

TUI review view:

```text
+------------------------------------------------------------------------------+
| ai-sdd  Review                                                eligibility     |
+------------------------------------------------------------------------------+
| Verdict: CHANGES REQUESTED       Reviewer: reviewer-agent + staff engineer    |
+----------------------+----------+---------------------------------------------+
| Spec                 | Coverage | Evidence                                    |
+----------------------+----------+---------------------------------------------+
| SPEC-EQ-001          | partial  | contract fixture missing APR/fees/total     |
| SPEC-EQ-002          | pass     | GraphQL pending guard verified              |
| SPEC-EQ-003          | fail     | telemetry attribution missing               |
+----------------------+----------+---------------------------------------------+
| Required fixes                                                              |
|   R-002 Add telemetry event without PII                                      |
|   R-003 Expand quote contract fixture                                        |
+------------------------------------------------------------------------------+
```

## Verification Results

```bash
$ sdd verify submit --slice eligibility-quote --from ci/verification-results.json
```

Artifact snippet: `slices/eligibility-quote/verification.json`

```json
{
  "schema_version": "sdd.native.verification.v1",
  "project": "split-debit-bnpl",
  "slice": "eligibility-quote",
  "submitted_by": {
    "actor_type": "ci",
    "actor_id": "github-actions",
    "run_url": "https://github.example/finco/graphql-orchestration/actions/10933"
  },
  "results": [
    {
      "repo": "finco/lending-service",
      "kind": "unit",
      "command": "swift test --filter BNPLQuotePolicyTests",
      "status": "passed",
      "specs": ["SPEC-EQ-001", "SPEC-EQ-002"]
    },
    {
      "repo": "finco/graphql-orchestration",
      "kind": "contract",
      "command": "npm run test:contract -- bnplQuote",
      "status": "failed",
      "specs": ["SPEC-EQ-001"],
      "failure": "Fixture missing APR, fee, and total cost assertions"
    },
    {
      "repo": "finco/mobile-web",
      "kind": "ui",
      "command": "pnpm test transaction-detail-bnpl",
      "status": "passed",
      "specs": ["SPEC-EQ-001", "SPEC-EQ-002", "SPEC-EQ-003"]
    }
  ],
  "overall_status": "failed"
}
```

TUI verification view:

```text
+------------------------------------------------------------------------------+
| ai-sdd  Verification                                          eligibility     |
+------------------------------------------------------------------------------+
| Overall: FAILED          Required for review approval: all required evidence  |
+--------------------------+----------+-------------------+---------------------+
| Repo                     | Kind     | Status            | Specs               |
+--------------------------+----------+-------------------+---------------------+
| lending-service          | unit     | passed            | EQ-001 EQ-002       |
| graphql-orchestration    | contract | failed            | EQ-001              |
| mobile-web               | ui       | passed            | EQ-001 EQ-002 EQ-003|
| cross-repo               | integ    | not submitted     | EQ-001 EQ-003       |
+--------------------------+----------+-------------------+---------------------+
| Blocked: review approval unavailable until required verification passes.      |
+------------------------------------------------------------------------------+
```

## Blocked State

```bash
$ sdd status --slice reversals-and-adjustments
```

```text
Slice: reversals-and-adjustments
State: blocked
Reason: unresolved_policy

Blockers
  - DEC-006: How are partial merchant reversals allocated across principal,
    fees, and paid installments?
  - DEC-007: Which ledger owns authoritative reversal state after vendor sync
    failure?

Impact
  - loan-booking may proceed only if it records reversal hooks as non-goals
    for MVP.
  - accounting-and-reconciliation cannot enter design until DEC-006 closes.
```

TUI blocked view:

```text
+------------------------------------------------------------------------------+
| ai-sdd  Blockers                                      reversals-adjustments   |
+------------------------------------------------------------------------------+
| State: BLOCKED             Owner needed: lending policy + accounting          |
+------------------------------------------------------------------------------+
| DEC-006  Partial reversal allocation                                          |
|   Blocks: reversals-and-adjustments, accounting-and-reconciliation            |
|   Needed: policy decision for principal, fees, paid installments              |
|                                                                              |
| DEC-007  Ledger authority during vendor sync failure                          |
|   Blocks: loan-booking hardening, accounting reconciliation                   |
|   Needed: architecture decision on source of truth and repair workflow        |
|                                                                              |
| Allowed parallel work                                                         |
|   eligibility-quote, repayment-schedule                                       |
+------------------------------------------------------------------------------+
```

## Attribution And Telemetry

Artifact snippet: `.sdd/telemetry/events.jsonl`

```jsonl
{"schema_version":"sdd.native.telemetry.v1","event_id":"evt_001","project":"split-debit-bnpl","slice":"eligibility-quote","phase":"requirements","status":"input_required","actor":{"type":"agent","id":"planner-agent","adapter":"codex","model":"unknown","token_confidence":"unavailable"},"duration_ms":18342,"policy_results":[{"policy":"clarification_required","status":"failed","reason":"ambiguous_policy"}]}
{"schema_version":"sdd.native.telemetry.v1","event_id":"evt_014","project":"split-debit-bnpl","slice":"eligibility-quote","phase":"gate","gate":"design_approval","status":"rejected","actor":{"type":"human","id":"staff-engineer"},"duration_ms":412000,"review_outcome":"policy_moved_to_lending_service"}
{"schema_version":"sdd.native.telemetry.v1","event_id":"evt_031","project":"split-debit-bnpl","slice":"eligibility-quote","phase":"verification","status":"failed","actor":{"type":"ci","id":"github-actions"},"verification_results":[{"repo":"finco/graphql-orchestration","kind":"contract","status":"failed","spec":"SPEC-EQ-001"}]}
```

Telemetry summary view:

```text
+------------------------------------------------------------------------------+
| ai-sdd  Telemetry                                             split-debit     |
+------------------------------------------------------------------------------+
| Project state: active       Slices: 6       Blocked: 2       Ready: 1         |
+-------------------------+----------------------------------------------------+
| Cycle time              | requirements 2h 14m | design 5h 42m | review 1h 8m |
| Agent activity          | planner 7 runs | implementer 2 runs | reviewer 1 run |
| Human gates             | approved 4 | rejected 1 | pending 3                  |
| Verification            | passed 6 | failed 1 | missing 2                    |
| Token attribution       | exact 0 | adapter-reported 2 | unavailable 8          |
| Top blocker             | unresolved reversal/accounting policy              |
+------------------------------------------------------------------------------+
```

## End-To-End TUI Project View

```text
+------------------------------------------------------------------------------+
| ai-sdd                                                        split-debit     |
+------------------------------------------------------------------------------+
| Program: Debit Modernization       Phase: design/review       Risk: high      |
| Source: native Git artifacts       UI: TUI                    Repos: 8        |
+------------------------------------------------------------------------------+
| Slices                         State         Gate                  Owner       |
+-------------------------------+-------------+----------------------+-----------+
| eligibility-quote              review        verification_failed  api-platform |
| loan-booking                   blocked       missing_specs        lending     |
| repayment-schedule             design        design_pending       experience  |
| autopay-collection             not_started   requirements_needed  payments    |
| reversals-and-adjustments      blocked       policy_needed        lending     |
| accounting-and-reconciliation  not_started   dependency_blocked   finance     |
+------------------------------------------------------------------------------+
| Current Critical Path                                                        |
|   1. Close DEC-004 ledger source of record for loan-booking                  |
|   2. Author loan-booking behavior specs                                      |
|   3. Fix eligibility quote contract fixture and submit integration evidence   |
|   4. Decide reversal allocation policy before accounting design               |
+------------------------------------------------------------------------------+
| Commands                                                                     |
|   open slice   validate gates   show graph   show telemetry   export report   |
+------------------------------------------------------------------------------+
```

## JSON Status Shape

```bash
$ sdd status --project split-debit-bnpl --json
```

```json
{
  "schema_version": "sdd.native.status.v1",
  "project": "split-debit-bnpl",
  "status": "active",
  "source_of_truth": "native_git_artifacts",
  "slices": [
    {
      "slug": "eligibility-quote",
      "phase": "review",
      "workflow_status": "blocked",
      "blocked_reason": "verification_failed",
      "required_next_action": "submit_required_verification",
      "repos": [
        "finco/mobile-web",
        "finco/graphql-orchestration",
        "finco/debit-transactions",
        "finco/lending-service"
      ]
    },
    {
      "slug": "loan-booking",
      "phase": "design",
      "workflow_status": "blocked",
      "blocked_reason": "missing_required_artifact",
      "missing_artifacts": ["specs.md"],
      "unresolved_decisions": ["DEC-004"]
    }
  ],
  "gates": {
    "implementation_ready": {
      "eligible_slices": [],
      "blocked_slices": ["eligibility-quote", "loan-booking"]
    }
  }
}
```

## Requirements Validated

- Native artifacts are justified. The workflow needs semantic validation across
  requirements, design, specs, tasks, decisions, approvals, verification, and
  telemetry. A loose external artifact checklist is not enough.
- Behavior specs should be first-class required artifacts. The missing
  `specs.md` block is the clearest product differentiator for governed
  enterprise agentic engineering.
- TUI is a credible first UI. The product experience is status-heavy,
  gate-heavy, and command-adjacent. A terminal board shows value without a
  hosted backend.
- Multi-repo dependency modeling is necessary. The value is not autonomous
  cross-repo implementation; it is knowing which repos, contracts, owners,
  approvals, and verification evidence are coupled.
- Human clarification is not a side path. It is core workflow state and should
  block downstream gates when product/legal/architecture ambiguity is material.
- Approval and rejection should be durable artifacts. Rejections create useful
  workflow state, task invalidation, and traceability.
- Telemetry needs confidence levels. Token usage will not always be exact across
  coding agents, CI, and humans; the schema should represent attribution
  confidence instead of pretending every number is authoritative.

## Requirements Challenged

- Fully modeling programs/projects/slices/tasks/reviews/telemetry in MVP may be
  too broad. The minimum credible demo path is project, slice, artifacts,
  gates, validation, and status. Program portfolio views can come after a single
  project works well.
- Multi-repo coordination should be read/write artifact coordination first, not
  distributed execution. Launching agents across many repos is a later riskier
  capability.
- Jira/GitHub replacement should not be the MVP claim. The product can produce
  planning/status artifacts that Jira or GitHub would normally display, but
  replacing issue trackers is unnecessary for requirements approval.
- Vendor-ledger and accounting flows expose high domain complexity. They are
  excellent for validating blockers and dependency gates, but they should not be
  the first implementation slice.
- A TUI should initially be a read-only or command-assisted control surface.
  Editing complex requirements inside the TUI can wait until artifact semantics
  and validation are stable.
- "Strict artifact validation" should mean policy-driven strictness, not one
  universal rule set. A regulated BNPL slice needs stronger gates than a low-risk
  internal UI cleanup.

## Recommended MVP Demo Slice

Build the first native workflow demo around `eligibility-quote`.

It is complex enough to prove multi-repo coordination, required behavior specs,
approval rejection, verification evidence, and telemetry, but it avoids the
highest-risk loan booking, reversal, vendor ledger, and accounting semantics.

The acceptance bar for the next design pass should be:

```text
1. Native artifact layout is accepted or revised.
2. Required artifact types and gate semantics are accepted.
3. Missing behavior specs block implementation readiness.
4. TUI project/slice/status views are accepted as the first UI direction.
5. OpenSpec dependency is explicitly removed from core architecture, with any
   compatibility moved to optional import/export.
```
