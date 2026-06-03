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
```
