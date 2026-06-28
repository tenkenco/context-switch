#!/usr/bin/env zsh
# claude-switch smoke tests.
# Runs in a sandboxed $HOME with a fake claude binary on PATH so no real
# Claude Code state is touched. Every test is independent — setup creates a
# fresh sandbox, teardown deletes it.
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

# Emit failure with context. Each assertion appends to PASS / FAIL.
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

assert_file_mode() {
  local desc="$1" file="$2" expected="$3"
  local actual
  actual="$(_cs_stat_mode "$file" 2>/dev/null)"
  if [[ "$actual" == "$expected" ]]; then
    _pass "$desc"
  else
    _fail "$desc" "expected mode $expected, got $actual on $file"
  fi
}

assert_returns() {
  local desc="$1" expected_rc="$2"
  shift 2
  "$@" >/dev/null 2>&1
  local rc=$?
  if ((rc == expected_rc)); then
    _pass "$desc"
  else
    _fail "$desc" "expected rc=$expected_rc, got $rc"
  fi
}

#------------------------------------------------------------------- sandbox

setup() {
  SANDBOX="$(mktemp -d -t cs-test.XXXXXX)"
  export HOME="$SANDBOX"
  mkdir -p "$HOME/.claude"
  # Plausible ~/.claude.json with an oauthAccount and one unrelated key
  # so we can verify the wrapper preserves other keys.
  cat >"$HOME/.claude.json" <<'JSON'
{
  "oauthAccount": {
    "emailAddress": "before@example.com",
    "organizationRateLimitTier": "default_test_tier",
    "accountUuid": "00000000-0000-0000-0000-000000000000"
  },
  "unrelatedKey": "must_be_preserved"
}
JSON
  # Fake claude binary that prints its argv so we can detect invocations.
  # Also fake pbpaste / pbcopy so clipboard branches are testable.
  mkdir -p "$SANDBOX/bin"
  cat >"$SANDBOX/bin/claude" <<'SH'
#!/bin/sh
printf 'FAKE_CLAUDE: %s\n' "$*"
SH
  cat >"$SANDBOX/bin/pbpaste" <<'SH'
#!/bin/sh
printf '%s' "${TEST_CLIPBOARD-}"
SH
  cat >"$SANDBOX/bin/pbcopy" <<SH
#!/bin/sh
cat > "$SANDBOX/.pbcopy.last"
SH
  chmod +x "$SANDBOX/bin/"*
  export PATH="$SANDBOX/bin:$PATH"
  # Reset shell state and source under test
  unset CLAUDE_CODE_OAUTH_TOKEN _CS_PROFILE _CS_TOKEN_SOURCE TEST_CLIPBOARD 2>/dev/null
  unfunction cs claude _cs_validate_name _cs_stat_mode _cs_paste _cs_copy \
    _cs_have_clipboard _cs_oauth_account_json _cs_read_token \
    _cs_save _cs_use _cs_off _cs_list _cs_check_token _cs_doctor \
    _cs_current _cs_rm _cs_help 2>/dev/null
  source "$CS_ZSH"
  # Override platform detection: cs.zsh probed PATH at source-time. With our
  # stubs first on PATH, it should have picked pbpaste/pbcopy — but reseat
  # explicitly in case the host runner has wl-paste/xclip ahead of pbpaste.
  _CS_PASTE_CMD="pbpaste"
  _CS_COPY_CMD="pbcopy"
}

