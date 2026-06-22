# Slice: classifier

## Delivers

The keystone: a deterministic `ChangePlan` engine type that takes a list of changed artifacts (from
`diff-source`) and classifies each by blast-radius tier, grounded in the loaded spec graph — no model, no
content heuristics.

- `ChangePlan` in `Sources/AISDDEngine` (per decision D5 — engine type, no new `AISDDModels` spec type).
- Tier mapping by path role:
  - `schemas/*.schema.yaml` → **contract**
  - `conventions/*`, `skills/*` → **refresh**
  - `workers/*`, `pipeline.yaml`, `checks/*` → **local**
  - other non-runtime `.ai-sdd/` paths → **local**, labeled `unclassified`
- **Consumer resolution for the `contract` tier:** load the pipeline + workers via the existing
  `SpecLoader` (reuse the `validate` load path — no second loader) and, for a changed schema, list every
  worker whose `consumes` includes that schema, as `(node id, worker name)`. That list is the blast radius.
- **Deleted schema with consumers (D2):** tier **contract**, and additionally flag a **breaking removal**
  (the listed consumers now reference a missing schema).
- **Added schema with 0 consumers (D3):** tier **contract**, blast radius "0 consumers (new)", carrying a
  flag that it is **not** ack-blocking (nothing depends on it yet).
- Result is an ordered, inspectable value: per-change `{ path, status, tier, consumers[], flags[] }`, plus
  a helper that reports the highest tier present (so the CLI can decide the exit code).
- The classifier takes the changed-artifact list as input (injected), so it is fully unit-testable against
  a fixture factory dir with synthetic schemas/workers — no git needed.

## Acceptance

- A changed `schemas/<x>.schema.yaml` → **contract**, with every worker that `consumes` `<x>` listed
  (fixture with ≥2 consumers).
- A changed `conventions/<stack>.md` → **refresh**; a changed `workers/<x>.worker.yaml` → **local**.
- A deleted consumed schema → **contract** + breaking-removal flag.
- An added schema with no consumers → **contract**, blast radius "0 consumers (new)", non-ack-blocking flag.
- Consumer resolution reuses `SpecLoader` (no duplicate parsing).
- The highest-tier helper returns `contract` when any contract change is present, else the max of the rest.
- `swift build` + `swift test` green.

## Stack

swift — `Sources/AISDDEngine`, tests in `Tests/AISDDEngineTests` (Swift Testing, typed errors).

## depends_on

diff-source
