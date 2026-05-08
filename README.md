# claude-switch

Run multiple Claude Code accounts side-by-side in different terminals.  
No constant `/logout` / `/login` ping-pong. ✨

```sh
# Terminal A
cs use personal
claude

# Terminal B
cs use work
claude
```

Each terminal stays pinned to its own account.

## Why this exists

Switching between Claude accounts all day is annoying, especially when the accounts have MFA enabled and you constantly hit rate limits.
You log in here, log out there, and eventually lose track of which terminal is using which identity. `claude-switch` fixes that by pinning one token per shell.

## How it works

1. `cs save <name>` stores:
   - a setup token (`claude setup-token`)
   - a snapshot of `oauthAccount` from `~/.claude.json`
2. `cs use <name>` sets that token in the current shell only.
3. The `claude` wrapper updates `oauthAccount` in `~/.claude.json` so `/status` matches the pinned account.

Auth comes from the env var token. The file update is display-only.

## Requirements

- macOS or Linux
- `zsh`
- [Claude Code CLI](https://claude.com/claude-code)
- `jq` (`brew install jq` on macOS, `apt install jq` on Debian/Ubuntu)
- Optional clipboard tool for non-pipe saves:
  - macOS: `pbpaste` / `pbcopy`
  - Linux (X11): `xclip`
  - Linux (Wayland): `wl-clipboard`
  - Pipe mode always works: `claude setup-token | cs save name`

## Install

### With a zsh plugin manager (recommended)

**zinit:**

```sh
zinit load tenkenco/claude-switch
```

**oh-my-zsh:**

```sh
git clone https://github.com/tenkenco/claude-switch \
  "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/claude-switch"
# then add `claude-switch` to your plugins=(...) array in ~/.zshrc
```

**sheldon** (in `~/.config/sheldon/plugins.toml`):

```toml
[plugins.claude-switch]
github = "tenkenco/claude-switch"
```

**antidote** (in `~/.zsh_plugins.txt`):

```text
tenkenco/claude-switch
```

### Without a plugin manager

```sh
git clone https://github.com/tenkenco/claude-switch.git ~/.claude-switch
~/.claude-switch/install.sh
```

Then open a new terminal (or `source ~/.zshrc`) and run `cs help`.

## One-time setup (per account)

```sh
# Login to account A in Claude Code first
claude setup-token | cs save personal

# Login to account B
claude setup-token | cs save work
```

Done. 🎉

## Daily usage

```sh
cs use work
claude

cs list
cs current
cs off
cs rm work
```

## Notes

- ⚠️ Setup tokens are CI-style auth: inference works, but default model/MCP behavior can differ from full interactive login.
- 🖥️ CLI-only: desktop app and IDE extensions do not inherit your shell env var.
- 🔐 `~/.claude/accounts/*.token` are bearer credentials. Protect them like API keys.
- 🧩 This tool depends on Claude Code internals, so future Claude releases may require updates.

## Tests

```sh
./tests/smoke.zsh
```

Covers profile validation, save/use/off/list/current/rm flows, wrapper behavior, and security checks.  
CI runs this suite on both macOS and Ubuntu in `.github/workflows/test.yml`.

## Design notes

[DESIGN.md](DESIGN.md) explains the experiments and why keychain-only swapping fails in long-running concurrent sessions.

## Contributing

- Use GitHub Issue templates for bug reports and feature requests.
- For setup/help questions, use GitHub Discussions.
- Before opening a PR, run:

```sh
./tests/smoke.zsh
```

- Follow the PR template checklist (test plan + docs updates where relevant).

## License

MIT ([LICENSE](LICENSE))
