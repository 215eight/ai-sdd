---
name: implement-feature
description: Implement an ai-sdd feature plan and record the acceptance ids covered by the changes.
---

# Implement an ai-sdd feature

Read `.ai-sdd/artifacts/feature-plan.v1.yaml` and `.ai-sdd/conventions/swift.md` first. Stay inside
the plan's `files` scope unless the plan is revised.

Use the repo's existing Swift package structure:

- `Sources/AISDDModels` for Codable spec-facing data.
- `Sources/AISDDEngine` for deterministic engine behavior.
- `Sources/AISDDCLI` for command-line surface.
- `Tests/AISDDEngineTests` for Swift Testing coverage.

Run the commands listed in the plan's `tests` field. At minimum, run `swift build`, `swift test`,
and `swift run ai-sdd validate .ai-sdd` when the factory surface changes.

Write `.ai-sdd/artifacts/changeset.v1.yaml` with:

- `summary`: what changed.
- `satisfies`: the acceptance item ids addressed by the implementation.

The deterministic gates run after submit and will reject missing artifacts, failed build/test,
or files outside the planned scope.
