# shellcheck disable=SC2148
# context-switch — per-terminal identity switcher for Claude Code and any other
# CLI that reads its config path from the environment.
# https://github.com/tenkenco/context-switch
#
# Usage:
#   1. Source this file from your ~/.zshrc:   source /path/to/cs.zsh
#   2. Log into each account once:           cs login personal
#                                            cs login work
#   3. Pin a terminal to a profile:          cs use work
#   4. Run claude in that terminal:          claude
#
# Other tools (profile.env):
#   Each profile may hold a `profile.env` file. `cs use` sources it, so one
#   command pins the whole toolchain — gcloud, AWS, kubectl, gh — not just
#   Claude Code. `cs env <name>` prints it. The contract is one
#   `export VAR=value` per line; cs tracks exactly those names, and unsets them
#   on `cs off` or when you pin the shell to a different profile. cs refuses a
#   file that exports PATH or the pin variables — see _CS_ENV_BLOCKED_VARS.
#
#   Why this matters for gcloud in particular: ~/.config/gcloud/active_config
#   and ~/.config/gcloud/application_default_credentials.json are single global
#   files. `gcloud auth login` rewrites them for every shell at once, which
#   breaks Terraform in whatever other terminal was using the other account.
#   Pointing CLOUDSDK_CONFIG (and GOOGLE_APPLICATION_CREDENTIALS, which Go-based
#   tools such as the Terraform google provider read directly) at a per-profile
#   directory removes the shared file entirely.
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
# ours apart with a sentinel in the actual function body, and when a foreign
# wrapper is present, keep a copy under _cs_prev_claude and say so rather than
# dropping it on the floor.
# Intentionally do not clear _CS_PROFILE: preserving the active profile across
# re-source keeps reporting/wrapper behavior aligned with the exported config dir.
#
# Written with plain-command tests (`typeset -f`, `functions -c`) rather than
# zsh's ${+functions[...]} / $functions[...] forms: this file is also parsed by
# shfmt and shellcheck as bash, and those flag-style expansions are a hard parse
# error there.
typeset -g _CS_FOREIGN_CLAUDE=""
if typeset -f claude >/dev/null 2>&1; then
  if [[ "$(typeset -f claude)" == *"_CS_CLAUDE_SWITCH_WRAPPER"* ]]; then
    unfunction claude 2>/dev/null
  else
    # Preserve the previous definition so the user can restore or inspect it —
    # but only CLAIM preservation if the copy actually succeeded. Announcing a
    # backup that does not exist is worse than announcing none: the user stops
    # looking for the function we just removed.
    if functions -c claude _cs_prev_claude 2>/dev/null; then
      _CS_FOREIGN_CLAUDE=saved
    else
      _CS_FOREIGN_CLAUDE=unsaved
    fi
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

# Vars we warn about but deliberately do NOT scrub. ANTHROPIC_BASE_URL selects
# where requests go rather than who they authenticate as, and users behind a
# corporate gateway need it to reach the API at all — stripping it would break
# them at the one moment it matters.
#
# Be honest about what that costs: scrubbing controls WHICH IDENTITY is used,
# not WHERE the request (and therefore the profile's bearer token) is sent. A
# BASE_URL pointing somewhere unexpected still receives that token. So every
# path that launches claude warns, not just `cs use`.
typeset -ga _CS_AUTH_NOTE_VARS=(
  ANTHROPIC_BASE_URL
)

# Print the not-scrubbed warning. Called from every launch path so the notice
# cannot be missed by whichever entry point the user happens to prefer.
_cs_warn_note_vars() {
  [[ -n "${ANTHROPIC_BASE_URL:-}" ]] || return 0
  echo "cs: note — ANTHROPIC_BASE_URL is set; this profile's token is sent to" >&2
  echo "    $ANTHROPIC_BASE_URL, not the default API endpoint (cs does not strip it)." >&2
}

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

# Profiles stay under ~/.claude even though cs now pins more than Claude Code.
# Do NOT "tidy" this into ~/.config/context-switch: Claude Code names each
# profile's keychain entry by the sha256 of CLAUDE_CONFIG_DIR, so moving the
# directory orphans every stored credential and forces a re-login everywhere.
_cs_profiles_root() { printf '%s' "$HOME/.claude/profiles"; }

# Per-profile config root. Claude Code honors CLAUDE_CONFIG_DIR for both the
# visible config and the keychain credential slot it derives from that path.
_cs_profile_config_dir() {
  printf '%s' "$(_cs_profiles_root)/$1"
}

# Optional per-profile environment file for every OTHER tool. Lives inside the
# config dir so `cs rm` removes it with the profile and nothing else has to know
# about it.
_cs_profile_env_file() {
  printf '%s' "$(_cs_profile_config_dir "$1")/profile.env"
}

# Names a profile.env must NOT set. cs refuses such a file outright rather than
# applying part of it, because both groups below break something the user cannot
# easily see:
#   - PATH, HOME, IFS, PWD, SHELL, TMPDIR: `cs off` unsets every tracked name,
#     and a shell left without PATH cannot run a single command.
#   - CLAUDE_CONFIG_DIR, _CS_PROFILE, _CS_PROFILE_ENV_VARS: these ARE the pin.
#     A file that rewrites them makes `cs use` report one profile while claude
#     launches as another.
typeset -ga _CS_ENV_BLOCKED_VARS=(
  PATH HOME IFS PWD OLDPWD SHELL TMPDIR
  CLAUDE_CONFIG_DIR _CS_PROFILE _CS_PROFILE_ENV_VARS
)

