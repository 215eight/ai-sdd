#!/usr/bin/env bash
#
# release.sh — create + push a format-validated release tag.
#
# The tag is the single source of truth for the binary version (scripts/gen-version.sh derives
# --version from `git describe`, which equals the tag on a clean tagged commit). Pushing the tag
# triggers .github/workflows/release.yml, which builds the macOS universal binary and publishes
# the `ai-sdd-macos-universal.tar.gz` asset that `ai-sdd update` downloads.
#
# Usage:
#   scripts/release.sh vMAJOR.MINOR.PATCH      # e.g. scripts/release.sh v0.6.0
#
# Enforces the canonical tag format locally so a malformed tag never reaches the repo. (The
# workflow re-validates as a backstop, since GitHub can't run a server-side pre-receive hook.)

set -euo pipefail

VER="${1:-}"
SEMVER='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

if [[ ! "$VER" =~ $SEMVER ]]; then
  echo "usage: scripts/release.sh vMAJOR.MINOR.PATCH   (e.g. v0.6.0)" >&2
  echo "  got: '${VER:-<empty>}' — must be vMAJOR.MINOR.PATCH: lowercase 'v', no leading zeros." >&2
  exit 1
fi

# The tag must capture a committed state — refuse to tag a dirty tree.
if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is dirty — commit or stash before tagging $VER." >&2
  exit 1
fi

if git rev-parse "$VER" >/dev/null 2>&1; then
  echo "error: tag $VER already exists." >&2
  exit 1
fi

git tag -a "$VER" -m "release $VER"
git push origin "$VER"
echo "pushed $VER — the release workflow will build + publish ai-sdd-macos-universal.tar.gz."
