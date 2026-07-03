# shellcheck disable=SC2148
# claude-switch — per-terminal Claude Code subscription switcher.
# https://github.com/tenkenco/claude-switch
#
# Usage:
#   1. Source this file from your ~/.zshrc:    source /path/to/cs.zsh
#   2. Bootstrap each account once:            claude setup-token | cs save <name>
#   3. Pin a terminal to a profile:            cs use <name>
#   4. Run claude in that terminal:            claude
#
# How it works:
#   `cs use <name>` exports CLAUDE_CODE_OAUTH_TOKEN in this shell only. Claude
#   Code reads the env var first and never touches the macOS Keychain on the
#   auth path, so two terminals with two different `cs use` values stay
#   isolated — no drift, no refresh-clobber, even in multi-hour sessions.
#
#   The `claude` wrapper also patches ~/.claude.json's oauthAccount field from
#   the profile snapshot before launch so /status displays the right email.
#   That patch is cosmetic; auth comes from the env var.
#
# Supported platforms:
#   - macOS (uses pbpaste/pbcopy + BSD stat)
#   - Linux Wayland (wl-paste/wl-copy + GNU stat)
#   - Linux X11    (xclip or xsel + GNU stat)

# Hard-clean stale function definitions so re-sourcing this file actually
# replaces them (zsh keeps old function bodies otherwise). Intentionally do
# not clear _CS_PROFILE here: preserving the active profile across re-source
# keeps reporting/wrapper behavior aligned with the exported auth token.
unfunction claude 2>/dev/null

#==============================================================================
# Platform detection (runs once at source time, not per-call).
#==============================================================================

# Clipboard. Preferred order: macOS native, Wayland, X11 (xclip), X11 (xsel).
# Empty values mean "no clipboard tool available" — the pipe path
# (`claude setup-token | cs save x`) still works without any clipboard tool.
typeset -g _CS_PASTE_CMD="" _CS_COPY_CMD=""
if command -v pbpaste >/dev/null 2>&1 && command -v pbcopy >/dev/null 2>&1; then
  _CS_PASTE_CMD="pbpaste"
  _CS_COPY_CMD="pbcopy"
elif command -v wl-paste >/dev/null 2>&1 && command -v wl-copy >/dev/null 2>&1; then
  _CS_PASTE_CMD="wl-paste -n"
  _CS_COPY_CMD="wl-copy"
elif command -v xclip >/dev/null 2>&1; then
  _CS_PASTE_CMD="xclip -selection clipboard -o"
  _CS_COPY_CMD="xclip -selection clipboard -i"
elif command -v xsel >/dev/null 2>&1; then
  _CS_PASTE_CMD="xsel --clipboard --output"
  _CS_COPY_CMD="xsel --clipboard --input"
fi

#==============================================================================
# Helpers (shared across subcommands).
#==============================================================================

