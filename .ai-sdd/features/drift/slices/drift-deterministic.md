# Slice: drift-deterministic

## Delivers
The `ai-sdd drift` command with the two guaranteed deterministic kinds (Dr1 MVP).

- A read-only `Drift` `ParsableCommand` in `Sources/AISDDCLI/main.swift` (registered in `subcommands:`) + a `Drift` engine type. Reports findings grouped by kind; each finding names its remedy. `--help` documents it.
- **Kind 1 — stale gate:** recompile each schema's checks in-memory (reuse the `ai-sdd-compile-schema` compiler logic) and diff against the committed `checks/*.check.yaml`; a difference is a finding. Remedy: `recompile <schema>`.
- **Kind 2 — fixture↔schema:** validate the repo's known fixtures against current schemas via `SchemaValidator`; a failure is a finding. Remedy: `fix fixture <path>` (Dr3 — fixtures from existing `docs/examples/` + `.ai-sdd`).
- Advisory exit (Dr2): `0` when no findings, `1` when findings exist; **never blocks a run**.
- Provenance-aware: a finding on a `hand-edited` artifact (the `provenance` feature) is annotated.
- Tests against fixtures: a deliberately-stale check is found; a bad fixture is found; a reconciled repo → no findings, exit 0.

## Acceptance
- A stale compiled check vs a recompile is reported (stale-gate, `recompile` remedy).
- A schema-violating fixture is reported (fixture↔schema, `fix fixture` remedy).
- Reconciled repo → no findings, exit 0; with findings → exit 1.
- A finding on a `hand-edited` artifact is annotated.
- `ai-sdd drift --help`; `swift build`, `swift test`, `swift run ai-sdd validate .ai-sdd` green.

## Stack
swift — `Sources/AISDDEngine/Drift.swift`, `Sources/AISDDCLI/main.swift`, reuse compile-schema logic + `SchemaValidator` + `Provenance`; tests in `Tests/AISDDEngineTests/EngineTests.swift`.

## depends_on
(none — first slice; consumes shipped compile-schema/SchemaValidator + the provenance feature's Provenance type)
