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
6. `cs login <name> gcloud` logs a second tool into the same profile, using the path that `profile.env` names. See [Providers](#providers).

### The one rule that matters

**One account → one profile, and always `cs use` before `claude`.**

Claude Code rotates OAuth refresh tokens: every refresh invalidates the previous refresh token. If the *same* account is logged into two credential slots — two profiles, or a profile **and** the unpinned default config — each refresh silently invalidates the other, and you get surprise `Please run /login` 401s. That is the single most common cause of "it made me log in again."

Run `cs doctor` to catch it: it lists every namespace's account and flags any account that appears in more than one. It then asks every provider about the same profiles.

## Requirements

- macOS or Linux
- `zsh`
- [Claude Code CLI](https://claude.com/claude-code) (2.x)
- `jq` (`brew install jq` on macOS, `apt install jq` on Debian/Ubuntu)
- The gcloud CLI, for the gcloud provider only. Everything else works without it.

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

`cs login` takes a provider as its second word, and the provider defaults to `claude`. `cs login work gcloud` logs gcloud into the same profile. See [Providers](#providers).

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
cs doctor        # verify logins, catch duplicate accounts, check providers
cs version       # which release you are on
cs off           # unpin this shell
cs rm work       # delete a profile's config, keychain login, and tool credentials
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

Write the profile's `profile.env` first, so `cs` knows where gcloud should write. Then run one command:

```sh
cs login work gcloud
```

That reads `CLOUDSDK_CONFIG` from the profile, runs both gcloud logins there, sets the quota project, and verifies the result. It does not pin your shell.

The same setup by hand looks like this. The `CLOUDSDK_CONFIG` export must be active, so run `cs use` first.

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

## Providers

A provider is one tool whose login `cs` can drive into a profile.

```sh
cs login work            # claude, the default
cs login work claude     # the same command, written out
cs login work gcloud     # gcloud, into this profile's directory
```

The provider is a bare word in position 2. Everything after it belongs to that provider, so `cs login work --claudeai --email you@work.com` still means what it always did. An argument that starts with a dash is a `claude auth login` flag, never a provider.

`claude` and `gcloud` ship with `cs`.

### Why the provider goes in the login command

Two operations write identity. `gcloud auth login` writes a credential to disk, which persists. `cs use` sets one shell's environment, which does not.

Those two operations do not commute. Run `gcloud auth login` before `cs use work` and the credential lands in the shared directory rather than the profile. Naming the profile in the login command removes the ordering, because then only one operation exists.

`cs login work gcloud` therefore replaces `cs use work` plus two gcloud commands. Daily work still uses `cs use`, once per terminal.

### What `cs login <profile> gcloud` does

1. Reads `CLOUDSDK_CONFIG` from the profile's `profile.env`. It uses your path, and does not assume one.
2. Runs `gcloud auth login` and `gcloud auth application-default login` there.
3. Sets the quota project from the profile's active project.
4. Verifies the result.

The verification checks two things. The file behind `GOOGLE_APPLICATION_CREDENTIALS` must exist. `gcloud auth list` must show exactly one account.

The command fails when the verification fails. A profile left holding two accounts therefore stops a `cs login work gcloud && ...` chain.

The command refuses a profile with no `profile.env`, and a `profile.env` that does not export `CLOUDSDK_CONFIG`. In both cases `cs` cannot tell where gcloud should write, and guessing would put a credential in the wrong directory.

Extra arguments go to both gcloud logins, so use flags that both commands accept. `cs login work gcloud --no-launch-browser` is the case this serves, on a host with no browser.

### `cs` uses a variable only when the profile pins it

Being set is not the same as being pinned, and the difference decides where your credential lands.

Suppose your `.zshrc` exports `CLOUDSDK_CONFIG`. That value reaches every command, including the subshell `cs` runs a provider in. `cs` clears the names a `profile.env` tracked, and a variable from your `.zshrc` was never tracked.

So `cs` reads `CLOUDSDK_CONFIG` from the profile's own `profile.env`, and ignores an inherited one. `cs login work gcloud` refuses and names the inherited value. `cs doctor` says nothing about gcloud for that profile.

The alternative would write the profile's credential into the global directory your `.zshrc` names, and report success. That is the leak this whole feature exists to prevent.

The same rule covers `GOOGLE_APPLICATION_CREDENTIALS`. A profile that pins the directory but not that variable gets no report about it.

### `cs doctor` runs the same checks

```sh
cs doctor
```

`cs doctor` reports each profile's Claude account, then asks every provider about the same profile. A profile that does not pin gcloud produces no gcloud output. `cs doctor` never guesses about a tool you do not use.

`cs doctor` prints every Claude account first, then every provider result:

```text
* work — you@work.com (claude.ai)
  personal — you@example.com (claude.ai)
  work — gcloud: you@work.com (my-project)
  personal — gcloud: NO application default credentials
```

### Writing your own provider

A provider is two shell functions, found by name:

```sh
_cs_provider_<tool>_login <profile> [args...]   # run that tool's login
_cs_provider_<tool>_check <profile>             # report that tool's health
```

Define them in your `.zshrc` after you source `cs.zsh`. `cs login <profile> <tool>` finds the login hook by name. Append the name to `_CS_PROVIDERS` and `cs doctor` calls the check hook too.

```sh
_CS_PROVIDERS+=(aws)
```

A check hook returns 0 when the tool is healthy, 1 on a real problem, and 2 for no opinion. Return 2 when the profile does not pin your tool. That is what keeps `cs doctor` quiet.

Use `_cs_with_profile_env <profile> <command...>` inside a hook. It applies the profile's `profile.env` in a subshell, so the caller's terminal keeps its own pin. It exits 2 when the file cannot be loaded, so a broken `profile.env` never reads as a problem with your tool.

Inside a hook, call `_cs_profile_pins <VAR>` before you read `VAR`. It answers whether this profile exported the name, which is the test that keeps an inherited value out of your tool.

A third hook is optional:

```sh
_cs_provider_<tool>_paths <profile>   # directories this tool owns, one per line
```

`cs rm` asks for those paths before it deletes anything, lists them in the confirmation prompt, and deletes them with the profile. Print paths; do not delete them yourself. `cs rm` holds the guards.

`cs rm` deletes a path only when every rule below holds. It names anything it refuses, so you can remove that by hand.

- The path is absolute, and is not a symlink.
- The path sits under your home directory, at least two levels down. `~/.ssh` and `~/Documents` are one level down, so `cs` never deletes them.
- The path is not `~/.config`, `~/.config/gcloud`, `~/.claude`, the profiles root, or any ancestor of your home directory.
- You own the path, and no one else can write it. This is the same test `cs` applies before it sources `profile.env`.

`cs` re-runs those checks immediately before it deletes, because the confirmation prompt sits between the first check and the deletion.

Print paths on standard output. `cs` sends everything your `profile.env` prints to standard error, so a banner line in that file cannot reach the deletion list.

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
- 🗑️ `cs rm <name>` also deletes the profile's gcloud directory, because `cs login <name> gcloud` puts a live OAuth token there. It names every such directory in the confirmation prompt first, and refuses a symlink, a shared directory, and anything sitting directly in your home directory.
- 🔒 `cs login <name> gcloud` checks the directory before it writes anything. It refuses a symlink, refuses a directory you do not own, and creates the directory and its parents with mode 0700. gcloud stores its refresh token in a file there, so the directory is the secret.
- 📁 Profiles stay under `~/.claude/profiles` even though `cs` now pins more than Claude Code. Claude Code names each keychain entry after the hash of that path. Moving the directory would orphan every stored credential.
- 🧰 `profile.env` pins other tools. `cs` sources it, so it runs code. Keep it to plain `export` lines, and keep it `chmod 600`.
- 🧹 Upgrading from a pre-keychain version? Those releases stored plaintext credentials in `~/.claude/accounts/<name>.*` — including a dump with your claude.ai tokens **and** every MCP server's tokens and client secrets. `cs rm <name>` now deletes them; check that directory for profiles you no longer use.
- ⚠️ A profile carried over from that era can look logged in (`cs list` shows an email) while having no stored credential, because the old `claude` wrapper wrote that email into the config cosmetically. `cs list` and `cs use` now say `no credential` when that is the case — run `cs login <name>` to fix it.
- 🔁 Two *concurrent* sessions of the **same** profile share one credential slot; heavy parallel use of one account can still rotate against itself.
- 🧩 This tool depends on Claude Code internals, so future Claude releases may require updates. Re-check with `cs doctor` after upgrades.
- 🧵 `claude` and `cs` also work in a shell rebuilt from a snapshot, such as the one Claude Code sources for every Bash tool call. That shell drops every `_cs_*` helper, so the `claude` wrapper calls none of them, and `cs` re-sources itself when it finds them missing.

## Tests

```sh
./tests/smoke.zsh
```

Covers profile validation, login/use/off/list/current/env/rm/doctor flows, isolated config behavior, duplicate-account detection, wrapper behavior, `profile.env` load and cleanup, path-traversal guards, the provider grammar, and the gcloud provider's login and check hooks.
CI runs this suite on both macOS and Ubuntu in `.github/workflows/test.yml`.

## Changelog

[CHANGELOG.md](CHANGELOG.md) lists what changed in each release. Run `cs version` to see which one you are on.

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
