# ai-sdd

Enterprise Spec-Driven Development workflow tooling.

This repository is the Swift implementation for the `ai-sdd` framework. The
current MVP is CLI-first and builds toward a shared `SDDCore` used by sibling CLI
and MCP interfaces.

## MVP Shape

- `SDDModels`: public domain contracts and JSON shapes.
- `SDDCore`: Swift workflow graph, OpenSpec artifact adapter, local telemetry
  sink, and workflow operations.
- `SDDCLI`: `sdd` command with JSON output.
- `SDDMCP`: placeholder package for the future MCP server.

The durable workflow source of truth is OpenSpec:

```text
openspec/changes/<feature_slug>/
```

Local MVP telemetry is written to:

```text
.sdd/telemetry/events.jsonl
```

## Build And Test

```bash
swift test
swift run sdd capabilities --json
swift run sdd validate-workspace --json
```

Useful MVP commands:

```bash
swift run sdd validate-workspace --json
swift run sdd start --feature checkout-flow --json
swift run sdd start --intake-file docs/intake/checkout.md --json
swift run sdd normalize-intake --file docs/intake/checkout.md --json
swift run sdd list-artifacts --feature checkout-flow --json
swift run sdd get-artifact --feature checkout-flow --type openspec_design --json
swift run sdd validate-artifacts --feature checkout-flow --json
swift run sdd next --run-id <run_id> --json
swift run sdd prepare-execution --run-id <run_id> --json
swift run sdd reject-gate --run-id <run_id> --phase plan --reason "Plan needs changes." --json
swift run sdd clear-lock --run-id <run_id> --json
swift run sdd mark-blocked --run-id <run_id> --reason missing_input --message "Waiting for input." --json
swift run sdd retry-action --run-id <run_id> --json
swift run sdd get-run-summary --run-id <run_id> --json
swift run sdd list-run-events --run-id <run_id> --json
```
