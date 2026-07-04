# shellcheck disable=SC2148
# claude-switch — per-terminal Claude Code account switcher.
# https://github.com/tenkenco/claude-switch
#
# Usage:
#   1. Source this file from your ~/.zshrc:   source /path/to/cs.zsh
#   2. Log into each account once:           cs login personal
#                                            cs login work
#   3. Pin a terminal to a profile:          cs use work
#   4. Run claude in that terminal:          claude
#
# How it works:
#   Claude Code 2.x stores OAuth credentials in the OS keychain, in an entry
#   keyed by a hash of CLAUDE_CONFIG_DIR:
#       "Claude Code-credentials-<first 8 hex of sha256(CLAUDE_CONFIG_DIR)>"
#   So pointing each shell at its own CLAUDE_CONFIG_DIR gives each account its
#   own isolated credential slot. `cs login <name>` runs `claude auth login`
#   with CLAUDE_CONFIG_DIR set to ~/.claude/profiles/<name>; `cs use <name>`
#   re-exports that same dir in the current shell.
#
#   IMPORTANT — one account, one profile. Claude Code rotates OAuth refresh
#   tokens: each refresh invalidates the previous refresh token. If the SAME
#   account is logged into two credential slots (e.g. a profile AND the default
#   unpinned config, or two profiles), they clobber each other and you get
#   surprise "Please run /login" 401s. Keep every account in exactly one
#   profile and always `cs use` before launching claude. `cs doctor` flags any
#   account that appears in more than one namespace.
#
# Supported platforms:
#   - macOS   (security keychain; shasum)
#   - Linux   (secret storage varies; CLAUDE_CONFIG_DIR isolation still applies)

# Hard-clean stale function definitions so re-sourcing this file actually
# replaces them (zsh keeps old function bodies otherwise). Intentionally do
# not clear _CS_PROFILE here: preserving the active profile across re-source
# keeps reporting/wrapper behavior aligned with the exported config dir.
unfunction claude 2>/dev/null

#==============================================================================
# Helpers (shared across subcommands).
#==============================================================================

# Auth env vars that OVERRIDE the profile's keychain login. Claude Code will use
# any of these in preference to the CLAUDE_CONFIG_DIR credential slot, which
# would silently authenticate the wrong account (and bill the wrong plan). We
# strip all of them when launching or inspecting a pinned profile.
typeset -ga _CS_AUTH_OVERRIDE_VARS=(
  CLAUDE_CODE_OAUTH_TOKEN
  ANTHROPIC_API_KEY
  ANTHROPIC_AUTH_TOKEN
  CLAUDE_CODE_USE_BEDROCK
  CLAUDE_CODE_USE_VERTEX
)

# Populate the global array _cs_scrub with `-u VAR` pairs for env(1), so a
# caller can run `env "${_cs_scrub[@]}" claude ...` to launch claude without any
# overriding auth var — without mutating the user's interactive shell.
typeset -ga _cs_scrub
_cs_build_scrub_args() {
  _cs_scrub=()
  local v
  for v in "${_CS_AUTH_OVERRIDE_VARS[@]}"; do
    _cs_scrub+=(-u "$v")
  done
}

