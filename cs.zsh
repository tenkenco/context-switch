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

# Re-sourcing this file must replace our own stale definitions (zsh keeps old
# function bodies otherwise) — but a `claude` function we did NOT define belongs
# to the user or another plugin, and silently destroying it is data loss. Tell
# ours apart with a marker, and when a foreign wrapper is present, keep a copy
# under _cs_prev_claude and say so rather than dropping it on the floor.
# Intentionally do not clear _CS_PROFILE: preserving the active profile across
# re-source keeps reporting/wrapper behavior aligned with the exported config dir.
#
# Written with plain-command tests (`typeset -f`, `functions -c`) rather than
# zsh's ${+functions[...]} / $functions[...] forms: this file is also parsed by
# shfmt and shellcheck as bash, and those flag-style expansions are a hard parse
# error there.
typeset -g _CS_FOREIGN_CLAUDE=""
if typeset -f claude >/dev/null 2>&1; then
  if [[ "${_CS_CLAUDE_WRAPPER_OWNED:-}" == "1" ]]; then
    unfunction claude 2>/dev/null
  else
    # Preserve the previous definition so the user can restore or inspect it.
    functions -c claude _cs_prev_claude 2>/dev/null
    _CS_FOREIGN_CLAUDE=1
    unfunction claude 2>/dev/null
  fi
fi

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
  ANTHROPIC_CUSTOM_HEADERS
  AWS_BEARER_TOKEN_BEDROCK
  CLAUDE_CODE_USE_BEDROCK
  CLAUDE_CODE_USE_VERTEX
)

