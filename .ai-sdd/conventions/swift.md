# ai-sdd Swift Conventions

This file is bootstrapped from repo evidence. Items marked as gaps have no clear in-repo exemplar
and should be confirmed before being treated as policy.

## Discovery Record

Evidence is recorded as **typed, machine-readable citation tokens** in the Evidence cell. A parser
collects ONLY backticked tokens whose content begins with a known prefix immediately followed by a
colon:

- `` `path:<repo-relative-path>` `` — a concrete repo-relative path (no globs); drift checks it exists.
- `` `cmd:<command>` `` — a shell command; drift checks it exits 0.

Every other backticked token is convention **vocabulary** (e.g. `@Test`, `#expect`, `swiftlint`,
`env:`) and is ignored, as is all surrounding prose. Commit SHAs and any other evidence stay ordinary
prose — they are not tokenized and not drift-checked. An **open-gap** row carries **no** typed token
(zero `path:`/`cmd:` tokens ⇒ nothing to verify ⇒ drift skips it).

| Change type | Evidence | Convention | Status |
|---|---|---|---|
| Build | `path:Package.swift`; `cmd:swift build` | Use SwiftPM. The baseline build command is `swift build`. | confirmed |
| Test | `path:Tests/AISDDEngineTests/EngineTests.swift` | Use Swift Testing (`@Test`, `#expect`, `#require`). Prefer exact typed errors such as `SpecLoadError` over `any Error`. | confirmed |
| Lint | `docs/examples/minimal/checks/lint.check.yaml` uses `true`; no `swiftlint`/`swift-format` config found | No repo lint command is established. Do not invent one; rely on `swift build` and `swift test` until a lint tool is added. | open gap |
| Run commands | `path:AGENTS.md`; `path:Sources/AISDDCLI/main.swift` | Validate a pipeline with `swift run ai-sdd validate <workspace>`. Drive runs with `start`, `next`, `submit`, `status`; graph with `graph`. | confirmed |
| Module/feature | `path:Package.swift` (commit `60d9f55` through `b759f5b` graph slices) | Add engine behavior under `Sources/AISDDEngine`, CLI surface under `Sources/AISDDCLI`, shared Codable spec types under `Sources/AISDDModels`, and focused tests under `Tests/AISDDEngineTests`. | confirmed |
| Model/entity | `path:Sources/AISDDModels/Spec.swift` (commits `dcba98e`, `b8c8504`) | Put spec-facing Codable data types in `AISDDModels`. Keep runtime behavior in `AISDDEngine`. | confirmed |
| Migration | No database/storage migration directory or migration commit found | No migration convention exists in this repo. If persistence changes, add a plan decision before inventing a migration format. | open gap |
| Test | `path:Tests/AISDDEngineTests/EngineTests.swift` (commit `1e98f16`) | Add tests close to the behavior being changed. Use pure functions and injectable shell execution where possible. | confirmed |
| Endpoint | No HTTP server, route, OpenAPI, or endpoint files found | No endpoint convention exists. Treat endpoint work as out of scope unless architecture changes. | open gap |
| Config/secrets | `path:README.md` mentions env-based secret references; `path:docs/examples/sdlc-plant/resources/github.resource.yaml` uses `env:`/credential handles | Do not commit secrets. Represent secret requirements as environment-backed handles in docs/specs, not literal values. | confirmed |
| Dependency/package | `path:Package.swift`; `path:Package.resolved` | Add Swift dependencies in `Package.swift` and keep resolution in `Package.resolved`. Use package products explicitly in target dependencies. | confirmed |
| Naming/layering | `path:AGENTS.md`; `path:Sources/AISDDEngine/Layout.swift`; `path:Package.swift` target boundaries | Keep path names centralized in `Layout.swift`. Keep design vocabulary in docs and commit messages, not code comments. | confirmed |
| CI/release | No `.github` workflows found; `QUICKSTART.md` references version/release binary; `Sources/AISDDCLI/main.swift` version string | No CI workflow is established. Version bumps must update the CLI version and adopter docs when release behavior changes. | open gap |

## Working Rules

- Read `docs/architecture.md` and `docs/decisions.md` before changing engine behavior.
- Do not alter accepted architecture decisions without maintainer direction.
- Keep topology in pipeline specs; Workers declare typed signatures only.
- Add or update deterministic gates when introducing new artifact schemas.
- Run `swift build`, `swift test`, and `swift run ai-sdd validate .ai-sdd` before submitting factory changes.
