# self-update — agent-driven framework distribution & update

## Goal
Let any teammate's coding agent (Claude Code **or** Codex) keep the ai-sdd framework current
without ever touching the CLI directly. When a session starts in a bootstrapped repo, the framework
detects whether a newer version exists than the one the repo is seeded at and, **on the teammate's
confirmation**, updates the engine binary and reseeds the repo's vendored skills/hooks/stamp. This is
backed by a prebuilt-binary GitHub release so an update is a download — never a Swift source build —
and the binary becomes the single self-contained carrier of the framework (engine + skills + hook
sources), so updating the binary inherently delivers the latest skills with no source clone.

Detection is automatic and unobtrusive (cached, fail-soft, multi-surfaced); application is always
explicit (apply-on-confirm), and the reseed lands as its own commit so it never tangles with a
teammate's feature work.

## In scope
- **Binary as single source of truth (Option B):** the framework skills + the pre-commit integrity
  hook source are embedded in the `ai-sdd` binary as resources, so the binary can reconcile a repo
  with no clone present.
- **`ai-sdd seed`** — reconcile everything into a repo *from the binary*: write framework skills →
  `.ai-sdd/skills/` and link `.agents/skills` + `.claude/skills`; install the pre-commit integrity
  hook into `.git/hooks/` (+ `.ai-sdd/hooks/pre-commit` source); install **SessionStart hooks for both
  agents** (see below); write the `.ai-sdd/VERSION` stamp. This is the binary-native successor to
  `scripts/bootstrap.sh`.
- **`ai-sdd update --check`** — cached (re-hits the network at most once/day), fail-soft version check
  that compares the running binary's version to the latest GitHub release tag of the **public** repo
  `215eight/ai-sdd` (`releases/latest`, anonymous, no auth). Silent on no-update / offline / API error.
- **`ai-sdd update`** — resolve the latest release, download the prebuilt macOS universal binary +
  its `.sha256`, **verify the checksum (fail closed)**, self-replace the on-PATH binary
  (`~/.local/bin/ai-sdd`), then re-run `ai-sdd seed`; write the new `.ai-sdd/VERSION`. No Swift build.
- **Update banner** — any `ai-sdd` command prints a one-line "update available — run /ai-sdd-update"
  notice to **stderr** (never stdout) when the cached check says the binary is behind.
- **`.ai-sdd/VERSION` stamp** — records the framework version the repo is seeded at; written by
  `seed`/`update`; read by the check to report drift.
- **SessionStart hooks for BOTH agents, installed by `ai-sdd seed`:**
  - Claude Code → `.claude/settings.json`
  - Codex → `.codex/hooks.json`
  - both run `ai-sdd update --check`; its stdout becomes agent context so the agent surfaces the
    notice at session start (before the teammate types anything).
- **`/ai-sdd-update` skill** — the apply-on-confirm wrapper: confirm `vCURRENT → vLATEST` with the
  teammate, run `ai-sdd update`, then commit the reseed as its **own** commit
  (`chore(ai-sdd): update framework to vX.Y.Z`) — a message that deliberately does not match the
  `[<feature>] <slice>:` pattern the integrity hook guards, so it passes cleanly.
- **Tag-derived versioning** — the binary's version comes from `git describe --tags --always --dirty`
  via a generated, gitignored `Sources/AISDDCLI/Version.swift`; `main.swift` references the generated
  symbol instead of a hardcoded string. A dev build self-identifies (`-dev`/describe value) so the
  check skips the update nudge for contributors.

## Out of scope
These are **manual infra** edits done alongside the run — `.github/` and `scripts/` are outside the
factory's declarable file scope, so they are companions to this feature, not slices the engine builds:
- `.github/workflows/release.yml` — the tag-triggered release pipeline (validate tag format → build
  universal binary → checksum → publish release). Embeds the skills into the binary at build time.
- `scripts/gen-version.sh` (git-describe → Version.swift), `scripts/release.sh` (format-validated tag
  helper), the `.gitignore` entry for `Version.swift`, and the `install.sh` hook to gen-version first.
