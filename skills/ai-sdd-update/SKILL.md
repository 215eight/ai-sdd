---
name: ai-sdd-update
description: Update the ai-sdd framework binary + skills to the latest release — an apply-on-confirm wrapper that runs `ai-sdd update --check`, surfaces the current-to-latest version transition, and (only on explicit confirmation) runs `ai-sdd update` and lands a standalone reseed commit. Agent-agnostic (claude-code or codex). Use when a teammate wants to update / upgrade ai-sdd, sees the update-available notice, or invokes `/ai-sdd-update`.
---

# Updating the ai-sdd framework

This skill is the **apply-on-confirm** wrapper a teammate invokes to update the ai-sdd framework —
the `ai-sdd` binary **and** the framework skills it seeds. The engine mechanics (network fetch,
checksum, binary self-replace, reseed) live behind `ai-sdd update`; this skill's job is to **gate the
apply on an explicit human OK** and land the reseed as a clean, standalone commit.

**Never auto-apply.** You run `ai-sdd update` **only** after the teammate explicitly confirms. No
confirmation, no apply — full stop.

**Agent-agnostic:** works the same under Claude Code or Codex — no host-specific assumptions. Run the
commands over the shell from the repo root; prefer the on-PATH `ai-sdd`, fall back to `.build/debug/ai-sdd`
when it is not resolvable.

## The contract (four steps)

### 1. Check — `ai-sdd update --check`

From the repo root:

```sh
ai-sdd update --check               # preferred — the installed, on-PATH binary
.build/debug/ai-sdd update --check  # fallback — when ai-sdd is not on PATH
```

Read the result and **show the teammate the version transition** plainly — the current version to the
latest available (e.g. "vCURRENT → vLATEST"). If the check reports **up to date** (no newer release),
say so, make **no changes**, and **stop** — there is nothing to apply.

### 2. Confirm — proceed ONLY on an explicit yes

When a newer release exists, **ask the teammate to confirm** before changing anything. Proceed to the
apply **only** on an explicit confirmation.

- On an explicit **decline** (or anything short of a clear yes): make **no changes** and stop.
- On **up-to-date** (from step 1): already stopped — nothing to confirm.

This is the apply-on-confirm rule, and it is unmistakable: you **never** run `ai-sdd update` without
the teammate's explicit go-ahead.

### 3. Apply — `ai-sdd update`

On confirmation, run the apply:

```sh
ai-sdd update               # preferred — the installed, on-PATH binary
.build/debug/ai-sdd update  # fallback — when ai-sdd is not on PATH
```

This self-replaces the binary and reseeds the framework skills into the repo. The reseed leaves
changes in the working tree to be committed in the next step.

### 4. Commit the reseed — its OWN standalone commit

Land the reseed as **exactly one standalone commit**, with the literal message:

```
chore(ai-sdd): update framework to vX.Y.Z
```

Substitute the resolved latest version for `vX.Y.Z` (the version you applied in step 3). This
conventional-commit form is **deliberately** chosen: it does **not** match the `[<feature>] <slice>:`
pattern the integrity pre-commit hook guards, so the reseed passes the hook cleanly and stays a
self-contained commit. **Never fold the reseed into a teammate's in-flight feature commit** — keep it
separate so framework updates never tangle with feature work.

```sh
git add -A
git commit -m "chore(ai-sdd): update framework to vX.Y.Z"   # substitute the resolved version
```

## After applying

Tell the teammate they're done — **no hard restart is needed**. The **next** command invocation /
skill invocation picks up the new binary and the freshly-seeded skills automatically.