# Name validation. Allow [A-Za-z0-9._-] but reject leading '.' / '-' and reject
# any '/' or '..' sequence. Prevents `cs rm ../foo` from escaping accounts/.
_cs_validate_name() {
  local n="$1"
  [[ -n "$n" ]] || return 1
  [[ "$n" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || return 1
  [[ "$n" == *..* ]] && return 1
  return 0
}

# Numeric file mode (e.g., "600"). BSD stat on macOS, GNU stat on Linux.
_cs_stat_mode() {
  local m
  m="$(stat -c '%a' "$1" 2>/dev/null)" && [[ -n "$m" ]] && {
    print -- "$m"
    return 0
  }
  m="$(stat -f '%Lp' "$1" 2>/dev/null)" && [[ -n "$m" ]] && {
    print -- "$m"
    return 0
  }
  return 1
}

_cs_have_clipboard() { [[ -n "$_CS_PASTE_CMD" ]]; }
_cs_paste() { eval "$_CS_PASTE_CMD"; }
_cs_copy() { eval "$_CS_COPY_CMD"; }

# Read the oauthAccount JSON object from ~/.claude.json. Echoes the JSON or
# nothing if the file or the key is missing. Errors handled by caller.
_cs_oauth_account_json() {
  local cfg="$HOME/.claude.json"
  [[ -f "$cfg" ]] || return 1
  jq -c '.oauthAccount // empty' "$cfg" 2>/dev/null
}

# Acquire a token via the highest-priority available source. Side effects:
#   _CS_TOKEN        — the token (raw, caller is responsible for trimming)
#   _CS_TOKEN_SOURCE — one of: flag, stdin, clipboard
# Returns 0 on success, 1 on failure.
#
# Implementation note: this MUST set globals rather than echo on stdout,
# because callers would need command-substitution to capture stdout, and
# command-substitution runs in a subshell where the source-tracking var
# would be lost on exit.
#
# Args: $1=explicit_token  $2=use_clipboard(0|1)  $3=use_stdin(0|1)
#       $4=cur_email (for prompt)  $5=cur_tier (for prompt)  $6=name (for prompt)
_cs_read_token() {
  local explicit_token="$1" use_clipboard="$2" use_stdin="$3"
  local cur_email="$4" cur_tier="$5" name="$6"
  _CS_TOKEN=""
  _CS_TOKEN_SOURCE=""
  if [[ -n "$explicit_token" ]]; then
    _CS_TOKEN="$explicit_token"
    _CS_TOKEN_SOURCE="flag"
    return 0
  fi
  if ((use_clipboard)); then
    if ! _cs_have_clipboard; then
      echo "cs: --clipboard requested but no clipboard tool found (pbpaste / wl-paste / xclip / xsel)" >&2
      return 1
    fi
    _CS_TOKEN="$(_cs_paste)"
    _CS_TOKEN_SOURCE="clipboard"
    return 0
  fi
  if ((use_stdin)) || [[ ! -t 0 ]]; then
    _CS_TOKEN="$(cat)"
    _CS_TOKEN_SOURCE="stdin"
    return 0
  fi
  # Interactive fallback: clipboard prompt if available, else error.
  if _cs_have_clipboard; then
    echo "Saving profile '$name' for $cur_email ($cur_tier)." >&2
    echo "Step 1: in another terminal, run:  claude setup-token" >&2
    echo "Step 2: copy the token to your clipboard." >&2
    printf "Press Enter when copied (or Ctrl-C to abort)... " >&2
    local ans
    read -r ans
    _CS_TOKEN="$(_cs_paste)"
    _CS_TOKEN_SOURCE="clipboard"
    return 0
  fi
  echo "cs: no input method available — pipe via stdin or install a clipboard tool" >&2
  return 1
}

#==============================================================================
# Subcommand implementations.
#==============================================================================

_cs_save() {
  local dir="$HOME/.claude/accounts"
  local user_cfg="$HOME/.claude.json"
  mkdir -p "$dir"
  chmod 700 "$dir"

  local name="" force=0 explicit_token="" use_clipboard=0 use_stdin=0 allow_mismatch=0
  while (($#)); do
    case "$1" in
    --force) force=1 ;;
    --allow-mismatch) allow_mismatch=1 ;;
    --token)
      if (($# < 2)) || [[ -z "${2:-}" ]]; then
        echo "cs save: --token requires a value" >&2
        return 1
      fi
      explicit_token="$2"
      shift
      ;;
    --clipboard) use_clipboard=1 ;;
    --stdin) use_stdin=1 ;;
    -*)
      echo "cs save: unknown flag '$1'" >&2
      return 1
      ;;
    *)
      if [[ -z "$name" ]]; then
        name="$1"
      else
        echo "cs save: too many args" >&2
        return 1
      fi
      ;;
    esac
    shift
  done
  [[ -z "$name" ]] && {
    echo "cs save <name> [--force] [--token <tok> | --clipboard | --stdin]" >&2
    return 1
  }
  _cs_validate_name "$name" || {
    echo "cs: invalid profile name '$name' (allowed: alnum, '.', '_', '-'; no leading '.' or '-'; no '..')" >&2
    return 1
  }
  if [[ -n "$explicit_token" ]]; then
    echo "cs: warning — '--token' on the command line gets recorded in shell history." >&2
    echo "    Prefer:  claude setup-token | cs save $name" >&2
  fi

  local tok_file="$dir/$name.token" acct_file="$dir/$name.account.json"
  if [[ (-e "$tok_file" || -e "$acct_file") && $force -eq 0 ]]; then
    echo "cs: profile '$name' exists. Pass --force." >&2
    return 1
  fi

  [[ -f "$user_cfg" ]] || {
    echo "cs: $user_cfg missing — open Claude Code at least once" >&2
    return 1
  }
  local acct
  acct="$(_cs_oauth_account_json)" || true
  [[ -z "$acct" ]] && {
    echo "cs: $user_cfg has no .oauthAccount — log into Claude Code first" >&2
    return 1
  }
  local cur_email cur_tier
  cur_email="$(echo "$acct" | jq -r '.emailAddress // "?"')"
  cur_tier="$(echo "$acct" | jq -r '.organizationRateLimitTier // "?"')"

  _cs_read_token "$explicit_token" "$use_clipboard" "$use_stdin" "$cur_email" "$cur_tier" "$name" || return 1
  local token
  token="$(printf '%s' "$_CS_TOKEN" | tr -d '[:space:]')"
  # Don't keep the raw token sitting in a global after we have a local copy.
  unset _CS_TOKEN
  [[ -z "$token" ]] && {
    echo "cs: empty token — aborted." >&2
    return 1
  }
  if [[ "$token" != sk-ant-oat* ]]; then
    echo "cs: pasted value doesn't look like a Claude setup-token (expected prefix 'sk-ant-oat')." >&2
    echo "    Refusing to save. If you're certain, retry with the right input source." >&2
    return 1
  fi

  # Verify the token against the API before trusting it. Two failure modes
  # this catches: (a) a dead token, (b) an identity mismatch — a setup-token
  # belongs to the BROWSER session that approved the OAuth URL, while the
  # snapshot comes from the CLI's login, and nothing else ever cross-checks
  # the two. Compare the token's real org (response header) to the snapshot's.
  local snap_org
  snap_org="$(echo "$acct" | jq -r '.organizationUuid // empty')"
  if command -v curl >/dev/null 2>&1; then
    _cs_check_token "$token"
    case $? in
    1)
      echo "cs: this token is not usable (${_CS_CHECK_STATUS}) — refusing to save." >&2
      echo "    Re-mint with: claude setup-token" >&2
      return 1
      ;;
    2)
      echo "cs: warning — could not verify the token (${_CS_CHECK_STATUS}); saving unverified." >&2
      echo "    Run 'cs doctor' once you're back online." >&2
      ;;
    0)
      if [[ -n "$snap_org" && -n "$_CS_CHECK_ORG" && "$_CS_CHECK_ORG" != "$snap_org" ]]; then
        if ((allow_mismatch)); then
          echo "cs: warning — token account differs from the CLI login being snapshotted" >&2
          echo "    ($cur_email). Saving anyway (--allow-mismatch): auth will use the" >&2
          echo "    token's account, but /status will display $cur_email." >&2
        else
          echo "cs: identity mismatch — refusing to save '$name'." >&2
          echo "    The token authenticates as org $_CS_CHECK_ORG, but the account" >&2
          echo "    snapshot would be taken from the CLI's current login:" >&2
          echo "      $cur_email (org $snap_org)" >&2
          echo "    This happens when the setup-token OAuth URL was approved in a browser" >&2
          echo "    logged into a different account than the CLI." >&2
          echo "    Fix:      /login the CLI as the token's account, then re-run:" >&2
          echo "              claude setup-token | cs save $name --force" >&2
          echo "    Override: add --allow-mismatch to save anyway (auth will be correct;" >&2
          echo "              /status will display the wrong identity)." >&2
          return 1
        fi
      fi
      ;;
    esac
  else
    echo "cs: warning — curl not found; saving without token verification." >&2
  fi

  # Write profile material with mode 600. Subshell so umask doesn't leak.
  (
    umask 077
    printf '%s' "$token" >"$tok_file"
    printf '%s\n' "$acct" >"$acct_file"
  )
  chmod 600 "$tok_file" "$acct_file" 2>/dev/null

  # Clear the clipboard if that's where the token came from.
  if [[ "$_CS_TOKEN_SOURCE" == "clipboard" ]] && _cs_have_clipboard; then
    printf '' | _cs_copy 2>/dev/null
  fi

  echo "cs: saved profile '$name' (email: $cur_email, tier: $cur_tier)"
}