teardown() {
  [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
  unset CLAUDE_CODE_OAUTH_TOKEN _CS_PROFILE TEST_CLIPBOARD SANDBOX 2>/dev/null
  # Restore PATH (best effort — only matters if the runner reuses this shell)
  PATH="${PATH#*:}"
}

# Helper: write a fully-formed profile (token + account snapshot) bypassing cs save.
seed_profile() {
  local name="$1" token="${2:-sk-ant-oat01-FAKE-TOKEN-FOR-TESTS}"
  mkdir -p "$HOME/.claude/accounts"
  printf '%s' "$token" >"$HOME/.claude/accounts/$name.token"
  cat >"$HOME/.claude/accounts/$name.account.json" <<JSON
{"emailAddress":"$name@example.com","organizationRateLimitTier":"tier_$name","accountUuid":"uuid-$name"}
JSON
  chmod 600 "$HOME/.claude/accounts/$name.token" "$HOME/.claude/accounts/$name.account.json"
}

#------------------------------------------------------------------- tests

t_validate_name() {
  echo "[validate_name]"
  setup
  local n
  for n in a abc a1 a_b a-b a.b a_-.b XyZ123 long-name_with.dots; do
    if _cs_validate_name "$n"; then
      _pass "valid: $n"
    else
      _fail "valid: $n" "should accept"
    fi
  done
  local bad
  for bad in "" "." ".foo" "-foo" "foo/bar" "../foo" "foo..bar" "a;b" "a b" "/abs" "a/b"; do
    if _cs_validate_name "$bad"; then
      _fail "invalid: ${bad:-<empty>}" "should reject"
    else
      _pass "invalid: ${bad:-<empty>}"
    fi
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

t_save_invalid_name() {
  echo "[save: invalid name rejected]"
  setup
  local n out
  for n in "../escape" "/tmp/escape" "..hidden" "evil; rm -rf /" "a/b" "" ".dot"; do
    out="$(printf 'sk-ant-oat01-x' | cs save "$n" 2>&1)"
    if [[ -z "$n" ]]; then
      assert_contains "save '<empty>' shows usage" "$out" "cs save"
    else
      assert_contains "save '$n' rejected" "$out" "invalid profile name"
    fi
    assert_file_absent "no token file leaked for '$n'" "$HOME/.claude/accounts/$n.token"
  done
  # Path-traversal target outside accounts dir must also not exist
  assert_file_absent "no traversal escape file" "$HOME/.claude/escape.token"
  teardown
}

t_save_happy_path_stdin() {
  echo "[save: happy path via stdin]"
  setup
  local out
  out="$(printf 'sk-ant-oat01-VALID-TEST-TOKEN' | cs save personal 2>&1)"
  assert_contains "save success message" "$out" "saved profile 'personal'"
  assert_contains "save shows email" "$out" "before@example.com"
  assert_file_exists "token file written" "$HOME/.claude/accounts/personal.token"
  assert_file_exists "account snapshot written" "$HOME/.claude/accounts/personal.account.json"
  assert_file_mode "token file mode 600" "$HOME/.claude/accounts/personal.token" "600"
  assert_file_mode "account file mode 600" "$HOME/.claude/accounts/personal.account.json" "600"
  local saved
  saved="$(cat "$HOME/.claude/accounts/personal.token")"
  assert_eq "token saved verbatim" "$saved" "sk-ant-oat01-VALID-TEST-TOKEN"
  teardown
}

t_save_strips_whitespace() {
  echo "[save: whitespace stripped]"
  setup
  printf '  sk-ant-oat01-WITH-WHITESPACE  \n\n' | cs save personal >/dev/null 2>&1
  local saved
  saved="$(cat "$HOME/.claude/accounts/personal.token")"
  assert_eq "leading/trailing whitespace stripped" "$saved" "sk-ant-oat01-WITH-WHITESPACE"
  teardown
}

t_save_force_required_to_overwrite() {
  echo "[save: --force required to overwrite]"
  setup
  printf 'sk-ant-oat01-A' | cs save personal >/dev/null 2>&1
  local out
  out="$(printf 'sk-ant-oat01-B' | cs save personal 2>&1)"
  assert_contains "second save without --force refuses" "$out" "Pass --force"
  local saved
  saved="$(cat "$HOME/.claude/accounts/personal.token")"
  assert_eq "original token preserved on refuse" "$saved" "sk-ant-oat01-A"
  out="$(printf 'sk-ant-oat01-B' | cs save personal --force 2>&1)"
  assert_contains "second save with --force succeeds" "$out" "saved profile 'personal'"
  saved="$(cat "$HOME/.claude/accounts/personal.token")"
  assert_eq "token replaced with --force" "$saved" "sk-ant-oat01-B"
  teardown
}

t_save_empty_token_rejected() {
  echo "[save: empty token rejected]"
  setup
  local out
  out="$(printf '' | cs save personal 2>&1)"
  assert_contains "empty token rejected" "$out" "empty token"
  assert_file_absent "no token file written" "$HOME/.claude/accounts/personal.token"
  teardown
}

t_save_bad_prefix_rejected_no_leak() {
  echo "[save: bad prefix rejected, no token leak]"
  setup
  local secret="aws-secret-key-AKIAEXAMPLE_SECRET_NEVER_LEAK"
  local out
  out="$(printf '%s' "$secret" | cs save personal 2>&1)"
  assert_contains "bad prefix rejected" "$out" "doesn't look like a Claude setup-token"
  assert_not_contains "first 20 chars NOT printed" "$out" "aws-secret-key-AKIAE"
  assert_not_contains "no length info leaked" "$out" "length"
  assert_file_absent "no token file written" "$HOME/.claude/accounts/personal.token"
  teardown
}

t_save_token_flag_warning() {
  echo "[save: --token flag warns about history]"
  setup
  local out
  out="$(cs save personal --token sk-ant-oat01-VIA-FLAG 2>&1)"
  assert_contains "--token flag warning emitted" "$out" "shell history"
  assert_contains "save still succeeds" "$out" "saved profile"
  teardown
}

t_save_missing_user_cfg() {
  echo "[save: missing ~/.claude.json]"
  setup
  rm -f "$HOME/.claude.json"
  local out
  out="$(printf 'sk-ant-oat01-x' | cs save personal 2>&1)"
  assert_contains "missing user_cfg detected" "$out" ".claude.json missing"
  assert_file_absent "no token file written" "$HOME/.claude/accounts/personal.token"
  teardown
}

t_save_missing_oauth_account() {
  echo "[save: ~/.claude.json without oauthAccount]"
  setup
  echo '{"unrelated":"x"}' >"$HOME/.claude.json"
  local out
  out="$(printf 'sk-ant-oat01-x' | cs save personal 2>&1)"
  assert_contains "missing oauthAccount detected" "$out" "no .oauthAccount"
  teardown
}

t_save_umask_not_leaked() {
  echo "[save: umask preserved across function call]"
  setup
  umask 022
  local before after
  before="$(umask)"
  printf 'sk-ant-oat01-x' | cs save personal >/dev/null 2>&1
  after="$(umask)"
  assert_eq "umask unchanged after cs save" "$after" "$before"
  teardown
}

t_save_unknown_flag() {
  echo "[save: unknown flag rejected]"
  setup
  local out
  out="$(cs save personal --bogus 2>&1)"
  assert_contains "unknown flag error" "$out" "unknown flag '--bogus'"
  teardown
}

t_save_too_many_args() {
  echo "[save: too many positional args]"
  setup
  local out
  out="$(cs save personal extra 2>&1)"
  assert_contains "too many args error" "$out" "too many args"
  teardown
}

t_save_stdin_flag_explicit() {
  echo "[save: --stdin flag explicit]"
  setup
  local out
  out="$(printf 'sk-ant-oat01-via-explicit-stdin' | cs save personal --stdin 2>&1)"
  assert_contains "explicit --stdin succeeds" "$out" "saved profile 'personal'"
  local saved
  saved="$(<"$HOME/.claude/accounts/personal.token")"
  assert_eq "explicit --stdin token saved" "$saved" "sk-ant-oat01-via-explicit-stdin"
  teardown
}

t_save_no_input_method() {
  echo "[save: no input method available]"
  setup
  # Force "no clipboard" by clearing the detected commands.
  _CS_PASTE_CMD="" _CS_COPY_CMD=""
  rm -f "$SANDBOX/bin/pbpaste" "$SANDBOX/bin/pbcopy"
  hash -r
  local out rc
  # stdin from /dev/null makes [[ ! -t 0 ]] true so it falls through to stdin
  # path and gets empty input. We just want to confirm graceful failure.
  out="$(cs save personal </dev/null 2>&1)"
  rc=$?
  assert_eq "save with no real input fails cleanly" "$rc" "1"
  teardown
}

t_save_no_clipboard_no_stdin() {
  echo "[save: --clipboard requested but no clipboard tool detected]"
  setup
  _CS_PASTE_CMD="" _CS_COPY_CMD=""
  rm -f "$SANDBOX/bin/pbpaste" "$SANDBOX/bin/pbcopy"
  hash -r
  local out
  out="$(cs save personal --clipboard 2>&1 </dev/null)"
  assert_contains "no-clipboard error mentions all known tools" "$out" "no clipboard tool found"
  teardown
}

t_clipboard_helpers_route_through_indirection() {
  echo "[clipboard: helpers respect _CS_PASTE_CMD / _CS_COPY_CMD]"
  setup
  # Repoint paste/copy at our stubs explicitly, even if detection chose differently.
  _CS_PASTE_CMD="pbpaste"
  _CS_COPY_CMD="pbcopy"
  export TEST_CLIPBOARD="hello-from-test-clipboard"
  local got
  got="$(_cs_paste)"
  assert_eq "_cs_paste returns clipboard content" "$got" "hello-from-test-clipboard"
  echo "written-via-helper" | _cs_copy
  local sent
  sent="$(<"$SANDBOX/.pbcopy.last")"
  assert_eq "_cs_copy writes through to clipboard tool" "$sent" "written-via-helper"
  teardown
}

t_stat_mode_helper() {
  echo "[stat: _cs_stat_mode returns numeric mode]"
  setup
  local f="$SANDBOX/.modetest"
  touch "$f"
  chmod 644 "$f"
  local m
  m="$(_cs_stat_mode "$f")"
  assert_eq "_cs_stat_mode reports 644" "$m" "644"
  chmod 600 "$f"
  m="$(_cs_stat_mode "$f")"
  assert_eq "_cs_stat_mode reports 600" "$m" "600"
  teardown
}

t_save_clipboard_clears_after_use() {
  echo "[save: clipboard cleared after successful clipboard-source save]"
  setup
  export TEST_CLIPBOARD="sk-ant-oat01-FROM-CLIPBOARD"
  # Need to feed Enter past the "press Enter to confirm" prompt and force clipboard
  echo "" | cs save personal --clipboard >/dev/null 2>&1
  # Our fake pbcopy writes to $SANDBOX/.pbcopy.last; if cleared, file is empty
  if [[ -f "$SANDBOX/.pbcopy.last" ]]; then
    local sz
    sz="$(wc -c <"$SANDBOX/.pbcopy.last" | tr -d ' ')"
    assert_eq "pbcopy was called with empty input" "$sz" "0"
  else
    _fail "pbcopy was called after clipboard-source save" "expected $SANDBOX/.pbcopy.last to exist"
  fi
  teardown
}

t_use_invalid_name() {
  echo "[use: invalid name rejected]"
  setup
  local out
  out="$(cs use ../foo 2>&1)"
  assert_contains "use '../foo' rejected" "$out" "invalid profile name"
  out="$(cs use 2>&1)"
  assert_contains "use no-arg shows usage" "$out" "cs use"
  teardown
}

t_use_missing_files() {
  echo "[use: missing files report cleanly]"
  setup
  local out
  out="$(cs use ghost 2>&1)"
  assert_contains "missing token file detected" "$out" "missing token"
  # Now create only token, not account
  mkdir -p "$HOME/.claude/accounts"
  printf 'sk-ant-oat01-x' >"$HOME/.claude/accounts/half.token"
  out="$(cs use half 2>&1)"
  assert_contains "missing account snapshot detected" "$out" "missing account snapshot"
  teardown
}

t_use_happy_path() {
  echo "[use: happy path exports env var]"
  setup
  seed_profile personal
  # IMPORTANT: cannot use `out=$(cs use ...)` — that runs cs use in a subshell,
  # so any env exports / shell-var assignments are lost on subshell exit.
  # Redirect stdout/stderr to a file instead so the function executes in this
  # shell and we can still inspect its output.
  cs use personal >|"$SANDBOX/.use.out" 2>&1
  local out
  out="$(<"$SANDBOX/.use.out")"
  assert_contains "use prints email" "$out" "personal@example.com"
  assert_eq "_CS_PROFILE set" "${_CS_PROFILE:-}" "personal"
  assert_eq "CLAUDE_CODE_OAUTH_TOKEN exported" "${CLAUDE_CODE_OAUTH_TOKEN:-}" "sk-ant-oat01-FAKE-TOKEN-FOR-TESTS"
  teardown
}

t_off_unsets() {
  echo "[off: clears env]"
  setup
  seed_profile personal
  cs use personal >/dev/null 2>&1
  cs off >/dev/null 2>&1
  assert_eq "_CS_PROFILE unset" "${_CS_PROFILE:-_NONE_}" "_NONE_"
  assert_eq "CLAUDE_CODE_OAUTH_TOKEN unset" "${CLAUDE_CODE_OAUTH_TOKEN:-_NONE_}" "_NONE_"
  teardown
}

t_list() {
  echo "[list]"
  setup
  local out
  out="$(cs list 2>&1)"
  assert_contains "list with no profiles" "$out" "no profiles"
  seed_profile personal
  seed_profile work
  # incomplete profile (token but no account snapshot)
  printf 'sk-ant-oat01-x' >"$HOME/.claude/accounts/halfbaked.token"
  out="$(cs list 2>&1)"
  assert_contains "list shows personal email" "$out" "personal@example.com"
  assert_contains "list shows work email" "$out" "work@example.com"
  assert_contains "incomplete profile flagged" "$out" "incomplete"
  cs use personal >/dev/null 2>&1
  out="$(cs list 2>&1)"
  assert_contains "pinned profile gets * marker" "$out" "* personal"
  assert_contains "non-pinned profile no marker" "$out" "  work"
  teardown
}

# Install a fake curl that emulates the API's HTTP status line. It inspects its
# args for the bearer token and prints a code: tokens containing "EXPIRED" ->
# 401, "DOWN" -> 000 (unreachable), otherwise 200. Matches the real curl's
# `-w '%{http_code}'` contract (code on stdout, body discarded via -o).
stub_curl() {
  cat >"$SANDBOX/bin/curl" <<'SH'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    *EXPIRED*) printf '401'; exit 0 ;;
    *DOWN*)    printf '000'; exit 0 ;;
  esac
done
printf '200'
SH
  chmod +x "$SANDBOX/bin/curl"
}

