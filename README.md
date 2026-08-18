# context-switch

Pin one identity per terminal. Claude Code, gcloud, AWS, kubectl, and `gh` all follow. ✨

```sh
# Terminal A
cs use personal
claude

# Terminal B
cs use work
claude
```

Each terminal stays pinned to its own account.

> Formerly `claude-switch`. The old repository URL still redirects here, and the old plugin entry point still works.

## Why this exists

Most CLI tools keep their identity in one global file. You log in for one account, and every other terminal silently switches with you.

Claude Code has this problem. You log in here, log out there, and lose track of which terminal uses which account.

gcloud has a worse version of it. `~/.config/gcloud/active_config` and `~/.config/gcloud/application_default_credentials.json` are single files shared by every shell. One `gcloud auth login` changes your active project everywhere, and overwrites the credentials Terraform reads. Your other terminal then fails mid-plan.

`context-switch` fixes both the same way. It pins each tool's config path per shell, so the terminal becomes the identity boundary.

## How it works

1. `cs login <name>` runs `claude auth login` with `CLAUDE_CONFIG_DIR` pointed at `~/.claude/profiles/<name>`.
2. Claude Code 2.x stores that account's OAuth credentials in the OS keychain, in an entry keyed by a hash of `CLAUDE_CONFIG_DIR` (`Claude Code-credentials-<sha256(dir)[:8]>`). Each profile therefore gets its own isolated credential slot.
3. `cs use <name>` exports that same `CLAUDE_CONFIG_DIR` in the current shell only.
4. `cs use <name>` then sources the profile's optional `profile.env`, which pins every other tool.
5. `claude` launches using the pinned profile's credentials — no rewriting, no env tokens.

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
zinit load tenkenco/context-switch
```

**oh-my-zsh:**

```sh
git clone https://github.com/tenkenco/context-switch \
  "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/context-switch"
# then add `context-switch` to your plugins=(...) array in ~/.zshrc
```

**sheldon** (in `~/.config/sheldon/plugins.toml`):

```toml
[plugins.context-switch]
github = "tenkenco/context-switch"
```

**antidote** (in `~/.zsh_plugins.txt`):

```text
tenkenco/context-switch
```

### Without a plugin manager

```sh
git clone https://github.com/tenkenco/context-switch.git ~/.context-switch
~/.context-switch/install.sh
```

Then open a new terminal (or `source ~/.zshrc`) and run `cs help`.

### Already installed as claude-switch?

Nothing breaks. GitHub redirects the old repository URL, and `claude-switch.plugin.zsh` still loads the tool. Your existing `source ~/.claude-switch/cs.zsh` line keeps working.

Renaming the checkout does break it, because `install.sh` writes an absolute path into your `.zshrc`. Update that line in the same step:

```sh
mv ~/.claude-switch ~/.context-switch
sed -i '' 's|/.claude-switch/cs.zsh|/.context-switch/cs.zsh|' ~/.zshrc
```

Re-running `install.sh` does not repair the old line. It only looks for its own current `source` line, so it appends a second one.

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
cs env work      # show the profile's env file for other tools
cs doctor        # verify logins + catch duplicate-account slots
cs off           # unpin this shell
cs rm work       # delete a profile's config + keychain login
```

## Pinning your other tools (`profile.env`)

Each profile can hold a `profile.env` file. `cs use` sources it, so one command pins your whole toolchain.

Write one `export` per line:

```sh
# ~/.claude/profiles/work/profile.env
export CLOUDSDK_CONFIG="$HOME/.config/gcloud-profiles/work"
export GOOGLE_APPLICATION_CREDENTIALS="$CLOUDSDK_CONFIG/application_default_credentials.json"
export AWS_PROFILE=work
export KUBECONFIG="$HOME/.kube/work.yaml"
export GH_CONFIG_DIR="$HOME/.config/gh-profiles/work"
```

Run `chmod 600` on that file. Sourcing runs code, so `cs` refuses the file unless you own it and only you can write it. `cs` checks the profile directory the same way, because anyone who can write that directory can replace the file with their own. `cs login` already creates the directory `0700`.

