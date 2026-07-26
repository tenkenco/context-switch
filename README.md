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
You log in here, log out there, and eventually lose track of which terminal is using which identity. `claude-switch` fixes that by pinning one isolated Claude Code config per shell.

## How it works

1. `cs login <name>` runs `claude auth login` with `CLAUDE_CONFIG_DIR` pointed at `~/.claude/profiles/<name>`.
2. Claude Code 2.x stores that account's OAuth credentials in the OS keychain, in an entry keyed by a hash of `CLAUDE_CONFIG_DIR` (`Claude Code-credentials-<sha256(dir)[:8]>`). Each profile therefore gets its own isolated credential slot.
3. `cs use <name>` exports that same `CLAUDE_CONFIG_DIR` in the current shell only.
4. `claude` launches using the pinned profile's credentials — no rewriting, no env tokens.

### The one rule that matters

**One account → one profile, and always `cs use` before `claude`.**

Claude Code rotates OAuth refresh tokens: every refresh invalidates the previous refresh token. If the *same* account is logged into two credential slots — two profiles, or a profile **and** the unpinned default config — each refresh silently invalidates the other, and you get surprise `Please run /login` 401s. That is the single most common cause of "it made me log in again."

Run `cs doctor` to catch it: it lists every namespace's account and flags any account that appears in more than one.

## Requirements

- macOS or Linux
- `zsh`
- [Claude Code CLI](https://claude.com/claude-code) (2.x)
- `jq` (`brew install jq` on macOS, `apt install jq` on Debian/Ubuntu)

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
# Login to account A inside an isolated profile
cs login personal --claudeai --email you@example.com

# Login to account B inside a different isolated profile
cs login work --claudeai --email you@work.com
```

Each login opens Claude's normal browser OAuth flow once. After that, daily switching uses the saved isolated config.

> **Don't also log in unpinned.** If you run `claude` with no profile pinned, it logs into the *default* namespace. If that account also has a profile, the two will rotate each other's refresh tokens and force re-logins. Keep each account in exactly one profile.

Done. 🎉

## Daily usage

```sh
cs use work      # terminal A → work
claude

cs use personal  # terminal B → personal
claude

cs run work -- -p "hi"   # one-shot: run claude as work without pinning
cs list          # show profiles, * marks this shell's pin
cs current       # what is this shell pinned to?
cs doctor        # verify logins + catch duplicate-account slots
cs off           # unpin this shell
cs rm work       # delete a profile's config + keychain login
```

## The `claude` wrapper (and how to avoid it)

Sourcing `cs.zsh` defines a `claude` shell function that keeps `CLAUDE_CONFIG_DIR` aligned with your pin and strips overriding auth vars before launching the real binary.

If another plugin or your own `.zshrc` already defines `claude`, claude-switch replaces it and says so, keeping the previous definition as `_cs_prev_claude`. To restore it:

```sh
functions[claude]=$functions[_cs_prev_claude]
```

To leave the `claude` name alone after sourcing, restore the previous definition as shown above and use `cs run`, which executes the real binary directly under a profile:

```sh
cs run work -- --version
```

Once you've made that choice, silence the per-shell notice with:

```sh
export CS_QUIET=1
```

`CS_QUIET` suppresses the advisory notices only. If claude-switch ever replaces a `claude` function it could **not** preserve, it still says so — that's data loss, not an advisory.

> **Note on `ANTHROPIC_BASE_URL`.** claude-switch strips overriding auth variables so the *identity* comes only from the profile's keychain slot, but it deliberately does not strip `ANTHROPIC_BASE_URL` — you may need it to reach the API at all. It controls *where* requests go, so the profile's token is sent to whatever endpoint it names. Every command that launches Claude warns when it is set.

## Notes

- ✅ `cs login` profiles use Claude Code's full `claude.ai` login in an isolated config directory (keychain-backed, per `CLAUDE_CONFIG_DIR`).
- 🩺 `cs doctor` flags the real failure mode: one account in multiple namespaces (which causes surprise re-logins).
- 🖥️ CLI-only: desktop app and IDE extensions do not inherit your shell's `CLAUDE_CONFIG_DIR`.
- 🔐 `~/.claude/profiles/<name>` contains full Claude Code login state. Protect it like your normal Claude config.
- 🧹 Upgrading from a pre-keychain version? Those releases stored plaintext credentials in `~/.claude/accounts/<name>.*` — including a dump with your claude.ai tokens **and** every MCP server's tokens and client secrets. `cs rm <name>` now deletes them; check that directory for profiles you no longer use.
- ⚠️ A profile carried over from that era can look logged in (`cs list` shows an email) while having no stored credential, because the old `claude` wrapper wrote that email into the config cosmetically. `cs list` and `cs use` now say `no credential` when that is the case — run `cs login <name>` to fix it.
- 🔁 Two *concurrent* sessions of the **same** profile share one credential slot; heavy parallel use of one account can still rotate against itself.
- 🧩 This tool depends on Claude Code internals, so future Claude releases may require updates. Re-check with `cs doctor` after upgrades.

## Tests

```sh
./tests/smoke.zsh
```

Covers profile validation, login/use/off/list/current/rm/doctor flows, isolated config behavior, duplicate-account detection, wrapper behavior, and path-traversal guards.
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
