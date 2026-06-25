# Slice: update-apply

**Phase:** m2 (detect + apply) · **Stack:** swift · **Depends on:** update-check

## Delivers
`ai-sdd update` — the apply half — a no-source-build update: download the prebuilt binary, verify it,
self-replace, and reseed.

`ai-sdd update` performs:
1. Resolve the latest release + its asset URLs (the macOS universal tarball + `.sha256`) from
   `releases/latest` (reusing `update-check`'s resolver).
2. Download the tarball + checksum to a temp dir; **verify the sha256 — abort (fail closed) on
   mismatch**, leaving the current binary untouched.
3. Self-replace the on-PATH binary (`~/.local/bin/ai-sdd`): unpack, then atomically move into place
   (download/verify to temp → `mv`), safe to do while the current process runs (replaces the file, not
   the running image).
4. Re-run `ai-sdd seed` (from the new binary's perspective) to refresh skills/hooks and write the new
   `.ai-sdd/VERSION`.
5. Print a concise summary (`vCURRENT → vLATEST`, reseeded) to stderr; exit non-zero with a clear
   message on any failure.

## Acceptance
- With a newer release: downloads the asset, replaces the on-PATH binary, reseeds, and writes the new
  `.ai-sdd/VERSION` — **no Swift build invoked**.
- **Checksum mismatch → aborts**, the existing binary and `.ai-sdd/VERSION` are unchanged, exit non-zero
  with an explicit error.
- Already up-to-date → no-op with a clear message.
- Download/extract/replace use injected network + filesystem seams so tests exercise success,
  checksum-mismatch, and download-failure paths over fixtures (no real network, no real `~/.local/bin`).
- `swift build` / `swift test` green.

## Notes
- PATH/rc are **not** touched (that was first-install only); update only swaps the binary file.
- `/ai-sdd-update` (next slice) wraps this with confirmation + the standalone reseed commit.
