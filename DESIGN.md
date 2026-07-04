# Design notes

The day-to-day setup and commands are documented in [README.md](README.md).  
This document explains the reasoning behind the implementation: what we tried, what failed, and why the final approach stays intentionally simple.

## Goal

I had enough of switching accounts whenever my Claude limit was reached.
The goal of `claude-switch` is to make concurrent account switching a touch
more bearable than logging into different MFA-enabled Google accounts
manually.

The goal is to make sure there's no silent identity drift, no background
daemons to babysit, and no brittle interception layer.

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
`claude-switch` (and `cs doctor`) may need an update.
