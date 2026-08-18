# Changelog

This project follows [semantic versioning](https://semver.org/).

## 1.0.0 — 2026-08-18

First tagged release. The project was called `claude-switch` before this.

### Added

- `profile.env`. Each profile may hold a file of `export VAR=value` lines.
  `cs use` sources it, so one command pins Claude Code, gcloud, AWS, kubectl,
  and `gh` together. `cs off` and `cs use <other>` unset exactly the names that
  file exported.
- Providers. `cs login <profile> [provider]` logs one tool into a profile. The
  provider defaults to `claude`, so `cs login work` is unchanged.
  `cs login work gcloud` runs both gcloud logins into the directory that
  profile's `profile.env` names, sets the quota project, and verifies.
- `cs doctor` now asks every provider about every profile. A check hook returns
  healthy, a real problem, or no opinion, so a profile that does not pin a tool
  produces no output for it.
- `cs rm` now deletes the directories a provider owns, and names them in the
  confirmation prompt first.
- `cs env <name>` prints a profile's env file, and `cs list` marks profiles that
  carry one with `[+env]`.
- `cs version`.
- Custom providers. Define `_cs_provider_<tool>_login` in your `.zshrc`, and
  append the name to `_CS_PROVIDERS`.

### Changed

- Renamed to `context-switch`, because it pins more than Claude Code. Profiles
  stay under `~/.claude/profiles`: Claude Code names each keychain entry after
  the hash of that path, so moving the directory would orphan every credential.
  `claude-switch.plugin.zsh` remains as a compatibility shim.

### Fixed

- `claude` and `cs` work in a shell rebuilt from a snapshot, such as the one
  Claude Code sources for every Bash tool call. That shell drops every `_cs_*`
  helper, so both entry points recover through a `__cs_restore` function, which
  the snapshot filter keeps.
- `cs` reads a variable only when the profile pinned it. A `CLOUDSDK_CONFIG`
  exported by your `.zshrc` used to send a profile's credential to that global
  directory, and `cs` reported success.
- A provider hook owns standard output alone. A line printed by `profile.env`
  used to reach `cs rm` as a directory to delete.
- `cs rm` refuses a path that is a symlink, sits directly in your home
  directory, is a shared configuration directory, or that you do not own. It
  re-checks immediately before it deletes.
- `cs login <profile> gcloud` checks the credential directory before gcloud
  writes a refresh token, and creates it and its parents with mode 0700.
- The `profile.env` parser cuts an unquoted comment before reading names, so
  comment text is no longer tracked as a variable.
- The parser refuses a quoted export line whose name it cannot read. Such a line
  used to set a variable that `cs` could never unset.
- Tracking no longer depends on the caller's `IFS`.
- `cs doctor` names a missing gcloud project instead of printing empty
  parentheses.

### Security

- A `profile.env` is refused unless you own it and only you can write it. The
  directory holding it is checked the same way, because anyone who can write
  that directory can replace the file.
- `cs` refuses a `profile.env` that exports `PATH`, `HOME`, `IFS`, `PWD`,
  `OLDPWD`, `SHELL`, `TMPDIR`, or the pin variables.
- `cs rm` deletes the legacy plaintext credential files written by pre-keychain
  releases.