t_doctor() {
  echo "[doctor: validates tokens against API]"
  setup
  stub_curl
  local out
  out="$(cs doctor 2>&1)"
  assert_contains "doctor with no profiles" "$out" "no profiles"

  seed_profile personal
  seed_profile work sk-ant-oat01-EXPIRED-TOKEN
  seed_profile dead sk-ant-oat01-DOWN-TOKEN

  out="$(cs doctor 2>&1)"
  assert_contains "healthy token reported OK" "$out" "personal@example.com: OK"
  assert_contains "expired token reported EXPIRED" "$out" "work@example.com: EXPIRED (401)"
  assert_contains "unreachable token reported" "$out" "dead@example.com: UNREACHABLE"
  assert_contains "expired triggers re-mint hint" "$out" "cs save <name> --force"

  # Non-zero exit when any token is expired (for scripting).
  cs doctor >/dev/null 2>&1
  assert_eq "doctor returns 1 when a token is expired" "$?" "1"

  # All-healthy run exits 0 and pins the * marker on the active profile.
  rm -f "$HOME/.claude/accounts/work."* "$HOME/.claude/accounts/dead."*
  cs use personal >/dev/null 2>&1
  out="$(cs doctor 2>&1)"
  assert_contains "active profile gets * marker" "$out" "* personal"
  cs doctor >/dev/null 2>&1
  assert_eq "doctor returns 0 when all healthy" "$?" "0"
  teardown
}

