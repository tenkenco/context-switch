#!/usr/bin/env bash
# context-switch installer — adds a `source` line to your ~/.zshrc.
# Idempotent: running it twice is a no-op.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_LINE="source \"$REPO_DIR/cs.zsh\""
RC_FILE="${ZDOTDIR:-$HOME}/.zshrc"

if [[ ! -f "$RC_FILE" ]]; then
  echo "context-switch: $RC_FILE doesn't exist. Create it and re-run." >&2
  exit 1
fi

# Hard requirements.
if ! command -v jq >/dev/null 2>&1; then
  echo "context-switch: 'jq' is required but not found in PATH." >&2
  case "$(uname -s)" in
  Darwin) echo "  Install via:  brew install jq" >&2 ;;
  Linux) echo "  Install via:  apt install jq    (or: dnf / pacman / etc.)" >&2 ;;
  esac
  exit 1
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "context-switch: 'claude' (Claude Code CLI) is required but not found." >&2
  echo "  Install via:  https://claude.com/claude-code" >&2
  exit 1
fi

# Only an ACTIVE source line counts. Matching the whole file would treat a
# commented-out line — including the one a user disabled on purpose — as an
# existing install, so `install.sh` would report success and change nothing.
if grep -v '^[[:space:]]*#' "$RC_FILE" | grep -Fq "$SOURCE_LINE"; then
  echo "context-switch: already installed in $RC_FILE — nothing to do."
  exit 0
fi

{
  printf '\n# context-switch (per-terminal identity switcher for Claude Code and other CLIs)\n'
  printf '%s\n' "$SOURCE_LINE"
} >>"$RC_FILE"

echo "context-switch: installed."
echo "  Open a new terminal (or run: source $RC_FILE) and try:  cs help"
