# Slice: embed-resources-inline

**Phase:** m2 (detect + apply) · **Stack:** swift · **Depends on:** update-skill
**Forward correction of:** embedded-skills (completed/immutable — corrected here, not rewritten)

## Why
The m2 live round-trip exposed a distribution-breaking bug. `embedded-skills` used SwiftPM `.copy`
resources on the `AISDDEngine` library target, which produces a **separate `ai-sdd_AISDDEngine.bundle`
directory** next to the binary, resolved at runtime via `Bundle.module`. The release tarball ships only
the `ai-sdd` binary, so a **relocated/downloaded lone binary crashes** on any embedded-resource access:

```
AISDDEngine/resource_bundle_accessor.swift: Fatal error: unable to find bundle named ai-sdd_AISDDEngine
```

`ai-sdd seed` and `ai-sdd update`'s reseed both crash for every real adopter (download a release → no
clone, no `.build`, no bundle). Option B ("the binary carries the framework") was never actually
achieved. m1 passed only because it ran a locally-built binary with the bundle co-located; the
relocated case was never tested.

## Delivers
Make the framework resources (the 7 skills + the `hooks/pre-commit` source) **truly part of the
compiled binary**, so a single relocated `ai-sdd` binary — with no `.build`, no sibling bundle, no
clone — can `seed`/`update` successfully.

- Replace the `.copy`-resources-into-a-bundle mechanism with **genuine in-binary embedding**. The
  architect chooses the mechanism against the real toolchain (Swift 6.3.1); **strongly prefer an
  in-package approach that needs no sibling bundle** — e.g. SwiftPM's `.embedInCode` resource rule (bytes
  compiled into the target) or a build-tool plugin that generates a Swift source of the contents. A
  manual `scripts/` generator (sibling to `gen-version.sh`) is the **last-resort fallback** — `scripts/`
  is outside the factory's file scope, so flag it as a manual-infra dependency if the mechanism requires
  it (do not author it inside this slice).
- `EmbeddedFramework` reads from the compiled-in bytes instead of `Bundle.module`. Its public API
  (`skillIds()`, per-skill `SKILL.md`, hook source, `materialize(to:)`) is unchanged so `Seeder` and the
  update path keep working.
- **Remove `Sources/AISDDEngine/Resources/` entirely** — the real-copy duplicates of `skills/` +
  `hooks/pre-commit` and their sync-obligation caveat go away (the embedding reads repo-root directly).
- Drop the `.copy` resource declarations + any now-unused bundle literals from `Package.swift` /
  `Layout.swift` so the `AISDDEngine` target no longer produces a resource bundle.

## Acceptance
- **Relocation test (the check that was missing):** build the binary, copy **only** the `ai-sdd`
  executable to an isolated directory that has no `.build`, no `ai-sdd_AISDDEngine.bundle`, and no ai-sdd
  clone; from there, `ai-sdd seed <tmp-repo>` **succeeds** and materializes all 7 skills + the hook (no
  `Bundle.module` fatal error). A Swift Testing case asserts `EmbeddedFramework` returns all 7 skill ids
  + non-empty `SKILL.md` + hook contents with no filesystem bundle present.
- `EmbeddedFramework`'s public API is unchanged; `Seeder` and `ai-sdd update`'s reseed are unaffected at
  the call sites.
- No `ai-sdd_AISDDEngine.bundle` is produced for the `AISDDEngine` target (verify the release/​build bin
  dir has no such bundle), and `Sources/AISDDEngine/Resources/` no longer exists.
- `swift build`, `swift test`, `swift run ai-sdd validate .ai-sdd` green.

## Notes
- This is the fix the m2 milestone re-validates: m2-detect-apply now `depends_on` this slice.
- If the chosen mechanism needs a build-time generator wired into `install.sh`/`release.yml` (manual
  infra), call it out clearly in the changeset caveats so it's added to the manual checklist (as
  `gen-version.sh` was).
- The broken `v0.6.0`/`v0.6.1` releases are superseded once this ships; release.yml's main-guard
  hardening remains a separate manual step.
