# Slice: update-check

**Phase:** m2 (detect + apply) · **Stack:** swift · **Depends on:** m1-distribution (milestone)

## Delivers
`ai-sdd update --check` — the detect half of the loop — plus the stderr update banner shared by all
commands. Cheap, cached, and fail-soft.

- `ai-sdd update --check`: resolve the latest release tag of the **public** repo `215eight/ai-sdd` via
  `releases/latest` (anonymous, no token); compare to the running binary's version (the
  `tag-derived-version` helpers). Behind → emit one notice line; up-to-date → silent.
- **Cache:** persist the last fetch timestamp + resolved latest version to `~/.cache/ai-sdd/last-check`
  (DC3); only hit the network if the cache is older than ~1 day, else read the cached verdict.
- **Fail-soft:** any network/parse/API error → silent, exit success, never blocks a session.
- **Banner:** a shared helper that any `ai-sdd` command calls; if the cached verdict says "behind", it
  prints the one-line notice to **stderr** (never stdout). Wire it into the user-facing commands
  (`status`, `next`, …) so it surfaces during normal use without corrupting `--json` stdout.
- **Drift note (DC5):** if the binary version is **newer** than `.ai-sdd/VERSION`, the check/banner
  emits a soft "repo seeded at X, engine at Y — run /ai-sdd-update to reseed" advisory (never blocks).
- Network access is injected (a `VersionChecker` protocol / closure) so tests don't hit the network.

## Acceptance
- Newer release available → exactly one notice line; none → silent; offline / API error → silent and
  exit 0.
- A second `--check` within the cache window performs **no** network call (verified via the injected
  fetcher in tests).
- `ai-sdd next --json` keeps clean, parseable JSON on stdout while the banner goes to stderr.
- Binary-newer-than-stamp emits the DC5 soft advisory; equal versions emit nothing.
- Tests over the injected fetcher + a temp cache file cover: behind/ahead/equal, cache hit vs miss,
  fetch error → silent, stdout/stderr separation.
- `swift build` / `swift test` green.

## Notes
- Hooks installed by `seed-command` call this exact command; this slice makes that call meaningful.
