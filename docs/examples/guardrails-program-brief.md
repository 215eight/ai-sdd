# Program: Factory safety guardrails (locks + provenance + drift)

> Hand this to `ai-sdd-plan-program` as the program brief. It is decision-closed from
> [ADR-0031](../decisions.md) (locks), [ADR-0032](../decisions.md) (provenance), and
> [ADR-0033](../decisions.md) (drift), all built on the shipped `ai-sdd plan` substrate (ADR-0030).
> TRANSCRIBE the decisions; do not invent scope, sequencing, or milestones. If anything is ambiguous,
> STOP and ask before emitting the master graph.

## Goal

Complete the factory safety layer on top of the shipped `ai-sdd plan` (risk-tiered change preview). Three
guardrails turn "preview only" into prevent + attribute + detect: **locks** make the reserved `frozen`
tier real so the factory *refuses* an unintended change to a protected artifact; **provenance** records
what the generators produced so re-bootstrap never silently clobbers a hand-edited artifact; **drift**
detects when committed artifacts have gone stale against reality. Together with `plan` they close the loop:
plan previews, locks prevents, provenance attributes, drift detects.

## Sub-features

Each becomes its own feature plan (`ai-sdd-plan` → `.ai-sdd/features/<id>/`). Single-owner program (the
ai-sdd maintainer drives; work is done by factory sub-agents) — owners are nominal, the program tier is
used for the **milestone gate**, not multi-person coordination.

- `locks` — ADR-0031. Add `frozen` as the top `Tier` (above `contract`) in `ChangePlan`; a committed
  `.ai-sdd/locks.yaml` glob manifest; promote a change to a locked path to `frozen` with a `locked` flag;
  `ai-sdd plan` renders it ✗ and exits **`3`** regardless of `--require-ack`; `--unlock <path>` downgrades
  for one invocation. Owner: **maintainer**.
- `provenance` — ADR-0032. A committed `.ai-sdd/provenance.json` mapping each generated artifact →
  `{ generator, generatedAt, contentHash }`; generators (bootstrap, compile-schema) write entries; a
  re-bootstrap compares on-disk hash to recorded hash and refuses to silently overwrite a hand-edited
  artifact; `ai-sdd plan` adds a `hand-edited` annotation. Determinism: timestamp is an input, hashes are
  content-addressed (no-op re-run = no diff). Owner: **maintainer**.
- `drift` — ADR-0033. `ai-sdd drift [<dir>]` reporting three divergence kinds: stale gate (recompile
  schema in-memory, diff vs committed check), fixture↔schema (`SchemaValidator`), convention↔code
  (mechanically re-check the Discovery Record's evidence citations). Advisory/non-blocking; each finding
  names its remedy; provenance-aware (annotate `hand-edited` findings). Owner: **maintainer**.

## Milestones

- `m1-guardrails-integrated` — **automated**. Validates that **locks** and **provenance** both extend
  `plan` correctly before `drift` builds on them: `swift build` + `swift test` + `swift run ai-sdd
  validate .ai-sdd` all green, AND a smoke check that a locked-artifact edit makes `ai-sdd plan` exit 3
  and a hand-edited generated artifact renders the `hand-edited` annotation. Gates `drift`. Owner:
  **maintainer**. (Manual↔automated swaps only the node's worker/checks per docs/milestones.md.)

## Sequencing

- `locks` → `m1-guardrails-integrated`
- `provenance` → `m1-guardrails-integrated`
- `m1-guardrails-integrated` → `drift`

(`locks` and `provenance` are independent — both build only on shipped code — so they run in parallel;
`drift` reuses provenance's annotation and the compile-schema/`SchemaValidator` machinery, so it follows
the milestone.)

## Constraints

- Swift; follow `.ai-sdd/conventions/swift.md`. Engine logic in `AISDDEngine`, CLI surface in `AISDDCLI`,
  tests in `Tests/AISDDEngineTests` (Swift Testing). Path constants in `Layout.swift`.
- **Reuse the shipped substrate** — `ChangePlan`/`Tier`, `PlanReport`, `ArtifactDiff`, `SpecLoader`,
  `SchemaValidator`, the `ai-sdd-compile-schema` compiler. No second loader/classifier/parser.
- Classification/detection is **engine logic over loaded specs** (ADR-0001), deterministic; the one
  non-deterministic edge (drift's convention-citation check) is scoped to *flagging* via deterministic
  citation breakage, never LLM-judging.
- Each ADR's Decision section is the contract for its feature — don't re-open closed decisions.
- Enforcement stays **commit-gated** (via `ai-sdd plan`), consistent with ADR-0030; any git hook is an
  optional convenience, not the mechanism.

## Open questions

- **O1** Single-owner program: confirm the program tier (one milestone gate) is worth it here vs three
  sequential `ai-sdd-plan` features. Proposed: **keep the program** — the `m1` gate genuinely blocks
  `drift` until locks+provenance land and verify together.
- **O2** `locks.yaml` glob syntax — propose simple path-prefix + `*` globs scoped under `.ai-sdd/`
  (e.g. `schemas/*.schema.yaml`, `conventions/operator.md`); full globbing deferred unless needed.
- **O3** Is drift's **convention-citation** check in this cycle's MVP, or deferred behind the two
  deterministic kinds (stale-gate, fixture↔schema)? Proposed: **ship the two deterministic kinds in MVP**,
  include the citation check if the `drift` feature plan keeps it thin; otherwise flag it as a follow-up
  slice.
- **O4** Should `m1` also require a minimal `ai-sdd drift` readiness (command exists, exits 0 clean)?
  Proposed: **no** — `m1` gates locks+provenance; drift is downstream of it.
