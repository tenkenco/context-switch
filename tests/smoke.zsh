#!/usr/bin/env zsh
# claude-switch smoke tests.
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
printf 'FAKE_CLAUDE: %s\n' "$*"
SH
  chmod +x "$SANDBOX/bin/claude"
  export PATH="$SANDBOX/bin:$PATH"

  unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR _CS_PROFILE \
    ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX 2>/dev/null
  unfunction cs claude _cs_prev_claude _cs_validate_name _cs_profiles_root \
    _cs_profile_config_dir _cs_sha256_8 _cs_keychain_service _cs_profile_email \
    _cs_profile_is_set_up _cs_profile_has_credential _cs_keychain_scheme_intact \
    _cs_build_scrub_args _cs_find_legacy_files _cs_login _cs_use _cs_run _cs_off \
    _cs_list _cs_current _cs_rm _cs_doctor _cs_help 2>/dev/null
  _CS_KC_SCHEME_CACHE=""
  source "$CS_ZSH" 2>/dev/null
}

teardown() {
  [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
  unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR _CS_PROFILE SANDBOX \
    ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX 2>/dev/null
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
  out="$(CS_TEST_LOGIN_FAIL=1 cs login aborted-login 2>&1)"
  assert_dir_absent "no phantom profile dir" "$HOME/.claude/profiles/aborted-login"
  out="$(cs list 2>&1)"
  assert_contains "list stays clean" "$out" "(no profiles"

  out="$(CS_TEST_LOGIN_EMPTY=1 cs login empty-login 2>&1)"
  assert_contains "empty successful login is rejected" "$out" "no oauthAccount"
  assert_dir_absent "empty successful login is cleaned up" \
    "$HOME/.claude/profiles/empty-login"

  # An existing, already-working profile must survive a failed re-login.
  seed_profile personal
  CS_TEST_LOGIN_FAIL=1 cs login personal >/dev/null 2>&1
  assert_file_exists "existing profile untouched" "$HOME/.claude/profiles/personal/.claude.json"
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

#------------------------------------------------------------------- run

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
t_doctor_healthy_and_duplicate
t_doctor_default_duplicate
t_doctor_not_logged_in
t_wrapper_unpinned_passthrough
t_wrapper_pinned_announces_and_aligns
t_wrapper_refuses_bad_profile
t_wrapper_scrubs_override_auth_vars
t_doctor_unpinned_does_not_star_default
t_foreign_claude_function_preserved
t_run_subcommand
t_doctor_needs_real_binary
t_credential_missing_is_reported
t_login_abort_cleans_up
t_rm_reports_exact_leftover_service
t_installer

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