t_current() {
  echo "[current]"
  setup
  seed_profile personal
  local out
  out="$(cs current 2>&1)"
  assert_contains "current when unset" "$out" "none"
  cs use personal >/dev/null 2>&1
  out="$(cs current 2>&1)"
  assert_eq "current when set" "$out" "personal"

  unset _CS_PROFILE
  out="$(cs current 2>&1)"
  assert_contains "current warns on token/profile mismatch" "$out" "token set, profile unknown"
  assert_contains "current mismatch includes recovery hint" "$out" "re-run: cs use <name>"
  teardown
}

t_resource_preserves_profile() {
  echo "[re-source: preserves active profile pin]"
  setup
  seed_profile personal
  cs use personal >/dev/null 2>&1

  source "$CS_ZSH"

  assert_eq "_CS_PROFILE preserved after re-source" "${_CS_PROFILE:-_NONE_}" "personal"
  local out
  out="$(cs current 2>&1)"
  assert_eq "current still reports pinned profile after re-source" "$out" "personal"
  teardown
}

t_rm_invalid_name() {
  echo "[rm: invalid name rejected — no fs side effects]"
  setup
  # Plant a sentinel file that a path-traversal rm would otherwise hit
  echo "DO NOT DELETE" >"$HOME/.claude/sentinel.token"
  local out
  out="$(cs rm "../sentinel" 2>&1)"
  assert_contains "rm '../sentinel' rejected" "$out" "invalid profile name"
  assert_file_exists "sentinel survived path-traversal rm" "$HOME/.claude/sentinel.token"
  out="$(cs rm 2>&1)"
  assert_contains "rm no-arg shows usage" "$out" "cs rm"
  teardown
}

