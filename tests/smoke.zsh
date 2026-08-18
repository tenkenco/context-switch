#!/usr/bin/env zsh
# context-switch smoke tests.
# Runs in a sandboxed $HOME with a fake claude binary on PATH so no real
# Claude Code state or keychain is touched. Every test is independent — setup
# creates a fresh sandbox, teardown deletes it.
#
# Usage:   ./tests/smoke.zsh
# Exit 0 on all pass, 1 on any failure.

set -u
emulate -L zsh
setopt extended_glob

REPO_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
CS_ZSH="$REPO_DIR/cs.zsh"
[[ -f "$CS_ZSH" ]] || {
  echo "FATAL: cannot find $CS_ZSH" >&2
  exit 1
}

PASS=0
FAIL=0
typeset -a FAILED

#------------------------------------------------------------------- helpers

_pass() {
  PASS=$((PASS + 1))
  echo "  ok  $1"
}
_fail() {
  FAIL=$((FAIL + 1))
  FAILED+=("$1")
  echo "  FAIL $1"
  shift
  for line in "$@"; do echo "       $line"; done
}

assert_contains() {
  local desc="$1" actual="$2" needle="$3"
  if [[ "$actual" == *"$needle"* ]]; then
    _pass "$desc"
  else
    _fail "$desc" "expected to contain: $needle" "actual: $actual"
  fi
}

assert_not_contains() {
  local desc="$1" actual="$2" needle="$3"
  if [[ "$actual" != *"$needle"* ]]; then
    _pass "$desc"
  else
    _fail "$desc" "expected NOT to contain: $needle" "actual: $actual"
  fi
}

assert_eq() {
  local desc="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    _pass "$desc"
  else
    _fail "$desc" "expected: $expected" "actual:   $actual"
  fi
}

assert_not_eq() {
  local desc="$1" actual="$2" unexpected="$3"
  if [[ "$actual" != "$unexpected" ]]; then
    _pass "$desc"
  else
    _fail "$desc" "expected values to differ" "actual: $actual"
  fi
}

assert_file_exists() {
  local desc="$1" file="$2"
  [[ -f "$file" ]] && _pass "$desc" || _fail "$desc" "missing: $file"
}

assert_file_absent() {
  local desc="$1" file="$2"
  [[ ! -e "$file" ]] && _pass "$desc" || _fail "$desc" "should not exist: $file"
}

assert_dir_absent() {
  local desc="$1" dir="$2"
  [[ ! -e "$dir" ]] && _pass "$desc" || _fail "$desc" "should not exist: $dir"
}

#------------------------------------------------------------------- sandbox

# Fake claude binary. Behaviors:
#   auth login   -> writes a profile .claude.json with an oauthAccount whose
#                   email comes from --email (or a default), echoes its argv,
#                   and records whether CLAUDE_CODE_OAUTH_TOKEN leaked in.
#   auth status  -> emits {loggedIn,...} JSON reflecting the config dir's
#                   .claude.json (loggedIn:false when none).
#   anything else-> echoes FAKE_CLAUDE: <argv>.
setup() {
  SANDBOX="$(mktemp -d -t cs-test.XXXXXX)"
  export HOME="$SANDBOX"
  mkdir -p "$HOME/.claude"
  mkdir -p "$SANDBOX/bin"
  cat >"$SANDBOX/bin/claude" <<'SH'
#!/bin/sh
if [ "$1" = "auth" ] && [ "$2" = "login" ]; then
  # Simulate a failed / Ctrl-C'd login: exit non-zero writing no config.
  [ -n "${CS_TEST_LOGIN_FAIL-}" ] && exit 130
  # Simulate a nominally successful login that writes no usable account state.
  [ -n "${CS_TEST_LOGIN_EMPTY-}" ] && exit 0
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN-}" ] && printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" >"${HOME}/.auth-login-token-env"
  all="$*"
  email="login@example.com"
  while [ $# -gt 0 ]; do
    [ "$1" = "--email" ] && { email="$2"; shift; }
    shift
  done
  mkdir -p "$CLAUDE_CONFIG_DIR"
  cat >"$CLAUDE_CONFIG_DIR/.claude.json" <<JSON
{"oauthAccount":{"emailAddress":"$email","organizationUuid":"org-$email"}}
JSON
  printf 'FAKE_CLAUDE_AUTH_LOGIN: %s\n' "$all"
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.claude.json"
  if [ -f "$cfg" ]; then
    email=$(sed -n 's/.*"emailAddress":"\([^"]*\)".*/\1/p' "$cfg")
    printf '{"loggedIn":true,"authMethod":"claude.ai","email":"%s","subscriptionType":"max"}\n' "$email"
  else
    printf '{"loggedIn":false}\n'
  fi
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "logout" ]; then
  rm -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.claude.json"
  printf 'FAKE_CLAUDE_LOGOUT\n'
  exit 0
fi
# record which overriding auth vars were present at launch so scrub is testable
printf 'API=%s TOKEN=%s BEDROCK=%s VERTEX=%s\n' "${ANTHROPIC_API_KEY-}" "${CLAUDE_CODE_OAUTH_TOKEN-}" "${CLAUDE_CODE_USE_BEDROCK-}" "${CLAUDE_CODE_USE_VERTEX-}" >"${HOME}/.claude-launch-env"
printf 'PROFILE=%s CONFIG=%s\n' "${_CS_PROFILE-}" "${CLAUDE_CONFIG_DIR-}" >"${HOME}/.claude-launch-profile"
# record a plain (non-auth) var so profile.env propagation is testable
printf 'TOOLVAR=%s\n' "${CS_TEST_TOOL-}" >"${HOME}/.claude-launch-toolvar"
printf 'FAKE_CLAUDE: %s\n' "$*"
SH
  chmod +x "$SANDBOX/bin/claude"
  export PATH="$SANDBOX/bin:$PATH"

  unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR _CS_PROFILE _CS_PROFILE_ENV_VARS \
    ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX \
    CS_TEST_TOOL CS_TEST_ONE CS_TEST_TWO CS_TEST_GCLOUD_LOGIN_FAIL 2>/dev/null
  unfunction cs claude _cs_prev_claude _cs_validate_name _cs_profiles_root \
    _cs_profile_config_dir _cs_sha256_8 _cs_keychain_service _cs_profile_email \
    _cs_profile_is_set_up _cs_profile_has_credential _cs_keychain_scheme_intact \
    _cs_build_scrub_args _cs_find_legacy_files _cs_warn_note_vars \
    _cs_profile_env_file _cs_parse_env_vars _cs_clear_profile_env \
    _cs_load_profile_env _cs_env _cs_env_find_blocked _cs_env_path_unsafe \
    _cs_source_diagnostics _cs_login _cs_login_cleanup _cs_use _cs_run _cs_off \
    _cs_list _cs_current _cs_rm _cs_doctor _cs_help __cs_restore \
    _cs_validate_provider _cs_provider_list _cs_with_profile_env _cs_profile_pins _cs_export_env_var_names _cs_rm_path_unsafe \
    _cs_provider_gcloud_paths _cs_gcloud_paths_here \
    _cs_provider_claude_login _cs_provider_gcloud_login _cs_provider_gcloud_check \
    _cs_gcloud_login_here _cs_gcloud_check_here _cs_gcloud_project 2>/dev/null
  _CS_KC_SCHEME_CACHE=""
  source "$CS_ZSH" 2>/dev/null
}

teardown() {
  [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
  unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR _CS_PROFILE _CS_PROFILE_ENV_VARS SANDBOX \
    ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX \
    CS_TEST_TOOL CS_TEST_ONE CS_TEST_TWO CS_TEST_GCLOUD_LOGIN_FAIL 2>/dev/null
  PATH="${PATH#*:}"
}

# Create a logged-in profile directly (no claude invocation).
seed_profile() {
  local name="$1" email="${2:-$1@example.com}"
  local cfg_dir="$HOME/.claude/profiles/$name"
  mkdir -p "$cfg_dir"
  cat >"$cfg_dir/.claude.json" <<JSON
{"oauthAccount":{"emailAddress":"$email","organizationUuid":"org-$name"}}
JSON
}

# Write a profile.env for an already-seeded profile. Body is passed verbatim.
seed_profile_env() {
  local name="$1" body="$2"
  local f="$HOME/.claude/profiles/$name/profile.env"
  mkdir -p "${f:h}"
  printf '%s\n' "$body" >"$f"
  chmod 600 "$f"
}

# Install a fake `security` that reports exactly the service names listed in
# $HOME/.kc-present (one per line). Shadows the real macOS binary because the
# sandbox bin comes first on PATH, so these tests behave identically on Linux.
fake_security() {
  : >"$HOME/.kc-present"
  : >"$HOME/.kc-undeletable"
  cat >"$SANDBOX/bin/security" <<'SH'
#!/bin/sh
# usage: security {find,delete}-generic-password -s <service>
cmd="$1"; shift
svc=""
while [ $# -gt 0 ]; do
  [ "$1" = "-s" ] && { svc="$2"; shift; }
  shift
done
case "$cmd" in
  find-generic-password)
    grep -Fxq "$svc" "$HOME/.kc-present" 2>/dev/null && exit 0
    exit 44 ;;
  delete-generic-password)
    if grep -Fxq "$svc" "$HOME/.kc-present" 2>/dev/null; then
      grep -Fxq "$svc" "$HOME/.kc-undeletable" 2>/dev/null && exit 77
      grep -Fxv "$svc" "$HOME/.kc-present" >"$HOME/.kc-present.tmp" 2>/dev/null
      mv "$HOME/.kc-present.tmp" "$HOME/.kc-present"
      exit 0
    fi
    exit 44 ;;
esac
exit 1
SH
  chmod +x "$SANDBOX/bin/security"
}

# Mark a profile as having a stored credential, using the same service name
# cs.zsh derives, so the test binds to the real hashing scheme.
kc_add_profile() {
  _cs_keychain_service "$HOME/.claude/profiles/$1" >>"$HOME/.kc-present"
  echo >>"$HOME/.kc-present"
}

# Create the plaintext credential files a pre-keychain `cs save` left behind.
seed_legacy_files() {
  local name="$1" dir="$HOME/.claude/accounts"
  mkdir -p "$dir"
  printf 'sk-ant-oat01-FAKE\n' >"$dir/$name.token"
  printf '{"emailAddress":"%s@example.com"}\n' "$name" >"$dir/$name.account.json"
  printf '{"claudeAiOauth":{"accessToken":"FAKE","refreshToken":"FAKE"}}\n' >"$dir/$name.json"
}

# Run <code> in a child zsh that has sourced cs.zsh and then dropped every
# single-underscore-prefixed function — reproducing what a reconstructed shell
# snapshot does. Claude Code writes one to ~/.claude/**/shell-snapshots/*.sh and
# sources it for every Bash tool call; it keeps the public `cs`/`claude` (and
# __double_underscore names) but filters _foo, zsh's convention for completion
# functions. That silently removed every _cs_* helper.
#
# Deliberately a CHILD PROCESS: stripping in-process would also delete this
# harness's own _pass/_fail helpers and take the suite down with it.
run_in_snapshot_shell() {
  zsh -c 'source "$1"
    for __f in ${(k)functions}; do
      [[ "$__f" == _[^_]* ]] && unfunction "$__f" 2>/dev/null
    done
    eval "$2"' zsh "$CS_ZSH" "$1" 2>&1
}

#------------------------------------------------------------------- tests

t_validate_name() {
  echo "[validate_name]"
  setup
  local n
  for n in a abc a1 a_b a-b a.b a_-.b XyZ123 long-name_with.dots; do
    if _cs_validate_name "$n"; then _pass "valid: $n"; else _fail "valid: $n" "should accept"; fi
  done
  local bad
  for bad in "" "." ".foo" "-foo" "foo/bar" "../foo" "foo..bar" "a;b" "a b" "/abs" "a/b"; do
    if _cs_validate_name "$bad"; then _fail "invalid: ${bad:-<empty>}" "should reject"; else _pass "invalid: ${bad:-<empty>}"; fi
  done
  teardown
}

t_help() {
  echo "[help]"
  setup
  local out
  out="$(cs help 2>&1)"
  assert_contains "cs help mentions Usage" "$out" "Usage:"
  out="$(cs --help 2>&1)"
  assert_contains "cs --help works" "$out" "Usage:"
  out="$(cs -h 2>&1)"
  assert_contains "cs -h works" "$out" "Usage:"
  out="$(cs 2>&1)"
  assert_contains "cs (no args) shows help" "$out" "Usage:"
  out="$(cs unknown 2>&1)"
  assert_contains "unknown subcommand error" "$out" "unknown subcommand"
  teardown
}

