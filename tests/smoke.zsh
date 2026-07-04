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
printf 'FAKE_CLAUDE: %s\n' "$*"
SH
  chmod +x "$SANDBOX/bin/claude"
  export PATH="$SANDBOX/bin:$PATH"

  unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR _CS_PROFILE 2>/dev/null
  unfunction cs claude _cs_validate_name _cs_profiles_root _cs_profile_config_dir \
    _cs_sha256_8 _cs_keychain_service _cs_profile_email _cs_profile_is_set_up \
    _cs_login _cs_use _cs_off _cs_list _cs_current _cs_rm _cs_doctor _cs_help 2>/dev/null
  source "$CS_ZSH"
}

teardown() {
  [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
  unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR _CS_PROFILE SANDBOX 2>/dev/null
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
  out="$(cs help 2>&1)"; assert_contains "cs help mentions Usage" "$out" "Usage:"
  out="$(cs --help 2>&1)"; assert_contains "cs --help works" "$out" "Usage:"
  out="$(cs -h 2>&1)"; assert_contains "cs -h works" "$out" "Usage:"
  out="$(cs 2>&1)"; assert_contains "cs (no args) shows help" "$out" "Usage:"
  out="$(cs unknown 2>&1)"; assert_contains "unknown subcommand error" "$out" "unknown subcommand"
  teardown
}

t_sha256_matches_claude_scheme() {
  echo "[keychain: service name = sha256(config dir)[:8]]"
  setup
  # Known vector: sha256("/tmp/x") first 8 hex.
  local expect
  expect="$(printf '%s' "/tmp/x" | shasum -a 256 | cut -c1-8)"
  local got
  got="$(_cs_sha256_8 "/tmp/x")"
  assert_eq "_cs_sha256_8 matches shasum" "$got" "$expect"
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
  local out; out="$(<"$SANDBOX/.out")"
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
  out="$(cs use ../foo 2>&1)"; assert_contains "rejects traversal" "$out" "invalid profile name"
  out="$(cs use 2>&1)"; assert_contains "no-arg usage" "$out" "cs use"
  out="$(cs use ghost 2>&1)"; assert_contains "missing profile" "$out" "not set up"
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
  out="$(cs list 2>&1)"; assert_contains "empty list" "$out" "no profiles"
  seed_profile personal
  seed_profile work work@corp.com
  mkdir -p "$HOME/.claude/profiles/halfbaked"   # dir, no login
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
  out="$(cs current 2>&1)"; assert_contains "none when unset" "$out" "none"
  cs use personal >/dev/null 2>&1
  out="$(cs current 2>&1)"; assert_eq "reports pin" "$out" "personal"
  unset _CS_PROFILE
  out="$(cs current 2>&1)"; assert_contains "warns on config-set-name-unknown" "$out" "name unknown"
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
  out="$(cs rm ../sentinel 2>&1)"; assert_contains "rejects traversal" "$out" "invalid profile name"
  assert_file_exists "sentinel survived" "$HOME/.claude/sentinel"
  out="$(cs rm ghost 2>&1)"; assert_contains "missing profile" "$out" "no such profile"

  seed_profile personal
  out="$(printf 'n\n' | cs rm personal 2>&1)"; assert_contains "declined aborts" "$out" "aborted"
  assert_file_exists "config kept after abort" "$HOME/.claude/profiles/personal/.claude.json"

  printf 'y\n' | cs rm personal >/dev/null 2>&1
  assert_dir_absent "config removed on confirm" "$HOME/.claude/profiles/personal"
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
  local out; out="$(<"$SANDBOX/.out")"
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
t_rm_pinned_clears_env
t_doctor_healthy_and_duplicate
t_doctor_default_duplicate
t_doctor_not_logged_in
t_wrapper_unpinned_passthrough
t_wrapper_pinned_announces_and_aligns
t_wrapper_refuses_bad_profile

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
