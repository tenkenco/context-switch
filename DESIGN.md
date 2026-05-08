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

On macOS (observed with Claude Code `2.1.132`), identity-related state appears in three places:

1. **Keychain: `Claude Code-credentials`**
   - Holds primary OAuth state (access token, refresh token, etc.)
   - Access tokens are refreshed in place while Claude is running

2. **`~/Library/Application Support/Claude/config.json` -> `oauth:tokenCache`**
   - Looks token-related at first glance
   - Is *not* the per-account OAuth state that matters for this problem

3. **`~/.claude.json` -> `oauthAccount`**
   - Drives visible identity (`/status`, email/org banner)
   - Is not the primary auth source

## Approach that looked good, then broke

The first attempt with Claude Code was straightforward: I had it write the desired keychain blob right before launching `claude`.

That works for short runs, but breaks in longer concurrent sessions:

1. Terminal A starts with account `work`
2. Terminal B starts with account `personal`
3. A later refresh in A reads the keychain entry currently on disk (`personal`) and silently flips

Because refreshes reuse shared keychain state, launch-time swapping alone cannot guarantee long-running per-process isolation.

## What works in practice

Use `CLAUDE_CODE_OAUTH_TOKEN` per shell.

When this is set, Claude follows the env-var token path instead of the keychain refresh behavior that causes drift. In practice, this gives true terminal-level isolation.

The tokens also are long-lived, so there's no need to re-login every time.

## Why `claude setup-token` is part of the flow

The env-var path expects long-lived tokens, so `claude setup-token` is the practical source. It's just a one-time setup to get the token every time I want to use a different account.

Tradeoff:

- isolation is reliable
- token-based auth can behave a little differently from normal login mode (default model selection, how `/status` displays identity, and MCP servers sometimes needing re-auth or showing different workspace context)

## Why we still patch `~/.claude.json`

Even when auth comes from `CLAUDE_CODE_OAUTH_TOKEN`, `/status` display still reads from global `oauthAccount`.
To keep the visible identity aligned with the selected account, the wrapper updates `oauthAccount` before launch.

That patch is cosmetic; authentication still comes from the env-var token.

```sh
cs use <name>  # exports CLAUDE_CODE_OAUTH_TOKEN (auth source)
claude         # patches oauthAccount for display, then runs real claude
```

## Out of scope

- local HTTP proxy for refresh interception
- multiple Claude installs as an isolation hack
- heavy per-profile full config isolation by default

Those options add moving parts and maintenance burden without improving the core reliability story.

## Platform support

The core mechanism (env-var auth, `oauthAccount` snapshot, and `~/.claude.json` patching) is platform-agnostic. The only macOS/Linux differences today are shell utilities:

| Concern | macOS | Linux |
| ------- | ----- | ----- |
| Clipboard helper | `pbpaste` / `pbcopy` | `wl-paste` / `wl-copy` (Wayland), `xclip` or `xsel` (X11) |
| File-mode read | `stat -f '%Lp'` (BSD) | `stat -c '%a'` (GNU) |

These are abstracted at source time:

```zsh
typeset -g _CS_PASTE_CMD _CS_COPY_CMD   # detected once when cs.zsh is sourced
_cs_have_clipboard / _cs_paste / _cs_copy / _cs_stat_mode   # only platform-aware helpers
```

Supporting additional Unix-like platforms (for example, BSD variants) should only require extending detection and possibly `_cs_stat_mode`. The keychain analysis, env-var auth path, and JSON patch strategy stay the same.

Native Windows is not currently supported because token storage behavior there has not been characterized. WSL follows the Linux path.

## Re-validate on new Claude versions

If Claude internals change, quickly re-check the assumptions:

```sh
strings "$(realpath "$(command -v claude)")" | grep -F "Claude Code-credentials"
jq '.oauthAccount | keys' ~/.claude.json
CLAUDE_CODE_OAUTH_TOKEN="<token>" claude -p "say pong"
```

If any of these assumptions drift, `claude-switch` may need an update.
