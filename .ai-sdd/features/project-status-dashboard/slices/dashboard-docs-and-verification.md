# Slice: Dashboard Docs And Verification

Document and verify the dashboard workflow.

## Brief

Update adopter-facing docs and add end-to-end verification around the dashboard command. This slice
confirms the feature works as a user workflow after the engine and CLI pieces land.

## Acceptance

- `QUICKSTART.md` documents:
  - `ai-sdd graph .ai-sdd --project --dashboard --out <file>`;
  - the local-run-state limitation;
  - that plant/team-live dashboards are out of scope for now.
- Tests or scripted verification generate a dashboard for a small fixture or the repo factory.
- `swift build` passes.
- `swift test` passes.
- `swift run ai-sdd validate .ai-sdd/features/project-status-dashboard` passes.

## Stack

swift

## Depends On

- dashboard-cli-integration
