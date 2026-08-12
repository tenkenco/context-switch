# Design notes

The day-to-day setup and commands are documented in [README.md](README.md).  
This document explains the reasoning behind the implementation: what we tried, what failed, and why the final approach stays intentionally simple.

## Goal

I had enough of switching accounts whenever my Claude limit was reached.
The goal of `context-switch` is to make concurrent account switching a touch
more bearable than logging into different MFA-enabled Google accounts
manually.

The goal is to make sure there's no silent identity drift, no background
daemons to babysit, and no brittle interception layer.

The same problem turned out to be general. Claude Code is one tool among many
that keeps its identity in a global file. So the tool now pins other CLIs too.
See [Generalizing past Claude Code](#generalizing-past-claude-code) below.

## Where identity state actually lives

On macOS, identity-related state appears in a few places:

1. **Keychain: `Claude Code-credentials`**
   - Holds primary OAuth state (access token, refresh token, etc.)
   - Access tokens are refreshed in place while Claude is running

2. **`~/Library/Application Support/Claude/config.json` -> `oauth:tokenCache`**
   - Looks token-related at first glance
   - Is *not* the per-account OAuth state that matters for this problem

3. **`~/.claude.json` -> `oauthAccount`**
   - Drives visible identity (`/status`, email/org banner)
   - Is not the primary auth source

4. **`CLAUDE_CONFIG_DIR`**
   - Overrides the Claude Code config/auth namespace for a process
   - Lets each shell point Claude at a different profile directory

## Approach that looked good, then broke

The first attempt with Claude Code was straightforward: I had it write the desired keychain blob right before launching `claude`.

That works for short runs, but breaks in longer concurrent sessions:

1. Terminal A starts with account `work`
2. Terminal B starts with account `personal`
3. A later refresh in A reads the keychain entry currently on disk (`personal`) and silently flips

Because refreshes reuse shared keychain state, launch-time swapping alone cannot guarantee long-running per-process isolation.

## What worked at first

Use `CLAUDE_CODE_OAUTH_TOKEN` per shell.

When this is set, Claude follows the env-var token path instead of the keychain refresh behavior that causes drift. In earlier Claude Code builds, this gave true terminal-level isolation.

The tokens also are long-lived, so there's no need to re-login every time.

## What works now (Claude Code 2.x)

Use a per-profile `CLAUDE_CONFIG_DIR` — and nothing else.

Claude Code 2.x moved OAuth credentials into the OS keychain, but keyed each
entry by a hash of the config dir:

```text
service name = "Claude Code-credentials-" + sha256(CLAUDE_CONFIG_DIR)[0:8]
```

So the keychain no longer has one shared blob that launch-time swapping fought
over — each `CLAUDE_CONFIG_DIR` gets its own credential slot. Pointing each
shell at its own profile dir gives true, durable credential isolation with no
interception layer at all:

```sh
cs login <name>   # one-time: claude auth login with CLAUDE_CONFIG_DIR=~/.claude/profiles/<name>
cs use <name>      # exports that CLAUDE_CONFIG_DIR for this shell
claude             # launches using the profile's keychain slot
```

The setup-token / `CLAUDE_CODE_OAUTH_TOKEN` path and the `oauthAccount` patch
were removed: config-dir hashing makes them unnecessary, and each carried its
own failure modes (CI-tier auth, expired tokens silently falling back to the
keychain, cosmetic patches drifting from real logins). `/status` already reads
correctly from each profile's own `.claude.json`, written by its login.

## The failure mode that remains: refresh-token rotation

Config-dir hashing isolates credential *storage*, but it does **not** isolate an
account's refresh-token lineage. Claude Code uses rotating OAuth refresh tokens:
each refresh issues a new refresh token and invalidates the previous one.

If the *same* account is logged into two credential slots — two profiles, or a
profile plus the unpinned default namespace — then whichever slot refreshes last
invalidates the other. The next time you use the stale slot, refresh fails with
a 401 and Claude Code asks you to `/login`. This looks exactly like "switching
broke my other account."

The fix is a usage rule, not code: **one account, one profile; always `cs use`
before `claude`.** `cs doctor` enforces it by reporting the account behind every
namespace (including the default) and failing if any account appears twice.

## Generalizing past Claude Code

Claude Code is not special here. Most CLI tools read their config path from an
environment variable, and store the active identity in one global file. The
environment variable is the escape hatch, because environment variables are per
process and children inherit them.

gcloud is the sharpest example, and the reason this feature exists:

- `~/.config/gcloud/active_config` names the active configuration. It is one
  file for every shell, so `gcloud config configurations activate` and
  `gcloud auth login` switch every terminal at once. Named configurations do
  not help, because activation itself is global.
- `~/.config/gcloud/application_default_credentials.json` holds the application
  default credentials. `gcloud auth application-default login` overwrites it
  with the newest account. The Terraform google provider reads that file, so a
  login for one account breaks Terraform runs for the other.

`CLOUDSDK_CONFIG` moves both files into a per-profile directory, which removes
the shared state entirely.

### Why `profile.env` sets two variables for gcloud

The recommended `profile.env` sets `CLOUDSDK_CONFIG` **and**
`GOOGLE_APPLICATION_CREDENTIALS`. The gcloud CLI honors the first. Whether Go's
application-default lookup honors it depends on the version of
`golang.org/x/oauth2/google` compiled into the tool, and the Terraform google
provider is Go. Every Google auth library honors
`GOOGLE_APPLICATION_CREDENTIALS` unconditionally. Setting both makes the
uncertain fact irrelevant.

### Why a data file and not per-tool code

A `profile.env` file makes adding a tool a data change, not a code change. The
repository stays one small zsh file. Per-tool logic can move into
`providers/*.zsh` later, if login or health-check behavior ever needs it.

### What the tracking contract buys

`cs` parses `export VAR=value` lines and records those names in
`_CS_PROFILE_ENV_VARS` at load time. It then unsets exactly those names on
`cs off`, and before applying a different profile.

Clearing before `cs use` applies the next profile is the important case. Without
it, `cs use work` after `cs use personal` would leave personal's
`CLOUDSDK_CONFIG` in a shell that claims to be work. That is the identity drift
this tool exists to prevent. `cs run` clears the caller's env for the same
reason, inside its subshell, before it loads the target profile.

Recording at load time is deliberate. Re-reading the file at unload time would
strand variables whenever the file changed or was deleted in between.

Recording happens *before* the file is sourced, which is subtler and matters
more. `source` returns the exit status of the file's last command. An ordinary
trailing line such as

```sh
[[ -d "$HOME/work-tools" ]] && export EXTRA=1
```

returns non-zero whenever that test fails — with every earlier export already
applied. An implementation that recorded the names after a successful `source`
would skip the record on exactly that file, and leave those variables set and
untracked forever. An ordering mistake would reintroduce the same drift.

### The refused-names list

`cs` rejects a `profile.env` outright when it exports `PATH`, `HOME`, `IFS`,
`PWD`, `OLDPWD`, `SHELL`, `TMPDIR`, `CLAUDE_CONFIG_DIR`, `_CS_PROFILE`, or
`_CS_PROFILE_ENV_VARS`.

The reason is the clearing rule above. `cs off` unsets every tracked name, so
tracking `PATH` would leave a shell that cannot run a single command. The last
three name the pin, so a file that sets them could make `cs use` report one
profile while `claude` launches as another.

Rejecting the whole file beats ignoring one line. A partly applied file leaves
the user with an identity they did not ask for and no error to explain it.

`cs use` also re-asserts `CLAUDE_CONFIG_DIR` and `_CS_PROFILE` after sourcing.
The refused-names check reads `export` lines, but the file is sourced, so a bare
`CLAUDE_CONFIG_DIR=...` assignment still updates the already-exported variable.
Arbitrary code in a sourced file cannot be fully contained; re-asserting the two
values cs actually knows is cheap and closes the case that matters.

### Why profiles stay under `~/.claude/profiles`

The path is now a misnomer, and it stays anyway. Claude Code names each keychain
entry after `sha256(CLAUDE_CONFIG_DIR)`. Moving the profiles directory changes
every hash, orphans every stored credential, and forces a re-login for every
profile. The cosmetic gain is not worth that.

### Sourcing is running code

`cs use` sources `profile.env`, so the file executes with your shell's
privileges. `cs` refuses to source a file that is group- or world-writable. It
does not sandbox the contents, because a file in your own home directory offers
no meaningful boundary to sandbox against. Keep the file to plain exports.

## Out of scope

- local HTTP proxy for refresh interception
- multiple Claude installs as an isolation hack

Those options add moving parts and maintenance burden without improving the core reliability story.

## Platform support

The whole mechanism is now just `CLAUDE_CONFIG_DIR` plus a `sha256` for the
keychain-service name (used by `cs rm`/`cs doctor`), so there is almost nothing
platform-specific left. `shasum` ships on macOS and most Linux; `sha256sum` is
the Linux fallback. Keychain deletion in `cs rm` uses `security` on macOS and is
skipped elsewhere (removing the profile dir is still enough to switch away).

Native Windows is not supported because keychain behavior there has not been
characterized. WSL follows the Linux path.

## Re-validate on new Claude versions

If Claude internals change, quickly re-check the assumptions:

```sh
# 1. Are credentials still keyed by sha256(CLAUDE_CONFIG_DIR)?
security dump-keychain 2>/dev/null | grep -o '"Claude Code-credentials[^"]*"' | sort -u
printf '%s' "$HOME/.claude/profiles/personal" | shasum -a 256 | cut -c1-8   # expect a matching suffix

# 2. Does each isolated config resolve to its own account?
CLAUDE_CONFIG_DIR="$HOME/.claude/profiles/personal" claude auth status --json
CLAUDE_CONFIG_DIR="$HOME/.claude/profiles/work"     claude auth status --json
```

If the suffix no longer matches, or two config dirs collapse to one account,
`context-switch` (and `cs doctor`) may need an update.