t_rm_nonexistent() {
  echo "[rm: nonexistent profile errors]"
  setup
  local out
  out="$(cs rm ghost 2>&1)"
  assert_contains "rm ghost reports missing" "$out" "no such profile"
  teardown
}

t_rm_aborted_no() {
  echo "[rm: declining the prompt aborts]"
  setup
  seed_profile personal
  local out
  out="$(printf 'n\n' | cs rm personal 2>&1)"
  assert_contains "rm aborted on n" "$out" "aborted"
  assert_file_exists "token kept after abort" "$HOME/.claude/accounts/personal.token"
  teardown
}

t_rm_confirmed_yes() {
  echo "[rm: confirming the prompt deletes both files]"
  setup
  seed_profile personal
  printf 'y\n' | cs rm personal >/dev/null 2>&1
  assert_file_absent "token removed" "$HOME/.claude/accounts/personal.token"
  assert_file_absent "account snapshot removed" "$HOME/.claude/accounts/personal.account.json"
  teardown
}

t_rm_pinned_clears_env() {
  echo "[rm: removing pinned profile clears env]"
  setup
  seed_profile personal
  cs use personal >/dev/null 2>&1
  printf 'y\n' | cs rm personal >/dev/null 2>&1
  assert_eq "_CS_PROFILE cleared" "${_CS_PROFILE:-_NONE_}" "_NONE_"
  assert_eq "CLAUDE_CODE_OAUTH_TOKEN cleared" "${CLAUDE_CODE_OAUTH_TOKEN:-_NONE_}" "_NONE_"
  teardown
}

