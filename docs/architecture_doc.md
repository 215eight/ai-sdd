# AI-SDD Architecture

## Source Of Truth

`docs/enterprise-ai-sdd-requirements.md` is the closed requirements and contract
document for the current implementation.

OpenSpec is the durable workflow source of truth. The MVP stores feature-scoped
artifacts under:

```text
openspec/changes/<feature_slug>/
```

The compact run summary is attached to the OpenSpec change at:

```text
openspec/changes/<feature_slug>/run-summary.json
```

`.sdd/telemetry/events.jsonl` is the MVP telemetry sink. It is an event log,
not workflow state.

## Package Boundaries

### SDDModels

`Sources/SDDModels` owns canonical public domain models, enum names, JSON field
shape, version metadata, artifact references, workflow statuses, action kinds,
identity attribution, telemetry events, and token attribution.

`SDDModels` must not import CLI, MCP, OpenSpec, telemetry backend, shell, or
process-execution dependencies.

### SDDCore

`Sources/SDDCore` owns workflow operations, the native Swift workflow graph,
OpenSpec artifact persistence, telemetry adapter boundaries, secret-resolution
boundaries, workspace validation, and coding-agent execution adapter contracts.

`SDDCore` reads durable workflow context from OpenSpec artifacts and the compact
OpenSpec run summary. It must not require a second workflow-state database for
the MVP.

### SDDCLI

`Sources/SDDCLI` owns the `sdd` executable and Swift Argument Parser command
surface. CLI commands call `SDDCore`; they do not implement workflow transition
rules.

CLI output for agent-facing commands must support structured JSON.

### SDDMCP

`Sources/SDDMCP` is reserved for the future MCP server. The MVP may keep this
target as a placeholder. When implemented, it must call `SDDCore` directly and
use `modelcontextprotocol/swift-sdk`.

## Workflow Rules

Coding agents must ask the workflow for the next action, execute exactly that
action, submit the result, and repeat until the run is completed, blocked, or
failed.

Workflow transition rules live in `SDDCore`. Codex-specific and Claude-specific
behavior belongs only in execution adapters.

## File Placement

Use these locations:

```text
Package.swift
Sources/SDDModels/
Sources/SDDCore/
Sources/SDDCLI/
Sources/SDDMCP/
Tests/SDDCoreTests/
docs/
openspec/
```

Do not add new `tasks_for_AI` runtime artifacts.

## Naming

Use `SDD` as the package and type prefix for product-facing symbols where a
generic name would be ambiguous. Keep public enum raw values aligned with the
requirements document.
