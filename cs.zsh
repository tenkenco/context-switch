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
#   `cs use <name>` exports a per-profile CLAUDE_CONFIG_DIR in this shell only.
#   Claude Code stores full login state inside that profile-specific config
#   namespace, so two terminals with two different `cs use` values stay
#   isolated. Legacy setup-token profiles still work as a fallback.
#
#   The `claude` wrapper also patches the active profile config's oauthAccount
#   field from the profile snapshot before launch so /status displays the
#   right email.
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

# Per-profile config root. Claude Code honors CLAUDE_CONFIG_DIR for both the
# visible ~/.claude.json equivalent and the full claude.ai auth namespace.
_cs_profile_config_dir() {
  local profile="$1"
  printf '%s' "$HOME/.claude/profiles/$profile"
}

_cs_profile_login_marker() {
  local profile="$1"
  printf '%s' "$(_cs_profile_config_dir "$profile")/.cs-full-login"
}

_cs_config_file() {
  if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
    printf '%s' "$CLAUDE_CONFIG_DIR/.claude.json"
  else
    printf '%s' "$HOME/.claude.json"
  fi
}

_cs_profile_has_full_login() {
  local profile="$1" cfg marker
  cfg="$(_cs_profile_config_dir "$profile")/.claude.json"
  marker="$(_cs_profile_login_marker "$profile")"
  [[ -f "$marker" && -f "$cfg" ]] || return 1
  jq -e '.oauthAccount.emailAddress? // empty' "$cfg" >/dev/null 2>&1
}

# Read the oauthAccount JSON object from the active Claude config. Echoes JSON or
# nothing if the file or the key is missing. Errors handled by caller.
_cs_oauth_account_json() {
  local cfg
  cfg="$(_cs_config_file)"
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
  local user_cfg
  user_cfg="$(_cs_config_file)"
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
    echo "cs save <name> [--force] [--allow-mismatch] [--token <tok> | --clipboard | --stdin]" >&2
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
  local cur_email cur_tier snap_org
  IFS=$'\t' read -r cur_email cur_tier snap_org <<<"$(printf '%s' "$acct" |
    jq -r '[.emailAddress // "?", .organizationRateLimitTier // "?", .organizationUuid // ""] | @tsv')"

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
      if [[ -z "$snap_org" || -z "$_CS_CHECK_ORG" ]]; then
        if ((allow_mismatch)); then
          echo "cs: warning — could not verify token/account identity; saving anyway (--allow-mismatch)." >&2
          echo "    Token status: ${_CS_CHECK_STATUS}; snapshot org: ${snap_org:-unknown}; token org: ${_CS_CHECK_ORG:-unknown}." >&2
        else
          echo "cs: could not verify token/account identity — refusing to save '$name'." >&2
          echo "    Token status: ${_CS_CHECK_STATUS}; snapshot org: ${snap_org:-unknown}; token org: ${_CS_CHECK_ORG:-unknown}." >&2
          echo "    Re-run after the API returns an organization id, or add --allow-mismatch" >&2
          echo "    to save anyway (auth may be correct; /status may display the wrong identity)." >&2
          return 1
        fi
      elif [[ "$_CS_CHECK_ORG" != "$snap_org" ]]; then
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

  local tok_file="$dir/$name.token" acct_file="$dir/$name.account.json" cfg_dir
  cfg_dir="$(_cs_profile_config_dir "$name")"
  if [[ ! -f "$tok_file" && ! -d "$cfg_dir" ]]; then
    echo "cs: profile '$name' is not set up. Run: cs login $name" >&2
    return 1
  fi

  export _CS_PROFILE="$name"
  export CLAUDE_CONFIG_DIR="$cfg_dir"
  mkdir -p "$CLAUDE_CONFIG_DIR"

  local email source token
  email="?"
  [[ -f "$acct_file" ]] && email="$(jq -r '.emailAddress // "?"' "$acct_file" 2>/dev/null)"
  if _cs_profile_has_full_login "$name"; then
    unset CLAUDE_CODE_OAUTH_TOKEN
    source="isolated claude.ai login"
    email="$(jq -r '.oauthAccount.emailAddress // "?"' "$CLAUDE_CONFIG_DIR/.claude.json" 2>/dev/null)"
  elif [[ -f "$tok_file" ]]; then
    token="$(<"$tok_file")"
    export CLAUDE_CODE_OAUTH_TOKEN="$token"
    source="setup-token fallback"
  else
    unset CLAUDE_CODE_OAUTH_TOKEN
    source="empty isolated config"
  fi
  echo "cs: this shell pinned to '$name' ($email, $source). Run 'claude' to launch."
}

