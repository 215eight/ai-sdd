# Slice: cli-locks

## Delivers
The user-facing freeze behavior in `ai-sdd plan`.

- `PlanReport`: render a `frozen` change as a hard ✗ with its lock `reason` (in the existing grouped output, above `contract`).
- `ai-sdd plan` exits **`3`** when any change is `frozen`, **independent of `--require-ack`** (a frozen change cannot be waved through by lowering the threshold). Exit `3` is distinct from validate's `1` and ack's `2`.
- `--unlock <path>` (repeatable `@Option`): downgrade a matching `frozen` change to its base tier for this invocation only (the lock file is untouched). L3: `--unlock` of a non-frozen/unmatched path is a no-op with a warning, not an error.
- Tests via the pure `PlanReport`/exit-decision path (no `ParsableCommand` driving): frozen → exit 3; frozen + `--require-ack contract` → still 3; `--unlock` downgrades to base tier then exits per threshold; non-frozen unaffected.

## Acceptance
- A locked-path change → ✗ rendered with reason, `ai-sdd plan` exits `3`.
- `--require-ack <any>` does not lower a frozen change below exit 3.
- `--unlock <path>` downgrades that change; exit follows the normal threshold afterward.
- `ai-sdd plan --help` documents `--unlock`.
- `swift build`, `swift test`, `swift run ai-sdd validate .ai-sdd` green.

## Stack
swift — `Sources/AISDDEngine/PlanReport.swift`, `Sources/AISDDCLI/main.swift`, tests in `Tests/AISDDEngineTests/EngineTests.swift`.

## depends_on
frozen-tier