_cs_use() {
  local dir="$HOME/.claude/accounts"
  local name="${1:-}"
  [[ -z "$name" ]] && {
    echo "cs use <name>" >&2
    return 1
  }
  _cs_validate_name "$name" || {
    echo "cs: invalid profile name '$name'" >&2
    return 1
  }

  local tok_file="$dir/$name.token" acct_file="$dir/$name.account.json"
  [[ -f "$tok_file" ]] || {
    echo "cs: profile '$name' missing token ($tok_file). Run: cs save $name" >&2
    return 1
  }
  [[ -f "$acct_file" ]] || {
    echo "cs: profile '$name' missing account snapshot ($acct_file). Run: cs save $name --force" >&2
    return 1
  }

  local token
  token="$(cat "$tok_file")"
  export CLAUDE_CODE_OAUTH_TOKEN="$token"
  _CS_PROFILE="$name"
  local email
  email="$(jq -r '.emailAddress // "?"' "$acct_file" 2>/dev/null)"
  echo "cs: this shell pinned to '$name' ($email). Run 'claude' to launch."
}

_cs_off() {
  unset CLAUDE_CODE_OAUTH_TOKEN _CS_PROFILE
  _cs_restore_keychain_account
  echo "cs: this shell unpinned (env-var cleared)."
}

