# AI-SDD Verification Guide

## Baseline Verification

Run after product code changes:

```bash
swift test
```

## CLI Smoke Verification

Run after CLI or workflow-operation changes:

```bash
swift run sdd capabilities --json
swift run sdd validate-workspace --json
swift run sdd validate-secrets --json
swift run sdd normalize-intake --file <intake_file> --json
swift run sdd start --intake-file <intake_file> --json
swift run sdd start --feature smoke-run --owner agent-session --actor-type agent --json
swift run sdd list-artifacts --feature smoke-run --json
swift run sdd validate-artifacts --feature smoke-run --json
swift run sdd next --run-id <run_id> --json
swift run sdd prepare-execution --run-id <run_id> --json
swift run sdd reject-gate --run-id <run_id> --phase plan --reason "Plan needs changes." --json
swift run sdd clear-lock --run-id <run_id> --json
swift run sdd mark-blocked --run-id <run_id> --reason missing_input --message "Waiting for input." --json
swift run sdd retry-action --run-id <run_id> --json
swift run sdd status --run-id <run_id> --json
swift run sdd get-run-summary --run-id <run_id> --json
swift run sdd list-run-events --run-id <run_id> --json
```

Use a temporary workspace for smoke checks that create OpenSpec artifacts.

## Risk Tiers

Low-risk changes:

- Model additions that do not change existing JSON fields.
- Documentation updates.

Verification: `swift test`.

Medium-risk changes:

- Workflow graph transition changes.
- OpenSpec artifact path changes.
- CLI command shape changes.

Verification: `swift test` plus CLI smoke verification.

High-risk changes:

- Public model field renames.
- Run summary persistence changes.
- Telemetry redaction or sink behavior changes.
- Execution adapter behavior changes.

Verification: `swift test`, CLI smoke verification, and focused tests for the
changed contract.
