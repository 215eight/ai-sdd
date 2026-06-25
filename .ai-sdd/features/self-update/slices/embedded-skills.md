# Slice: embedded-skills

**Phase:** m1 (distribution foundation) · **Stack:** swift · **Depends on:** —

## Delivers
Make the `ai-sdd` binary the self-contained carrier of the framework (Option B): embed the framework
skills **and** the pre-commit integrity hook source as resources compiled into the binary, plus a typed
accessor that reads them back out at runtime — so the binary can reconcile a repo with **no source
clone present**.

- Declare the framework skill set (`ai-sdd-bootstrap`, `ai-sdd-plan`, `ai-sdd-plan-program`,
  `ai-sdd-compile-schema`, `ai-sdd-run`, `ai-sdd-cheatsheet`, and — added by the `update-skill` slice —
  `ai-sdd-update`) and the `hooks/pre-commit` source as SwiftPM **resources** of the relevant target
  (`Package.swift` `resources:` / a resource bundle).
- An engine accessor (in `AISDDEngine`) exposes each embedded skill's files and the hook source as
  in-memory contents / a materialize-to-dir helper. No filesystem assumptions about a clone.
- Path literals centralized in `Layout.swift` per `.ai-sdd/conventions/swift.md`.

## Acceptance
- The release/build embeds the skills + hook source; a binary run from an arbitrary directory (no
  ai-sdd clone on disk) can enumerate and materialize every framework skill and the hook source via the
  accessor.
- Unit tests (`Tests/AISDDEngineTests`, Swift Testing) assert the accessor returns the expected skill
  ids and non-empty `SKILL.md` + hook contents from the bundled resources (no network, no clone).
- `swift build` / `swift test` green.

## Notes
- This is the prerequisite for `seed-command` and `update` — both materialize from this accessor.
- Keep skills as the source of truth in `skills/` at build time; the resource bundling copies them in.
  (The `update-skill` slice adds `ai-sdd-update` to that set.)