t_sha256_matches_claude_scheme() {
  echo "[keychain: service name = sha256(config dir)[:8]]"
  setup
  # Compute the expected digest with whichever tool _cs_sha256_8 itself uses,
  # so the test doesn't hard-depend on shasum where only sha256sum exists.
  local expect
  if command -v shasum >/dev/null 2>&1; then
    expect="$(printf '%s' "/tmp/x" | shasum -a 256 | cut -c1-8)"
  elif command -v sha256sum >/dev/null 2>&1; then
    expect="$(printf '%s' "/tmp/x" | sha256sum | cut -c1-8)"
  else
    _pass "sha256 tool unavailable — skipped"
    teardown
    return
  fi
  local got
  got="$(_cs_sha256_8 "/tmp/x")"
  assert_eq "_cs_sha256_8 matches sha256 tool" "$got" "$expect"
  local svc
  svc="$(_cs_keychain_service "/tmp/x")"
  assert_eq "service name is well-formed" "$svc" "Claude Code-credentials-$expect"
  teardown
}

t_login_isolated_no_token_leak() {
  echo "[login: isolated, no token leak, writes profile config]"
  setup
  export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-SHOULD-NOT-LEAK"
  local out
  out="$(cs login work --claudeai --email work@corp.com 2>&1)"
  assert_contains "invokes claude auth login" "$out" "FAKE_CLAUDE_AUTH_LOGIN: auth login --claudeai"
  assert_file_absent "auth login did NOT inherit token env" "$HOME/.auth-login-token-env"
  assert_file_exists "profile config written" "$HOME/.claude/profiles/work/.claude.json"
  assert_contains "success reports email" "$out" "work@corp.com"
  teardown
}

t_login_default_args_prefill_email() {
  echo "[login: re-login pre-fills last email]"
  setup
  seed_profile work work@corp.com
  local out
  out="$(cs login work 2>&1)"
  assert_contains "defaults to --claudeai" "$out" "auth login --claudeai"
  assert_contains "pre-fills previous email" "$out" "--email work@corp.com"
  teardown
}

t_use_sets_env_no_token() {
  echo "[use: exports config dir + profile, never a token]"
  setup
  seed_profile personal
  export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-STALE"
  cs use personal >|"$SANDBOX/.out" 2>&1
  local out
  out="$(<"$SANDBOX/.out")"
  assert_contains "reports pin + email" "$out" "personal@example.com"
  assert_eq "_CS_PROFILE set" "${_CS_PROFILE:-}" "personal"
  assert_eq "CLAUDE_CONFIG_DIR exported" "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude/profiles/personal"
  assert_eq "stale token cleared" "${CLAUDE_CODE_OAUTH_TOKEN:-_NONE_}" "_NONE_"
  zsh -c '[[ "$_CS_PROFILE" == "personal" && "$CLAUDE_CONFIG_DIR" == "$HOME/.claude/profiles/personal" ]]'
  assert_eq "env exported for child shells" "$?" "0"
  teardown
}

t_use_invalid_and_missing() {
  echo "[use: invalid + missing handled]"
  setup
  local out
  out="$(cs use ../foo 2>&1)"
  assert_contains "rejects traversal" "$out" "invalid profile name"
  out="$(cs use 2>&1)"
  assert_contains "no-arg usage" "$out" "cs use"
  out="$(cs use ghost 2>&1)"
  assert_contains "missing profile" "$out" "not set up"
  teardown
}

t_off_clears_env() {
  echo "[off: clears env]"
  setup
  seed_profile personal
  cs use personal >/dev/null 2>&1
  cs off >/dev/null 2>&1
  assert_eq "_CS_PROFILE unset" "${_CS_PROFILE:-_NONE_}" "_NONE_"
  assert_eq "CLAUDE_CONFIG_DIR unset" "${CLAUDE_CONFIG_DIR:-_NONE_}" "_NONE_"
  assert_eq "CLAUDE_CODE_OAUTH_TOKEN unset" "${CLAUDE_CODE_OAUTH_TOKEN:-_NONE_}" "_NONE_"
  teardown
}

t_list() {
  echo "[list]"
  setup
  local out
  out="$(cs list 2>&1)"
  assert_contains "empty list" "$out" "no profiles"
  seed_profile personal
  seed_profile work work@corp.com
  mkdir -p "$HOME/.claude/profiles/halfbaked" # dir, no login
  out="$(cs list 2>&1)"
  assert_contains "shows personal email" "$out" "personal@example.com"
  assert_contains "shows work email" "$out" "work@corp.com"
  assert_contains "incomplete flagged" "$out" "incomplete"
  cs use personal >/dev/null 2>&1
  out="$(cs list 2>&1)"
  assert_contains "pinned gets * marker" "$out" "* personal"
  assert_contains "non-pinned no marker" "$out" "  work"
  teardown
}

t_current() {
  echo "[current]"
  setup
  seed_profile personal
  local out
  out="$(cs current 2>&1)"
  assert_contains "none when unset" "$out" "none"
  cs use personal >/dev/null 2>&1
  out="$(cs current 2>&1)"
  assert_eq "reports pin" "$out" "personal"
  unset _CS_PROFILE
  out="$(cs current 2>&1)"
  assert_contains "warns on config-set-name-unknown" "$out" "name unknown"
  teardown
}

t_resource_preserves_profile() {
  echo "[re-source: preserves active pin]"
  setup
  seed_profile personal
  cs use personal >/dev/null 2>&1
  source "$CS_ZSH"
  assert_eq "_CS_PROFILE preserved" "${_CS_PROFILE:-_NONE_}" "personal"
  teardown
}

t_rm() {
  echo "[rm: prompt, deletes config, guards traversal]"
  setup
  # traversal guard: plant a sentinel a naive rm would nuke
  mkdir -p "$HOME/.claude/profiles"
  echo "keep" >"$HOME/.claude/sentinel"
  local out
  out="$(cs rm ../sentinel 2>&1)"
  assert_contains "rejects traversal" "$out" "invalid profile name"
  assert_file_exists "sentinel survived" "$HOME/.claude/sentinel"
  out="$(cs rm ghost 2>&1)"
  assert_contains "missing profile" "$out" "no such profile"

  seed_profile personal
  out="$(printf 'n\n' | cs rm personal 2>&1)"
  assert_contains "declined aborts" "$out" "aborted"
  assert_file_exists "config kept after abort" "$HOME/.claude/profiles/personal/.claude.json"

  printf 'y\n' | cs rm personal >/dev/null 2>&1
  assert_dir_absent "config removed on confirm" "$HOME/.claude/profiles/personal"
  teardown
}

t_rm_legacy_credentials() {
  echo "[rm: deletes legacy plaintext credential files]"
  setup
  local acct="$HOME/.claude/accounts" out

  # Profile with BOTH a config dir and legacy files.
  seed_profile personal
  seed_legacy_files personal
  out="$(printf 'y\n' | cs rm personal 2>&1)"
  assert_contains "warns about legacy files" "$out" "legacy plaintext credential files"
  assert_dir_absent "config removed" "$HOME/.claude/profiles/personal"
  assert_file_absent "token removed" "$acct/personal.token"
  assert_file_absent "account snapshot removed" "$acct/personal.account.json"
  assert_file_absent "credential dump removed" "$acct/personal.json"

  # Legacy files only, no config dir — the upgrade case that was unremovable.
  seed_legacy_files orphan
  out="$(printf 'y\n' | cs rm orphan 2>&1)"
  assert_not_contains "legacy-only profile is removable" "$out" "no such profile"
  assert_file_absent "orphan token removed" "$acct/orphan.token"
  assert_file_absent "orphan dump removed" "$acct/orphan.json"

  # Declining must not delete credentials.
  seed_legacy_files keep
  out="$(printf 'n\n' | cs rm keep 2>&1)"
  assert_contains "declined aborts" "$out" "aborted"
  assert_file_exists "token kept after abort" "$acct/keep.token"

  # A name with no config dir and no legacy files is still an error.
  out="$(cs rm ghost 2>&1)"
  assert_contains "still errors on unknown profile" "$out" "no such profile"

  # Other profiles' files are untouched.
  seed_legacy_files other
  seed_profile personal
  printf 'y\n' | cs rm personal >/dev/null 2>&1
  assert_file_exists "other profile's token untouched" "$acct/other.token"
  teardown
}

t_foreign_claude_function_preserved() {
  echo "[wrapper: a pre-existing 'claude' function is preserved, not destroyed]"
  setup
  # Simulate another plugin (or the user's zshrc) owning `claude`.
  unfunction claude _cs_prev_claude 2>/dev/null
  claude() { echo "OTHER_PLUGIN_WRAPPER"; }
  # Source in THIS shell (not a $( ) subshell) so the function stash and the
  # preserved function actually persists; capture stderr via a file instead.
  local out err="$HOME/.src-err"
  source "$CS_ZSH" 2>"$err" >/dev/null
  out="$(cat "$err")"
  assert_contains "warns about the collision" "$out" "'claude' function was already defined"
  assert_contains "names the escape hatch" "$out" "cs run"
  local prev
  prev="$(_cs_prev_claude 2>&1)"
  assert_eq "previous definition preserved" "$prev" "OTHER_PLUGIN_WRAPPER"

  # Re-sourcing over our OWN wrapper must not warn or stash again.
  source "$CS_ZSH" 2>"$err" >/dev/null
  out="$(cat "$err")"
  assert_not_contains "no warning when replacing our own wrapper" "$out" "already defined"

  # Restoring the foreign function makes it foreign again. A later re-source
  # must preserve and report it instead of trusting stale ownership state.
  functions -c _cs_prev_claude claude
  unfunction _cs_prev_claude 2>/dev/null
  source "$CS_ZSH" 2>"$err" >/dev/null
  out="$(cat "$err")"
  assert_contains "restored foreign wrapper detected on re-source" "$out" "already defined"
  prev="$(_cs_prev_claude 2>&1)"
  assert_eq "restored wrapper preserved again" "$prev" "OTHER_PLUGIN_WRAPPER"
  teardown
}

t_run_subcommand() {
  echo "[run: one-shot profile launch that bypasses the wrapper]"
  setup
  seed_profile personal
  local out
  out="$(cs run personal -- --version 2>&1)"
  assert_contains "invokes the real binary" "$out" "FAKE_CLAUDE: --version"
  assert_eq "shell not pinned by run" "${_CS_PROFILE:-_NONE_}" "_NONE_"
  assert_eq "config dir not exported by run" "${CLAUDE_CONFIG_DIR:-_NONE_}" "_NONE_"

  # Args should reach claude without the '--' being required.
  out="$(cs run personal --version 2>&1)"
  assert_contains "'--' is optional" "$out" "FAKE_CLAUDE: --version"

  # A one-shot run from an already-pinned shell must present one coherent
  # profile to Claude and to any nested shell it launches.
  seed_profile work
  cs use personal >/dev/null 2>&1
  out="$(cs run work -- hi 2>&1)"
  assert_contains "run from pinned shell still invokes Claude" "$out" "FAKE_CLAUDE: hi"
  local launched
  launched="$(<"$HOME/.claude-launch-profile")"
  assert_eq "child profile matches run target" "$launched" \
    "PROFILE=work CONFIG=$HOME/.claude/profiles/work"
  assert_eq "calling shell keeps its pin" "${_CS_PROFILE:-}" "personal"
  assert_eq "calling shell keeps its config" "${CLAUDE_CONFIG_DIR:-}" \
    "$HOME/.claude/profiles/personal"

  out="$(cs run ../evil 2>&1)"
  assert_contains "validates the name" "$out" "invalid profile name"
  out="$(cs run ghost 2>&1)"
  assert_contains "rejects unknown profile" "$out" "is not set up"

  # It must ignore a foreign `claude` function entirely.
  claude() { echo "SHOULD_NOT_RUN"; }
  out="$(cs run personal -- hi 2>&1)"
  assert_not_contains "does not call a shell function" "$out" "SHOULD_NOT_RUN"
  teardown
}

