#!/usr/bin/env bash
#
# install.sh — build the `ai-sdd` engine from source and put it on your PATH.
#
# For new adopters on macOS. After cloning this repo, `cd` into it and run:
#
#     ./scripts/install.sh
#
# It will:
#   1. report the shell + bash you're running (so it edits the right rc file)
#   2. ensure Swift is available (via the Xcode Command Line Tools), installing it if missing
#   3. compile the release `ai-sdd` binary
#   4. create ~/.local/bin if needed and copy the binary there
#   5. add ~/.local/bin to your PATH in your shell's rc file (idempotent)
#
# Re-running is safe: every step is idempotent.
#
# This installs only the ENGINE BINARY. To vendor the ai-sdd toolkit (framework
# skills + the integrity pre-commit hook) INTO a repo you want to adopt, use
# `scripts/bootstrap.sh <target-repo>` — a separate, per-repo, idempotent seeder.

set -euo pipefail

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  BOLD=''; GREEN=''; YELLOW=''; RED=''; DIM=''; RESET=''
fi

step()  { printf '\n%s==>%s %s%s%s\n' "$BOLD$GREEN" "$RESET" "$BOLD" "$*" "$RESET"; }
info()  { printf '    %s\n' "$*"; }
warn()  { printf '%s warn:%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()   { printf '%s error:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Locate the repo root (this script lives in <repo>/scripts/)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

[ -f "$REPO_ROOT/Package.swift" ] || die "Package.swift not found in $REPO_ROOT — run this from a clone of the ai-sdd repo."

INSTALL_DIR="$HOME/.local/bin"
BIN_NAME="ai-sdd"

# ---------------------------------------------------------------------------
# 0. macOS only (for now)
# ---------------------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "This installer currently supports macOS only (detected $(uname -s))."

# ---------------------------------------------------------------------------
# 1. Report the shell / bash in use — this decides which rc file we edit later
# ---------------------------------------------------------------------------
step "Checking your shell"
LOGIN_SHELL_PATH="${SHELL:-}"
LOGIN_SHELL_NAME="$(basename "${LOGIN_SHELL_PATH:-unknown}")"
info "Login shell : ${LOGIN_SHELL_PATH:-unknown}  (${LOGIN_SHELL_NAME})"
info "Running bash: ${BASH_VERSION:-unknown}"

# Pick the rc file to edit for the PATH update, based on the login shell.
case "$LOGIN_SHELL_NAME" in
  zsh)  RC_FILE="$HOME/.zshrc" ;;
  bash) RC_FILE="$HOME/.bash_profile" ;;          # macOS login shells read .bash_profile
  *)    RC_FILE="$HOME/.profile"
        warn "Unrecognized shell '$LOGIN_SHELL_NAME' — will use ~/.profile for the PATH update." ;;
esac
info "PATH update will target: $RC_FILE"

# ---------------------------------------------------------------------------
# 2. Ensure Swift is available (via the Xcode Command Line Tools)
# ---------------------------------------------------------------------------
step "Checking for Swift / Xcode Command Line Tools"
if xcode-select -p >/dev/null 2>&1 && command -v swift >/dev/null 2>&1; then
  info "Found: $(swift --version 2>&1 | head -n1)"
else
  warn "Swift toolchain not found — installing the Xcode Command Line Tools."
  info "A macOS dialog will open. Click 'Install' and accept the license, then re-run this script."
  # This triggers the GUI installer; it returns immediately and cannot be fully scripted.
  xcode-select --install 2>/dev/null || true
  die "Waiting on the Command Line Tools install. Re-run ./scripts/install.sh once it finishes."
fi

# ---------------------------------------------------------------------------
# 3. Compile the release binary
# ---------------------------------------------------------------------------
step "Compiling $BIN_NAME (release)"
info "Stamping version from git (git describe → Version.swift)"
"$SCRIPT_DIR/gen-version.sh"
info "swift build -c release  (first build downloads dependencies — this can take a few minutes)"
swift build -c release

BUILT_BIN="$(swift build -c release --show-bin-path)/$BIN_NAME"
[ -x "$BUILT_BIN" ] || die "Build reported success but $BUILT_BIN is missing."
info "Built: $BUILT_BIN"

# ---------------------------------------------------------------------------
# 4. Create ~/.local/bin and copy the binary in
# ---------------------------------------------------------------------------
step "Installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp -f "$BUILT_BIN" "$INSTALL_DIR/$BIN_NAME"
chmod +x "$INSTALL_DIR/$BIN_NAME"
info "Copied → $INSTALL_DIR/$BIN_NAME"
info "Version: $("$INSTALL_DIR/$BIN_NAME" --version 2>&1 | head -n1)"

# ---------------------------------------------------------------------------
# 5. Ensure ~/.local/bin is on PATH (idempotent rc-file edit)
# ---------------------------------------------------------------------------
step "Ensuring $INSTALL_DIR is on your PATH"
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
MARKER='# added by ai-sdd install.sh'

if printf '%s' ":$PATH:" | grep -q ":$INSTALL_DIR:"; then
  info "$INSTALL_DIR is already on PATH in this session."
fi

if [ -f "$RC_FILE" ] && grep -qF "$MARKER" "$RC_FILE"; then
  info "PATH entry already present in $RC_FILE — nothing to add."
else
  {
    printf '\n%s\n' "$MARKER"
    printf '%s\n' "$PATH_LINE"
  } >> "$RC_FILE"
  info "Added PATH entry to $RC_FILE"
  NEEDS_RELOAD=1
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
step "Done"
if command -v "$BIN_NAME" >/dev/null 2>&1; then
  info "${GREEN}ai-sdd is on your PATH.${RESET} Try: ${BOLD}ai-sdd cheatsheet${RESET}"
else
  info "Installed, but ai-sdd isn't resolvable in this shell yet."
fi
if [ "${NEEDS_RELOAD:-0}" = "1" ]; then
  printf '\n%sOpen a new terminal, or run:%s  source %s\n' "$YELLOW" "$RESET" "$RC_FILE"
fi
printf '%sThen verify from any directory:%s  ai-sdd --version\n' "$DIM" "$RESET"
