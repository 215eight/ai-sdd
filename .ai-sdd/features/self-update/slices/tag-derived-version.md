# Slice: tag-derived-version

**Phase:** m1 (distribution foundation) · **Stack:** swift · **Depends on:** —

## Delivers
Make the binary's reported version **tag-derived** instead of a hardcoded string, so the tag is the
single source of truth and can never drift from `--version`.

- The entry file references a generated symbol (`AISDDVersion.current`) rather than the literal
  `"ai-sdd 0.5.0"` (currently the `version:` arg of `CommandConfiguration`, ~`main.swift:13`).
- **Rename the entry file** `Sources/AISDDCLI/main.swift` → a non-special name (e.g. `CLI.swift`):
  a file literally named `main.swift` forces top-level-code mode, which Swift forbids alongside the
  target's `@main` once a second file (`Version.swift`) exists. The build fails
  (`'main' attribute cannot be used in a module that contains top-level code`) until this rename lands,
  so it is part of this slice and must land **together** with introducing `Version.swift`.
- The generated file `Sources/AISDDCLI/Version.swift` is **gitignored** (a build product) and emits a
  **namespaced** symbol — `enum AISDDVersion { static let current = "<ver>" }` (a bare top-level `let`
  would re-trigger the `@main` conflict). A dev build with no tag yields a `git describe`/`-dev` value;
  a clean tagged build yields the bare semver. `scripts/gen-version.sh` already emits this exact form.
- Version read/compare helpers in `AISDDEngine` (parse `vX.Y.Z`, detect a `-dev`/non-release value,
  semver-compare two versions) — reused by `update-check`, `seed` (`.ai-sdd/VERSION`), and drift (DC5).

## Acceptance
- `ai-sdd --version` reflects the generated `AISDDVersion.current`: a clean `v0.6.0` build → `ai-sdd 0.6.0`;
  a dev build → a describe/`-dev` value flagged as non-release by the helper.
- Version helpers have unit tests: `0.6.0` > `0.5.0`; a `-dev` value is recognized as "skip the update
  nudge"; malformed input fails closed (treated as unknown, no crash).
- `swift build` / `swift test` green.

## Notes
- The **generator** (`scripts/gen-version.sh`, via `git describe`) and the `.gitignore` entry are
  **manual-infra companions** (`scripts/` is outside the factory's file scope) — they must exist so the
  factory's own `swift build` finds `Version.swift`. This slice owns only the Swift-source contract
  (the `aiSddVersion` reference + the helpers); the architect should assume `Version.swift` is provided
  by the generator and may commit a `0.0.0-dev` placeholder strategy only if needed to keep the build
  green during the run.
