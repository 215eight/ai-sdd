# Feature: self-update — agent-driven framework distribution & update

> **APPROVED 2026-06-25 — decisions DC1–DC6 closed (DC2 changed: delete `bootstrap.sh` outright);
> slices generated.**

## Source Brief
[`.ai-sdd/features/self-update/brief.md`](brief.md) — co-authored in this session.

## Goal
Let any teammate's coding agent (Claude Code **or** Codex) keep the ai-sdd framework current without
touching the CLI directly. When a session starts in a bootstrapped repo, the framework detects whether
a newer version exists than the one the repo is seeded at and, **on the teammate's confirmation**,
updates the engine binary and reseeds the repo. This is backed by a prebuilt-binary GitHub release, so
an update is a download — never a Swift source build — and the binary becomes the single self-contained
carrier of the framework (engine + skills + hook sources), so updating the binary inherently delivers
the latest skills with no source clone. Detection is automatic and unobtrusive (cached, fail-soft,
multi-surfaced); application is always explicit; the reseed lands as its own commit.

## In Scope
- **Binary as single source of truth (Option B):** framework skills + the pre-commit integrity hook
  source embedded in the `ai-sdd` binary as resources, readable back out with no clone.
- **`ai-sdd seed`** — reconcile a repo *from the binary*: write skills → `.ai-sdd/skills/` + link
  `.agents/skills` and `.claude/skills`; install the pre-commit integrity hook (+ `.ai-sdd/hooks/`
  source); install **SessionStart hooks for both agents** (`.claude/settings.json` + `.codex/hooks.json`,
  both running `ai-sdd update --check`); write the `.ai-sdd/VERSION` stamp. Binary-native successor to
  `scripts/bootstrap.sh`.
- **`ai-sdd update --check`** — cached (≤ once/day), fail-soft check comparing the running binary's
  version to the latest GitHub release tag of the **public** repo `215eight/ai-sdd` (`releases/latest`,
  anonymous). Silent on no-update / offline / API error.
- **`ai-sdd update`** — resolve latest release, download the macOS universal binary + `.sha256`,
  **verify the checksum (fail closed)**, self-replace the on-PATH binary, re-run `ai-sdd seed`, write
  the new `.ai-sdd/VERSION`. No Swift build.
- **Update banner** — any `ai-sdd` command prints a one-line "update available — run /ai-sdd-update" to
  **stderr** (never stdout) when the cache says the binary is behind.
- **`.ai-sdd/VERSION` stamp** — records the seeded framework version; written by `seed`/`update`.
- **`/ai-sdd-update` skill** — apply-on-confirm wrapper: confirm `vCURRENT → vLATEST`, run `ai-sdd
  update`, commit the reseed as its **own** commit (`chore(ai-sdd): update framework to vX.Y.Z`) — a
  message that does not match the `[<feature>] <slice>:` pattern the integrity hook guards.
- **Tag-derived versioning (source change)** — `main.swift` references a generated symbol
  (`aiSddVersion`) instead of a hardcoded string; the generated `Version.swift` is gitignored and comes
  from `git describe`. Dev builds self-identify so the check skips the nudge.

## Out Of Scope
**Manual-infra companions** (`.github/` + `scripts/` are outside the factory's declarable file scope —
edited by hand alongside the run, not built as slices):
- `.github/workflows/release.yml` (tag-triggered: validate tag format → universal build → checksum →
  publish release; embeds skills into the binary at build time).
- `scripts/gen-version.sh`, `scripts/release.sh`, the `Version.swift` `.gitignore` entry, the
  `install.sh` gen-version hook.

Also out of scope:
- Linux / Windows binaries (macOS universal only).
- macOS code signing / notarization (start **unsigned**; `xattr -d com.apple.quarantine` is the escape
  hatch; revisit only if Gatekeeper bites).
- **Auto-applying** updates without confirmation (detect-at-session-start, apply-on-confirm only).

## Acceptance
- `ai-sdd --version` reports the **tag-derived** version (clean `v0.6.0` tag → `ai-sdd 0.6.0`); a dev
  build reports a describe/`-dev` value and the check does **not** nudge.