t_doctor_needs_real_binary() {
  echo "[doctor: detects a missing CLI even though cs defines claude()]"
  setup
  seed_profile personal
  # Drop the fake binary AND narrow PATH: the developer running these tests very
  # likely has a real claude installed, which would otherwise still be found.
  local saved_path="$PATH"
  rm -f "$SANDBOX/bin/claude"
  PATH="$SANDBOX/bin:/usr/bin:/bin"
  hash -r 2>/dev/null
  local out rc
  out="$(cs doctor 2>&1)"
  rc=$?
  PATH="$saved_path"
  hash -r 2>/dev/null
  assert_contains "reports the CLI as missing" "$out" "needs the claude CLI"
  assert_eq "exits non-zero" "$rc" "1"
  teardown
}

t_credential_missing_is_reported() {
  echo "[list/use: config says logged in but no credential is stored]"
  setup
  fake_security
  seed_profile personal
  seed_profile work
  # 'work' has a real slot; 'personal' does not — the legacy-upgrade shape,
  # where an older cs patched oauthAccount in cosmetically.
  kc_add_profile work

  local out
  out="$(cs list 2>&1)"
  assert_contains "flags the credential-less profile" "$out" "personal — personal@example.com (no credential"
  assert_not_contains "leaves the healthy profile alone" "$out" "work — work@example.com (no credential"

  out="$(cs use personal 2>&1)"
  assert_contains "cs use warns too" "$out" "no credential is stored"
  out="$(cs use work 2>&1)"
  assert_contains "healthy profile pins normally" "$out" "Run 'claude' to launch"

  # When NO profile has a slot we cannot distinguish "scheme changed" from
  # "genuinely missing", so cs must stay quiet rather than cry wolf.
  : >"$HOME/.kc-present"
  _CS_KC_SCHEME_CACHE=""
  out="$(cs list 2>&1)"
  assert_not_contains "silent when the scheme looks unreadable" "$out" "no credential"
  teardown
}

t_login_abort_cleans_up() {
  echo "[login: an aborted login leaves no phantom profile]"
  setup
  local out
  local rc
  out="$(CS_TEST_LOGIN_FAIL=1 cs login aborted-login 2>&1)"
  rc=$?
  assert_dir_absent "no phantom profile dir" "$HOME/.claude/profiles/aborted-login"
  # An aborted login must not look successful to `cs login x && ...`.
  assert_not_eq "aborted login does not return 0" "$rc" "0"
  assert_eq "aborted login propagates the failure code" "$rc" "130"
  out="$(cs list 2>&1)"
  assert_contains "list stays clean" "$out" "(no profiles"

  out="$(CS_TEST_LOGIN_EMPTY=1 cs login empty-login 2>&1)"
  rc=$?
  assert_contains "empty successful login is rejected" "$out" "no oauthAccount"
  assert_not_eq "empty login does not return 0" "$rc" "0"
  assert_dir_absent "empty successful login is cleaned up" \
    "$HOME/.claude/profiles/empty-login"

  # An existing, already-working profile must survive a failed re-login.
  seed_profile personal
  CS_TEST_LOGIN_FAIL=1 cs login personal >/dev/null 2>&1
  assert_file_exists "existing profile untouched" "$HOME/.claude/profiles/personal/.claude.json"
  teardown
}

t_foreign_claude_unsaved_is_reported_honestly() {
  echo "[wrapper: an unpreservable foreign function is reported as LOST, not kept]"
  setup
  # The 'unsaved' branch fires only where `functions -c` is unavailable, which
  # we cannot produce on a supported zsh — drive the diagnostics directly so
  # both branches are covered rather than assumed.
  local out err="$HOME/.diag-err"
  _CS_FOREIGN_CLAUDE=unsaved
  _cs_source_diagnostics 2>"$err" >/dev/null
  out="$(cat "$err")"
  assert_contains "says it could not preserve" "$out" "NOT be preserved"
  assert_contains "says the definition is lost" "$out" "LOST"
  assert_not_contains "does not claim a backup exists" "$out" "is kept"
  assert_not_contains "does not offer a bogus restore command" "$out" "_cs_prev_claude]"

  # The 'saved' branch must still promise a backup.
  _CS_FOREIGN_CLAUDE=saved
  _cs_source_diagnostics 2>"$err" >/dev/null
  out="$(cat "$err")"
  assert_contains "saved branch promises the copy" "$out" "kept"
  assert_contains "saved branch names the restore command" "$out" "_cs_prev_claude"

  # Real data loss is never silenced by CS_QUIET; the advisory is.
  unfunction claude _cs_prev_claude 2>/dev/null
  claude() { echo "OTHER_PLUGIN_WRAPPER"; }
  CS_QUIET=1 source "$CS_ZSH" 2>"$err" >/dev/null
  out="$(cat "$err")"
  assert_not_contains "CS_QUIET silences the advisory" "$out" "already defined"
  assert_eq "but the function is still preserved" "$(_cs_prev_claude 2>&1)" "OTHER_PLUGIN_WRAPPER"
  teardown
}

t_base_url_warned_on_every_launch_path() {
  echo "[base-url: warned wherever claude is launched, not just cs use]"
  setup
  seed_profile personal
  export ANTHROPIC_BASE_URL="https://gateway.example.invalid"
  local out
  out="$(cs use personal 2>&1)"
  assert_contains "cs use warns" "$out" "ANTHROPIC_BASE_URL is set"
  out="$(cs run personal -- hi 2>&1)"
  assert_contains "cs run warns" "$out" "ANTHROPIC_BASE_URL is set"
  # Pin in THIS shell (not a $( ) subshell) so the wrapper sees _CS_PROFILE and
  # takes the pinned branch rather than the unpinned passthrough.
  cs use personal >/dev/null 2>&1
  out="$(claude hi 2>&1)"
  assert_contains "the claude wrapper warns" "$out" "ANTHROPIC_BASE_URL is set"

  # It is a note, not a block: the launch still happens, and the var survives.
  assert_contains "launch still proceeds" "$out" "FAKE_CLAUDE: hi"
  assert_eq "base url not stripped from the shell" "$ANTHROPIC_BASE_URL" \
    "https://gateway.example.invalid"

  unset ANTHROPIC_BASE_URL
  out="$(cs run personal -- hi 2>&1)"
  assert_not_contains "silent when unset" "$out" "ANTHROPIC_BASE_URL"
  teardown
}

t_rm_reports_exact_leftover_service() {
  echo "[rm: reports the exact keychain service that survived deletion]"
  setup
  fake_security
  local target="$HOME/profile-target" cfg_dir="$HOME/.claude/profiles/personal"
  mkdir -p "$target" "$HOME/.claude/profiles"
  ln -s "$target" "$cfg_dir"
  local literal_svc canonical_svc
  literal_svc="$(_cs_keychain_service "$cfg_dir")"
  canonical_svc="$(_cs_keychain_service "${cfg_dir:A}")"
  assert_not_eq "symlink produces distinct keychain services" "$literal_svc" "$canonical_svc"
  printf '%s\n' "$literal_svc" >"$HOME/.kc-present"
  printf '%s\n' "$literal_svc" >"$HOME/.kc-undeletable"

  local out
  out="$(printf 'y\n' | cs rm personal 2>&1)"
  assert_contains "warning names surviving literal service" "$out" \
    "security delete-generic-password -s '$literal_svc'"
  assert_not_contains "warning does not name absent canonical service" "$out" \
    "security delete-generic-password -s '$canonical_svc'"
  teardown
}

t_installer() {
  echo "[install.sh: idempotency and commented-out source lines]"
  setup
  local rc_file="$HOME/.zshrc" out
  : >"$rc_file"

  out="$(bash "$REPO_DIR/install.sh" 2>&1)"
  assert_contains "reports install" "$out" "installed"
  local n
  n="$(grep -c "source \"$REPO_DIR/cs.zsh\"" "$rc_file")"
  assert_eq "source line written once" "$n" "1"

  out="$(bash "$REPO_DIR/install.sh" 2>&1)"
  assert_contains "second run is a no-op" "$out" "already installed"
  n="$(grep -c "source \"$REPO_DIR/cs.zsh\"" "$rc_file")"
  assert_eq "still only one source line" "$n" "1"

  # A commented-out line is NOT an installation. This used to report
  # "already installed" and change nothing, leaving cs unloadable.
  printf '# source "%s/cs.zsh"\n' "$REPO_DIR" >"$rc_file"
  out="$(bash "$REPO_DIR/install.sh" 2>&1)"
  assert_not_contains "commented line is not an install" "$out" "already installed"
  n="$(grep -c "^source \"$REPO_DIR/cs.zsh\"" "$rc_file")"
  assert_eq "active line added" "$n" "1"

  # Indented comments too.
  printf '   #   source "%s/cs.zsh"\n' "$REPO_DIR" >"$rc_file"
  out="$(bash "$REPO_DIR/install.sh" 2>&1)"
  assert_not_contains "indented comment is not an install" "$out" "already installed"
  teardown
}

t_rm_pinned_clears_env() {
  echo "[rm: removing pinned profile clears env]"
  setup
  seed_profile personal
  cs use personal >/dev/null 2>&1
  printf 'y\n' | cs rm personal >/dev/null 2>&1
  assert_eq "_CS_PROFILE cleared" "${_CS_PROFILE:-_NONE_}" "_NONE_"
  assert_eq "CLAUDE_CONFIG_DIR cleared" "${CLAUDE_CONFIG_DIR:-_NONE_}" "_NONE_"
  teardown
}

t_profile_env_applied_on_use() {
  echo "[profile.env: applied and tracked on use]"
  setup
  seed_profile personal
  seed_profile_env personal 'export CS_TEST_ONE=one
export CS_TEST_TWO="two"'
  # Redirect rather than capture: $(...) is a subshell, so exports made by
  # `cs use` would never reach this shell and every assertion below would lie.
  cs use personal >|"$SANDBOX/.out" 2>&1
  local out
  out="$(<"$SANDBOX/.out")"
  assert_contains "reports what it applied" "$out" "profile.env applied"
  assert_contains "names the first var" "$out" "CS_TEST_ONE"
  assert_contains "names the second var" "$out" "CS_TEST_TWO"
  assert_eq "first var exported" "${CS_TEST_ONE:-}" "one"
  assert_eq "second var exported" "${CS_TEST_TWO:-}" "two"
  assert_eq "tracked names recorded" "${_CS_PROFILE_ENV_VARS:-}" "CS_TEST_ONE CS_TEST_TWO"
  zsh -c '[[ "$CS_TEST_ONE" == "one" ]]'
  assert_eq "vars reach child shells" "$?" "0"
  teardown
}

t_profile_env_swapped_between_profiles() {
  echo "[profile.env: switching profiles does not leak the old one]"
  setup
  seed_profile personal
  seed_profile work work@corp.com
  seed_profile_env personal 'export CS_TEST_ONE=personal'
  seed_profile_env work 'export CS_TEST_TWO=work'
  cs use personal >/dev/null 2>&1
  assert_eq "personal var set" "${CS_TEST_ONE:-}" "personal"
  cs use work >/dev/null 2>&1
  assert_eq "personal var gone after switch" "${CS_TEST_ONE:-_NONE_}" "_NONE_"
  assert_eq "work var set" "${CS_TEST_TWO:-}" "work"
  assert_eq "tracked names replaced" "${_CS_PROFILE_ENV_VARS:-}" "CS_TEST_TWO"
  # A profile with no env file must still clear the previous profile's vars.
  seed_profile bare bare@example.com
  cs use bare >/dev/null 2>&1
  assert_eq "work var gone after bare profile" "${CS_TEST_TWO:-_NONE_}" "_NONE_"
  assert_eq "tracking cleared" "${_CS_PROFILE_ENV_VARS:-_NONE_}" "_NONE_"
  teardown
}

t_profile_env_cleared_on_off_and_rm() {
  echo "[profile.env: cleared by off, deleted by rm]"
  setup
  seed_profile personal
  seed_profile_env personal 'export CS_TEST_ONE=one'
  cs use personal >/dev/null 2>&1
  cs off >/dev/null 2>&1
  assert_eq "off unsets the var" "${CS_TEST_ONE:-_NONE_}" "_NONE_"
  assert_eq "off clears tracking" "${_CS_PROFILE_ENV_VARS:-_NONE_}" "_NONE_"

  cs use personal >/dev/null 2>&1
  printf 'y\n' | cs rm personal >/dev/null 2>&1
  assert_file_absent "rm deletes the env file" "$HOME/.claude/profiles/personal/profile.env"
  assert_eq "rm unsets the var" "${CS_TEST_ONE:-_NONE_}" "_NONE_"
  assert_eq "rm clears tracking" "${_CS_PROFILE_ENV_VARS:-_NONE_}" "_NONE_"
  teardown
}