_cs_off() {
  local was_pinned=0
  [[ -n "${_CS_PROFILE:-}" || -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" || -n "${CLAUDE_CONFIG_DIR:-}" ]] && was_pinned=1
  unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR _CS_PROFILE
  ((was_pinned)) && _cs_restore_keychain_account
  echo "cs: this shell unpinned (profile env cleared)."
}

_cs_login() {
  local name="${1:-}"
  [[ -z "$name" ]] && {
    echo "cs login <name> [claude auth login args...]" >&2
    return 1
  }
  shift
  _cs_validate_name "$name" || {
    echo "cs: invalid profile name '$name'" >&2
    return 1
  }

  local cfg_dir acct_file marker_file acct email tier
  cfg_dir="$(_cs_profile_config_dir "$name")"
  acct_file="$HOME/.claude/accounts/$name.account.json"
  marker_file="$(_cs_profile_login_marker "$name")"
  mkdir -p "$cfg_dir" "$HOME/.claude/accounts"
  chmod 700 "$cfg_dir" "$HOME/.claude/accounts" 2>/dev/null

  if (($# == 0)); then
    set -- --claudeai
    if [[ -f "$acct_file" ]] && command -v jq >/dev/null 2>&1; then
      email="$(jq -r '.emailAddress // empty' "$acct_file" 2>/dev/null)"
      [[ -n "$email" ]] && set -- "$@" --email "$email"
    fi
  fi

  echo "cs: logging into isolated profile '$name' ($cfg_dir)" >&2
  env -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR="$cfg_dir" claude auth login "$@" || return $?

  local old_config_dir="${CLAUDE_CONFIG_DIR:-}" had_config_dir=0
  [[ -n "${CLAUDE_CONFIG_DIR+x}" ]] && had_config_dir=1
  export CLAUDE_CONFIG_DIR="$cfg_dir"
  acct="$(_cs_oauth_account_json)" || true
  if ((had_config_dir)); then
    export CLAUDE_CONFIG_DIR="$old_config_dir"
  else
    unset CLAUDE_CONFIG_DIR
  fi
  [[ -z "$acct" ]] && {
    echo "cs: login completed but no oauthAccount was written in $cfg_dir/.claude.json" >&2
    return 1
  }
  (
    umask 077
    printf '%s\n' "$acct" >"$acct_file"
    printf '1\n' >"$marker_file"
  )
  chmod 600 "$acct_file" "$marker_file" 2>/dev/null
  IFS=$'\t' read -r email tier <<<"$(printf '%s' "$acct" |
    jq -r '[.emailAddress // "?", .organizationRateLimitTier // "?"] | @tsv' 2>/dev/null)"
  echo "cs: saved isolated login for '$name' (email: $email, tier: $tier)"
}

_cs_list() {
  local dir="$HOME/.claude/accounts"
  setopt local_options null_glob
  local found=0 f name marker email tier suffix cfg_dir source existing seen
  local -a names
  names=()
  for f in "$dir"/*.token; do
    names+=("${f:t:r}")
  done
  for f in "$HOME/.claude/profiles"/*; do
    [[ -d "$f" ]] || continue
    name="${f:t}"
    seen=0
    for existing in "${names[@]}"; do
      [[ "$existing" == "$name" ]] && {
        seen=1
        break
      }
    done
    ((seen)) || names+=("$name")
  done
  for name in "${names[@]}"; do
    found=1
    marker="  "
    [[ "$name" == "$_CS_PROFILE" ]] && marker="* "
    suffix=""
    if [[ -f "$dir/$name.account.json" ]]; then
      email="$(jq -r '.emailAddress // "?"' "$dir/$name.account.json" 2>/dev/null)"
      tier="$(jq -r '.organizationRateLimitTier // "?"' "$dir/$name.account.json" 2>/dev/null)"
      suffix=" — $email ($tier)"
    else
      suffix=" — incomplete"
    fi
    cfg_dir="$(_cs_profile_config_dir "$name")"
    if _cs_profile_has_full_login "$name"; then
      source="isolated login"
    elif [[ -f "$dir/$name.token" ]]; then
      source="setup-token"
    else
      source="empty config"
    fi
    suffix="$suffix [$source]"
    echo "${marker}${name}${suffix}"
  done
  ((found)) || echo "(no profiles — run: cs login <name> or cs save <name>)"
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
  local tok="$1" code hdrs cfg_tok
  _CS_CHECK_STATUS=""
  _CS_CHECK_ORG=""
  hdrs="$(mktemp)" || {
    _CS_CHECK_STATUS="UNREACHABLE (could not create temp file)"
    return 2
  }
  cfg_tok="${tok//\\/\\\\}"
  cfg_tok="${cfg_tok//\"/\\\"}"
  # The authorization header goes in via a stdin config (-K -), not argv:
  # on Linux /proc/<pid>/cmdline is world-readable, so a token in curl's
  # arguments would be visible to every local user for the whole request.
  # printf is a zsh builtin, so no process ever holds the token in argv. Escape
  # curl-config metacharacters so a malformed paste cannot skip verification.
  code="$(printf 'header = "authorization: Bearer %s"\n' "$cfg_tok" |
    curl -sS -o /dev/null -D "$hdrs" -w '%{http_code}' --max-time 20 -K - \
      https://api.anthropic.com/v1/messages \
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
  401)
    _CS_CHECK_STATUS="EXPIRED ($code)"
    return 1
    ;;
  403)
    _CS_CHECK_STATUS="FORBIDDEN (403)"
    return 2
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
  local found=0 f name email snap_org rc bad=0 mismatch=0 unverified=0 identity_unknown=0 tok marker note
  for f in "$dir"/*.token; do
    found=1
    name="${f:t:r}"
    marker="  "
    [[ "$name" == "$_CS_PROFILE" ]] && marker="* "
    email="?"
    snap_org=""
    if [[ -f "$dir/$name.account.json" ]]; then
      IFS=$'\t' read -r email snap_org <<<"$(
        jq -r '[.emailAddress // "?", .organizationUuid // ""] | @tsv' "$dir/$name.account.json" 2>/dev/null
      )"
    fi
    tok="$(<"$f")"
    _cs_check_token "$tok"
    rc=$?
    ((rc == 1)) && bad=1
    ((rc == 2)) && unverified=1
    note=""
    if ((rc == 2)); then
      note=" — NOT VERIFIED"
    elif ((rc == 0)); then
      if [[ -z "$snap_org" || -z "$_CS_CHECK_ORG" ]]; then
        identity_unknown=1
        note=" — IDENTITY UNKNOWN (missing snapshot org or token org)"
      elif [[ "$snap_org" != "$_CS_CHECK_ORG" ]]; then
        mismatch=1
        note=" — ORG MISMATCH (token belongs to a different account than the snapshot)"
      fi
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
  if ((identity_unknown)); then
    echo "" >&2
    echo "cs: one or more profiles could not be identity-checked because either" >&2
    echo "the saved snapshot or the token response lacked an organization id." >&2
    echo "Re-save after logging the CLI into the intended account:" >&2
    echo "    claude setup-token | cs save <name> --force" >&2
    return 1
  fi
  if ((unverified)); then
    echo "" >&2
    echo "cs: one or more tokens could not be verified. Re-run once network/API" >&2
    echo "checks are available; until then, expired-token fallback may be masked." >&2
    return 1
  fi
  return 0
}

_cs_current() {
  if [[ -n "$_CS_PROFILE" ]]; then
    echo "$_CS_PROFILE"
    return 0
  fi
  if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
    echo "(profile config set, name unknown — re-run: cs use <name>)"
    return 0
  fi
  if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    echo "(token set, profile unknown — re-run: cs use <name>)"
    return 0
  fi
  echo "(none — claude will use the default config)"
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

  local tok_file="$dir/$name.token" acct_file="$dir/$name.account.json" cfg_dir
  cfg_dir="$(_cs_profile_config_dir "$name")"
  [[ -f "$tok_file" || -f "$acct_file" || -d "$cfg_dir" ]] || {
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
  rm -rf "$cfg_dir"
  if [[ "$_CS_PROFILE" == "$name" ]]; then
    unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR _CS_PROFILE
  fi
  echo "cs: removed '$name'."
}

_cs_help() {
  cat <<'EOF'
cs — per-terminal Claude Code subscription switcher.

Usage:
  cs login <name> [claude auth login args...]
                             Log into a full isolated Claude Code profile.
  cs save <name> [--force] [--allow-mismatch]
                             Bootstrap a legacy setup-token profile.
                             Verifies the token is live AND belongs to the same account
                             as the CLI login being snapshotted; refuses on mismatch
                             unless --allow-mismatch.
  cs use <name>              Pin THIS shell to the isolated profile.
  cs off                     Unset the profile env; subsequent `claude` uses default config.
  cs list                    List profiles; * marks the one pinned in this shell.
  cs doctor                  Validate each saved token against the API (OK / EXPIRED /
                             ORG MISMATCH when a token belongs to a different account
                             than its snapshot).
  cs current                 Print the pin for this shell.
  cs rm <name>               Delete a saved profile.

Bootstrap (once per account):
  Preferred full Claude Code login:
             cs login work --claudeai --email you@example.com

  Legacy setup-token fallback:
  In Claude Code, /login to account A.
  Easiest:   claude setup-token | cs save personal
  Or copy/paste:
             claude setup-token   (copy the printed token to clipboard)
             cs save personal     (reads from clipboard automatically)
  /logout, /login to account B, repeat with `cs save work`.

How it works:
  - cs login <name> runs `claude auth login` with CLAUDE_CONFIG_DIR pointed at
    ~/.claude/profiles/<name>. That stores full Claude Code login state in a
    profile-specific config namespace.
  - cs use <name> sets CLAUDE_CONFIG_DIR for THIS shell. If the profile has a
    full login, Claude uses that claude.ai login. If it only has a saved setup
    token, cs falls back to CLAUDE_CODE_OAUTH_TOKEN.
  - The `claude` wrapper additionally patches the active profile config's
    oauthAccount field from the profile snapshot before launch, so /status
    displays the right email.

Caveats:
  - A setup-token belongs to the BROWSER session that approved the OAuth URL,
    while the account snapshot comes from the CLI's /login. `cs save` verifies
    the two match (via the token's anthropic-organization-id) and refuses on
    mismatch. Easiest way to stay consistent: /login the CLI to the account
    first, then run `claude setup-token | cs save <name>`.
  - Setup-tokens are fallback CI-tier auth. They authenticate fine for
    inference but may not provide full Claude Code Max behavior.
  - GUI clients (desktop app, IDE extensions) don't inherit your shell's
    CLAUDE_CONFIG_DIR. CLI-only feature.
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
  login) _cs_login "$@" ;;
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
# `claude` wrapper. Patches the active profile config's oauthAccount from the
# pinned profile's snapshot so /status displays the correct email.
#==============================================================================

_cs_profile_account_file() {
  local profile="$1"
  printf '%s' "$HOME/.claude/accounts/$profile.account.json"
}

# State files for undoing the cosmetic patch:
#   .keychain.account.json — last oauthAccount known to come from a real
#                            /login in this config namespace, not from cs.
#   .cs-last-patch.json    — exact oauthAccount JSON cs last wrote, so we can
#                            tell "still our stale patch" from "user re-logged
#                            in since" and never clobber a real login.
_cs_keychain_stash_file() {
  if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
    printf '%s' "$CLAUDE_CONFIG_DIR/.keychain.account.json"
  else
    printf '%s' "$HOME/.claude/accounts/.keychain.account.json"
  fi
}
_cs_last_patch_file() {
  if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
    printf '%s' "$CLAUDE_CONFIG_DIR/.cs-last-patch.json"
  else
    printf '%s' "$HOME/.claude/accounts/.cs-last-patch.json"
  fi
}

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

_cs_write_oauth_account() {
  local src="$1" cfg="$2" tmp mode
  tmp="$(mktemp)" || return 1
  if jq --slurpfile a "$src" '.oauthAccount = $a[0]' "$cfg" >"$tmp" 2>/dev/null; then
    mode="$(_cs_stat_mode "$cfg")"
    [[ -n "$mode" ]] && chmod "$mode" "$tmp"
    mv "$tmp" "$cfg"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

_cs_patch_oauth_account_for_profile() {
  local profile="$1"
  local af cfg
  af="$(_cs_profile_account_file "$profile")"
  cfg="$(_cs_config_file)"

  if [[ -L "$cfg" ]]; then
    echo "cs: warning — $cfg is a symlink; skipping oauthAccount patch (auth still uses profile config/env)" >&2
    return 0
  fi
  [[ -f "$af" ]] || return 0
  if [[ ! -e "$cfg" ]]; then
    mkdir -p "${cfg:h}" 2>/dev/null
    (
      umask 077
      printf '{}\n' >"$cfg"
    ) || return 0
  fi
  [[ -f "$cfg" ]] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "cs: warning — jq is required to patch $cfg (auth still uses profile config/env)" >&2
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

  if _cs_write_oauth_account "$af" "$cfg"; then
    (
      umask 077
      jq -c . "$af" 2>/dev/null >"$(_cs_last_patch_file)"
    )
    return 0
  fi
  echo "cs: warning — failed to patch $cfg oauthAccount (auth still uses profile config/env)" >&2
  return 0
}

# Undo a stale cosmetic patch. If the active config still shows exactly what cs
# last wrote, an unpinned launch would otherwise display the pinned profile's
# identity while actually authenticating with the default config. Restore the
# stashed default identity. If the user has /login'd since (oauthAccount no
# longer matches our last patch), leave everything alone.
_cs_restore_keychain_account() {
  local cfg stash last cur
  cfg="$(_cs_config_file)"
  stash="$(_cs_keychain_stash_file)"
  [[ -f "$stash" && -f "$cfg" && ! -L "$cfg" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  last="$(cat "$(_cs_last_patch_file)" 2>/dev/null)"
  [[ -n "$last" ]] || return 0
  cur="$(jq -c '.oauthAccount // empty' "$cfg" 2>/dev/null)"
  [[ "$cur" == "$last" ]] || return 0
  if _cs_write_oauth_account "$stash" "$cfg"; then
    rm -f "$(_cs_last_patch_file)"
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