# Names the env file exports, so `cs use` and `cs off` can undo them later.
#
# CONTRACT: one `export VAR=value` per line. Any other shell code in the file
# still runs when the file is sourced — cs simply cannot track or unset what it
# did. Keep the file to plain exports and this stays predictable.
typeset -ga _cs_env_var_names
typeset -g _cs_env_parse_ambiguous=0
_cs_parse_env_vars() {
  _cs_env_var_names=()
  _cs_env_parse_ambiguous=0
  local f="$1" name
  [[ -f "$f" ]] || return 0
  # `export A=1 B=2` really does set both, so tracking only the first would
  # leave B set forever. Split an export line on whitespace and take every
  # NAME= token.
  #
  # A QUOTED line is the hard case, because a quoted value may contain spaces
  # and even a "WORD=" that is not a variable at all (export K="a B=2"). There
  # is no way to tell those apart without implementing shell quoting here. An
  # earlier version silently kept just the first name, and that was a security
  # hole, not merely incomplete: `export CS_OK="yes" PATH="/nowhere"` hid PATH
  # from the blocked-name check, sourced the file, and broke the shell.
  #
  # So a quoted line carrying more than one candidate is reported as ambiguous
  # and the caller refuses the whole file. Guessing is the one option that is
  # never safe.
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if [[ "$name" == "!AMBIGUOUS" ]]; then
      _cs_env_parse_ambiguous=1
      continue
    fi
    _cs_env_var_names+=("$name")
  done < <(awk '
    /^[[:space:]]*export[[:space:]]/ {
      line = $0
      sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      quoted = (line ~ /["'"'"']/)
      n = split(line, parts, /[[:space:]]+/)
      count = 0
      for (i = 1; i <= n; i++)
        if (parts[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) count++
      if (quoted && count > 1) { print "!AMBIGUOUS"; next }
      for (i = 1; i <= n; i++) {
        if (parts[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
          eq = index(parts[i], "=")
          print substr(parts[i], 1, eq - 1)
        }
      }
    }
  ' "$f" 2>/dev/null)
  return 0
}

# Names in _cs_env_var_names that cs refuses to manage. Populates the global
# _cs_env_blocked_found (same pattern as _cs_scrub).
typeset -ga _cs_env_blocked_found
_cs_env_find_blocked() {
  _cs_env_blocked_found=()
  local n b
  for n in "${_cs_env_var_names[@]}"; do
    for b in "${_CS_ENV_BLOCKED_VARS[@]}"; do
      [[ "$n" == "$b" ]] && _cs_env_blocked_found+=("$n")
    done
  done
  return 0
}

# Unset whatever the previously loaded profile.env exported. Driven by the
# exported _CS_PROFILE_ENV_VARS recorded at load time, NOT by re-reading the
# file: the file can be edited or deleted between `cs use` and `cs off`, and
# re-parsing it then would leave the stale vars set forever.
_cs_clear_profile_env() {
  [[ -n "${_CS_PROFILE_ENV_VARS:-}" ]] || return 0
  # Split on whitespace whatever the caller's IFS is. `emulate -L zsh` does not
  # reset IFS, and a profile.env line as ordinary as `IFS=,` would otherwise
  # make the loop below see one giant field and call `unset "CS_A CS_B"`, which
  # fails on an invalid parameter name and strands every tracked variable.
  local IFS=$' \t\n'
  local v b skip
  # Unquoted command substitution field-splits in both zsh and bash. Var names
  # are validated at parse time, so splitting on whitespace is safe here.
  # shellcheck disable=SC2046
  for v in $(printf '%s' "$_CS_PROFILE_ENV_VARS"); do
    # Never unset a protected name, no matter what the tracking list says.
    # _CS_PROFILE_ENV_VARS is exported, so it can arrive from a parent process
    # or a stale session rather than from a file cs actually parsed. cs never
    # writes a blocked name into it, so one appearing here did not come from us
    # — and honoring `PATH` would leave a shell that cannot run a command.
    skip=0
    for b in "${_CS_ENV_BLOCKED_VARS[@]}"; do
      [[ "$v" == "$b" ]] && skip=1
    done
    ((skip)) && continue
    unset "$v"
  done
  unset _CS_PROFILE_ENV_VARS
  return 0
}

# Is a path something an attacker could have written? Echoes the reason and
# returns 0 when it is unsafe, so callers can report WHY they refused.
#
# Both checks follow symlinks on purpose. `-O` and `find -L` resolve the link,
# and a link's own mode is 0777 on Linux and 0755 on macOS no matter what it
# points at, so testing the link itself proves nothing.
_cs_env_path_unsafe() {
  local p="$1"
  if [[ ! -O "$p" ]]; then
    printf 'it is not owned by you'
    return 0
  fi
  # Prove find can actually answer before trusting an empty answer. This is a
  # security gate, so "find is missing" or "-perm is unsupported" must read as a
  # refusal, not as approval. Without this probe the mode check fails OPEN: on a
  # box with zsh but no findutils, a chmod 666 file you own would sail through.
  if [[ -z "$(find -L "$p" -maxdepth 0 -print 2>/dev/null)" ]]; then
    printf 'its permissions could not be read'
    return 0
  fi
  if [[ -n "$(find -L "$p" -maxdepth 0 \( -perm -g+w -o -perm -o+w \) 2>/dev/null)" ]]; then
    printf 'it is group- or world-writable'
    return 0
  fi
  return 1
}

# Source a profile's env file into the CURRENT shell and record what it set.
_cs_load_profile_env() {
  _cs_env_var_names=()
  local f
  f="$(_cs_profile_env_file "$1")"
  [[ -f "$f" ]] || return 0

  # Sourcing is running code, so refuse anything an attacker could have written.
  local why
  if why="$(_cs_env_path_unsafe "$f")"; then
    echo "cs: refusing to load $f — $why." >&2
    echo "    Fix it with: chmod 600 '$f'" >&2
    return 1
  fi

  # The DIRECTORY matters as much as the file. Anyone who can write the profile
  # directory can delete profile.env and drop in their own 0600 copy, which
  # passes the check above with a perfect-looking mode. `cs login` creates the
  # directory 0700, but a permissive umask, a restored backup, or a synced home
  # can loosen it after the fact — and nothing else would ever notice.
  #
  # Check BOTH the profile directory and the directory the file really lives in.
  # When profile.env is a symlink those differ, and it is the target's directory
  # that decides who can delete-and-replace the thing actually sourced.
  local d
  for d in "$(_cs_profile_config_dir "$1")" "${f:A:h}"; do
    if why="$(_cs_env_path_unsafe "$d")"; then
      echo "cs: refusing to load $f — its directory $d is unsafe: $why." >&2
      echo "    Anyone who can write that directory can replace the file." >&2
      echo "    Fix it with: chmod 700 '$d'" >&2
      return 1
    fi
  done

  _cs_parse_env_vars "$f"

  if ((_cs_env_parse_ambiguous)); then
    echo "cs: refusing to load $f — a quoted export line sets more than one" >&2
    echo "    variable, and cs cannot tell a real name from text inside a quoted" >&2
    echo "    value. Put one 'export VAR=value' on each line." >&2
    _cs_env_var_names=()
    return 1
  fi

  _cs_env_find_blocked
  if ((${#_cs_env_blocked_found})); then
    echo "cs: refusing to load $f — it sets ${_cs_env_blocked_found[*]}." >&2
    echo "    'cs off' unsets every name cs tracks, so managing these would break" >&2
    echo "    your shell or the profile pin itself. Remove those lines." >&2
    _cs_env_var_names=()
    return 1
  fi

  # Record the names BEFORE sourcing, not after. `source` returns the exit
  # status of the file's LAST command, so an ordinary trailing line such as
  #     [[ -d "$HOME/work" ]] && export EXTRA=1
  # returns non-zero whenever that test fails — with every earlier export
  # already applied. Tracking afterwards would skip the record and strand those
  # variables set-but-untracked forever, which is precisely the cross-profile
  # drift this feature exists to stop.
  ((${#_cs_env_var_names})) && export _CS_PROFILE_ENV_VARS="${_cs_env_var_names[*]}"

  # Snapshot the shell essentials before sourcing. The blocked-name check reads
  # `export` lines, but a BARE assignment (`IFS=,`, `PATH=/nowhere`) never
  # reaches the parser and still changes this shell, because these variables are
  # already exported. A poisoned IFS is the nastiest of them: it silently breaks
  # every word split cs performs afterwards, including its own cleanup.
  local _sv_path="$PATH" _sv_ifs="$IFS" _sv_home="$HOME"
  local _sv_shell="${SHELL-}" _sv_tmpdir="${TMPDIR-}"

  # shellcheck source=/dev/null
  source "$f"
  local src_rc=$?

  # Put back anything the file moved, and say so. Listed by name rather than by
  # indirection so shfmt and shellcheck can still parse this file.
  local moved=()
  [[ "$PATH" != "$_sv_path" ]] && {
    PATH="$_sv_path"
    moved+=(PATH)
  }
  [[ "$IFS" != "$_sv_ifs" ]] && {
    IFS="$_sv_ifs"
    moved+=(IFS)
  }
  [[ "$HOME" != "$_sv_home" ]] && {
    HOME="$_sv_home"
    moved+=(HOME)
  }
  [[ "${SHELL-}" != "$_sv_shell" ]] && {
    SHELL="$_sv_shell"
    moved+=(SHELL)
  }
  [[ "${TMPDIR-}" != "$_sv_tmpdir" ]] && {
    TMPDIR="$_sv_tmpdir"
    moved+=(TMPDIR)
  }
  ((${#moved})) && echo "cs: note — profile.env changed ${moved[*]}; cs restored it." >&2

  # Re-assert the record AFTER sourcing, for the same reason `cs use` re-asserts
  # the pin: the blocked-name check reads `export` lines, but the file is sourced,
  # so a bare `unset _CS_PROFILE_ENV_VARS` (or a bare assignment) is invisible to
  # the parser and would silently disable every later cleanup.
  if ((${#_cs_env_var_names})); then
    export _CS_PROFILE_ENV_VARS="${_cs_env_var_names[*]}"
  fi

  if ((src_rc != 0)); then
    echo "cs: $f returned a non-zero status. Its exports are still tracked, so" >&2
    echo "    'cs off' will clear them — but check the file for a failing line." >&2
    return 1
  fi
  return 0
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

#==============================================================================
# Providers.
#
# A provider is one tool whose login `cs` can drive into a profile. Providers
# are plain functions, found by name:
#
#   _cs_provider_<provider>_login <profile> [args...]   run that tool's login
#   _cs_provider_<provider>_check <profile>             report that tool's health
#
# Keeping them in this file rather than a providers/ directory is deliberate.
# cs.zsh is sourced directly — by an absolute path from .zshrc, and by plugin
# managers from their own clone — so a sibling directory would add a path to
# resolve and break whenever someone copies the single file. The naming
# convention costs nothing and lets you add your own provider from .zshrc:
# define _cs_provider_aws_login and `cs login work aws` starts working.
#
# A check hook returns 0 (healthy), 1 (a real problem), or 2 (no opinion). 2 is
# the important one: `cs doctor` must stay quiet about a tool the profile does
# not pin, and must never guess.
#==============================================================================

# Provider names are stricter than profile names: lowercase, no dots, because
# the name is pasted into a function name and looked up.
_cs_validate_provider() {
  [[ "$1" =~ ^[a-z][a-z0-9_]*$ ]]
}

# The providers cs ships with. `cs login` accepts any provider whose login hook
# is defined, so a hook you write in .zshrc works without touching this list;
# append to the list as well and `cs doctor` will call its check hook too.
typeset -ga _CS_PROVIDERS=(claude gcloud)

_cs_provider_list() { printf '%s' "${_CS_PROVIDERS[*]}"; }

# Run a command with a profile's profile.env applied, and nothing else changed.
# Always in a subshell, so the caller's shell keeps its own pin — this is the
# `cs run` promise, reused. Clearing the CALLER's profile env first matters for
# the same reason it does there: running a gcloud login from a shell pinned to
# `work` must not hand the child work's CLOUDSDK_CONFIG.
_cs_with_profile_env() {
  local name="$1"
  shift
  (
    _cs_clear_profile_env
    _cs_load_profile_env "$name" || exit 1
    "$@"
  )
}

#------------------------------------------------------------------ provider: claude

_cs_provider_claude_login() {
  local name="$1"
  shift

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
  local interrupted=0
  trap 'interrupted=1' INT

  env "${_cs_scrub[@]}" CLAUDE_CONFIG_DIR="$cfg_dir" claude auth login "$@"
  local rc=$?
  # After zsh runs an INT handler, $? no longer reflects the interrupted
  # command, so the flag — not rc — is what proves Ctrl-C happened. Returning
  # from inside the trap instead would exit with 0, making an aborted login
  # look successful to `cs login x && …`.
  ((interrupted)) && rc=130
  if ((rc != 0)); then
    _cs_login_cleanup "$name" "$cfg_dir" "$created"
    return "$rc"
  fi

  if ! _cs_profile_is_set_up "$name"; then
    echo "cs: login completed but no oauthAccount was written in $cfg_dir/.claude.json" >&2
    _cs_login_cleanup "$name" "$cfg_dir" "$created"
    return 1
  fi
  echo "cs: saved isolated login for '$name' (email: $(_cs_profile_email "$name"))"
}

#------------------------------------------------------------------ provider: gcloud

# The active project of the pinned gcloud configuration, or nothing. `gcloud
# config get-value` reports an unset value as the literal text "(unset)" — on
# stdout in older releases, on stderr in newer ones — so filter both rather than
# passing that text on to set-quota-project.
_cs_gcloud_project() {
  local p
  p="$(gcloud config get-value project 2>/dev/null)"
  [[ "$p" == "(unset)" ]] && p=""
  printf '%s' "$p"
}

# Health of one profile's gcloud login. Runs INSIDE the profile.env subshell,
# so CLOUDSDK_CONFIG and GOOGLE_APPLICATION_CREDENTIALS are the profile's own.
# Returns 0 healthy, 1 a real problem, 2 no opinion.
_cs_gcloud_check_here() {
  local name="$1"
  # A profile that does not pin gcloud is not a gcloud problem. Say nothing.
  [[ -n "${CLOUDSDK_CONFIG:-}" ]] || return 2

  local bad=0 accounts count
  accounts="$(gcloud auth list --format='value(account)' 2>/dev/null)"
  count=0
  [[ -n "$accounts" ]] && count="$(printf '%s\n' "$accounts" | grep -c .)"

  if ((count == 0)); then
    echo "  $name — gcloud: NO ACCOUNT in $CLOUDSDK_CONFIG"
    echo "      fix: cs login $name gcloud" >&2
    bad=1
  elif ((count > 1)); then
    echo "  $name — gcloud: $count ACCOUNTS in one profile"
    printf '%s\n' "$accounts" | sed 's/^/        /'
    echo "      A profile holds one account. Delete the wrong one:" >&2
    echo "        cs use $name && gcloud auth revoke <account>" >&2
    bad=1
  else
    echo "  $name — gcloud: $accounts ($(_cs_gcloud_project))"
  fi

  # The second credential. Its absence is invisible to `gcloud auth list` and
  # breaks Terraform and every client library, because a
  # GOOGLE_APPLICATION_CREDENTIALS that names a missing file is an error to
  # those libraries — they do not fall back to any other credential.
  if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" && ! -f "$GOOGLE_APPLICATION_CREDENTIALS" ]]; then
    echo "  $name — gcloud: NO application default credentials"
    echo "      $GOOGLE_APPLICATION_CREDENTIALS does not exist, so Terraform and" >&2
    echo "      the client libraries fail. Fix: cs login $name gcloud" >&2
    bad=1
  fi

  return "$bad"
}

_cs_provider_gcloud_check() {
  local name="$1"
  command -v gcloud >/dev/null 2>&1 || return 2
  [[ -f "$(_cs_profile_env_file "$name")" ]] || return 2
  _cs_with_profile_env "$name" _cs_gcloud_check_here "$name"
}

# Runs INSIDE the profile.env subshell.
_cs_gcloud_login_here() {
  local name="$1"
  shift
  [[ -n "${CLOUDSDK_CONFIG:-}" ]] || {
    echo "cs: profile '$name' does not export CLOUDSDK_CONFIG, so cs cannot tell" >&2
    echo "    gcloud where to write. Add it to the profile.env shown by:" >&2
    echo "      cs env $name" >&2
    return 1
  }
  mkdir -p "$CLOUDSDK_CONFIG" || return 1
  # gcloud keeps its credentials in a file inside this directory, on every
  # platform — there is no keychain here. The directory IS the secret.
  chmod 700 "$CLOUDSDK_CONFIG" 2>/dev/null

  echo "cs: logging gcloud into profile '$name' ($CLOUDSDK_CONFIG)" >&2
  gcloud auth login "$@" || return $?

  # The SECOND credential, and the one people skip. `gcloud auth login` serves
  # the gcloud command itself. This writes application_default_credentials.json,
  # which Terraform, the client libraries, and most SDKs read.
  echo "cs: now the application default credentials (what Terraform reads)" >&2
  gcloud auth application-default login || return $?

  local project
  project="$(_cs_gcloud_project)"
  if [[ -n "$project" ]]; then
    gcloud auth application-default set-quota-project "$project" 2>/dev/null ||
      echo "cs: could not set the quota project to '$project'; set it by hand." >&2
  else
    echo "cs: this profile has no project set. Some APIs reject application" >&2
    echo "    default credentials without a quota project. Set both:" >&2
    echo "      cs use $name" >&2
    echo "      gcloud config set project <project>" >&2
    echo "      gcloud auth application-default set-quota-project <project>" >&2
  fi

  echo "cs: verifying" >&2
  _cs_gcloud_check_here "$name"
}

_cs_provider_gcloud_login() {
  local name="$1"
  shift
  command -v gcloud >/dev/null 2>&1 || {
    echo "cs: the gcloud CLI is not installed (or not in PATH)." >&2
    return 1
  }
  [[ -f "$(_cs_profile_env_file "$name")" ]] || {
    echo "cs: profile '$name' has no profile.env, so cs cannot tell gcloud where" >&2
    echo "    to write. Create one, then run this again:" >&2
    echo "      cs env $name" >&2
    return 1
  }
  _cs_with_profile_env "$name" _cs_gcloud_login_here "$name" "$@"
}

#------------------------------------------------------------------ login dispatcher

# cs login <profile> [provider] [provider args...]
#
# The provider is a bare word in position 2, and everything after it belongs to
# that provider. An argument starting with '-' there is NOT a provider: it is a
# `claude auth login` flag, which is what every `cs login` looked like before
# providers existed. That rule is what keeps `cs login work --claudeai` working.
_cs_login() {
  local name="${1:-}"
  [[ -z "$name" ]] && {
    echo "cs login <profile> [provider] [provider args...]" >&2
    echo "  providers: $(_cs_provider_list)" >&2
    return 1
  }
  shift
  _cs_validate_name "$name" || {
    echo "cs: invalid profile name '$name'" >&2
    return 1
  }

  local provider="claude"
  if [[ -n "${1:-}" && "$1" != -* ]]; then
    provider="$1"
    shift
  fi
  _cs_validate_provider "$provider" || {
    echo "cs: invalid provider '$provider' (lowercase letters, digits, underscore)" >&2
    return 1
  }
  if ! typeset -f "_cs_provider_${provider}_login" >/dev/null 2>&1; then
    echo "cs: unknown provider '$provider'" >&2
    echo "    known providers: $(_cs_provider_list)" >&2
    return 1
  fi

  # Only the claude provider creates the profile. Every other provider logs a
  # tool INTO an existing profile, and needs that profile's profile.env to know
  # where the tool should write.
  if [[ "$provider" != "claude" && ! -d "$(_cs_profile_config_dir "$name")" ]]; then
    echo "cs: profile '$name' is not set up. Run: cs login $name" >&2
    return 1
  fi

  "_cs_provider_${provider}_login" "$name" "$@"
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

  # Drop the OUTGOING profile's env before installing the new one. Without this,
  # `cs use a` then `cs use b` leaves a's CLOUDSDK_CONFIG (or AWS_PROFILE, or
  # KUBECONFIG) pointing at a's identity while the shell claims to be b — the
  # exact cross-contamination this tool exists to prevent.
  _cs_clear_profile_env

  export _CS_PROFILE="$name"
  export CLAUDE_CONFIG_DIR="$cfg_dir"
  # Clear cs's own legacy artifact so it can't override the keychain login.
  unset CLAUDE_CODE_OAUTH_TOKEN

  # Load profile.env BEFORE the override-var check below, so a profile.env that
  # sets ANTHROPIC_API_KEY (or Bedrock/Vertex, or ANTHROPIC_BASE_URL) gets the
  # same warning as one the user exported by hand.
  _cs_load_profile_env "$name"
  local env_rc=$?
  # Non-empty here means profile.env set it, since it was unset a moment ago.
  # Honoring it would defeat the per-profile keychain isolation.
  if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    echo "cs: note — profile.env set CLAUDE_CODE_OAUTH_TOKEN; ignoring it (the keychain login wins)." >&2
    unset CLAUDE_CODE_OAUTH_TOKEN
  fi

  # Re-assert the pin. _cs_load_profile_env rejects a file that EXPORTS these,
  # but the file is sourced, so arbitrary code in it can still assign them (a
  # bare `CLAUDE_CONFIG_DIR=...` updates the already-exported variable). Claiming
  # a pin we no longer hold is the worst outcome available here, so check.
  if [[ "${CLAUDE_CONFIG_DIR:-}" != "$cfg_dir" || "${_CS_PROFILE:-}" != "$name" ]]; then
    echo "cs: note — profile.env moved the pin; restoring it to '$name'." >&2
    export _CS_PROFILE="$name"
    export CLAUDE_CONFIG_DIR="$cfg_dir"
  fi

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

  _cs_warn_note_vars

  # Name what the env file pinned. The whole point is that one command moved
  # more than Claude Code, so the user should be able to see it happen. Only
  # claim success when the load actually succeeded — announcing "applied" right
  # after an error message reads as though the error did not matter.
  ((env_rc == 0 && ${#_cs_env_var_names})) && echo "cs: profile.env applied — ${_cs_env_var_names[*]}"

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

  # The pin above always succeeds, but a refused or failing profile.env must not
  # be swallowed: `cs use work && terraform apply` would otherwise run against
  # whichever cloud identity the shell already carried.
  return "$env_rc"
}

# Run claude under a profile without pinning the shell and without going through
# the `claude` wrapper — `env` executes the real binary, so a `claude` function
# from another plugin is neither consulted nor clobbered. This is the escape
# hatch for anyone who would rather context-switch not own the `claude` name.
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
  # Run in a subshell so the profile's env file reaches the child WITHOUT
  # pinning the caller's shell — `cs run` promises not to change this terminal.
  (
    # Clear the CALLER's profile env first, for the same reason `cs use` does.
    # Running `cs run home` from a shell pinned to `work` otherwise hands the
    # child work's CLOUDSDK_CONFIG while claude runs as home. The common case is
    # worse still: when the target profile has no profile.env of its own,
    # nothing would overwrite the caller's variables at all.
    _cs_clear_profile_env
    # A bad env file is reported, not fatal: claude's own isolation comes from
    # CLAUDE_CONFIG_DIR, which is set below regardless.
    _cs_load_profile_env "$name"
    _cs_warn_note_vars
    _cs_build_scrub_args
    # Keep the child environment internally consistent when the calling shell is
    # already pinned to another profile. Nested shells inherit both variables.
    env "${_cs_scrub[@]}" _CS_PROFILE="$name" CLAUDE_CONFIG_DIR="$cfg_dir" claude "$@"
  )
}

_cs_off() {
  _cs_clear_profile_env
  unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR _CS_PROFILE
  echo "cs: this shell unpinned (profile env cleared)."
}

_cs_list() {
  setopt local_options null_glob
  local root f name marker email envmark found=0 cred=0
  root="$(_cs_profiles_root)"
  for f in "$root"/*; do
    [[ -d "$f" ]] || continue
    found=1
    name="${f:t}"
    marker="  "
    [[ "$name" == "${_CS_PROFILE:-}" ]] && marker="* "
    # Flag profiles that pin other tools too, so `cs list` shows the full scope
    # of what `cs use <name>` will change.
    envmark=""
    [[ -f "$(_cs_profile_env_file "$name")" ]] && envmark=" [+env]"
    if _cs_profile_is_set_up "$name"; then
      email="$(_cs_profile_email "$name")"
      # Only contradict the config when we positively confirmed the credential
      # is gone (rc 1); rc 2 means "couldn't check" and stays silent.
      _cs_profile_has_credential "$name"
      cred=$?
      if ((cred == 1)); then
        echo "${marker}${name} — ${email}${envmark} (no credential — run: cs login $name)"
      else
        echo "${marker}${name} — ${email}${envmark}"
      fi
    else
      echo "${marker}${name} — incomplete${envmark} (run: cs login $name)"
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

# Show a profile's env file: where it lives, and what it sets. Read-only on
# purpose — the file is yours to edit with your own editor.
_cs_env() {
  local name="${1:-}"
  [[ -z "$name" ]] && {
    echo "cs env <name>" >&2
    return 1
  }
  _cs_validate_name "$name" || {
    echo "cs: invalid profile name '$name'" >&2
    return 1
  }
  local cfg_dir f
  cfg_dir="$(_cs_profile_config_dir "$name")"
  [[ -d "$cfg_dir" ]] || {
    echo "cs: profile '$name' is not set up. Run: cs login $name" >&2
    return 1
  }
  f="$(_cs_profile_env_file "$name")"
  echo "$f"
  if [[ -f "$f" ]]; then
    echo ""
    cat "$f"
    return 0
  fi
  echo ""
  echo "(no env file yet — create it with one 'export VAR=value' per line, e.g.)" >&2
  cat >&2 <<EOF

  cat > '$f' <<'ENV'
  export CLOUDSDK_CONFIG="\$HOME/.config/gcloud-profiles/$name"
  export GOOGLE_APPLICATION_CREDENTIALS="\$HOME/.config/gcloud-profiles/$name/application_default_credentials.json"
  export AWS_PROFILE=$name
  export KUBECONFIG="\$HOME/.kube/$name.yaml"
  export GH_CONFIG_DIR="\$HOME/.config/gh-profiles/$name"
ENV
  chmod 600 '$f'
EOF
  return 0
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
    local d svc had_before=0 probed=0
    local -a dirs=("$cfg_dir") leftover_svcs=()
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
      security find-generic-password -s "$svc" >/dev/null 2>&1 && leftover_svcs+=("$svc")
    done
    if ((${#leftover_svcs})); then
      echo "cs: warning — the keychain credential for '$name' is STILL PRESENT after deletion." >&2
      for svc in "${leftover_svcs[@]}"; do
        echo "    Remove it by hand: security delete-generic-password -s '$svc'" >&2
      done
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
    _cs_clear_profile_env
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

  # Ask every provider that has a check hook. A hook returns 0 healthy, 1 a real
  # problem, 2 no opinion — and a profile that does not pin the tool must reach
  # the 2 case and print nothing. Doctor stays quiet about tools you do not use.
  local prov prc
  for name in "${slots[@]}"; do
    [[ -n "$name" ]] || continue
    for prov in "${_CS_PROVIDERS[@]}"; do
      typeset -f "_cs_provider_${prov}_check" >/dev/null 2>&1 || continue
      "_cs_provider_${prov}_check" "$name"
      prc=$?
      ((prc == 1)) && bad=1
    done
  done

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
cs — per-terminal identity switcher for Claude Code and your other CLIs.

Usage:
  cs login <profile> [provider] [provider args...]
                    Log a tool into a profile. The provider defaults to
                    `claude`, so `cs login work` is unchanged. `cs login work
                    gcloud` logs gcloud into that profile instead.
  cs use <name>     Pin THIS shell to a profile: exports CLAUDE_CONFIG_DIR, then
                    sources the profile's profile.env (see below).
  cs env <name>     Print the path and contents of the profile's env file.
  cs run <name> [--] [args...]
                    Run claude once under a profile without pinning the shell.
                    Bypasses the `claude` wrapper entirely, so it is also the
                    way to coexist with another plugin's `claude` function.
  cs off            Unpin this shell (claude falls back to the default config).
  cs list           List profiles; * marks the one pinned in this shell.
  cs doctor         Check each profile's login AND flag any account that is
                    logged into more than one namespace (the thing that causes
                    surprise re-logins). Also runs every provider's check.
  cs current        Print the pin for this shell.
  cs rm <name>      Delete a profile's config, its keychain login, and any
                    legacy plaintext credential files left by an older cs.

One-time setup (per account):
  cs login personal
  cs login work

Daily use:
  cs use work && claude      # terminal A
  cs use personal && claude  # terminal B

Pinning other tools (profile.env):
  Write ~/.claude/profiles/<name>/profile.env with one export per line:

    export CLOUDSDK_CONFIG="$HOME/.config/gcloud-profiles/work"
    export GOOGLE_APPLICATION_CREDENTIALS="$CLOUDSDK_CONFIG/application_default_credentials.json"
    export AWS_PROFILE=work
    export KUBECONFIG="$HOME/.kube/work.yaml"

  `cs use work` then sources it, so the whole terminal is one identity. `cs off`
  and `cs use <other>` unset exactly the names that file exported.

  gcloud is the clearest case. Its active_config and its application default
  credentials are single global files, so `gcloud auth login` in one terminal
  changes the account and the Terraform credentials in every other terminal.
  Point CLOUDSDK_CONFIG at a per-profile directory and that stops. Set
  GOOGLE_APPLICATION_CREDENTIALS too: Go tools such as the Terraform google
  provider may not read CLOUDSDK_CONFIG, but every Google auth library reads
  GOOGLE_APPLICATION_CREDENTIALS.

  Log gcloud in once per profile, and run BOTH commands:

    cs use work
    mkdir -p "$CLOUDSDK_CONFIG"
    gcloud auth login                      # the gcloud command's own credential
    gcloud auth application-default login  # what Terraform and the SDKs read

  Without the second command, GOOGLE_APPLICATION_CREDENTIALS names a file that
  does not exist, and Google auth libraries fail instead of falling back.

  To see which accounts a profile holds, pin it and run `gcloud auth list`. That
  command reads $CLOUDSDK_CONFIG only. Delete a wrong account with
  `gcloud auth revoke <account>` while that profile is pinned. A shell with no
  pin uses the shared ~/.config/gcloud directory instead, where every account
  you log in stays in one list.

Providers:
  A provider is one tool whose login cs can drive into a profile:

    cs login work            # claude, the default
    cs login work claude     # the same, written out
    cs login work gcloud     # gcloud, into this profile's CLOUDSDK_CONFIG

  The provider is a bare word in position 2. Everything after it belongs to
  that provider, so `cs login work --claudeai` still means what it always did.

  `cs login work gcloud` reads CLOUDSDK_CONFIG from the profile's profile.env,
  runs BOTH gcloud logins there, sets the quota project, and then verifies.
  `cs doctor` runs the same verification for every profile that pins gcloud.

  Providers are plain functions, found by name. To add your own, define
  _cs_provider_<tool>_login (and optionally _cs_provider_<tool>_check) in your
  .zshrc, then append the name to _CS_PROVIDERS so `cs doctor` calls it.

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
  - profile.env tracking understands `export VAR=value` lines only. Other shell
    code in that file still runs, but `cs off` cannot undo it.
  - `cs off` UNSETS a tracked name; it does not restore what your shell held
    before `cs use`.
  - cs refuses a profile.env that exports PATH, HOME, IFS, PWD, OLDPWD, SHELL,
    TMPDIR, CLAUDE_CONFIG_DIR, _CS_PROFILE, or _CS_PROFILE_ENV_VARS. The first
    group would break the shell when `cs off` unsets it; the rest are the pin.
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
  env) _cs_env "$@" ;;
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
  # Function-body sentinel used at source time to distinguish this wrapper from
  # a function restored or installed later by the user or another plugin.
  : _CS_CLAUDE_SWITCH_WRAPPER
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
  # Launch with every overriding auth var stripped, so the IDENTITY comes only
  # from the profile's keychain slot — not a stray ANTHROPIC_API_KEY / OAuth
  # token / custom headers / Bedrock / Vertex setting. This does not control
  # where the request goes: ANTHROPIC_BASE_URL is deliberately left intact
  # (see _CS_AUTH_NOTE_VARS), hence the warning. `env … claude` runs the real
  # binary directly, which also avoids re-entering this wrapper.
  _cs_warn_note_vars
  _cs_build_scrub_args
  env "${_cs_scrub[@]}" claude "$@"
}

#==============================================================================
# Source-time diagnostics. Printed once per shell, to stderr, so they never
# pollute a `cs list` or `cs current` someone is parsing. Kept in a function so
# both branches are reachable from the tests.
#==============================================================================

_cs_source_diagnostics() {
  if [[ "$_CS_FOREIGN_CLAUDE" == "saved" ]]; then
    echo "cs: note — a 'claude' function was already defined in this shell; context-switch" >&2
    echo "    replaced it with its profile-aware wrapper. The previous definition is kept" >&2
    echo "    as '_cs_prev_claude' (restore with: functions[claude]=\$functions[_cs_prev_claude])." >&2
    echo "    To bypass the wrapper entirely, use: cs run <name> -- <args>" >&2
    echo "    Silence this notice with: export CS_QUIET=1" >&2
  elif [[ "$_CS_FOREIGN_CLAUDE" == "unsaved" ]]; then
    # We removed their function and could NOT keep a copy. Say exactly that.
    echo "cs: WARNING — a 'claude' function was already defined in this shell and could" >&2
    echo "    NOT be preserved (this zsh does not support 'functions -c'). It has been" >&2
    echo "    REPLACED and the previous definition is LOST for this shell. Re-open a" >&2
    echo "    shell without sourcing context-switch to get it back." >&2
  fi

  # jq is a hard requirement of install.sh, but plugin managers (zinit, oh-my-zsh,
  # sheldon, antidote) source this file directly and never run the installer.
  # Without jq every profile silently reports as 'incomplete' even when it works.
  if ! command -v jq >/dev/null 2>&1; then
    echo "cs: warning — 'jq' not found in PATH. Profile status will read as 'incomplete'" >&2
    echo "    and 'cs doctor' will not run. Install jq (brew install jq / apt install jq)." >&2
  fi
}

# CS_QUIET suppresses the advisory notices for users who have read them once and
# deliberately kept their own `claude` wrapper. The 'unsaved' case is real data
# loss, not an advisory, so it is never silenced.
if [[ -z "${CS_QUIET:-}" || "$_CS_FOREIGN_CLAUDE" == "unsaved" ]]; then
  _cs_source_diagnostics
fi
