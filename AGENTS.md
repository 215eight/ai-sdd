# AGENTS.md

This repository is the Swift implementation of `ai-sdd`.

Legacy scaffold files are reference material only. Do not use `ai-specs/`,
`prompts/`, or the legacy planning docs as runtime product behavior unless a
task explicitly asks for a migration or comparison.

Before changing product code, read:

- `docs/enterprise-ai-sdd-requirements.md` - closed requirements and v0 contracts
- `docs/architecture_doc.md` - package and layer rules
- `docs/verification_guide_doc.md` - verification commands

Implementation boundaries:

- `Sources/SDDModels` owns public domain contracts and JSON shapes.
- `Sources/SDDCore` owns workflow operations, the Swift workflow graph,
  OpenSpec artifact persistence, telemetry adapters, and execution adapters.
- `Sources/SDDCLI` owns the Swift Argument Parser command surface.
- `Sources/SDDMCP` is reserved for the future MCP server and must use
  `modelcontextprotocol/swift-sdk` when implemented.

The durable workflow source of truth is OpenSpec. Runtime workflow state must
be derived from `openspec/changes/<feature_slug>/` artifacts and the compact
run summary attached to that OpenSpec change.

The implementation must stay coding-agent agnostic. Codex and Claude Code
behavior belongs only inside execution adapter implementations.