t_profile_env_tracks_despite_failing_last_line() {
  echo "[profile.env: a failing last line must not strand exported vars]"
  setup
  seed_profile personal
  # `source` returns the status of the file's LAST command, so this ordinary
  # trailing guard makes the whole load return non-zero — with CS_TEST_ONE and
  # CS_TEST_TWO already exported.
  seed_profile_env personal 'export CS_TEST_ONE=one
export CS_TEST_TWO=two
[[ -d /no/such/directory ]] && export CS_TEST_TOOL=three'
  cs use personal >|"$SANDBOX/.out" 2>&1
  local out
  out="$(<"$SANDBOX/.out")"
  assert_eq "vars were exported" "${CS_TEST_ONE:-}" "one"
  # The trailing conditional does not start with `export`, so it falls outside
  # the documented contract and is not tracked. The plain exports above it are —
  # that is the regression this test guards.
  assert_eq "plain exports tracked anyway" "${_CS_PROFILE_ENV_VARS:-}" "CS_TEST_ONE CS_TEST_TWO"
  assert_contains "reports the failing file" "$out" "returned a non-zero status"
  assert_not_contains "does not claim success" "$out" "profile.env applied"
  cs off >/dev/null 2>&1
  assert_eq "off clears the first" "${CS_TEST_ONE:-_NONE_}" "_NONE_"
  assert_eq "off clears the second" "${CS_TEST_TWO:-_NONE_}" "_NONE_"
  teardown
}

t_profile_env_refuses_blocked_names() {
  echo "[profile.env: refuses names that would break the shell or the pin]"
  setup
  seed_profile personal
  seed_profile_env personal 'export CS_TEST_ONE=one
export PATH="/nowhere:$PATH"'
  cs use personal >|"$SANDBOX/.out" 2>&1
  local out saved_path="$PATH"
  out="$(<"$SANDBOX/.out")"
  assert_contains "names the offending variable" "$out" "it sets PATH"
  assert_eq "nothing from the file applied" "${CS_TEST_ONE:-_NONE_}" "_NONE_"
  assert_eq "nothing tracked" "${_CS_PROFILE_ENV_VARS:-_NONE_}" "_NONE_"
  assert_eq "PATH untouched" "$PATH" "$saved_path"
  assert_eq "still pinned" "${_CS_PROFILE:-}" "personal"

  # The pin variables are blocked for the same reason.
  seed_profile_env personal 'export CLAUDE_CONFIG_DIR=/tmp/elsewhere'
  cs use personal >|"$SANDBOX/.out" 2>&1
  out="$(<"$SANDBOX/.out")"
  assert_contains "blocks the pin variable" "$out" "it sets CLAUDE_CONFIG_DIR"
  assert_eq "config dir still correct" "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude/profiles/personal"
  teardown
}

t_profile_env_pin_survives_bare_assignment() {
  echo "[profile.env: a bare assignment cannot move the pin]"
  setup
  seed_profile personal
  # No `export`, so the blocked-name parser does not see it — but the variable
  # is already exported, so the assignment still changes it.
  seed_profile_env personal 'CLAUDE_CONFIG_DIR=/tmp/elsewhere'
  cs use personal >|"$SANDBOX/.out" 2>&1
  local out
  out="$(<"$SANDBOX/.out")"
  assert_contains "reports the correction" "$out" "moved the pin"
  assert_eq "config dir restored" "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude/profiles/personal"
  assert_eq "profile restored" "${_CS_PROFILE:-}" "personal"
  teardown
}

t_profile_env_use_reports_failure_status() {
  echo "[profile.env: cs use exits non-zero when the env file is refused]"
  setup
  seed_profile personal
  seed_profile_env personal 'export CS_TEST_ONE=one'
  cs use personal >/dev/null 2>&1
  assert_eq "healthy file exits 0" "$?" "0"
  chmod 666 "$HOME/.claude/profiles/personal/profile.env"
  cs use personal >/dev/null 2>&1
  assert_eq "refused file exits non-zero" "$?" "1"
  teardown
}

t_profile_env_symlink_permissions_checked() {
  echo "[profile.env: the writability guard follows a symlink]"
  setup
  seed_profile personal
  local target="$SANDBOX/exposed.env"
  printf 'export CS_TEST_ONE=one\n' >"$target"
  chmod 666 "$target"
  ln -s "$target" "$HOME/.claude/profiles/personal/profile.env"
  cs use personal >|"$SANDBOX/.out" 2>&1
  local out
  out="$(<"$SANDBOX/.out")"
  assert_contains "refuses the symlinked file" "$out" "group- or world-writable"
  assert_eq "var not exported" "${CS_TEST_ONE:-_NONE_}" "_NONE_"
  teardown
}

t_profile_env_refuses_writable_directory() {
  echo "[profile.env: refuses a profile directory others can write]"
  setup
  seed_profile personal
  # The FILE is immaculate. The DIRECTORY is not, so an attacker can delete the
  # file and drop in their own 0600 copy that passes every check on the file.
  seed_profile_env personal 'export CS_TEST_ONE=attacker'
  chmod 777 "$HOME/.claude/profiles/personal"
  cs use personal >|"$SANDBOX/.out" 2>&1
  local out
  out="$(<"$SANDBOX/.out")"
  assert_contains "explains the directory is unsafe" "$out" "its directory"
  assert_contains "names the permission problem" "$out" "group- or world-writable"
  assert_eq "nothing from the file applied" "${CS_TEST_ONE:-_NONE_}" "_NONE_"
  assert_eq "still pinned" "${_CS_PROFILE:-}" "personal"
  chmod 700 "$HOME/.claude/profiles/personal"
  cs use personal >/dev/null 2>&1
  assert_eq "loads once the directory is fixed" "${CS_TEST_ONE:-}" "attacker"
  teardown
}

t_profile_env_clear_ignores_blocked_names() {
  echo "[profile.env: cs off never unsets a protected name]"
  setup
  seed_profile personal
  # _CS_PROFILE_ENV_VARS is exported, so it can reach this shell from a parent
  # process or a stale session rather than from a file cs parsed. Honoring a
  # PATH entry in it would leave a shell that cannot run a single command.
  export _CS_PROFILE_ENV_VARS="PATH HOME CS_TEST_ONE"
  export CS_TEST_ONE=one
  local saved_path="$PATH"
  cs off >/dev/null 2>&1
  assert_eq "PATH survives" "$PATH" "$saved_path"
  assert_not_eq "HOME survives" "${HOME:-}" ""
  assert_eq "the ordinary name is still cleared" "${CS_TEST_ONE:-_NONE_}" "_NONE_"
  assert_eq "tracking cleared" "${_CS_PROFILE_ENV_VARS:-_NONE_}" "_NONE_"
  teardown
}

t_profile_env_tracks_multiple_exports_per_line() {
  echo "[profile.env: two exports on one line are both tracked]"
  setup
  seed_profile personal
  seed_profile_env personal 'export CS_TEST_ONE=one CS_TEST_TWO=two'
  cs use personal >/dev/null 2>&1
  assert_eq "both applied" "${CS_TEST_ONE:-}/${CS_TEST_TWO:-}" "one/two"
  assert_eq "both tracked" "${_CS_PROFILE_ENV_VARS:-}" "CS_TEST_ONE CS_TEST_TWO"
  cs off >/dev/null 2>&1
  assert_eq "both cleared" "${CS_TEST_ONE:-_NONE_}/${CS_TEST_TWO:-_NONE_}" "_NONE_/_NONE_"

  # A QUOTED line with two candidates is ambiguous: cs cannot tell a real name
  # from text inside a quoted value without implementing shell quoting. Guessing
  # the first one was a security hole, not just an incomplete feature — see
  # t_profile_env_quoted_multi_cannot_smuggle_blocked_name. Refuse instead.
  teardown
  setup
  seed_profile personal
  seed_profile_env personal 'export CS_TEST_ONE="a CS_TEST_TWO=decoy"'
  cs use personal >|"$SANDBOX/.out" 2>&1
  local out
  out="$(<"$SANDBOX/.out")"
  assert_contains "refuses the ambiguous line" "$out" "cannot read the variable name"
  assert_contains "says how to fix it" "$out" "must set exactly one variable"
  assert_eq "nothing applied" "${CS_TEST_ONE:-_NONE_}" "_NONE_"

  # A quoted line yielding ZERO readable names is just as uncertain. It exports
  # a variable cs cannot see, so cs could never unset it on the next `cs use`.
  teardown
  setup
  seed_profile personal
  seed_profile_env personal 'export "CS_TEST_ONE"=leaks'
  cs use personal >|"$SANDBOX/.out" 2>&1
  out="$(<"$SANDBOX/.out")"
  assert_contains "refuses an unreadable quoted name" "$out" "cannot read the variable name"
  assert_eq "the invisible export never applied" "${CS_TEST_ONE:-_NONE_}" "_NONE_"
  assert_not_contains "does not claim success" "$out" "profile.env applied"
  teardown
}

t_profile_env_quoted_multi_cannot_smuggle_blocked_name() {
  echo "[profile.env: a quoted line cannot smuggle a blocked name past the check]"
  setup
  seed_profile personal
  # The blocked-name check runs on parsed names. A parser that kept only the
  # FIRST name on a quoted line let PATH through untracked and unchecked: the
  # file was sourced and the shell was left unable to run any command.
  seed_profile_env personal 'export CS_TEST_ONE="yes" PATH="/nowhere"'
  local saved_path="$PATH"
  cs use personal >|"$SANDBOX/.out" 2>&1
  local out
  out="$(<"$SANDBOX/.out")"
  assert_contains "refuses the file" "$out" "cannot read the variable name"
  assert_eq "PATH untouched" "$PATH" "$saved_path"
  assert_eq "the shell can still run commands" "$(command -v env >/dev/null && echo yes || echo no)" "yes"
  assert_eq "nothing applied" "${CS_TEST_ONE:-_NONE_}" "_NONE_"
  assert_not_contains "does not claim success" "$out" "profile.env applied"
  teardown
}

t_profile_env_survives_hostile_ifs() {
  echo "[profile.env: a bare IFS assignment cannot strand the cleanup]"
  setup
  seed_profile personal
  # `export IFS=` is blocked, but a BARE assignment is invisible to the parser
  # and still changes the shell. cs off must split its own record regardless.
  seed_profile_env personal 'export CS_TEST_ONE=one
export CS_TEST_TWO=two
IFS=,'
  local saved_ifs="$IFS"
  cs use personal >|"$SANDBOX/.out" 2>&1
  local out
  out="$(<"$SANDBOX/.out")"
  assert_eq "both applied" "${CS_TEST_ONE:-}/${CS_TEST_TWO:-}" "one/two"
  assert_eq "IFS restored in the caller's shell" "$IFS" "$saved_ifs"
  assert_contains "says it restored IFS" "$out" "changed IFS"
  cs off >/dev/null 2>&1
  assert_eq "first cleared" "${CS_TEST_ONE:-_NONE_}" "_NONE_"
  assert_eq "second cleared" "${CS_TEST_TWO:-_NONE_}" "_NONE_"
  assert_eq "shell fully unpinned" "${_CS_PROFILE:-_NONE_}" "_NONE_"
  teardown
}

t_profile_env_bare_path_assignment_restored() {
  echo "[profile.env: a bare PATH assignment is restored, not left broken]"
  setup
  seed_profile personal
  seed_profile_env personal 'export CS_TEST_ONE=one
PATH=/nowhere'
  local saved_path="$PATH"
  cs use personal >|"$SANDBOX/.out" 2>&1
  local out
  out="$(<"$SANDBOX/.out")"
  assert_eq "PATH restored" "$PATH" "$saved_path"
  assert_contains "says it restored PATH" "$out" "changed PATH"
  assert_eq "the ordinary export still applied" "${CS_TEST_ONE:-}" "one"
  teardown
}

