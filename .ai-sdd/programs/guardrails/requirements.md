# Program: Factory safety guardrails (locks + provenance + drift)

> **APPROVED 2026-06-22 — decisions closed; master graph emitted.** Planning gate (Step 2) cleared.

## Source Brief

`docs/examples/guardrails-program-brief.md` — decision-closed from ADR-0031 (locks), ADR-0032
(provenance), ADR-0033 (drift), all on the shipped `ai-sdd plan` substrate (ADR-0030).

## Goal

Complete the factory safety layer on top of `ai-sdd plan` (risk-tiered change preview). Three guardrails
turn "preview only" into prevent + attribute + detect: **locks** make the reserved `frozen` tier real so
the factory *refuses* an unintended change to a protected artifact; **provenance** records what the
generators produced so re-bootstrap never silently clobbers a hand-edited artifact; **drift** detects
when committed artifacts have gone stale against reality. Together with `plan`: plan previews, locks
prevents, provenance attributes, drift detects.

## Sub-features (each → its own `ai-sdd-plan` feature)

Single-owner program; owners nominal (the maintainer drives, factory sub-agents do the work). The
program tier is used for the **`m1` milestone gate**, not multi-person coordination.

- **`locks`** (ADR-0031) — add `frozen` as the top `Tier` (above `contract`) in `ChangePlan`; a committed
  `.ai-sdd/locks.yaml` glob manifest; promote a change to a locked path to `frozen` (+`locked` flag);
  `ai-sdd plan` renders it ✗ and exits **`3`** regardless of `--require-ack`; `--unlock <path>` downgrades
  for one invocation. Owner: **maintainer**.
- **`provenance`** (ADR-0032) — committed `.ai-sdd/provenance.json` (`path → {generator, generatedAt,
  contentHash}`); generators write entries; re-bootstrap compares on-disk hash to recorded hash and
  refuses to silently overwrite a hand-edited artifact; `ai-sdd plan` adds a `hand-edited` annotation.
  Deterministic (timestamp is an input, hashes content-addressed). Owner: **maintainer**.
- **`drift`** (ADR-0033) — `ai-sdd drift [<dir>]` reporting divergence: stale gate (recompile schema,
  diff vs committed check), fixture↔schema (`SchemaValidator`), convention↔code (re-check Discovery
  Record citations). Advisory/non-blocking; each finding names its remedy; provenance-aware. Owner:
  **maintainer**.

## Milestones

- **`m1-guardrails-integrated`** — **automated**. Gates `drift` until `locks` and `provenance` both land
  and verify together. Validation command: `swift build` + `swift test` + `swift run ai-sdd validate
  .ai-sdd`, plus a smoke check that a locked-artifact edit makes `ai-sdd plan` exit 3 and a hand-edited
  generated artifact renders the `hand-edited` annotation. Owner: **maintainer**. (Manual↔automated swaps
  only the node's worker/checks per docs/milestones.md.)

## Sequencing

- `locks` → `m1-guardrails-integrated`
- `provenance` → `m1-guardrails-integrated`
- `m1-guardrails-integrated` → `drift`

(`locks` and `provenance` are independent — both build only on shipped code — so they run in parallel;
`drift` reuses provenance's annotation and the compile-schema/`SchemaValidator` machinery, so it follows
the milestone.)

## Constraints

- Swift; follow `.ai-sdd/conventions/swift.md`. Engine logic in `AISDDEngine`, CLI in `AISDDCLI`, tests in
  `Tests/AISDDEngineTests` (Swift Testing). Path constants in `Layout.swift`.
- **Reuse the shipped substrate** — `ChangePlan`/`Tier`, `PlanReport`, `ArtifactDiff`, `SpecLoader`,
  `SchemaValidator`, the `ai-sdd-compile-schema` compiler. No second loader/classifier/parser.
- Deterministic engine logic (ADR-0001); the one non-deterministic edge (drift's convention-citation
  check) is scoped to *flagging* via deterministic citation breakage, never LLM-judging.
- Each ADR's Decision section is its feature's contract — don't re-open closed decisions.
- Enforcement stays **commit-gated** via `ai-sdd plan`; any git hook is an optional convenience.

## Decisions (closed — approved 2026-06-22)

| # | Question | Proposed resolution | Status |
|---|---|---|---|
| D1 | Program tier worth it for a single-owner cycle? (O1) | **Keep the program** — the `m1` gate genuinely blocks `drift` until `locks`+`provenance` land *and* verify together; three feature-sized chunks + a gate is the program tier's job. | closed |
| D2 | `locks.yaml` glob syntax (O2) | **Simple path-prefix + `*` globs** scoped under `.ai-sdd/` (e.g. `schemas/*.schema.yaml`, `conventions/operator.md`); full globbing deferred unless a feature slice needs it. | closed |
| D3 | Is drift's convention-citation check in MVP? (O3) | **Ship the two deterministic kinds** (stale-gate, fixture↔schema) in MVP; include the citation check **iff** the `drift` feature plan keeps it thin, else flag a follow-up slice. | closed |
| D4 | Does `m1` also require `ai-sdd drift` readiness? (O4) | **No** — `m1` gates `locks`+`provenance`; `drift` is downstream of it. | closed |
| D5 | `m1` manual or automated? | **Automated** — the validation is a deterministic command set (build/test/validate + the locked-edit & hand-edited smokes); no human judgment needed. | closed |
| D6 | Owners | **All `maintainer`** (nominal, single-owner program). | closed |
| D7 | Lazy vs up-front feature planning | **Up-front** — three features is small; plan `locks`+`provenance`+`drift` now. (Lazy is available but buys little here.) | closed |
