#!/usr/bin/env bash
#
# bootstrap.sh — vendor the ai-sdd toolkit INTO an adopting repo (idempotent).
#
# This is the DETERMINISTIC seeding step. It copies fixed artifacts from an ai-sdd
# clone into a target repo so an agent can then run the INTELLIGENT `ai-sdd-bootstrap`
# *skill* (which authors workers/schemas/conventions/gates from the codebase). The two
# are complementary: this script does the file-copying; the skill does the thinking.
#
# It installs three things into the target repo:
#   1. the framework skills      → <target>/.ai-sdd/skills/        (+ .agents / .claude symlinks)
#   2. the integrity hook source → <target>/.ai-sdd/hooks/pre-commit
#   3. the pre-commit hook        → <target>/.git/hooks/pre-commit  (chained, idempotent)
#
# Usage:
#   scripts/bootstrap.sh [TARGET_REPO]          # TARGET: arg, else prompt (default cwd)
#   scripts/bootstrap.sh --aisdd <path> [TARGET]
#
# Re-running is safe and idempotent: it REFRESHES the vendored skills + hook source,
# and only ADDS what's missing for the symlinks and the installed hook (a foreign hook
# is chained exactly once; nothing is duplicated or clobbered).
#
# The ai-sdd home ($AISDD) is auto-derived from this script's location; pass --aisdd
# only if you run a copy of the script from outside the clone.

set -euo pipefail

# ---------------------------------------------------------------------------
# Output helpers (match install.sh)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  BOLD=''; GREEN=''; YELLOW=''; RED=''; DIM=''; RESET=''
fi
step() { printf '\n%s==>%s %s%s%s\n' "$BOLD$GREEN" "$RESET" "$BOLD" "$*" "$RESET"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s warn:%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()  { printf '%s error:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Derive $AISDD (this script's repo root) and parse args
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AISDD="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --aisdd)   AISDD="$(cd "$2" && pwd)"; shift 2 ;;
    --aisdd=*) AISDD="$(cd "${1#*=}" && pwd)"; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    -*)        die "unknown option: $1" ;;
    *)         TARGET="$1"; shift ;;
  esac
done

# The ai-sdd home must look like a real clone (the artifacts we copy from must exist).
{ [ -d "$AISDD/skills" ] && [ -f "$AISDD/hooks/pre-commit" ]; } || \
  die "ai-sdd home '$AISDD' is missing skills/ or hooks/pre-commit — run from the ai-sdd clone, or pass --aisdd <path>."

# Resolve the target repo: arg → interactive prompt → fail.
if [ -z "$TARGET" ]; then
  if [ -t 0 ]; then
    printf 'Target repo to seed [%s]: ' "$PWD"
    read -r TARGET
    [ -n "$TARGET" ] || TARGET="$PWD"
  else
    die "no TARGET given and stdin is not a TTY — pass the target repo path as an argument."
  fi
fi
TARGET="$(cd "$TARGET" 2>/dev/null && pwd)" || die "target repo '$TARGET' is not a directory."

step "Seeding ai-sdd into a repo"
info "ai-sdd home : $AISDD"
info "Target repo : $TARGET"
[ "$TARGET" = "$AISDD" ] && info "(self-hosting: target is the ai-sdd clone itself)"
[ -d "$TARGET/.git" ] || warn "target has no .git — the pre-commit hook install (step 3) will be skipped."

FRAMEWORK_SKILLS="ai-sdd-bootstrap ai-sdd-plan ai-sdd-plan-program ai-sdd-compile-schema ai-sdd-run ai-sdd-cheatsheet"

# ---------------------------------------------------------------------------
# 1. Vendor the framework skills + point the agent skill dirs at the in-repo copy
# ---------------------------------------------------------------------------
step "Vendoring framework skills → .ai-sdd/skills/ (+ agent symlinks)"
mkdir -p "$TARGET/.ai-sdd/skills" "$TARGET/.agents/skills" "$TARGET/.claude/skills"
for s in $FRAMEWORK_SKILLS; do
  if [ ! -d "$AISDD/skills/$s" ]; then
    warn "skill '$s' not found in $AISDD/skills — skipping"
    continue
  fi
  rm -rf "$TARGET/.ai-sdd/skills/$s"                              # clean refresh (drops removed files)
  cp -R "$AISDD/skills/$s" "$TARGET/.ai-sdd/skills/$s"           # vendor INTO the repo (committed)
  ln -sfn "../../.ai-sdd/skills/$s" "$TARGET/.agents/skills/$s"  # Codex   → in-repo (committed)
  ln -sfn "../../.ai-sdd/skills/$s" "$TARGET/.claude/skills/$s"  # Claude  → in-repo (local)
  info "$s"
done

# ---------------------------------------------------------------------------
# 2. Vendor the integrity pre-commit hook SOURCE (committed, reviewable)
# ---------------------------------------------------------------------------
step "Vendoring the pre-commit hook source → .ai-sdd/hooks/pre-commit"
mkdir -p "$TARGET/.ai-sdd/hooks"
cp "$AISDD/hooks/pre-commit" "$TARGET/.ai-sdd/hooks/pre-commit"
chmod +x "$TARGET/.ai-sdd/hooks/pre-commit"
info "→ .ai-sdd/hooks/pre-commit"

# ---------------------------------------------------------------------------
# 3. Install the pre-commit hook into .git/hooks (idempotent + chaining)
# ---------------------------------------------------------------------------
if [ -d "$TARGET/.git" ]; then
  step "Installing the pre-commit hook → .git/hooks/pre-commit"
  HOOK_SRC="$TARGET/.ai-sdd/hooks/pre-commit"
  HOOK_DST="$TARGET/.git/hooks/pre-commit"
  MARKER='ai-sdd:managed-hook'
  mkdir -p "$TARGET/.git/hooks"
  if [ -f "$HOOK_DST" ] && grep -q "$MARKER" "$HOOK_DST"; then
    cp "$HOOK_SRC" "$HOOK_DST"                                    # managed hook present — refresh in place
    info "refreshed the managed hook"
  elif [ -f "$HOOK_DST" ]; then
    if [ ! -e "$TARGET/.git/hooks/.pre-commit.local" ]; then      # preserve a foreign hook by chaining it once
      mv "$HOOK_DST" "$TARGET/.git/hooks/.pre-commit.local"
      info "chained your existing pre-commit → .pre-commit.local"
    fi
    cp "$HOOK_SRC" "$HOOK_DST"
    info "installed the managed hook (chaining your prior hook)"
  else
    cp "$HOOK_SRC" "$HOOK_DST"
    info "installed"
  fi
  chmod +x "$HOOK_DST"
  if [ -e "$TARGET/.git/hooks/.pre-commit.local" ]; then
    chmod +x "$TARGET/.git/hooks/.pre-commit.local"
  fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
step "Done"
info "${GREEN}Seeded${RESET} $TARGET"
info "Commit ${BOLD}.ai-sdd/${RESET} and ${BOLD}.agents/skills/${RESET} so collaborators inherit the toolkit."
info "Next: open the repo and run the ${BOLD}/ai-sdd-bootstrap${RESET} skill to author the factory."