t_profile_env_tracking_survives_self_unset() {
  echo "[profile.env: a file cannot disable its own cleanup]"
  setup
  seed_profile personal
  seed_profile_env personal 'export CS_TEST_ONE=one
export CS_TEST_TWO=two
unset _CS_PROFILE_ENV_VARS'
  cs use personal >/dev/null 2>&1
  assert_eq "record re-asserted after sourcing" "${_CS_PROFILE_ENV_VARS:-_NONE_}" "CS_TEST_ONE CS_TEST_TWO"
  cs off >/dev/null 2>&1
  assert_eq "first cleared" "${CS_TEST_ONE:-_NONE_}" "_NONE_"
  assert_eq "second cleared" "${CS_TEST_TWO:-_NONE_}" "_NONE_"
  teardown
}

t_profile_env_symlink_target_directory_checked() {
  echo "[profile.env: the symlink target's directory is checked too]"
  setup
  seed_profile personal
  # File mode is perfect and the profile dir is 0700. The target's DIRECTORY is
  # what a teammate could write, and that is where the file can be replaced.
  local shared="$SANDBOX/shared"
  mkdir -p "$shared"
  printf 'export CS_TEST_ONE=one\n' >"$shared/env.sh"
  chmod 600 "$shared/env.sh"
  chmod 777 "$shared"
  ln -s "$shared/env.sh" "$HOME/.claude/profiles/personal/profile.env"
  cs use personal >|"$SANDBOX/.out" 2>&1
  local out
  out="$(<"$SANDBOX/.out")"
  assert_contains "refuses on the target's directory" "$out" "its directory"
  assert_eq "nothing applied" "${CS_TEST_ONE:-_NONE_}" "_NONE_"
  teardown
}

t_profile_env_run_clears_caller_env() {
  echo "[profile.env: cs run does not leak the caller's profile into the child]"
  setup
  seed_profile work work@corp.com
  seed_profile home home@example.com
  seed_profile_env work 'export CS_TEST_TOOL=fromwork'
  # `home` deliberately has NO profile.env — the caller's value must still go.
  cs use work >/dev/null 2>&1
  cs run home -- --version >/dev/null 2>&1
  assert_eq "child did not inherit work's var" "$(<"$HOME/.claude-launch-toolvar")" "TOOLVAR="
  assert_eq "caller keeps its own pin" "${_CS_PROFILE:-}" "work"
  assert_eq "caller keeps its own var" "${CS_TEST_TOOL:-}" "fromwork"
  teardown
}

t_profile_env_refuses_world_writable() {
  echo "[profile.env: refuses a file others can write]"
  setup
  seed_profile personal
  seed_profile_env personal 'export CS_TEST_ONE=one'
  chmod 666 "$HOME/.claude/profiles/personal/profile.env"
  cs use personal >|"$SANDBOX/.out" 2>&1
  local out
  out="$(<"$SANDBOX/.out")"
  assert_contains "explains the refusal" "$out" "group- or world-writable"
  assert_eq "var not exported" "${CS_TEST_ONE:-_NONE_}" "_NONE_"
  # The Claude pin must still succeed — a bad env file is not a reason to leave
  # the shell pointing at the previous account.
  assert_eq "still pinned to the profile" "${_CS_PROFILE:-}" "personal"
  teardown
}

t_profile_env_reaches_run_without_pinning() {
  echo "[profile.env: cs run passes it to the child, leaves the shell alone]"
  setup
  seed_profile work work@corp.com
  seed_profile_env work 'export CS_TEST_TOOL=fromwork'
  cs run work -- --version >/dev/null 2>&1
  assert_eq "child saw the var" "$(<"$HOME/.claude-launch-toolvar")" "TOOLVAR=fromwork"
  assert_eq "caller shell not given the var" "${CS_TEST_TOOL:-_NONE_}" "_NONE_"
  assert_eq "caller shell not pinned" "${_CS_PROFILE:-_NONE_}" "_NONE_"
  teardown
}

t_env_subcommand() {
  echo "[env: prints the path and contents]"
  setup
  seed_profile personal
  local out
  out="$(cs env personal 2>&1)"
  assert_contains "prints the path" "$out" "profiles/personal/profile.env"
  assert_contains "offers a template when absent" "$out" "no env file yet"
  seed_profile_env personal 'export CS_TEST_ONE=one'
  out="$(cs env personal 2>&1)"
  assert_contains "prints the contents" "$out" "export CS_TEST_ONE=one"
  out="$(cs env ghost 2>&1)"
  assert_contains "missing profile" "$out" "not set up"
  out="$(cs env ../foo 2>&1)"
  assert_contains "rejects traversal" "$out" "invalid profile name"
  teardown
}

t_list_marks_env_profiles() {
  echo "[list: flags profiles that pin other tools]"
  setup
  seed_profile personal
  seed_profile work work@corp.com
  seed_profile_env work 'export CS_TEST_ONE=one'
  local out
  out="$(cs list 2>&1)"
  assert_contains "work marked" "$out" "work@corp.com [+env]"
  assert_not_contains "personal not marked" "$out" "personal@example.com [+env]"
  teardown
}

t_doctor_healthy_and_duplicate() {
  echo "[doctor: healthy profiles + duplicate-account detection]"
  setup
  seed_profile personal personal@example.com
  seed_profile work work@corp.com
  local out
  out="$(cs doctor 2>&1)"
  assert_contains "personal reported" "$out" "personal — personal@example.com (claude.ai)"
  assert_contains "work reported" "$out" "work — work@corp.com (claude.ai)"
  cs doctor >/dev/null 2>&1
  assert_eq "healthy distinct profiles exit 0" "$?" "0"

  # Now make two profiles share an account -> must flag + fail.
  seed_profile work2 personal@example.com
  out="$(cs doctor 2>&1)"
  assert_contains "duplicate flagged" "$out" "DUPLICATE — 'personal@example.com'"
  assert_contains "duplicate lists both slots" "$out" "personal, work2"
  cs doctor >/dev/null 2>&1
  assert_eq "duplicate exits 1" "$?" "1"
  teardown
}

t_doctor_default_duplicate() {
  echo "[doctor: default namespace duplicating a profile is flagged]"
  setup
  seed_profile personal personal@example.com
  # Default (no CLAUDE_CONFIG_DIR) also logged into the same account.
  cat >"$HOME/.claude/.claude.json" <<'JSON'
{"oauthAccount":{"emailAddress":"personal@example.com","organizationUuid":"org-default"}}
JSON
  local out
  out="$(cs doctor 2>&1)"
  assert_contains "default listed" "$out" "(default) — personal@example.com"
  assert_contains "default duplicate flagged" "$out" "DUPLICATE — 'personal@example.com'"
  assert_contains "hint to log default out" "$out" "claude auth logout"
  teardown
}

t_doctor_not_logged_in() {
  echo "[doctor: profile dir without login is flagged]"
  setup
  mkdir -p "$HOME/.claude/profiles/empty"
  local out
  out="$(cs doctor 2>&1)"
  assert_contains "empty profile flagged" "$out" "empty — NOT LOGGED IN"
  cs doctor >/dev/null 2>&1
  assert_eq "not-logged-in exits 1" "$?" "1"
  teardown
}

t_wrapper_unpinned_passthrough() {
  echo "[wrapper: unpinned passes through]"
  setup
  local out
  out="$(claude hello 2>&1)"
  assert_contains "fake claude invoked" "$out" "FAKE_CLAUDE: hello"
  assert_not_contains "no profile prefix" "$out" "launching claude"
  teardown
}

t_wrapper_pinned_announces_and_aligns() {
  echo "[wrapper: pinned announces account and aligns config dir]"
  setup
  seed_profile personal
  cs use personal >/dev/null 2>&1
  # Drift CLAUDE_CONFIG_DIR; wrapper should realign it to the pin. Run in the
  # current shell (redirect, not $(...)) so the realigning export is observable.
  export CLAUDE_CONFIG_DIR="/wrong/place"
  claude foo >|"$SANDBOX/.out" 2>&1
  local out
  out="$(<"$SANDBOX/.out")"
  assert_contains "announces profile" "$out" "launching claude as 'personal'"
  assert_contains "shows email" "$out" "personal@example.com"
  assert_contains "passes args through" "$out" "FAKE_CLAUDE: foo"
  assert_eq "config dir realigned to pin" "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude/profiles/personal"
  teardown
}

t_wrapper_refuses_bad_profile() {
  echo "[wrapper: refuses invalid _CS_PROFILE]"
  setup
  _CS_PROFILE="../escape"
  local out
  out="$(claude 2>&1)"
  assert_contains "refuses traversal profile" "$out" "refusing to launch"
  assert_not_contains "fake claude NOT invoked" "$out" "FAKE_CLAUDE"
  teardown
}

t_wrapper_scrubs_override_auth_vars() {
  echo "[wrapper: strips ANTHROPIC_API_KEY / token / bedrock / vertex at launch]"
  setup
  seed_profile personal
  export ANTHROPIC_API_KEY="sk-ant-api-LEAK"
  export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-LEAK"
  export CLAUDE_CODE_USE_BEDROCK="1"
  export CLAUDE_CODE_USE_VERTEX="1"
  cs use personal >/dev/null 2>&1
  claude go >/dev/null 2>&1
  local launched
  launched="$(<"$HOME/.claude-launch-env")"
  assert_eq "launched claude saw no overriding auth vars" "$launched" "API= TOKEN= BEDROCK= VERTEX="
  # And the user's interactive shell keeps its own API key (not clobbered).
  assert_eq "shell ANTHROPIC_API_KEY preserved" "${ANTHROPIC_API_KEY:-}" "sk-ant-api-LEAK"
  teardown
}

t_doctor_unpinned_does_not_star_default() {
  echo "[doctor: unpinned shell does not star (default)]"
  setup
  seed_profile personal personal@example.com
  cat >"$HOME/.claude/.claude.json" <<'JSON'
{"oauthAccount":{"emailAddress":"other@example.com","organizationUuid":"org-default"}}
JSON
  unset _CS_PROFILE
  local out
  out="$(cs doctor 2>&1)"
  assert_contains "default listed" "$out" "(default) — other@example.com"
  assert_not_contains "default NOT starred when unpinned" "$out" "* (default)"
  teardown
}

#--------------------------------- snapshot-shell resilience (regression)
# A shell rebuilt from a snapshot has `cs`/`claude` but no _cs_* helpers. The
# wrapper used to call _cs_validate_name there, get 127, read that as "invalid
# profile" and hard-refuse — making `claude` unusable from Claude Code's own
# Bash tool, subagents and scripts. Providers made this worse: every provider
# function is a _cs_* name too, so `cs doctor` and `cs login <p> gcloud` died
# the same way. These pin the degraded path.

t_snapshot_shell_wrapper_launches() {
  echo "[snapshot shell: wrapper launches without _cs_* helpers]"
  setup
  seed_profile personal personal@example.com
  local out
  out="$(run_in_snapshot_shell '
    typeset -f _cs_validate_name >/dev/null && print "HELPERS_PRESENT"
    _CS_PROFILE=personal
    claude go
    print "CFG=$CLAUDE_CONFIG_DIR"
  ')"
  assert_not_contains "helpers really are stripped" "$out" "HELPERS_PRESENT"
  assert_not_contains "no command-not-found" "$out" "command not found"
  assert_not_contains "does not refuse to launch" "$out" "refusing to launch"
  assert_contains "announces profile" "$out" "launching claude as 'personal'"
  assert_contains "and still resolves the email" "$out" "personal@example.com"
  assert_contains "args passed through" "$out" "FAKE_CLAUDE: go"
  assert_contains "config dir aligned to pin" "$out" "CFG=$HOME/.claude/profiles/personal"
  teardown
}

t_snapshot_shell_wrapper_scrubs_override_auth_vars() {
  echo "[snapshot shell: wrapper still strips overriding auth vars]"
  setup
  seed_profile personal personal@example.com
  # The security-critical case: a pass-through fallback would let a stray
  # ANTHROPIC_API_KEY authenticate (and bill) the wrong identity, which is the
  # exact thing the scrub exists to prevent. It must survive helper loss.
  run_in_snapshot_shell '
    export ANTHROPIC_API_KEY=sk-ant-api-LEAK
    export CLAUDE_CODE_OAUTH_TOKEN=oat-LEAK
    export CLAUDE_CODE_USE_BEDROCK=1
    export CLAUDE_CODE_USE_VERTEX=1
    _CS_PROFILE=personal
    claude go
  ' >/dev/null
  assert_file_exists "fake claude was invoked" "$HOME/.claude-launch-env"
  local launched
  launched="$(<"$HOME/.claude-launch-env")"
  assert_eq "launched claude saw no overriding auth vars" "$launched" "API= TOKEN= BEDROCK= VERTEX="
  teardown
}