```sh
chmod 700 ~/.claude/profiles/work
chmod 600 ~/.claude/profiles/work/profile.env
```

`cs use work` now sets all of it. `cs off` unsets it. `cs use personal` unsets it and applies personal's file instead. `cs list` marks profiles that carry one with `[+env]`.

### Setting up gcloud this way

Do this once per account. The `CLOUDSDK_CONFIG` export must already be active, so run `cs use` first.

```sh
cs use work
mkdir -p "$CLOUDSDK_CONFIG"
gcloud auth login                       # writes only into this profile's directory
gcloud auth application-default login   # what Terraform reads
gcloud config set project my-project
gcloud auth application-default set-quota-project my-project
```

Set the quota project. Some APIs reject application default credentials without one, and Terraform hits that.

A fresh `CLOUDSDK_CONFIG` directory starts empty. Your existing gcloud logins do not carry over, so you log in once per profile.

Set `GOOGLE_APPLICATION_CREDENTIALS` as well as `CLOUDSDK_CONFIG`. The gcloud CLI reads the first variable. Go programs such as the Terraform google provider may not, and every Google auth library reads the second one.

#### Run both login commands

The two login commands save two different credentials.

`gcloud auth login` saves the credential that the `gcloud` command itself uses. `gcloud auth application-default login` saves the application default credential, in the file `application_default_credentials.json`. Terraform, client libraries, and most SDKs read the second credential.

Skipping the second command leaves `GOOGLE_APPLICATION_CREDENTIALS` pointing at a file that does not exist. Google auth libraries then fail. They do not fall back to another credential:

```text
google.auth.exceptions.DefaultCredentialsError: File
/Users/you/.config/gcloud-profiles/work/application_default_credentials.json
was not found.
```

Run this check after you log in. It must print a real file:

```sh
cs use work
ls -l "$GOOGLE_APPLICATION_CREDENTIALS"
```

#### Check which accounts a profile holds

```sh
cs use work
gcloud auth list     # every account saved in this profile
gcloud config list   # the active account and project
```

`gcloud auth list` reads `$CLOUDSDK_CONFIG` only, so each profile keeps its own list. A healthy profile lists exactly one account.

#### Remove an account from the wrong profile

`gcloud auth revoke` deletes one saved credential from the active `CLOUDSDK_CONFIG` directory. Pin the profile first, so you delete from the right directory.

```sh
cs use work
gcloud auth list                        # confirm the account is here
gcloud auth revoke you@personal.example # delete it from this profile
gcloud auth list                        # confirm one account remains
```

`gcloud auth application-default revoke` deletes the application default credential of the pinned profile. Use it when the wrong account wrote that file.

Revoking deletes the login. Run `gcloud auth login` again in the profile that should hold that account.

#### Do not run gcloud unpinned

`cs use` is what points gcloud at the per-profile directory. A shell with no pin uses the shared directory `~/.config/gcloud` instead. Every account you log in there stays in one list. One `gcloud auth login` there changes the active account for every unpinned shell. This rule matches the Claude rule above. Pin the shell first, then run the tool.

Read the shared directory the same way:

```sh
CLOUDSDK_CONFIG="$HOME/.config/gcloud" gcloud auth list
```

Delete from it the accounts that you now keep in profiles:

```sh
CLOUDSDK_CONFIG="$HOME/.config/gcloud" gcloud auth revoke you@work.example
```

### What cs can and cannot undo

`cs` tracks the names on `export VAR=value` lines, and unsets exactly those. Two exports on one unquoted line both count.

`cs` refuses the file when a **quoted** line sets more than one variable. It cannot tell a real name from text inside a quoted value, and guessing the first one was a security hole: `export OK="yes" PATH="/nowhere"` hid `PATH` from the refused-names check. Put one export on each line.

Any other shell code in the file still runs when the file is sourced. `cs` cannot track that. A conditional export like `[[ -d "$D" ]] && export X=1` does not start with `export`, so it falls outside the contract. Keep the file to plain exports.