_cs_list() {
  local dir="$HOME/.claude/accounts"
  setopt local_options null_glob
  local found=0 f name marker email tier suffix
  for f in "$dir"/*.token; do
    found=1
    name="${f:t:r}"
    marker="  "
    [[ "$name" == "$_CS_PROFILE" ]] && marker="* "
    suffix=""
    if [[ -f "$dir/$name.account.json" ]]; then
      email="$(jq -r '.emailAddress // "?"' "$dir/$name.account.json" 2>/dev/null)"
      tier="$(jq -r '.organizationRateLimitTier // "?"' "$dir/$name.account.json" 2>/dev/null)"
      suffix=" — $email ($tier)"
    else
      suffix=" — incomplete (re-run: cs save $name --force)"
    fi
    echo "${marker}${name}${suffix}"
  done
  ((found)) || echo "(no profiles — run: cs save <name>)"
}

# Validate a single token against the Anthropic API, bypassing the keychain.
# This is the only reliable expiry check: newer Claude Code silently falls back
# to the keychain on a 401 ("OAuth 401 recovery"), so launching `claude` can
# appear to "work" even when the pinned token is dead. A direct API call sees
# the raw 200/401 with no fallback.
#
# Sets globals rather than echoing (command-substitution would run in a
# subshell and lose the org, same constraint as _cs_read_token):
#   _CS_CHECK_STATUS — human-readable status word
#   _CS_CHECK_ORG    — anthropic-organization-id response header. This is the
#                      account the token REALLY belongs to: a setup-token is
#                      bound to the browser session that approved the OAuth
#                      URL, which need not match the CLI's login.
# Returns 0 if usable, 1 if expired/invalid, 2 if indeterminate.
_cs_check_token() {
  local tok="$1" code hdrs
  _CS_CHECK_STATUS=""
  _CS_CHECK_ORG=""
  hdrs="$(mktemp)"
  code="$(curl -sS -o /dev/null -D "$hdrs" -w '%{http_code}' --max-time 20 \
    https://api.anthropic.com/v1/messages \
    -H "authorization: Bearer $tok" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' 2>/dev/null)"
  _CS_CHECK_ORG="$(tr -d '\r' <"$hdrs" 2>/dev/null |
    awk -F': ' 'tolower($1)=="anthropic-organization-id"{print $2; exit}')"
  rm -f "$hdrs"
  case "$code" in
  200)
    _CS_CHECK_STATUS="OK"
    return 0
    ;;
  401 | 403)
    _CS_CHECK_STATUS="EXPIRED ($code)"
    return 1
    ;;
  000 | "")
    _CS_CHECK_STATUS="UNREACHABLE (no network/curl)"
    return 2
    ;;
  429)
    _CS_CHECK_STATUS="OK but RATE-LIMITED (429)"
    return 0
    ;;
  *)
    _CS_CHECK_STATUS="UNKNOWN (HTTP $code)"
    return 2
    ;;
  esac
}

# Validate every saved profile's token against the API. Surfaces the silent
# keychain-fallback masking: tells you which profiles need `cs save --force`.
_cs_doctor() {
  local dir="$HOME/.claude/accounts"
  if ! command -v curl >/dev/null 2>&1; then
    echo "cs: doctor needs curl to validate tokens." >&2
    return 1
  fi
  setopt local_options null_glob
  local found=0 f name email snap_org rc bad=0 mismatch=0 tok marker note
  for f in "$dir"/*.token; do
    found=1
    name="${f:t:r}"
    marker="  "
    [[ "$name" == "$_CS_PROFILE" ]] && marker="* "
    email="?"
    snap_org=""
    if [[ -f "$dir/$name.account.json" ]]; then
      email="$(jq -r '.emailAddress // "?"' "$dir/$name.account.json" 2>/dev/null)"
      snap_org="$(jq -r '.organizationUuid // empty' "$dir/$name.account.json" 2>/dev/null)"
    fi
    tok="$(cat "$f" 2>/dev/null)"
    _cs_check_token "$tok"
    rc=$?
    ((rc == 1)) && bad=1
    note=""
    if ((rc == 0)) && [[ -n "$snap_org" && -n "$_CS_CHECK_ORG" && "$snap_org" != "$_CS_CHECK_ORG" ]]; then
      mismatch=1
      note=" — ORG MISMATCH (token belongs to a different account than the snapshot)"
    fi
    echo "${marker}${name} — ${email}: ${_CS_CHECK_STATUS}${note}"
  done
  ((found)) || {
    echo "(no profiles — run: cs save <name>)"
    return 0
  }
  if ((bad)); then
    echo "" >&2
    echo "cs: one or more tokens are expired. Re-mint with:" >&2
    echo "    claude setup-token | cs save <name> --force" >&2
    echo "Note: an expired token does NOT error at launch — Claude Code silently" >&2
    echo "falls back to your keychain account, so the wrong account runs quietly." >&2
    return 1
  fi
  if ((mismatch)); then
    echo "" >&2
    echo "cs: one or more profiles have an identity mismatch: the token authenticates" >&2
    echo "as a different account than the saved snapshot, so /status will display the" >&2
    echo "wrong email. Fix: /login the CLI as the token's account, then re-run:" >&2
    echo "    claude setup-token | cs save <name> --force" >&2
    return 1
  fi
  return 0
}

_cs_current() {
  if [[ -n "$_CS_PROFILE" ]]; then
    echo "$_CS_PROFILE"
    return 0
  fi
  if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    echo "(token set, profile unknown — re-run: cs use <name>)"
    return 0
  fi
  echo "(none — claude will use the keychain default)"
}

_cs_rm() {
  local dir="$HOME/.claude/accounts"
  local name="${1:-}"
  [[ -z "$name" ]] && {
    echo "cs rm <name>" >&2
    return 1
  }
  _cs_validate_name "$name" || {
    echo "cs: invalid profile name '$name'" >&2
    return 1
  }

  local tok_file="$dir/$name.token" acct_file="$dir/$name.account.json"
  [[ -f "$tok_file" || -f "$acct_file" ]] || {
    echo "cs: no such profile: $name" >&2
    return 1
  }
  printf "delete profile '%s'? [y/N] " "$name"
  local ans
  read -r ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || {
    echo "aborted."
    return 0
  }
  rm -f "$tok_file" "$acct_file"
  if [[ "$_CS_PROFILE" == "$name" ]]; then
    unset CLAUDE_CODE_OAUTH_TOKEN _CS_PROFILE
  fi
  echo "cs: removed '$name'."
}

_cs_help() {
  cat <<'EOF'
cs — per-terminal Claude Code subscription switcher.

Usage:
  cs save <name> [--force] [--allow-mismatch]
                             Bootstrap a profile (paste setup-token + snapshot account).
                             Verifies the token is live AND belongs to the same account
                             as the CLI login being snapshotted; refuses on mismatch
                             unless --allow-mismatch.
  cs use <name>              Export CLAUDE_CODE_OAUTH_TOKEN for THIS shell only.
  cs off                     Unset the env var; subsequent `claude` uses keychain default.
  cs list                    List profiles; * marks the one pinned in this shell.
  cs doctor                  Validate each saved token against the API (OK / EXPIRED /
                             ORG MISMATCH when a token belongs to a different account
                             than its snapshot).
  cs current                 Print the pin for this shell.
  cs rm <name>               Delete a saved profile.

Bootstrap (once per account):
  In Claude Code, /login to account A.
  Easiest:   claude setup-token | cs save personal
  Or copy/paste:
             claude setup-token   (copy the printed token to clipboard)
             cs save personal     (reads from clipboard automatically)
  /logout, /login to account B, repeat with `cs save work`.

How it works:
  - cs use <name> sets CLAUDE_CODE_OAUTH_TOKEN in your shell. Claude Code reads
    the env var first and never touches the macOS Keychain on the auth path.
    Two terminals with two different `cs use` are truly isolated — no drift,
    no refresh-clobber, even in multi-hour sessions.
  - The `claude` wrapper additionally patches ~/.claude.json's oauthAccount
    field from the profile snapshot before launch, so /status displays the
    right email. This is cosmetic; auth is the env var. Unpinned launches and
    `cs off` restore the keychain account's identity so a plain `claude`
    doesn't keep displaying the last pinned profile.

Caveats:
  - A setup-token belongs to the BROWSER session that approved the OAuth URL,
    while the account snapshot comes from the CLI's /login. `cs save` verifies
    the two match (via the token's anthropic-organization-id) and refuses on
    mismatch. Easiest way to stay consistent: /login the CLI to the account
    first, then run `claude setup-token | cs save <name>`.
  - Setup-tokens are CI-tier auth. They authenticate fine for inference but
    Claude Code may default to a non-Max model and show fewer MCPs / no
    identity in /status. Use `/model opus` per session if needed.
  - GUI clients (desktop app, IDE extensions) don't read shell env vars; they
    use the keychain. CLI-only feature.
  - Two terminals launching `claude` at the literal same instant could race
    on the ~/.claude.json patch (cosmetic display only, not auth).
  - Re-run `cs save <name> --force` if a token eventually expires. Newer Claude
    Code silently falls back to your keychain account on an expired token (no
    error), so the wrong account can run quietly. Run `cs doctor` to catch it.
EOF
}

#==============================================================================
# Public dispatcher.
#==============================================================================

cs() {
  local subcmd="${1:-help}"
  (($# > 0)) && shift
  case "$subcmd" in
  save) _cs_save "$@" ;;
  use) _cs_use "$@" ;;
  off) _cs_off "$@" ;;
  list | ls) _cs_list "$@" ;;
  doctor | check) _cs_doctor "$@" ;;
  current) _cs_current "$@" ;;
  rm) _cs_rm "$@" ;;
  help | -h | --help | "") _cs_help ;;
  *)
    echo "cs: unknown subcommand '$subcmd' (try: cs help)" >&2
    return 1
    ;;
  esac
}

#==============================================================================
# `claude` wrapper. Patches ~/.claude.json oauthAccount from the pinned
# profile's snapshot so /status displays the correct email; auth is the env
# var that `cs use` already exported.
#==============================================================================

_cs_profile_account_file() {
  local profile="$1"
  printf '%s' "$HOME/.claude/accounts/$profile.account.json"
}

# State files for undoing the cosmetic patch:
#   .keychain.account.json — last oauthAccount known to come from a real
#                            /login (the keychain identity), not from cs.
#   .cs-last-patch.json    — exact oauthAccount JSON cs last wrote, so we can
#                            tell "still our stale patch" from "user re-logged
#                            in since" and never clobber a real login.
_cs_keychain_stash_file() { printf '%s' "$HOME/.claude/accounts/.keychain.account.json"; }
_cs_last_patch_file() { printf '%s' "$HOME/.claude/accounts/.cs-last-patch.json"; }

_cs_profile_email() {
  local af="$1"
  if ! command -v jq >/dev/null 2>&1; then
    echo "?"
    return 0
  fi
  local email
  email="$(jq -r '.emailAddress // "?"' "$af" 2>/dev/null)"
  [[ -n "$email" ]] && echo "$email" || echo "?"
}

_cs_patch_oauth_account_for_profile() {
  local profile="$1"
  local af cfg tmp mode
  af="$(_cs_profile_account_file "$profile")"
  cfg="$HOME/.claude.json"

  if [[ -L "$cfg" ]]; then
    echo "cs: warning — ~/.claude.json is a symlink; skipping oauthAccount patch (auth still uses env var)" >&2
    return 0
  fi
  [[ -f "$af" && -f "$cfg" ]] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "cs: warning — jq is required to patch ~/.claude.json (auth still uses env var)" >&2
    return 0
  fi

  # If the current oauthAccount is not something cs wrote, it came from a
  # real /login — stash it so unpinned launches can restore the true display.
  local cur last
  cur="$(jq -c '.oauthAccount // empty' "$cfg" 2>/dev/null)"
  last="$(cat "$(_cs_last_patch_file)" 2>/dev/null)"
  if [[ -n "$cur" && "$cur" != "$last" ]]; then
    (
      umask 077
      printf '%s\n' "$cur" >"$(_cs_keychain_stash_file)"
    )
  fi

  tmp="$(mktemp)"
  if jq --slurpfile a "$af" '.oauthAccount = $a[0]' "$cfg" >"$tmp"; then
    mode="$(_cs_stat_mode "$cfg")"
    [[ -n "$mode" ]] && chmod "$mode" "$tmp"
    mv "$tmp" "$cfg"
    (
      umask 077
      jq -c '.oauthAccount // empty' "$cfg" 2>/dev/null >"$(_cs_last_patch_file)"
    )
    return 0
  fi
  rm -f "$tmp"
  echo "cs: warning — failed to patch ~/.claude.json oauthAccount (auth still uses env var)" >&2
  return 0
}

# Undo a stale cosmetic patch. If ~/.claude.json still shows exactly what cs
# last wrote, an unpinned launch would otherwise display the pinned profile's
# identity while actually authenticating as the keychain account. Restore the
# stashed keychain identity. If the user has /login'd since (oauthAccount no
# longer matches our last patch), leave everything alone.
_cs_restore_keychain_account() {
  local cfg="$HOME/.claude.json" stash last cur tmp mode
  stash="$(_cs_keychain_stash_file)"
  [[ -f "$stash" && -f "$cfg" && ! -L "$cfg" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  last="$(cat "$(_cs_last_patch_file)" 2>/dev/null)"
  [[ -n "$last" ]] || return 0
  cur="$(jq -c '.oauthAccount // empty' "$cfg" 2>/dev/null)"
  [[ "$cur" == "$last" ]] || return 0
  tmp="$(mktemp)"
  if jq --slurpfile a "$stash" '.oauthAccount = $a[0]' "$cfg" >"$tmp" 2>/dev/null; then
    mode="$(_cs_stat_mode "$cfg")"
    [[ -n "$mode" ]] && chmod "$mode" "$tmp"
    mv "$tmp" "$cfg"
    rm -f "$(_cs_last_patch_file)"
  else
    rm -f "$tmp"
  fi
  return 0
}

claude() {
  [[ -n "$_CS_PROFILE" ]] || {
    _cs_restore_keychain_account
    command claude "$@"
    return
  }
  if ! _cs_validate_name "$_CS_PROFILE"; then
    echo "cs: refusing to launch — _CS_PROFILE='$_CS_PROFILE' is not a valid profile name" >&2
    return 1
  fi
  _cs_patch_oauth_account_for_profile "$_CS_PROFILE"
  local af email
  af="$(_cs_profile_account_file "$_CS_PROFILE")"
  email="$(_cs_profile_email "$af")"
  echo "cs: launching claude as '$_CS_PROFILE' ($email)" >&2
  command claude "$@"
}