# Name validation. Allow [A-Za-z0-9._-] but reject leading '.' / '-' and reject
# any '/' or '..' sequence. Prevents `cs rm ../foo` from escaping profiles/.
_cs_validate_name() {
  local n="$1"
  [[ -n "$n" ]] || return 1
  [[ "$n" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || return 1
  [[ "$n" == *..* ]] && return 1
  return 0
}

_cs_profiles_root() { printf '%s' "$HOME/.claude/profiles"; }

# Per-profile config root. Claude Code honors CLAUDE_CONFIG_DIR for both the
# visible config and the keychain credential slot it derives from that path.
_cs_profile_config_dir() {
  printf '%s' "$(_cs_profiles_root)/$1"
}

# sha256 -> first 8 hex chars. This mirrors how Claude Code names the keychain
# credential entry for a given CLAUDE_CONFIG_DIR, letting `cs rm`/`cs doctor`
# find the right slot. Prefer shasum (ships on macOS), fall back to sha256sum.
_cs_sha256_8() {
  local s
  if command -v shasum >/dev/null 2>&1; then
    s="$(printf '%s' "$1" | shasum -a 256 2>/dev/null)"
  elif command -v sha256sum >/dev/null 2>&1; then
    s="$(printf '%s' "$1" | sha256sum 2>/dev/null)"
  else
    return 1
  fi
  [[ -n "$s" ]] || return 1
  # Use cut rather than a zsh ${s[1,8]} slice: scalar slicing is sensitive to
  # the user's KSH_ARRAYS option, which would silently shift the range.
  printf '%s' "$s" | cut -c1-8
}

# Keychain service name Claude Code uses for a given config dir (macOS).
_cs_keychain_service() {
  local suffix
  suffix="$(_cs_sha256_8 "$1")" || return 1
  printf 'Claude Code-credentials-%s' "$suffix"
}

# Read the visible account email a profile is logged into, offline, from the
# profile's own config. Echoes the email or "?" if unknown.
_cs_profile_email() {
  local cfg email
  cfg="$(_cs_profile_config_dir "$1")/.claude.json"
  [[ -f "$cfg" ]] || {
    printf '?'
    return 0
  }
  if command -v jq >/dev/null 2>&1; then
    email="$(jq -r '.oauthAccount.emailAddress // "?"' "$cfg" 2>/dev/null)"
  fi
  printf '%s' "${email:-?}"
}

# True if a profile dir has a completed login (config with an oauthAccount).
_cs_profile_is_set_up() {
  local cfg
  cfg="$(_cs_profile_config_dir "$1")/.claude.json"
  [[ -f "$cfg" ]] || return 1
  # Without jq we cannot confirm an oauthAccount was written, so treat the
  # profile as NOT set up rather than assuming success (a bare .claude.json is
  # created before login completes). jq is a hard install requirement anyway.
  command -v jq >/dev/null 2>&1 || return 1
  jq -e '.oauthAccount.emailAddress? // empty' "$cfg" >/dev/null 2>&1
}

#==============================================================================
# Subcommand implementations.
#==============================================================================

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

  local cfg_dir
  cfg_dir="$(_cs_profile_config_dir "$name")"
  mkdir -p "$cfg_dir"
  chmod 700 "$cfg_dir" 2>/dev/null

  # Default to an interactive claude.ai login. If we've logged this profile in
  # before, pre-fill the email we saw last time for a smoother re-login.
  if (($# == 0)); then
    set -- --claudeai
    local prev_email
    prev_email="$(_cs_profile_email "$name")"
    [[ -n "$prev_email" && "$prev_email" != "?" ]] && set -- "$@" --email "$prev_email"
  fi

  echo "cs: logging into isolated profile '$name' ($cfg_dir)" >&2
  # Run login in the profile's namespace, without leaking any overriding auth
  # env (API key, OAuth token, Bedrock/Vertex) into it.
  _cs_build_scrub_args
  env "${_cs_scrub[@]}" CLAUDE_CONFIG_DIR="$cfg_dir" claude auth login "$@" || return $?

  if ! _cs_profile_is_set_up "$name"; then
    echo "cs: login completed but no oauthAccount was written in $cfg_dir/.claude.json" >&2
    return 1
  fi
  echo "cs: saved isolated login for '$name' (email: $(_cs_profile_email "$name"))"
}

_cs_use() {
  local name="${1:-}"
  [[ -z "$name" ]] && {
    echo "cs use <name>" >&2
    return 1
  }
  _cs_validate_name "$name" || {
    echo "cs: invalid profile name '$name'" >&2
    return 1
  }

  local cfg_dir
  cfg_dir="$(_cs_profile_config_dir "$name")"
  [[ -d "$cfg_dir" ]] || {
    echo "cs: profile '$name' is not set up. Run: cs login $name" >&2
    return 1
  }

  export _CS_PROFILE="$name"
  export CLAUDE_CONFIG_DIR="$cfg_dir"
  # Clear cs's own legacy artifact so it can't override the keychain login.
  unset CLAUDE_CODE_OAUTH_TOKEN

  # Other overriding auth vars (API key, Bedrock/Vertex) belong to the user's
  # shell — don't silently unset them, but warn: the `claude` wrapper scrubs
  # them at launch, and a bare `command claude` would NOT be isolated. Checked
  # by name (not ${(P)…} indirection) so shfmt/shellcheck can parse this file.
  local present=()
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && present+=(ANTHROPIC_API_KEY)
  [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]] && present+=(ANTHROPIC_AUTH_TOKEN)
  [[ -n "${CLAUDE_CODE_USE_BEDROCK:-}" ]] && present+=(CLAUDE_CODE_USE_BEDROCK)
  [[ -n "${CLAUDE_CODE_USE_VERTEX:-}" ]] && present+=(CLAUDE_CODE_USE_VERTEX)
  ((${#present})) && echo "cs: note — ${present[*]} set; 'claude' will ignore it for this profile (bare 'command claude' would not)." >&2

  local email
  email="$(_cs_profile_email "$name")"
  if _cs_profile_is_set_up "$name"; then
    echo "cs: this shell pinned to '$name' ($email). Run 'claude' to launch."
  else
    echo "cs: this shell pinned to '$name' (not logged in yet — run: cs login $name)."
  fi
}

_cs_off() {
  unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR _CS_PROFILE
  echo "cs: this shell unpinned (profile env cleared)."
}

_cs_list() {
  setopt local_options null_glob
  local root f name marker email found=0
  root="$(_cs_profiles_root)"
  for f in "$root"/*; do
    [[ -d "$f" ]] || continue
    found=1
    name="${f:t}"
    marker="  "
    [[ "$name" == "${_CS_PROFILE:-}" ]] && marker="* "
    if _cs_profile_is_set_up "$name"; then
      email="$(_cs_profile_email "$name")"
      echo "${marker}${name} — ${email}"
    else
      echo "${marker}${name} — incomplete (run: cs login $name)"
    fi
  done
  ((found)) || echo "(no profiles — run: cs login <name>)"
}

_cs_current() {
  if [[ -n "${_CS_PROFILE:-}" ]]; then
    echo "$_CS_PROFILE"
    return 0
  fi
  if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
    echo "(profile config set, name unknown — re-run: cs use <name>)"
    return 0
  fi
  echo "(none — claude will use the default config)"
}

_cs_rm() {
  local name="${1:-}"
  [[ -z "$name" ]] && {
    echo "cs rm <name>" >&2
    return 1
  }
  _cs_validate_name "$name" || {
    echo "cs: invalid profile name '$name'" >&2
    return 1
  }

  local cfg_dir
  cfg_dir="$(_cs_profile_config_dir "$name")"
  [[ -d "$cfg_dir" ]] || {
    echo "cs: no such profile: $name" >&2
    return 1
  }
  printf "delete profile '%s' (config + keychain login)? [y/N] " "$name"
  local ans
  read -r ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || {
    echo "aborted."
    return 0
  }

  # Remove the keychain credential slot(s) for this config dir (macOS). Claude
  # Code keys the entry by sha256 of the path; try both the literal path and the
  # symlink-resolved path (${cfg_dir:A}) in case Claude canonicalizes it (e.g. a
  # symlinked $HOME or /var -> /private/var). Loop per service in case duplicate
  # items share the name. Warn rather than silently orphan a live credential.
  if command -v security >/dev/null 2>&1; then
    local d svc removed=0 leftover=0
    local -a dirs=("$cfg_dir")
    [[ "${cfg_dir:A}" != "$cfg_dir" ]] && dirs+=("${cfg_dir:A}")
    for d in "${dirs[@]}"; do
      svc="$(_cs_keychain_service "$d")"
      [[ -n "$svc" ]] || continue
      while security delete-generic-password -s "$svc" >/dev/null 2>&1; do removed=1; done
      security find-generic-password -s "$svc" >/dev/null 2>&1 && leftover=1
    done
    if ((leftover)) || { ((!removed)) && security find-generic-password -s "Claude Code-credentials-$(_cs_sha256_8 "$cfg_dir")" >/dev/null 2>&1; }; then
      echo "cs: warning — a keychain credential for '$name' may remain (Claude Code's naming scheme may have changed). Check with: security dump-keychain | grep 'Claude Code-credentials'" >&2
    fi
  fi

  rm -rf "$cfg_dir"
  if [[ "${_CS_PROFILE:-}" == "$name" ]]; then
    unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR _CS_PROFILE
  fi
  echo "cs: removed '$name'."
}

# Check each profile's login via `claude auth status --json` (the local CLI's
# view of each keychain slot) and — crucially — flag the failure mode that
# actually bites: the SAME account logged into more than one credential slot.
# Because Claude Code rotates refresh tokens, two slots holding one account
# invalidate each other, causing intermittent forced re-logins.
_cs_doctor() {
  if ! command -v claude >/dev/null 2>&1; then
    echo "cs: doctor needs the claude CLI." >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "cs: doctor needs jq." >&2
    return 1
  fi
  setopt local_options null_glob
  local root f name marker email method found=0 bad=0
  local label json logged
  local -A email_slots
  # Parallel list of emails in first-seen order, so the duplicate scan can
  # iterate without the ${(@k)…} flag (which older shfmt/shellcheck can't parse).
  local -a seen_order
  root="$(_cs_profiles_root)"
  # Scrub every overriding auth var so `auth status` reports the profile's real
  # keychain login, not a stray API key / Bedrock / Vertex identity.
  _cs_build_scrub_args

  # Include the default (unpinned) namespace — it's the most common accidental
  # duplicate. Key "" means "no CLAUDE_CONFIG_DIR".
  local -a slots
  slots=("")
  for f in "$root"/*; do
    [[ -d "$f" ]] && slots+=("${f:t}")
  done

  for name in "${slots[@]}"; do
    if [[ -z "$name" ]]; then
      label="(default)"
      json="$(env "${_cs_scrub[@]}" -u CLAUDE_CONFIG_DIR claude auth status --json 2>/dev/null)"
    else
      found=1
      label="$name"
      json="$(env "${_cs_scrub[@]}" CLAUDE_CONFIG_DIR="$(_cs_profile_config_dir "$name")" \
        claude auth status --json 2>/dev/null)"
    fi
    # Only the pinned profile gets a '*'. Guard against name="" (default slot)
    # matching an unset _CS_PROFILE, which would falsely star "(default)".
    marker="  "
    [[ -n "$name" && "$name" == "${_CS_PROFILE:-}" ]] && marker="* "

    # Distinguish "CLI said logged out" from "couldn't get a parseable status"
    # (network blip, rate limit, older CLI) — don't cry "NOT LOGGED IN" on noise.
    if [[ -z "$json" ]] || ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
      [[ -z "$name" ]] && continue
      echo "${marker}${label} — STATUS UNKNOWN (could not query 'claude auth status')"
      bad=1
      continue
    fi
    logged="$(printf '%s' "$json" | jq -r '.loggedIn // false' 2>/dev/null)"
    if [[ "$logged" != "true" ]]; then
      # Default namespace with no login is fine and expected; profiles are not.
      [[ -z "$name" ]] && continue
      echo "${marker}${label} — NOT LOGGED IN"
      bad=1
      continue
    fi
    email="$(printf '%s' "$json" | jq -r '.email // "?"' 2>/dev/null)"
    method="$(printf '%s' "$json" | jq -r '.authMethod // .loginMethod // "?"' 2>/dev/null)"
    [[ -z "$email" ]] && email="?"
    echo "${marker}${label} — ${email} (${method})"
    [[ "$email" == "?" ]] && continue
    [[ -z "${email_slots[$email]:-}" ]] && seen_order+=("$email")
    email_slots[$email]="${email_slots[$email]:+${email_slots[$email]}, }${label}"
  done

  ((found)) || {
    echo "(no profiles — run: cs login <name>)"
    return 0
  }

  # Report any account that shows up in more than one slot.
  local e dupes=0
  for e in "${seen_order[@]}"; do
    if [[ "${email_slots[$e]}" == *", "* ]]; then
      dupes=1
      echo "" >&2
      echo "cs: DUPLICATE — '$e' is logged into multiple namespaces:" >&2
      echo "      ${email_slots[$e]}" >&2
    fi
  done
  if ((dupes)); then
    echo "" >&2
    echo "cs: Claude Code rotates OAuth refresh tokens, so two slots holding the" >&2
    echo "    same account invalidate each other and cause surprise 'Please run" >&2
    echo "    /login' 401s. Keep each account in exactly ONE profile:" >&2
    echo "      - If '(default)' duplicates a profile, log the default out:" >&2
    echo "          env -u CLAUDE_CONFIG_DIR claude auth logout" >&2
    echo "      - Then always 'cs use <name>' before launching claude." >&2
    echo "      - Remove an extra profile with: cs rm <name>" >&2
    return 1
  fi
  ((bad)) && return 1
  return 0
}

_cs_help() {
  cat <<'EOF'
cs — per-terminal Claude Code account switcher.

Usage:
  cs login <name> [claude auth login args...]
                    Log a full claude.ai account into an isolated profile.
  cs use <name>     Pin THIS shell to a profile (exports CLAUDE_CONFIG_DIR).
  cs off            Unpin this shell (claude falls back to the default config).
  cs list           List profiles; * marks the one pinned in this shell.
  cs doctor         Check each profile's login AND flag any account that is
                    logged into more than one namespace (the thing that causes
                    surprise re-logins).
  cs current        Print the pin for this shell.
  cs rm <name>      Delete a profile's config and its keychain login.

One-time setup (per account):
  cs login personal
  cs login work

Daily use:
  cs use work && claude      # terminal A
  cs use personal && claude  # terminal B

The golden rule:
  One account -> one profile, and always `cs use` before `claude`. Claude Code
  now isolates credentials per CLAUDE_CONFIG_DIR (a keychain entry keyed by the
  hash of that path), but it rotates OAuth refresh tokens. If the same account
  lives in two slots (two profiles, or a profile plus the unpinned default),
  each refresh invalidates the other -> intermittent forced re-logins. Run
  `cs doctor` to catch it.

Caveats:
  - GUI clients (desktop app, IDE extensions) don't inherit your shell's
    CLAUDE_CONFIG_DIR. This is a CLI-only feature.
  - Two concurrent sessions of the SAME profile still share one credential
    slot; heavy parallel use of one account can still rotate against itself.
EOF
}

#==============================================================================
# Public dispatcher.
#==============================================================================

cs() {
  # This file is sourced into the user's interactive shell, so isolate option
  # state: KSH_ARRAYS, SH_WORD_SPLIT, NO_NOMATCH etc. from their ~/.zshrc would
  # otherwise change how our slicing/array/glob code evaluates. `emulate -L zsh`
  # (LOCAL_OPTIONS) resets to zsh defaults for this call and every helper it
  # invokes, and restores on return.
  emulate -L zsh
  local subcmd="${1:-help}"
  (($# > 0)) && shift
  case "$subcmd" in
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
# `claude` wrapper. Thin: keeps the config dir aligned with the pin and prints
# which account is launching. No credential rewriting — auth comes entirely
# from the isolated CLAUDE_CONFIG_DIR keychain slot.
#==============================================================================

claude() {
  emulate -L zsh
  [[ -n "${_CS_PROFILE:-}" ]] || {
    # Unpinned: pass through untouched (the user may intentionally be using an
    # API key or the default login here).
    command claude "$@"
    return
  }
  if ! _cs_validate_name "$_CS_PROFILE"; then
    echo "cs: refusing to launch — _CS_PROFILE='$_CS_PROFILE' is not a valid profile name" >&2
    return 1
  fi
  # Keep the exported config dir consistent with the pin (defends against a
  # shell where _CS_PROFILE and CLAUDE_CONFIG_DIR drifted apart).
  local cfg_dir
  cfg_dir="$(_cs_profile_config_dir "$_CS_PROFILE")"
  export CLAUDE_CONFIG_DIR="$cfg_dir"
  echo "cs: launching claude as '$_CS_PROFILE' ($(_cs_profile_email "$_CS_PROFILE"))" >&2
  # Launch with every overriding auth var stripped, so auth comes ONLY from the
  # profile's keychain slot — not a stray ANTHROPIC_API_KEY / OAuth token /
  # Bedrock / Vertex setting. `env … claude` runs the real binary directly,
  # which also avoids re-entering this wrapper.
  _cs_build_scrub_args
  env "${_cs_scrub[@]}" claude "$@"
}