- Linux / Windows binaries (macOS universal only for now).
- macOS code signing / notarization (start **unsigned**; document `xattr -d com.apple.quarantine` as
  the escape hatch, revisit only if Gatekeeper bites).
- **Auto-applying** updates without confirmation. Detection is automatic; application is always
  confirmed.

## Acceptance
- `ai-sdd --version` reports the **tag-derived** version: on a clean `v0.6.0` tag → `ai-sdd 0.6.0`;
  a dev build reports a describe/`-dev` value and the check does **not** nudge.
- `ai-sdd seed` on a **fresh repo with no source clone present** produces the same result
  `bootstrap.sh` did — vendored skills + `.agents`/`.claude` links + pre-commit hook — **plus** both
  SessionStart hooks and `.ai-sdd/VERSION`.
- `ai-sdd update --check`: a newer release available → exactly one notice line; none → silent; offline
  / API error → silent and non-blocking; a second run within a day uses the cache (no network call).
- `ai-sdd update`: downloads the latest release asset, **aborts on checksum mismatch**, replaces the
  on-PATH binary, reseeds, and writes the new `.ai-sdd/VERSION` — with **no Swift build**.
- The update banner appears on **stderr** and never corrupts the parseable JSON on `ai-sdd next --json`
  stdout.
- A bootstrapped repo opened in **Claude Code** surfaces the notice via the `.claude` SessionStart hook;
  opened in **Codex** surfaces it via `.codex/hooks.json` (after the one-time hook-trust prompt).
- `/ai-sdd-update` proceeds **only** on confirmation and lands the reseed as a standalone commit that
  passes the integrity pre-commit hook.

## Constraints
- Swift package; macOS; engine + CLI live in `Sources/AISDDEngine` / `Sources/AISDDCLI`. Match the
  existing CLI command structure and the house conventions in `.ai-sdd/conventions/`.
- Public repo `215eight/ai-sdd`; release downloads are anonymous (no token).
- Provider-neutral where a cross-tool standard exists (skills → `.agents` + `.claude`); per-tool where
  none exists (hooks → `.codex` + `.claude`). `seed` writes both, in both formats.
- Grounded, deterministic engine path — the version check and update are mechanical (download, verify,
  copy, reconcile); no AI judgment inside the engine.
- The CI pipeline + version-generation pieces are manual; the binary + skill pieces are factory-driven
  and dogfooded through plan → run.

## Milestones (optional)
- **m1 — distribution foundation.** Tag-derived versioning + skills embedded in the binary +
  `ai-sdd seed` reconciling a repo from the binary with no clone. Validates that a prebuilt binary can
  fully seed a repo. (Pairs with the manual `release.yml` + `gen-version.sh`.) Owner: framework advocate.
- **m2 — detect + apply.** `ai-sdd update --check` (cached/fail-soft) + the stderr banner +
  `ai-sdd update` (download/verify/self-replace/reseed) + `.ai-sdd/VERSION` + both-agent SessionStart
  hooks + the `/ai-sdd-update` skill. Validates the end-to-end detect-at-session-start, apply-on-confirm
  loop. Owner: framework advocate.

## Open questions (to close with the user in the requirements draft)
- **Feature slug** — `self-update`? (proposed)
- **bootstrap.sh transition** — introduce `ai-sdd seed` and reduce `bootstrap.sh` to a thin shim that
  shells out to the binary now, fully retiring it later? (proposed) vs. delete it immediately.
- **Check cache location** — `~/.cache/ai-sdd/last-check` (per-user, uncommitted)? (proposed) vs.
  inside `.ai-sdd/`.
- **First release tag** — tag `v0.5.0` to match the current binary string, then ship this feature as
  `v0.6.0`? (proposed)
- **Version-drift behavior** — if the binary is newer than `.ai-sdd/VERSION` (binary updated but repo
  not reseeded), should `--check`/`status` warn and suggest `/ai-sdd-update`? (proposed: yes, a soft
  warning, no block).