t_snapshot_shell_wrapper_warns_about_base_url() {
  echo "[snapshot shell: the base-url notice survives too]"
  setup
  seed_profile personal personal@example.com
  # cs deliberately does NOT strip ANTHROPIC_BASE_URL, so the profile's token
  # still goes wherever it points. Every launch path warns; a snapshot shell is
  # a launch path.
  local out
  out="$(run_in_snapshot_shell '
    export ANTHROPIC_BASE_URL=https://proxy.example
    _CS_PROFILE=personal
    claude go
  ')"
  assert_contains "warns about the base url" "$out" "ANTHROPIC_BASE_URL is set"
  assert_contains "names the endpoint" "$out" "https://proxy.example"
  teardown
}

t_snapshot_shell_wrapper_refuses_bad_profile() {
  echo "[snapshot shell: wrapper still refuses an invalid _CS_PROFILE]"
  setup
  local out
  out="$(run_in_snapshot_shell '_CS_PROFILE=../evil; claude go')"
  assert_contains "refuses traversal profile" "$out" "refusing to launch"
  assert_file_absent "fake claude NOT invoked" "$HOME/.claude-launch-env"
  teardown
}

t_snapshot_shell_wrapper_unpinned_passthrough() {
  echo "[snapshot shell: unpinned still passes through cleanly]"
  setup
  local out
  out="$(run_in_snapshot_shell 'unset _CS_PROFILE; claude go')"
  assert_not_contains "no command-not-found" "$out" "command not found"
  assert_not_contains "no profile banner" "$out" "launching claude as"
  assert_contains "args passed through" "$out" "FAKE_CLAUDE: go"
  teardown
}

t_snapshot_shell_cs_self_heals() {
  echo "[snapshot shell: cs dispatcher re-sources its helpers]"
  setup
  seed_profile personal personal@example.com
  seed_profile work work@example.com
  local out
  out="$(run_in_snapshot_shell 'cs current; cs list')"
  assert_not_contains "no command-not-found" "$out" "command not found"
  assert_contains "lists personal" "$out" "personal"
  assert_contains "lists work" "$out" "work"
  teardown
}

t_snapshot_shell_provider_commands_self_heal() {
  echo "[snapshot shell: provider subcommands work too]"
  setup
  fake_gcloud
  seed_profile work work@corp.com
  seed_gcloud_env work
  # Every provider function is a _cs_* name, so this whole feature was dead in a
  # snapshot shell until cs learned to re-source itself.
  local out
  out="$(run_in_snapshot_shell 'cs login work gcloud')"
  assert_not_contains "login: no command-not-found" "$out" "command not found"
  assert_contains "login reaches the provider" "$out" "gcloud-profiles/work"
  assert_file_exists "and writes the credential" \
    "$HOME/.config/gcloud-profiles/work/application_default_credentials.json"
  out="$(run_in_snapshot_shell 'cs doctor')"
  assert_not_contains "doctor: no command-not-found" "$out" "command not found"
  assert_contains "doctor reports the provider" "$out" "work — gcloud:"
  teardown
}

t_snapshot_shell_reports_a_missing_self() {
  echo "[snapshot shell: cs and claude say so when they cannot restore]"
  setup
  seed_profile personal personal@example.com
  # _CS_SELF is how the recovery finds this file. Without it both entry points
  # must give an actionable message, not a bare "command not found".
  local out
  for cmd in "cs list" "claude go"; do
    out="$(zsh -c 'source "$1"
      for __f in ${(k)functions}; do
        [[ "$__f" == _[^_]* ]] && unfunction "$__f" 2>/dev/null
      done
      _CS_SELF=/nonexistent/cs.zsh
      _CS_PROFILE=personal
      eval "$2"' zsh "$CS_ZSH" "$cmd" 2>&1)"
    assert_contains "$cmd explains the problem" "$out" "helper functions are missing"
    assert_contains "$cmd says what to do" "$out" "Re-source cs.zsh and retry"
    assert_not_contains "$cmd does not launch anyway" "$out" "FAKE_CLAUDE"
  done
  teardown
}

t_use_warn_list_stays_in_sync() {
  echo "[use: the warn list matches _CS_AUTH_OVERRIDE_VARS]"
  setup
  # _cs_use names the overriding auth vars one per line rather than looping with
  # ${(P)…} indirection, because that form is not parseable by the shfmt and
  # shellcheck runs in CI. Two copies can drift, and a var missing here is one
  # the user is never warned about. Pin them.
  #
  # CLAUDE_CODE_OAUTH_TOKEN is deliberately absent from the warn list: _cs_use
  # UNSETS it a few lines earlier, with its own note, because it conflicts with
  # the pin. Warning that it is "still set" would be false.
  local canonical listed
  canonical="$(print -l "${_CS_AUTH_OVERRIDE_VARS[@]}" |
    grep -v '^CLAUDE_CODE_OAUTH_TOKEN$' | sort -u | tr '\n' ' ')"
  listed="$(grep -oE 'present\+=\([A-Z][A-Z0-9_]+\)' "$CS_ZSH" |
    grep -oE '[A-Z][A-Z0-9_]+' | sort -u | tr '\n' ' ')"
  assert_eq "warn list == _CS_AUTH_OVERRIDE_VARS minus the token" "$listed" "$canonical"
  teardown
}

t_restore_helper_survives_the_snapshot_filter() {
  echo "[snapshot shell: the recovery helper is itself kept]"
  setup
  # The double underscore is what makes one recovery path possible instead of
  # two inlined copies. If the filter ever drops __ names too, this fails first
  # and explains why everything else broke.
  local out
  out="$(run_in_snapshot_shell 'typeset -f __cs_restore >/dev/null && print KEPT || print DROPPED')"
  assert_contains "__cs_restore survives" "$out" "KEPT"
  out="$(run_in_snapshot_shell 'typeset -f _cs_validate_name >/dev/null && print KEPT || print DROPPED')"
  assert_contains "_cs_* helpers do not" "$out" "DROPPED"
  teardown
}

#------------------------------------------------------------------- run

# Install a fake `gcloud` that records its argv and answers `auth list` from a
# newline-separated account list in $HOME/.gcloud-accounts. Shadows any real
# gcloud, because the sandbox bin comes first on PATH — so these tests behave
# the same on a laptop with the Cloud SDK and on a CI runner that ships one.
fake_gcloud() {
  : >"$HOME/.gcloud-accounts"
  : >"$HOME/.gcloud-argv"
  cat >"$SANDBOX/bin/gcloud" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${HOME}/.gcloud-argv"
printf 'CONFIG=%s\n' "${CLOUDSDK_CONFIG-}" >>"${HOME}/.gcloud-argv"
if [ "$1" = "auth" ] && [ "$2" = "list" ]; then
  cat "${HOME}/.gcloud-accounts"
  exit 0
fi
if [ "$1" = "config" ] && [ "$2" = "get-value" ]; then
  cat "${HOME}/.gcloud-project" 2>/dev/null || printf '(unset)\n'
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "login" ]; then
  [ -n "${CS_TEST_GCLOUD_LOGIN_FAIL-}" ] && exit 1
  mkdir -p "$CLOUDSDK_CONFIG"
  printf '%s\n' "login@example.com" >"${HOME}/.gcloud-accounts"
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "application-default" ] && [ "$3" = "login" ]; then
  mkdir -p "$CLOUDSDK_CONFIG"
  printf '{}\n' >"$CLOUDSDK_CONFIG/application_default_credentials.json"
  exit 0
fi
exit 0
SH
  chmod +x "$SANDBOX/bin/gcloud"
}

# A profile.env that pins gcloud into the sandbox.
seed_gcloud_env() {
  local name="$1"
  seed_profile_env "$name" "export CLOUDSDK_CONFIG=\"\$HOME/.config/gcloud-profiles/$name\"
export GOOGLE_APPLICATION_CREDENTIALS=\"\$HOME/.config/gcloud-profiles/$name/application_default_credentials.json\""
}

t_login_provider_grammar() {
  echo "[login: provider is a bare word in position 2]"
  setup
  local out
  # No provider -> claude, exactly as before providers existed.
  out="$(cs login personal 2>&1)"
  assert_contains "defaults to claude" "$out" "FAKE_CLAUDE_AUTH_LOGIN"
  assert_contains "keeps the claudeai default" "$out" "--claudeai"
  # A dash argument in position 2 is a claude flag, not a provider.
  out="$(cs login work --claudeai --email me@corp.com 2>&1)"
  assert_contains "passthrough still works" "$out" "--email me@corp.com"
  assert_contains "passthrough profile logged in" "$out" "saved isolated login for 'work'"
  # The provider written out means the same thing.
  out="$(cs login home claude --email me@home.com 2>&1)"
  assert_contains "explicit claude provider" "$out" "--email me@home.com"
  # Unknown and malformed providers are refused before any lookup.
  out="$(cs login personal nope 2>&1)"
  assert_contains "unknown provider refused" "$out" "unknown provider 'nope'"
  assert_contains "unknown provider lists the known ones" "$out" "claude gcloud"
  out="$(cs login personal 'Bad;Name' 2>&1)"
  assert_contains "malformed provider refused" "$out" "invalid provider"
  teardown
}

t_login_gcloud_provider() {
  echo "[login: the gcloud provider]"
  setup
  fake_gcloud
  seed_profile work work@corp.com

  # No profile.env -> cs cannot know where gcloud should write.
  local out
  out="$(cs login work gcloud 2>&1)"
  assert_contains "refuses without profile.env" "$out" "has no profile.env"
  assert_contains "points at cs env" "$out" "cs env work"

  # A profile.env that pins nothing for gcloud is also refused.
  seed_profile_env work 'export CS_TEST_ONE=one'
  out="$(cs login work gcloud 2>&1)"
  assert_contains "refuses without CLOUDSDK_CONFIG" "$out" "does not export CLOUDSDK_CONFIG"

  # The real path.
  seed_gcloud_env work
  printf 'qbraid-staging\n' >"$HOME/.gcloud-project"
  out="$(cs login work gcloud 2>&1)"
  assert_contains "announces the target directory" "$out" "gcloud-profiles/work"
  assert_contains "runs the second login" "$out" "application default credentials"
  assert_file_exists "writes the ADC file" \
    "$HOME/.config/gcloud-profiles/work/application_default_credentials.json"
  local argv
  argv="$(cat "$HOME/.gcloud-argv")"
  assert_contains "ran auth login" "$argv" "auth login"
  assert_contains "ran application-default login" "$argv" "auth application-default login"
  assert_contains "set the quota project" "$argv" "set-quota-project qbraid-staging"
  assert_contains "gcloud saw the profile's config dir" "$argv" "gcloud-profiles/work"
  assert_contains "verification reports the account" "$out" "gcloud: login@example.com"

  # An unknown profile is refused before the provider runs.
  out="$(cs login ghost gcloud 2>&1)"
  assert_contains "unknown profile refused" "$out" "not set up"

  # A failed first login must stop there. Running the second login anyway would
  # write application default credentials for whatever account was already
  # active — a different account from the one the user just failed to log in.
  seed_profile home home@example.com
  seed_gcloud_env home
  export CS_TEST_GCLOUD_LOGIN_FAIL=1
  : >"$HOME/.gcloud-argv"
  cs login home gcloud >/dev/null 2>&1
  assert_not_eq "failed login exits non-zero" "$?" "0"
  argv="$(cat "$HOME/.gcloud-argv")"
  assert_not_contains "second login skipped" "$argv" "application-default login"
  assert_file_absent "no ADC file written" \
    "$HOME/.config/gcloud-profiles/home/application_default_credentials.json"
  unset CS_TEST_GCLOUD_LOGIN_FAIL
  teardown
}

t_login_gcloud_does_not_pin_the_shell() {
  echo "[login: the gcloud provider leaves this shell alone]"
  setup
  fake_gcloud
  seed_profile work work@corp.com
  seed_gcloud_env work
  cs login work gcloud >/dev/null 2>&1
  assert_eq "shell stays unpinned" "${_CS_PROFILE-unset}" "unset"
  assert_eq "shell has no CLOUDSDK_CONFIG" "${CLOUDSDK_CONFIG-unset}" "unset"
  teardown
}

