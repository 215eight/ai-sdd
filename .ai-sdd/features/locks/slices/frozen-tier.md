# Slice: frozen-tier

## Delivers
The `frozen` tier in the classifier, plus lock-manifest loading and promotion.

- Add `frozen` as the top case of `Tier` (above `contract`) in `ChangePlan.swift`, preserving the `Comparable` order `refresh < local < contract < frozen`.
- Load `.ai-sdd/locks.yaml` — a list of `{ glob, reason }` entries; globs are path-prefix + `*` scoped under `.ai-sdd/` (L2: absent file ⇒ no locks, not an error). Path constant in `Layout.swift`.
- After base-tier classification, **promote** any change whose path matches a lock glob to `frozen`, attaching a `locked` flag carrying the matched glob's `reason`.
- Pure/injectable: classification takes the change list + factory dir; lock matching is unit-testable against a fixture `locks.yaml`.

## Acceptance
- `frozen` sorts above `contract`.
- A change matching a `locks.yaml` glob is classified `frozen` with a `locked` flag + reason.
- A non-matching change keeps its base tier.
- Absent `locks.yaml` ⇒ no promotion, no error (L2).
- `swift build` + `swift test` green.

## Stack
swift — `Sources/AISDDEngine/ChangePlan.swift`, `Layout.swift`, tests in `Tests/AISDDEngineTests/EngineTests.swift`.

## depends_on
(none — first slice)