# Vars we warn about but deliberately do NOT scrub. ANTHROPIC_BASE_URL redirects
# where requests go rather than who they authenticate as, and users behind a
# corporate gateway need it to reach the API at all — stripping it would break
# them. Surface it so a surprising identity isn't silently explained away.
typeset -ga _CS_AUTH_NOTE_VARS=(
  ANTHROPIC_BASE_URL
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
#
# NOTE: this is necessary but NOT sufficient. An older claude-switch cosmetically
# patched oauthAccount into each profile's .claude.json so `/status` showed the
# right email, so a profile carried over from that era looks logged in here while
# having no credential at all. Pair with _cs_profile_has_credential for the truth.
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

# Is Claude Code's keychain naming scheme still what we think it is? Verified by
# finding at least one slot for a dir we know about. Without this, a scheme
# change (or a locked keychain) would make every profile look credential-less
# and bury the user in false alarms. Memoized per `cs` invocation.
typeset -g _CS_KC_SCHEME_CACHE=""
_cs_keychain_scheme_intact() {
  [[ -n "$_CS_KC_SCHEME_CACHE" ]] && return "$_CS_KC_SCHEME_CACHE"
  setopt local_options null_glob
  local d svc rc=1
  for d in "$(_cs_profiles_root)"/*; do
    [[ -d "$d" ]] || continue
    svc="$(_cs_keychain_service "$d")" || continue
    if security find-generic-password -s "$svc" >/dev/null 2>&1; then
      rc=0
      break
    fi
  done
  _CS_KC_SCHEME_CACHE="$rc"
  return "$rc"
}

# Does the OS credential store actually hold a login for this profile?
#   0 = yes, 1 = confirmed missing, 2 = cannot tell (non-macOS, no shasum, or
#   the scheme/keychain looks unreadable). Callers must treat 2 as "no opinion"
#   — claiming a profile is broken on a guess is worse than staying quiet.
_cs_profile_has_credential() {
  command -v security >/dev/null 2>&1 || return 2
  local svc
  svc="$(_cs_keychain_service "$(_cs_profile_config_dir "$1")")" || return 2
  security find-generic-password -s "$svc" >/dev/null 2>&1 && return 0
  _cs_keychain_scheme_intact || return 2
  return 1
}

# Legacy plaintext credential files from the pre-keychain `cs save` era, kept
# at ~/.claude/accounts/<name>.*:
#   <name>.token        - long-lived OAuth bearer token
#   <name>.account.json - account snapshot (email, org, tier)
#   <name>.json         - full credential dump: the claude.ai OAuth access and
#                         refresh tokens PLUS every MCP server's tokens and
#                         client secrets
# Nothing in the current code writes these, and nothing else removes them, so a
# profile deleted after upgrading would leave live credentials on disk. `cs rm`
# takes them with the profile. Populates the global _cs_legacy_files (same
# pattern as _cs_scrub) with the ones that actually exist.
typeset -ga _cs_legacy_files
_cs_find_legacy_files() {
  _cs_legacy_files=()
  local name="$1" dir="$HOME/.claude/accounts" f
  for f in "$dir/$name.token" "$dir/$name.account.json" "$dir/$name.json"; do
    [[ -f "$f" ]] && _cs_legacy_files+=("$f")
  done
}

#==============================================================================
# Subcommand implementations.
#==============================================================================

# Remove a profile dir that THIS login created and never finished setting up.
# Never touches a dir that already existed: a failed re-login of a working
# profile must leave that profile alone.
_cs_login_cleanup() {
  local name="$1" cfg_dir="$2" created="$3"
  ((created)) || return 0
  _cs_profile_is_set_up "$name" && return 0
  rm -rf "$cfg_dir"
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

  local cfg_dir created=0
  cfg_dir="$(_cs_profile_config_dir "$name")"
  # Remember whether this dir is ours to clean up: an aborted or failed login
  # must not leave a half-made profile behind. One that does shows up in
  # `cs list` as incomplete, is accepted by `cs use`, and makes `cs doctor`
  # return 1 on every run until someone notices and removes it by hand.
  [[ -d "$cfg_dir" ]] || created=1
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
  # env (API key, OAuth token, custom headers, Bedrock/Vertex) into it. The
  # `always` block runs on error AND on interrupt, so Ctrl-C at the login prompt
  # cleans up too.
  _cs_build_scrub_args
  # LOCAL_TRAPS keeps this INT handler from leaking into the user's shell; it
  # covers Ctrl-C at the login prompt, while the rc check below covers a login
  # that merely fails. (zsh's `{...} always {...}` would express this in one
  # construct, but shfmt/shellcheck parse this file as bash and cannot read it.)
  setopt local_options local_traps
  trap '_cs_login_cleanup "$name" "$cfg_dir" "$created"; return 130' INT

  env "${_cs_scrub[@]}" CLAUDE_CONFIG_DIR="$cfg_dir" claude auth login "$@"
  local rc=$?
  if ((rc != 0)); then
    _cs_login_cleanup "$name" "$cfg_dir" "$created"
    return "$rc"
  fi

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

  # Other overriding auth vars (API key, custom headers, Bedrock/Vertex) belong
  # to the user's shell — don't silently unset them, but warn: the `claude`
  # wrapper scrubs them at launch, and a bare `command claude` would NOT be
  # isolated. Listed by name (not ${(P)…} indirection) so shfmt/shellcheck can
  # parse this file; keep in sync with _CS_AUTH_OVERRIDE_VARS above.
  local present=()
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && present+=(ANTHROPIC_API_KEY)
  [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]] && present+=(ANTHROPIC_AUTH_TOKEN)
  [[ -n "${ANTHROPIC_CUSTOM_HEADERS:-}" ]] && present+=(ANTHROPIC_CUSTOM_HEADERS)
  [[ -n "${AWS_BEARER_TOKEN_BEDROCK:-}" ]] && present+=(AWS_BEARER_TOKEN_BEDROCK)
  [[ -n "${CLAUDE_CODE_USE_BEDROCK:-}" ]] && present+=(CLAUDE_CODE_USE_BEDROCK)
  [[ -n "${CLAUDE_CODE_USE_VERTEX:-}" ]] && present+=(CLAUDE_CODE_USE_VERTEX)
  ((${#present})) && echo "cs: note — ${present[*]} set; 'claude' will ignore it for this profile (bare 'command claude' would not)." >&2

  # Not scrubbed (see _CS_AUTH_NOTE_VARS) — flag it so a surprising account or
  # a failing request isn't a mystery.
  [[ -n "${ANTHROPIC_BASE_URL:-}" ]] &&
    echo "cs: note — ANTHROPIC_BASE_URL is set; requests go to it, not the default API (cs does not strip it)." >&2

  local email cred
  email="$(_cs_profile_email "$name")"
  if _cs_profile_is_set_up "$name"; then
    _cs_profile_has_credential "$name"
    cred=$?
    if ((cred == 1)); then
      # The config claims an account but the keychain slot is gone — the classic
      # leftover from the era when cs patched oauthAccount in cosmetically.
      echo "cs: this shell pinned to '$name' ($email) — but no credential is stored for it."
      echo "    Run 'cs login $name' or 'claude' will just prompt you to log in." >&2
    else
      echo "cs: this shell pinned to '$name' ($email). Run 'claude' to launch."
    fi
  else
    echo "cs: this shell pinned to '$name' (not logged in yet — run: cs login $name)."
  fi
}

# Run claude under a profile without pinning the shell and without going through
# the `claude` wrapper — `env` executes the real binary, so a `claude` function
# from another plugin is neither consulted nor clobbered. This is the escape
# hatch for anyone who would rather claude-switch not own the `claude` name.
_cs_run() {
  local name="${1:-}"
  [[ -z "$name" ]] && {
    echo "cs run <name> [--] [claude args...]" >&2
    return 1
  }
  _cs_validate_name "$name" || {
    echo "cs: invalid profile name '$name'" >&2
    return 1
  }
  shift
  [[ "${1:-}" == "--" ]] && shift

  local cfg_dir
  cfg_dir="$(_cs_profile_config_dir "$name")"
  [[ -d "$cfg_dir" ]] || {
    echo "cs: profile '$name' is not set up. Run: cs login $name" >&2
    return 1
  }
  # $commands, not `command -v`: after this file is sourced, `command -v claude`
  # matches our own shell function and would claim the CLI is installed when it
  # is not.
  [[ -n "${commands[claude]:-}" ]] || {
    echo "cs: the claude CLI is not installed (or not in PATH)." >&2
    return 1
  }
  _cs_build_scrub_args
  env "${_cs_scrub[@]}" CLAUDE_CONFIG_DIR="$cfg_dir" claude "$@"
}

_cs_off() {
  unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR _CS_PROFILE
  echo "cs: this shell unpinned (profile env cleared)."
}

_cs_list() {
  setopt local_options null_glob
  local root f name marker email found=0 cred=0
  root="$(_cs_profiles_root)"
  for f in "$root"/*; do
    [[ -d "$f" ]] || continue
    found=1
    name="${f:t}"
    marker="  "
    [[ "$name" == "${_CS_PROFILE:-}" ]] && marker="* "
    if _cs_profile_is_set_up "$name"; then
      email="$(_cs_profile_email "$name")"
      # Only contradict the config when we positively confirmed the credential
      # is gone (rc 1); rc 2 means "couldn't check" and stays silent.
      _cs_profile_has_credential "$name"
      cred=$?
      if ((cred == 1)); then
        echo "${marker}${name} — ${email} (no credential — run: cs login $name)"
      else
        echo "${marker}${name} — ${email}"
      fi
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
  # A profile upgraded from the `cs save` era may have legacy credential files
  # and no config dir (it was never re-created with `cs login`). Accept either,
  # so those credentials are removable at all.
  _cs_find_legacy_files "$name"
  if [[ ! -d "$cfg_dir" ]] && ((${#_cs_legacy_files} == 0)); then
    echo "cs: no such profile: $name" >&2
    return 1
  fi

  local what="config + keychain login"
  if ((${#_cs_legacy_files})); then
    what="$what + legacy credential files"
    echo "cs: '$name' has legacy plaintext credential files from an older cs:" >&2
    local f
    for f in "${_cs_legacy_files[@]}"; do echo "      $f" >&2; done
  fi
  printf "delete profile '%s' (%s)? [y/N] " "$name" "$what"
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
    local d svc had_before=0 leftover=0 probed=0
    local -a dirs=("$cfg_dir")
    [[ "${cfg_dir:A}" != "$cfg_dir" ]] && dirs+=("${cfg_dir:A}")
    for d in "${dirs[@]}"; do
      svc="$(_cs_keychain_service "$d")"
      [[ -n "$svc" ]] || continue
      probed=1
      # Probe BEFORE deleting. Inferring "no credential" from a find that failed
      # is wrong: a locked keychain (or a denied access prompt) fails both the
      # delete and the find, which used to read as "nothing was there" and left
      # a live credential orphaned without a word.
      security find-generic-password -s "$svc" >/dev/null 2>&1 && had_before=1
      while security delete-generic-password -s "$svc" >/dev/null 2>&1; do :; done
      security find-generic-password -s "$svc" >/dev/null 2>&1 && leftover=1
    done
    if ((leftover)); then
      echo "cs: warning — the keychain credential for '$name' is STILL PRESENT after deletion." >&2
      echo "    Remove it by hand: security delete-generic-password -s '$svc'" >&2
    elif ((!probed)); then
      # No sha256 tool, so we never derived a service name to look for.
      echo "cs: warning — could not derive the keychain service name for '$name'; a credential may remain." >&2
      echo "    Check with: security dump-keychain | grep 'Claude Code-credentials'" >&2
    elif ((!had_before)) && ! _cs_keychain_scheme_intact; then
      # Found nothing to delete AND no other profile has a slot either — more
      # likely the keychain is unreadable or the scheme moved than that this
      # profile genuinely had no credential.
      echo "cs: note — no keychain credential was found for '$name'. If you expected one," >&2
      echo "    Claude Code's naming scheme may have changed; check with:" >&2
      echo "    security dump-keychain | grep 'Claude Code-credentials'" >&2
    fi
  fi

  rm -rf "$cfg_dir"
  if ((${#_cs_legacy_files})); then
    # Report anything that survived rather than claiming a clean removal: these
    # are live credentials, so a silent failure is the worst outcome.
    rm -f "${_cs_legacy_files[@]}"
    local left=() f
    for f in "${_cs_legacy_files[@]}"; do
      [[ -e "$f" ]] && left+=("$f")
    done
    if ((${#left})); then
      echo "cs: warning — could not delete: ${left[*]}" >&2
      echo "    These hold live credentials; remove them by hand." >&2
    fi
  fi
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
  # $commands[claude] is the real binary. `command -v claude` would match the
  # `claude` shell function this file defines and pass even with no CLI present,
  # which then surfaced as every profile reporting STATUS UNKNOWN.
  if [[ -z "${commands[claude]:-}" ]]; then
    echo "cs: doctor needs the claude CLI (not found in PATH)." >&2
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
  cs run <name> [--] [args...]
                    Run claude once under a profile without pinning the shell.
                    Bypasses the `claude` wrapper entirely, so it is also the
                    way to coexist with another plugin's `claude` function.
  cs off            Unpin this shell (claude falls back to the default config).
  cs list           List profiles; * marks the one pinned in this shell.
  cs doctor         Check each profile's login AND flag any account that is
                    logged into more than one namespace (the thing that causes
                    surprise re-logins).
  cs current        Print the pin for this shell.
  cs rm <name>      Delete a profile's config, its keychain login, and any
                    legacy plaintext credential files left by an older cs.

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
  # Keychain probes are memoized per invocation, not per shell: a login or
  # removal between two `cs` calls must not be masked by a stale answer.
  _CS_KC_SCHEME_CACHE=""
  local subcmd="${1:-help}"
  (($# > 0)) && shift
  case "$subcmd" in
  login) _cs_login "$@" ;;
  use) _cs_use "$@" ;;
  run) _cs_run "$@" ;;
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
# Mark the wrapper as ours so a later re-source can tell it from a foreign one.
typeset -g _CS_CLAUDE_WRAPPER_OWNED=1

#==============================================================================
# Source-time diagnostics. Printed once per shell, to stderr, so they never
# pollute a `cs list` or `cs current` someone is parsing.
#==============================================================================

if [[ -n "$_CS_FOREIGN_CLAUDE" ]]; then
  echo "cs: note — a 'claude' function was already defined in this shell; claude-switch" >&2
  echo "    replaced it with its profile-aware wrapper. The previous definition is kept" >&2
  echo "    as '_cs_prev_claude' (restore with: functions[claude]=\$functions[_cs_prev_claude])." >&2
  echo "    To leave the 'claude' name alone entirely, use: cs run <name> -- <args>" >&2
fi

# jq is a hard requirement of install.sh, but plugin managers (zinit, oh-my-zsh,
# sheldon, antidote) source this file directly and never run the installer.
# Without jq every profile silently reports as 'incomplete' even when it works.
if ! command -v jq >/dev/null 2>&1; then
  echo "cs: warning — 'jq' not found in PATH. Profile status will read as 'incomplete'" >&2
  echo "    and 'cs doctor' will not run. Install jq (brew install jq / apt install jq)." >&2
fi