t_provider_output_is_not_mixed_with_profile_env_output() {
  echo "[providers: profile.env output never reaches a hook's channel]"
  setup
  fake_gcloud
  seed_profile work work@corp.com
  # A profile.env that prints something. A banner, a `mkdir -pv`, a sourced
  # helper — all ordinary. cs rm reads a hook's stdout as directories to delete,
  # so a printed path must never land there.
  seed_profile_env work "export CLOUDSDK_CONFIG=\"\$HOME/.config/gcloud-profiles/work\"
echo \"\$HOME/Documents\""
  mkdir -p "$HOME/Documents"
  printf 'my thesis' >"$HOME/Documents/thesis.txt"
  cs login work gcloud >/dev/null 2>&1

  # Capture stdout ONLY. The printed line still reaches the user, on stderr;
  # what must not happen is cs treating it as a directory to delete.
  local out
  out="$(printf 'y\n' | cs rm work 2>/dev/null)"
  assert_not_contains "the printed path is not offered for deletion" "$out" "Documents"
  assert_file_exists "and it still exists" "$HOME/Documents/thesis.txt"
  assert_dir_absent "the real provider directory is still deleted" \
    "$HOME/.config/gcloud-profiles/work"

  # doctor reads a check hook's stdout the same way, so a profile.env must not
  # be able to write a line into the report.
  seed_profile home home@corp.com
  seed_profile_env home "export CLOUDSDK_CONFIG=\"\$HOME/.config/gcloud-profiles/home\"
echo 'home — gcloud: attacker@evil.example (spoofed)'"
  printf 'real@corp.com\n' >"$HOME/.gcloud-accounts"
  out="$(cs doctor 2>/dev/null)"
  assert_not_contains "a profile.env cannot forge a doctor line" "$out" "spoofed"
  teardown
}

t_gcloud_refuses_an_unsafe_credential_directory() {
  echo "[gcloud: the credential directory is checked before any login]"
  setup
  fake_gcloud
  seed_profile work work@corp.com

  # A symlink standing in for the directory would send the refresh token
  # wherever it points.
  mkdir -p "$HOME/attacker"
  mkdir -p "$HOME/.config/gcloud-profiles"
  ln -s "$HOME/attacker" "$HOME/.config/gcloud-profiles/work"
  seed_gcloud_env work
  local out
  out="$(cs login work gcloud 2>&1)"
  assert_contains "refuses a symlinked directory" "$out" "is a symlink"
  assert_eq "gcloud was never run" "$(cat "$HOME/.gcloud-argv")" ""
  assert_file_absent "no credential reached the attacker's directory" \
    "$HOME/attacker/application_default_credentials.json"

  # A world-writable directory that you own is repaired, not refused: cs sets
  # 0700 before the login runs, so the refresh token never lands in a directory
  # someone else can read.
  rm -f "$HOME/.config/gcloud-profiles/work"
  mkdir -p "$HOME/.config/gcloud-profiles/work"
  chmod 777 "$HOME/.config/gcloud-profiles/work"
  cs login work gcloud >/dev/null 2>&1
  local mode
  mode="$(_cs_env_path_unsafe "$HOME/.config/gcloud-profiles/work" || echo safe)"
  assert_eq "a world-writable directory is tightened first" "$mode" "safe"

  # The normal case still works, and the directory it creates is private.
  rm -rf "$HOME/.config/gcloud-profiles"
  cs login work gcloud >/dev/null 2>&1
  assert_file_exists "the login wrote the credential" \
    "$HOME/.config/gcloud-profiles/work/application_default_credentials.json"
  local mode
  mode="$(_cs_env_path_unsafe "$HOME/.config/gcloud-profiles/work" || echo safe)"
  assert_eq "the directory is private" "$mode" "safe"
  mode="$(_cs_env_path_unsafe "$HOME/.config/gcloud-profiles" || echo safe)"
  assert_eq "so is the directory above it" "$mode" "safe"
  teardown
}

t_rm_guard_normalizes_paths() {
  echo "[rm: the delete guard normalizes before comparing]"
  setup
  # A raw string test is defeated by a trailing slash, a '.' component, or a
  # symlink — all ordinary ways to write a directory in a profile.env.
  local p
  for p in "$HOME/.config/gcloud" "$HOME/.config/gcloud/" "$HOME/.config/gcloud/." \
    "$HOME/./.config/gcloud" "$HOME/.config" "$HOME/.config/" "$HOME" "$HOME/" \
    "$HOME/.claude" "$HOME/.claude/profiles" "/" "relative/path" \
    "$HOME/.ssh" "$HOME/.aws" "$HOME/.gnupg" "$HOME/Documents" "/etc"; do
    if _cs_rm_path_unsafe "$p" >/dev/null 2>&1; then
      _pass "refuses $p"
    else
      _fail "refuses $p" "the guard allowed it"
    fi
  done
  # A real per-profile directory must still be deletable. It has to exist and be
  # private, because the guard now applies the same ownership and mode test cs
  # uses before it sources profile.env.
  mkdir -p "$HOME/.config/gcloud-profiles/work"
  chmod 700 "$HOME/.config/gcloud-profiles/work"
  if _cs_rm_path_unsafe "$HOME/.config/gcloud-profiles/work" >/dev/null 2>&1; then
    _fail "allows a per-profile directory" "the guard refused it"
  else
    _pass "allows a per-profile directory"
  fi

  # A world-writable one is not cs's to delete.
  mkdir -p "$HOME/.config/gcloud-profiles/loose"
  chmod 777 "$HOME/.config/gcloud-profiles/loose"
  if _cs_rm_path_unsafe "$HOME/.config/gcloud-profiles/loose" >/dev/null 2>&1; then
    _pass "refuses a world-writable directory"
  else
    _fail "refuses a world-writable directory" "the guard allowed it"
  fi

  # Nor is a symlink standing in for one: the guard compares resolved paths, so
  # deleting through the link would destroy whatever it points at.
  mkdir -p "$HOME/victim"
  ln -s "$HOME/victim" "$HOME/.config/gcloud-profiles/linked"
  if _cs_rm_path_unsafe "$HOME/.config/gcloud-profiles/linked" >/dev/null 2>&1; then
    _pass "refuses a symlinked provider directory"
  else
    _fail "refuses a symlinked provider directory" "the guard allowed it"
  fi
  teardown
}

t_rm_warns_when_it_cannot_read_provider_paths() {
  echo "[rm: never drops provider paths in silence]"
  setup
  fake_gcloud
  seed_profile work work@corp.com
  seed_gcloud_env work
  cs login work gcloud >/dev/null 2>&1
  local gdir="$HOME/.config/gcloud-profiles/work"
  assert_file_exists "the login wrote credentials" "$gdir/application_default_credentials.json"

  # Now make profile.env unreadable. cs rm deletes the profile, which takes the
  # only record of where that gcloud directory is — so it must say so.
  chmod 666 "$HOME/.claude/profiles/work/profile.env"
  local out
  out="$(printf 'y\n' | cs rm work 2>&1)"
  assert_contains "warns that it cannot read profile.env" "$out" "could not read profile.env"
  assert_contains "says the directories are not deleted" "$out" "will NOT be"
  assert_contains "gives the reason" "$out" "group- or world-writable"
  assert_file_exists "the credentials are still findable" \
    "$gdir/application_default_credentials.json"
  teardown
}