t_claude_wrapper_unpinned_passthrough() {
  echo "[claude wrapper: unpinned just passes through]"
  setup
  local out
  out="$(claude hello 2>&1)"
  assert_contains "fake claude invoked" "$out" "FAKE_CLAUDE: hello"
  assert_not_contains "no profile prefix when unpinned" "$out" "launching claude"
  teardown
}

t_claude_wrapper_pinned_patches_json() {
  echo "[claude wrapper: pinned patches ~/.claude.json]"
  setup
  seed_profile personal
  cs use personal >/dev/null 2>&1
  local out
  out="$(claude foo 2>&1)"
  assert_contains "wrapper announces profile" "$out" "launching claude as 'personal'"
  assert_contains "fake claude got args" "$out" "FAKE_CLAUDE: foo"
  # Verify ~/.claude.json oauthAccount was rewritten
  local email
  email="$(jq -r '.oauthAccount.emailAddress' "$HOME/.claude.json")"
  assert_eq "oauthAccount email patched to profile's" "$email" "personal@example.com"
  local preserved
  preserved="$(jq -r '.unrelatedKey' "$HOME/.claude.json")"
  assert_eq "unrelated json keys preserved" "$preserved" "must_be_preserved"
  teardown
}

t_claude_wrapper_invalid_profile() {
  echo "[claude wrapper: refuses bad _CS_PROFILE]"
  setup
  _CS_PROFILE="../escape"
  local out
  out="$(claude 2>&1)"
  assert_contains "wrapper refuses path-traversal _CS_PROFILE" "$out" "refusing to launch"
  assert_not_contains "fake claude NOT invoked" "$out" "FAKE_CLAUDE"
  teardown
}

t_claude_wrapper_skips_symlink_cfg() {
  echo "[claude wrapper: skips patch when ~/.claude.json is a symlink]"
  setup
  seed_profile personal
  cs use personal >/dev/null 2>&1
  rm "$HOME/.claude.json"
  ln -s "$HOME/elsewhere.json" "$HOME/.claude.json"
  local out
  out="$(claude 2>&1)"
  assert_contains "symlink warning emitted" "$out" "symlink"
  assert_contains "fake claude still launched" "$out" "FAKE_CLAUDE"
  assert_file_absent "did NOT create symlink target" "$HOME/elsewhere.json"
  teardown
}

#------------------------------------------------------------------- run

t_validate_name
t_help
t_save_invalid_name
t_save_happy_path_stdin
t_save_strips_whitespace
t_save_force_required_to_overwrite
t_save_empty_token_rejected
t_save_bad_prefix_rejected_no_leak
t_save_token_flag_warning
t_save_missing_user_cfg
t_save_missing_oauth_account
t_save_umask_not_leaked
t_save_unknown_flag
t_save_too_many_args
t_save_stdin_flag_explicit
t_save_no_input_method
t_save_no_clipboard_no_stdin
t_clipboard_helpers_route_through_indirection
t_stat_mode_helper
t_save_clipboard_clears_after_use
t_use_invalid_name
t_use_missing_files
t_use_happy_path
t_off_unsets
t_list
t_doctor
t_current
t_resource_preserves_profile
t_rm_invalid_name
t_rm_nonexistent
t_rm_aborted_no
t_rm_confirmed_yes
t_rm_pinned_clears_env
t_claude_wrapper_unpinned_passthrough
t_claude_wrapper_pinned_patches_json
t_claude_wrapper_invalid_profile
t_claude_wrapper_skips_symlink_cfg

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