- `ai-sdd seed` on a **fresh repo with no source clone** reproduces `bootstrap.sh`'s result (vendored
  skills + `.agents`/`.claude` links + pre-commit hook) **plus** both SessionStart hooks and
  `.ai-sdd/VERSION`.
- `ai-sdd update --check`: newer release → one notice line; none → silent; offline / API error → silent
  and non-blocking; second run within a day uses the cache (no network).
- `ai-sdd update`: downloads the latest asset, **aborts on checksum mismatch**, replaces the on-PATH
  binary, reseeds, writes the new `.ai-sdd/VERSION` — with **no Swift build**.
- The banner is on **stderr** and never corrupts the JSON on `ai-sdd next --json` stdout.
- A bootstrapped repo surfaces the notice via the `.claude` SessionStart hook in Claude Code, and via
  `.codex/hooks.json` in Codex (after the one-time hook-trust prompt).
- `/ai-sdd-update` proceeds **only** on confirmation and lands the reseed as a standalone commit that
  passes the integrity pre-commit hook.
- `swift build`, `swift test`, `swift run ai-sdd validate .ai-sdd` green throughout.

## Constraints
- Engine logic in `AISDDEngine`, CLI in `AISDDCLI`, tests in `Tests/AISDDEngineTests` (Swift Testing),
  path literals centralized in `Layout.swift` — per `.ai-sdd/conventions/swift.md`.
- Public repo `215eight/ai-sdd`; release downloads anonymous (no token).
- Deterministic engine path — version check + update are mechanical (download, verify, copy, reconcile);
  no AI judgment inside the engine. Injectable network/shell so tests don't hit the network.
- Provider-neutral where a cross-tool standard exists (skills → `.agents` + `.claude`); per-tool where
  none (hooks → `.codex` + `.claude`); `seed` writes both, in both formats.

## Decisions (proposed — confirm or change each)
| # | Question | Proposed | Status |
|---|---|---|---|
| DC1 | Feature slug | `self-update`. | closed |
| DC2 | `bootstrap.sh` transition | **Delete `scripts/bootstrap.sh` outright** — its entire job is assumed by the `ai-sdd seed` binary subcommand (Option B). There is **no `seed.sh`** shell wrapper; seeding is a binary command. QUICKSTART/README onboarding changes from `scripts/bootstrap.sh <repo>` to `ai-sdd seed`. (The `bootstrap.sh` **deletion** is on the manual checklist — `scripts/` is outside the factory's file scope; the `ai-sdd seed` command + the doc edits are factory slices.) | closed |
| DC3 | `--check` cache location | `~/.cache/ai-sdd/last-check` — per-user, **uncommitted**, holds the last fetch timestamp + result. Not inside `.ai-sdd/` (avoids per-repo noise + accidental commits). | closed |
| DC4 | First release tag | Tag **`v0.5.0`** now to match the current binary string and give `git describe` a real anchor; ship this feature as **`v0.6.0`**. | closed |
| DC5 | Version-drift behavior | If the binary is **newer** than `.ai-sdd/VERSION` (binary updated, repo not reseeded), `--check`/`status` emit a **soft** warning suggesting `/ai-sdd-update` (reseed) — advisory, never blocks. | closed |
| DC6 | Slicing (two milestone phases, m1 → m2) | **m1 distribution foundation:** `embedded-skills` (skills + hook source as binary resources + accessor) · `tag-derived-version` (main.swift → generated `aiSddVersion`; version helpers) · `seed-command` (`ai-sdd seed` reconciles repo from binary, incl. both SessionStart hooks + `.ai-sdd/VERSION` + the onboarding doc edits; `depends_on` the first two) → **m1-distribution** gate (owner: 215eight). **m2 detect + apply:** `update-check` (`ai-sdd update --check` + stderr banner; `depends_on` m1) · `update-apply` (`ai-sdd update` download/verify/self-replace/reseed; `depends_on` update-check) · `update-skill` (`/ai-sdd-update`, embedded as a framework skill; `depends_on` update-apply) → **m2-detect-apply** gate (owner: 215eight). Each slice is one plan→implement→review cycle. | closed |

---

### Planning gate — APPROVED 2026-06-25
Human approved DC1–DC6 in session, with one change: **DC2 → delete `bootstrap.sh`** (no thin shim).
Slices generated below; manual-infra steps tracked on a separate checklist handed alongside the run.

