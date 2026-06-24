# Slice: precommit-tripwire (S6 — depends on S3)

## Delivers
Catch the bypass case at the git boundary. `ai-sdd-bootstrap` idempotently installs a POSIX-shell
pre-commit hook that inspects the commit message: if the subject matches `[<feature>] <slice>:`, the
hook checks for a corresponding `nodeCompleted` event for `<slice>` in
`.ai-sdd/runs/<feature>/events/`. No match → refuse the commit with a single-line, copy-pasteable
error: ``slice "<slice>" of feature "<feature>" was not submitted — run `ai-sdd submit <feature>`
first`` (submit auto-starts via S3's resolver if needed). `git commit --no-verify` bypasses, emitting a
one-line stderr warning so the bypass is visible in logs. If `ai-sdd` is not on `$PATH`, the hook
prints a clear "install ai-sdd or use --no-verify" message and exits non-zero. An existing `pre-commit`
hook is chained, not overwritten (rename → `.pre-commit.local`; the new hook runs the integrity check
then delegates).

## Why
Even when the user invokes an agent entirely outside the `/ai-sdd-run` skill, work still reaches git as
a `[feature] slice:` commit. The tripwire is the only mechanism that catches that path — it makes
"forgot to submit" fail loudly instead of silently diverging the ledger from main.

## Acceptance
- A bootstrapped repo has the hook installed; re-running `ai-sdd-bootstrap` is idempotent (no
  duplicate; a chained `.pre-commit.local` is preserved).
- Committing `[<feature>] <slice>: msg` with no `nodeCompleted` event fails with the specified error;
  after `ai-sdd submit` the same commit succeeds.
- `--no-verify` bypasses with a stderr warning; missing `ai-sdd` → clear message, non-zero exit.
- An existing pre-commit hook is chained and still runs.

## Notes
**Scope-gate caveat (D4):** the hook install logic lives in the `ai-sdd-bootstrap` skill (declarable),
but the hook itself lands in `.git/hooks/` at bootstrap runtime — not a committed file the factory
manifest declares. The hook is POSIX shell, no new runtime deps, and calls `ai-sdd` via `$PATH`.
