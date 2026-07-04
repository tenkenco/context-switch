#!/usr/bin/env bash
# claude-switch installer — adds a `source` line to your ~/.zshrc.
# Idempotent: running it twice is a no-op.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_LINE="source \"$REPO_DIR/cs.zsh\""
RC_FILE="${ZDOTDIR:-$HOME}/.zshrc"

if [[ ! -f "$RC_FILE" ]]; then
  echo "claude-switch: $RC_FILE doesn't exist. Create it and re-run." >&2
  exit 1
fi

# Hard requirements.
if ! command -v jq >/dev/null 2>&1; then
  echo "claude-switch: 'jq' is required but not found in PATH." >&2
  case "$(uname -s)" in
  Darwin) echo "  Install via:  brew install jq" >&2 ;;
  Linux) echo "  Install via:  apt install jq    (or: dnf / pacman / etc.)" >&2 ;;
  esac
  exit 1
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "claude-switch: 'claude' (Claude Code CLI) is required but not found." >&2
  echo "  Install via:  https://claude.com/claude-code" >&2
  exit 1
fi

if grep -Fq "$SOURCE_LINE" "$RC_FILE"; then
  echo "claude-switch: already installed in $RC_FILE — nothing to do."
  exit 0
fi

{
  printf '\n# claude-switch (per-terminal Claude Code subscription switcher)\n'
  printf '%s\n' "$SOURCE_LINE"
} >>"$RC_FILE"

echo "claude-switch: installed."
echo "  Open a new terminal (or run: source $RC_FILE) and try:  cs help"