A bare assignment with no `export` also escapes the parser, because these variables are already exported. `cs` restores `PATH`, `IFS`, `HOME`, `SHELL`, `TMPDIR`, and the pin variables after it sources the file, and tells you when it had to.

`cs off` unsets a tracked name. It does not restore a value your shell held before `cs use`. If your `.zshrc` sets `AWS_PROFILE` and a `profile.env` overrides it, `cs off` leaves `AWS_PROFILE` unset.

### Names cs refuses to manage

`cs` rejects the whole file, and applies none of it, when `profile.env` exports any of these:

`PATH` `HOME` `IFS` `PWD` `OLDPWD` `SHELL` `TMPDIR` `CLAUDE_CONFIG_DIR` `_CS_PROFILE` `_CS_PROFILE_ENV_VARS`

The first group would break your shell. `cs off` unsets every tracked name, and a shell without `PATH` cannot run any command. The second group is the pin itself. A file that rewrites it would make `cs use` report one profile while `claude` launches as another.

To put a per-profile directory on your `PATH`, prepend it in your `.zshrc` instead.

## The `claude` wrapper (and how to avoid it)

Sourcing `cs.zsh` defines a `claude` shell function that keeps `CLAUDE_CONFIG_DIR` aligned with your pin and strips overriding auth vars before launching the real binary.

If another plugin or your own `.zshrc` already defines `claude`, context-switch replaces it and says so, keeping the previous definition as `_cs_prev_claude`. To restore it:

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

`CS_QUIET` suppresses the advisory notices only. If context-switch ever replaces a `claude` function it could **not** preserve, it still says so — that's data loss, not an advisory.

> **Note on `ANTHROPIC_BASE_URL`.** context-switch strips overriding auth variables so the *identity* comes only from the profile's keychain slot, but it deliberately does not strip `ANTHROPIC_BASE_URL` — you may need it to reach the API at all. It controls *where* requests go, so the profile's token is sent to whatever endpoint it names. Every command that launches Claude warns when it is set.

## Notes

- ✅ `cs login` profiles use Claude Code's full `claude.ai` login in an isolated config directory (keychain-backed, per `CLAUDE_CONFIG_DIR`).
- 🩺 `cs doctor` flags the real failure mode: one account in multiple namespaces (which causes surprise re-logins).
- 🖥️ CLI-only: desktop app and IDE extensions do not inherit your shell's `CLAUDE_CONFIG_DIR`.
- 🔐 `~/.claude/profiles/<name>` contains full Claude Code login state. Protect it like your normal Claude config.
- 📁 Profiles stay under `~/.claude/profiles` even though `cs` now pins more than Claude Code. Claude Code names each keychain entry after the hash of that path. Moving the directory would orphan every stored credential.
- 🧰 `profile.env` pins other tools. `cs` sources it, so it runs code. Keep it to plain `export` lines, and keep it `chmod 600`.
- 🧹 Upgrading from a pre-keychain version? Those releases stored plaintext credentials in `~/.claude/accounts/<name>.*` — including a dump with your claude.ai tokens **and** every MCP server's tokens and client secrets. `cs rm <name>` now deletes them; check that directory for profiles you no longer use.
- ⚠️ A profile carried over from that era can look logged in (`cs list` shows an email) while having no stored credential, because the old `claude` wrapper wrote that email into the config cosmetically. `cs list` and `cs use` now say `no credential` when that is the case — run `cs login <name>` to fix it.
- 🔁 Two *concurrent* sessions of the **same** profile share one credential slot; heavy parallel use of one account can still rotate against itself.
- 🧩 This tool depends on Claude Code internals, so future Claude releases may require updates. Re-check with `cs doctor` after upgrades.

## Tests

```sh
./tests/smoke.zsh
```

Covers profile validation, login/use/off/list/current/env/rm/doctor flows, isolated config behavior, duplicate-account detection, wrapper behavior, `profile.env` load and cleanup, and path-traversal guards.
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