t_env_trailing_conditional_still_applies() {
  echo "[profile.env: a trailing conditional does not block a provider]"
  setup
  fake_gcloud
  seed_profile work work@corp.com
  # The file's own comments call this pattern ordinary: `source` returns the
  # status of the LAST command, and this one is false on most machines.
  seed_profile_env work "export CLOUDSDK_CONFIG=\"\$HOME/.config/gcloud-profiles/work\"
export GOOGLE_APPLICATION_CREDENTIALS=\"\$HOME/.config/gcloud-profiles/work/application_default_credentials.json\"
[[ -d \"\$HOME/definitely-not-here\" ]] && export CS_TEST_ONE=1"
  local out
  out="$(cs login work gcloud 2>&1)"
  assert_not_contains "does not call the file unusable" "$out" "unusable"
  assert_contains "the login runs" "$out" "gcloud-profiles/work"
  assert_file_exists "and writes the credential" \
    "$HOME/.config/gcloud-profiles/work/application_default_credentials.json"

  # cs rm must still find the directory through that same file.
  out="$(printf 'y\n' | cs rm work 2>&1)"
  assert_contains "rm still finds the directory" "$out" "gcloud-profiles/work"
  assert_dir_absent "and deletes it" "$HOME/.config/gcloud-profiles/work"
  teardown
}

t_env_parser_ignores_comments() {
  echo "[profile.env: an unquoted comment is not a variable name]"
  setup
  seed_profile work
  # A phantom name in a comment must not be tracked, and must not be unset.
  seed_profile_env work 'export CS_TEST_ONE=one # note CS_TEST_TWO=2'
  export CS_TEST_TWO="mine"
  cs use work >/dev/null 2>&1
  assert_eq "comment name not tracked" "$_CS_PROFILE_ENV_VARS" "CS_TEST_ONE"
  cs off >/dev/null 2>&1
  assert_eq "the shell's own variable survives" "${CS_TEST_TWO-gone}" "mine"
  unset CS_TEST_TWO

  # A blocked name inside a comment must not get the file refused.
  seed_profile_env work 'export CS_TEST_ONE=one # legacy PATH=/nowhere'
  local out
  out="$(cs use work 2>&1)"
  assert_not_contains "no false refusal" "$out" "refusing to load"
  assert_contains "the real export applies" "$out" "profile.env applied — CS_TEST_ONE"
  cs off >/dev/null 2>&1

  # A '#' inside a quoted value is part of the value, not a comment.
  seed_profile_env work 'export CS_TEST_ONE="a#b"'
  cs use work >/dev/null 2>&1
  assert_eq "quoted hash kept" "$CS_TEST_ONE" "a#b"
  cs off >/dev/null 2>&1

  # A real second export on the same line is still tracked.
  seed_profile_env work 'export CS_TEST_ONE=one CS_TEST_TWO=two # trailing'
  cs use work >/dev/null 2>&1
  assert_eq "both real names tracked" "$_CS_PROFILE_ENV_VARS" "CS_TEST_ONE CS_TEST_TWO"
  cs off >/dev/null 2>&1
  teardown
}

t_env_tracking_survives_a_custom_ifs() {
  echo "[profile.env: tracking does not depend on the caller's IFS]"
  setup
  seed_profile work
  seed_profile_env work 'export CS_TEST_ONE=one
export CS_TEST_TWO=two'
  local saved="$IFS"
  IFS=,
  cs use work >/dev/null 2>&1
  assert_eq "names joined on whitespace" "$_CS_PROFILE_ENV_VARS" "CS_TEST_ONE CS_TEST_TWO"
  cs off >/dev/null 2>&1
  assert_eq "first name unset" "${CS_TEST_ONE-gone}" "gone"
  assert_eq "second name unset" "${CS_TEST_TWO-gone}" "gone"
  IFS="$saved"
  teardown
}

t_gcloud_usage_error_is_not_a_broken_env_file() {
  echo "[gcloud: the tool's own exit 2 is not a profile.env failure]"
  setup
  fake_gcloud
  seed_profile work work@corp.com
  seed_gcloud_env work
  # gcloud uses argparse, which exits 2 on a usage error.
  cat >"$SANDBOX/bin/gcloud" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${HOME}/.gcloud-argv"
exit 2
SH
  chmod +x "$SANDBOX/bin/gcloud"
  local out
  out="$(cs login work gcloud --bogus-flag 2>&1)"
  assert_not_contains "does not blame profile.env" "$out" "unusable"
  assert_contains "the login was attempted" "$(cat "$HOME/.gcloud-argv")" "--bogus-flag"
  cs login work gcloud --bogus-flag >/dev/null 2>&1
  assert_eq "gcloud's own status is passed through" "$?" "2"
  teardown
}

t_rm_removes_provider_credentials() {
  echo "[rm: deletes the profile's gcloud directory too]"
  setup
  fake_gcloud
  seed_profile work work@corp.com
  seed_gcloud_env work
  cs login work gcloud >/dev/null 2>&1
  local gdir="$HOME/.config/gcloud-profiles/work"
  assert_file_exists "the login wrote credentials" "$gdir/application_default_credentials.json"

  local out
  out="$(printf 'y\n' | cs rm work 2>&1)"
  assert_contains "names the directory before deleting" "$out" "$gdir"
  assert_contains "the prompt mentions provider credentials" "$out" "provider credentials"
  assert_dir_absent "the gcloud directory is gone" "$gdir"
  assert_dir_absent "the profile is gone" "$HOME/.claude/profiles/work"
  teardown
}

t_rm_refuses_a_shared_directory() {
  echo "[rm: never deletes a shared gcloud directory]"
  setup
  fake_gcloud
  seed_profile work work@corp.com
  # A profile.env that points at gcloud's own shared directory.
  seed_profile_env work "export CLOUDSDK_CONFIG=\"\$HOME/.config/gcloud\""
  mkdir -p "$HOME/.config/gcloud"
  printf '{}\n' >"$HOME/.config/gcloud/credentials.db"
  local out
  out="$(printf 'y\n' | cs rm work 2>&1)"
  assert_contains "says it refused" "$out" "refusing to delete"
  assert_contains "explains why" "$out" "shared configuration directory"
  assert_file_exists "the shared directory survives" "$HOME/.config/gcloud/credentials.db"
  assert_dir_absent "the profile is still removed" "$HOME/.claude/profiles/work"
  teardown
}

t_gcloud_ignores_inherited_config() {
  echo "[gcloud: a CLOUDSDK_CONFIG from the user's shell is never used]"
  setup
  fake_gcloud
  seed_profile work work@corp.com
  # A profile.env that pins other things, but nothing for gcloud.
  seed_profile_env work 'export CS_TEST_ONE=one'
  # ...and a shell that exports gcloud's shared directory, as a .zshrc would.
  export CLOUDSDK_CONFIG="$HOME/.config/gcloud"
  printf 'a@example.com\nb@example.com\n' >"$HOME/.gcloud-accounts"

  local out
  out="$(cs login work gcloud 2>&1)"
  assert_contains "login refuses" "$out" "does not export CLOUDSDK_CONFIG"
  assert_contains "login names the inherited value" "$out" "cs will not use it"
  assert_eq "gcloud was never run" "$(cat "$HOME/.gcloud-argv")" ""
  assert_file_absent "no credential in the shared directory" \
    "$HOME/.config/gcloud/application_default_credentials.json"

  # doctor must not report the shell's accounts under this profile's name.
  out="$(cs doctor 2>&1)"
  assert_not_contains "doctor stays silent" "$out" "gcloud"
  cs doctor >/dev/null 2>&1
  assert_eq "doctor exits 0" "$?" "0"
  unset CLOUDSDK_CONFIG
  teardown
}

t_gcloud_ignores_inherited_adc_path() {
  echo "[gcloud: an inherited GOOGLE_APPLICATION_CREDENTIALS is not judged]"
  setup
  fake_gcloud
  seed_profile work work@corp.com
  # This profile pins the directory but NOT the ADC path.
  seed_profile_env work "export CLOUDSDK_CONFIG=\"\$HOME/.config/gcloud-profiles/work\""
  printf 'work@corp.com\n' >"$HOME/.gcloud-accounts"
  # The shell names an ADC file that does not exist.
  export GOOGLE_APPLICATION_CREDENTIALS="$HOME/nowhere/adc.json"

  local out
  out="$(cs doctor 2>&1)"
  assert_contains "reports the account" "$out" "gcloud: work@corp.com"
  assert_not_contains "no false ADC failure" "$out" "NO application default"
  cs doctor >/dev/null 2>&1
  assert_eq "doctor exits 0" "$?" "0"
  unset GOOGLE_APPLICATION_CREDENTIALS
  teardown
}

t_gcloud_adc_outside_the_config_dir() {
  echo "[gcloud: an ADC path outside CLOUDSDK_CONFIG gets different advice]"
  setup
  fake_gcloud
  seed_profile work work@corp.com
  seed_profile_env work "export CLOUDSDK_CONFIG=\"\$HOME/.config/gcloud-profiles/work\"
export GOOGLE_APPLICATION_CREDENTIALS=\"\$HOME/keys/work-sa.json\""
  printf 'work@corp.com\n' >"$HOME/.gcloud-accounts"
  local out
  out="$(cs doctor 2>&1)"
  assert_contains "still reports the missing file" "$out" "NO application default credentials"
  assert_contains "explains no login writes it" "$out" "no login writes it"
  assert_not_contains "does not suggest a login that cannot help" "$out" "Fix: cs login work gcloud"
  teardown
}

t_gcloud_unusable_env_file() {
  echo "[gcloud: an unusable profile.env is not a gcloud failure]"
  setup
  fake_gcloud
  seed_profile work work@corp.com
  # A refused file: cs never manages PATH.
  seed_profile_env work 'export PATH=/nowhere'

  local out
  out="$(cs doctor 2>&1)"
  assert_contains "doctor explains the refusal" "$out" "refusing to load"
  assert_not_contains "doctor blames no gcloud account" "$out" "NO ACCOUNT"
  cs doctor >/dev/null 2>&1
  assert_eq "doctor does not fail on it" "$?" "0"

  out="$(cs login work gcloud 2>&1)"
  assert_contains "login says no login ran" "$out" "no gcloud login ran"
  assert_eq "gcloud was never run" "$(cat "$HOME/.gcloud-argv")" ""
  cs login work gcloud >/dev/null 2>&1
  assert_not_eq "login exits non-zero" "$?" "0"
  teardown
}

t_gcloud_args_reach_both_logins() {
  echo "[gcloud: extra arguments reach both logins]"
  setup
  fake_gcloud
  seed_profile work work@corp.com
  seed_gcloud_env work
  cs login work gcloud --no-launch-browser >/dev/null 2>&1
  local argv
  argv="$(cat "$HOME/.gcloud-argv")"
  assert_contains "first login got the flag" "$argv" "auth login --no-launch-browser"
  assert_contains "second login got the flag" "$argv" \
    "auth application-default login --no-launch-browser"
  teardown
}

t_doctor_gcloud_checks() {
  echo "[doctor: gcloud provider checks]"
  setup
  fake_gcloud
  seed_profile work work@corp.com
  local out

  # No profile.env -> no opinion, and no gcloud line at all.
  out="$(cs doctor 2>&1)"
  assert_not_contains "silent without profile.env" "$out" "gcloud"
  cs doctor >/dev/null 2>&1
  assert_eq "still exits 0" "$?" "0"

  # A profile.env that does not pin gcloud is also no opinion.
  seed_profile_env work 'export CS_TEST_ONE=one'
  out="$(cs doctor 2>&1)"
  assert_not_contains "silent without CLOUDSDK_CONFIG" "$out" "gcloud"

  # Pinned, but never logged in.
  seed_gcloud_env work
  out="$(cs doctor 2>&1)"
  assert_contains "reports no account" "$out" "gcloud: NO ACCOUNT"
  cs doctor >/dev/null 2>&1
  assert_eq "no account exits 1" "$?" "1"

  # Logged in, but the application default credentials were never written.
  printf 'work@corp.com\n' >"$HOME/.gcloud-accounts"
  out="$(cs doctor 2>&1)"
  assert_contains "reports the account" "$out" "gcloud: work@corp.com"
  assert_contains "names the missing project" "$out" "(no project set)"
  printf 'my-project\n' >"$HOME/.gcloud-project"
  out="$(cs doctor 2>&1)"
  assert_contains "reports the project when set" "$out" "gcloud: work@corp.com (my-project)"
  rm -f "$HOME/.gcloud-project"
  out="$(cs doctor 2>&1)"
  assert_contains "reports the missing ADC file" "$out" "NO application default credentials"
  cs doctor >/dev/null 2>&1
  assert_eq "missing ADC exits 1" "$?" "1"

  # Both credentials present -> healthy and quiet.
  mkdir -p "$HOME/.config/gcloud-profiles/work"
  printf '{}\n' >"$HOME/.config/gcloud-profiles/work/application_default_credentials.json"
  out="$(cs doctor 2>&1)"
  assert_not_contains "healthy says nothing about ADC" "$out" "NO application default"
  cs doctor >/dev/null 2>&1
  assert_eq "healthy exits 0" "$?" "0"

  # Two accounts in one profile is the leak this feature exists to catch.
  printf 'work@corp.com\npersonal@example.com\n' >"$HOME/.gcloud-accounts"
  out="$(cs doctor 2>&1)"
  assert_contains "flags two accounts" "$out" "gcloud: 2 ACCOUNTS in one profile"
  assert_contains "names the leaked account" "$out" "personal@example.com"
  cs doctor >/dev/null 2>&1
  assert_eq "two accounts exits 1" "$?" "1"
  teardown
}

t_validate_name
t_help
t_sha256_matches_claude_scheme
t_login_isolated_no_token_leak
t_login_default_args_prefill_email
t_use_sets_env_no_token
t_use_invalid_and_missing
t_off_clears_env
t_list
t_current
t_resource_preserves_profile
t_rm
t_rm_legacy_credentials
t_rm_pinned_clears_env
t_profile_env_applied_on_use
t_profile_env_swapped_between_profiles
t_profile_env_cleared_on_off_and_rm
t_profile_env_tracks_despite_failing_last_line
t_profile_env_refuses_blocked_names
t_profile_env_pin_survives_bare_assignment
t_profile_env_use_reports_failure_status
t_profile_env_symlink_permissions_checked
t_profile_env_refuses_writable_directory
t_profile_env_clear_ignores_blocked_names
t_profile_env_tracks_multiple_exports_per_line
t_profile_env_quoted_multi_cannot_smuggle_blocked_name
t_profile_env_survives_hostile_ifs
t_profile_env_bare_path_assignment_restored
t_profile_env_tracking_survives_self_unset
t_profile_env_symlink_target_directory_checked
t_profile_env_run_clears_caller_env
t_profile_env_refuses_world_writable
t_profile_env_reaches_run_without_pinning
t_env_subcommand
t_list_marks_env_profiles
t_doctor_healthy_and_duplicate
t_doctor_default_duplicate
t_doctor_not_logged_in
t_wrapper_unpinned_passthrough
t_wrapper_pinned_announces_and_aligns
t_wrapper_refuses_bad_profile
t_wrapper_scrubs_override_auth_vars
t_doctor_unpinned_does_not_star_default
t_foreign_claude_function_preserved
t_foreign_claude_unsaved_is_reported_honestly
t_base_url_warned_on_every_launch_path
t_run_subcommand
t_doctor_needs_real_binary
t_credential_missing_is_reported
t_login_abort_cleans_up
t_rm_reports_exact_leftover_service
t_installer
t_snapshot_shell_wrapper_launches
t_snapshot_shell_wrapper_scrubs_override_auth_vars
t_snapshot_shell_wrapper_warns_about_base_url
t_snapshot_shell_wrapper_refuses_bad_profile
t_snapshot_shell_wrapper_unpinned_passthrough
t_snapshot_shell_cs_self_heals
t_snapshot_shell_provider_commands_self_heal
t_snapshot_shell_reports_a_missing_self
t_restore_helper_survives_the_snapshot_filter
t_use_warn_list_stays_in_sync
t_login_provider_grammar
t_login_gcloud_provider
t_login_gcloud_does_not_pin_the_shell
t_doctor_gcloud_checks
t_gcloud_ignores_inherited_config
t_env_parser_ignores_comments
t_rm_guard_normalizes_paths
t_provider_output_is_not_mixed_with_profile_env_output
t_gcloud_refuses_an_unsafe_credential_directory
t_rm_warns_when_it_cannot_read_provider_paths
t_env_trailing_conditional_still_applies
t_env_tracking_survives_a_custom_ifs
t_gcloud_usage_error_is_not_a_broken_env_file
t_rm_removes_provider_credentials
t_rm_refuses_a_shared_directory
t_gcloud_ignores_inherited_adc_path
t_gcloud_adc_outside_the_config_dir
t_gcloud_unusable_env_file
t_gcloud_args_reach_both_logins

#------------------------------------------------------------------- summary

echo ""
echo "================================================================"
echo "  $PASS passed, $FAIL failed"
if ((FAIL > 0)); then
  echo ""
  echo "  Failed tests:"
  for t in "${FAILED[@]}"; do echo "    - $t"; done
  echo "================================================================"
  exit 1
fi
echo "================================================================"
exit 0
