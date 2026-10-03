# Config layout and settings file

Status: implemented (#48, #49). Kept as a design record: it describes the layout as proposed, so its "Today" columns are the pre-change state. Current behavior is documented in `docs/config.md`.

## Problem

`~/.preflight` holds both the tooling (a git clone) and the user's own data: `config/accounts.sh`,
`config/owl.sh`, `config/envsets/`, `state/`. That mixes two lifecycles:

- `preflight update` and `preflight uninstall` operate on the whole directory, so they can touch user data
  (`uninstall` does `rm -rf "$PREFLIGHT_DIR"`).
- Config is a sourced shell file, so it is code, not data. It cannot be validated, edited by a tool, or
  shared with the PowerShell sibling, which keeps its own copy in `pwsh/config/accounts.ps1`.
- The cache already follows XDG (`lib/cache.sh`). Config and state do not.

## Goals

1. Code and user data live in different places. `~/.preflight` becomes a disposable clone.
2. Settings become data (JSON), readable by both the bash and PowerShell implementations.

Non-goals:

- Migrating existing installs. There is one install today; it is moved by hand. No legacy mode, no migrate
  command, no fallback to the old locations.
- Changing the env set file format (`envsets/*.tsv`, `.active`), moving `pwsh/` config, or changing what any
  setting means.

## Layout

| What | Today | Proposed |
|---|---|---|
| Code, defaults, templates | `~/.preflight` | `~/.preflight` (unchanged) |
| Settings | `config/accounts.sh`, `config/owl.sh` | `$XDG_CONFIG_HOME/preflight/config.json` |
| Env sets | `config/envsets/` | `$XDG_CONFIG_HOME/preflight/envsets/` |
| Owl state, patched OMP theme | `state/owl/` | `$XDG_STATE_HOME/preflight/owl/` |
| Cache | `$XDG_CACHE_HOME/preflight` | unchanged |
| Profiles and templates (tracked) | `config/*.template`, `accounts.*.sh` | `defaults/` |

`XDG_CONFIG_HOME` defaults to `~/.config` and `XDG_STATE_HOME` to `~/.local/state`. Overrides, in
priority order: `PREFLIGHT_CONFIG_DIR` / `PREFLIGHT_STATE_DIR`, then the XDG variables, then the defaults.

The tracked `config/` directory is renamed to `defaults/`, so "config" means only "the user's live config".
Nothing user-owned lives inside the repo afterwards, so `.gitignore` drops its `config/` and `state/` entries.

## Phase 1: move (no format change)

Resolve the directories once, in `init.sh`, through one function (`_pf_resolve_dirs` in `lib/paths.sh`), and export `PREFLIGHT_CONFIG_DIR` and
`PREFLIGHT_STATE_DIR`. Everything that builds a path from `$PREFLIGHT_DIR/config` or `$PREFLIGHT_DIR/state`
uses them instead:

- `git mv config defaults`, and every path that names it. Find them with `grep -rn 'config/'` rather than from
  this list, which is the known set: `init.sh`, `install.sh` (including the profile listing at the end),
  `.gitignore`, `AGENTS.md`, `README.md`, the profile and template comments, the owl theme file
  (`config/theme-catppuccin.omp.json`), and the user-facing messages that say "set in config/accounts.sh" in
  `lib/help.sh`, `lib/aws.sh`, `lib/project.sh`, `lib/onepassword.sh`, `lib/envsets.sh` and
  `lib/preflight.sh`. `pwsh/config/` is a separate directory and is not renamed.
- `init.sh`: profile picker, template copy, `source` of `accounts.sh` and `owl.sh`. The sha256 block that
  refreshes an untouched `owl.sh` is deleted; it only exists to upgrade old installs.
- `install.sh`: first-run copy.
- `lib/envsets.sh`: `_op_envsets_dir`.
- `lib/owl.sh`: `OWL_THEME_DIR` default becomes the resolved state directory.
- `defaults/owl.sh.template`: `OWL_OMP_CONFIG` is hard-coded to `$PREFLIGHT_DIR/state/owl/theme-catppuccin.omp.json`
  today. It becomes `$PREFLIGHT_STATE_DIR/owl/theme-catppuccin.omp.json`.
- `lib/preflight.sh`: the AWS profile setter writes `accounts.sh` today, and `uninstall` (below).
- `tests/op-env.sh`: 8 `PREFLIGHT_DIR` references.

**`preflight uninstall`.** Removes code only. It prints where config, state and cache live, and removes
them only with `--purge`. Every `rm -rf` here goes through the guard in `lib/cache.sh` (refuse empty, `/` and
`$HOME`), extended to also refuse `$XDG_CONFIG_HOME`, `$XDG_STATE_HOME` and `$XDG_CACHE_HOME` themselves (implemented as `_pf_safe_rm_dir` in `lib/paths.sh`, which `preflight-cache-clear` now shares), so a
`PREFLIGHT_CONFIG_DIR=~/.config` typo cannot purge every application's config. Today `uninstall` runs a bare
`rm -rf "$dir"` (`lib/preflight.sh`), and `--purge` must not be the first path that deletes something outside
the clone.

**Collision to fix.** The README documents `PREFLIGHT_DIR=~/.config/preflight` as an install location. That
would put code and config in one directory. Change the example, and have the resolver refuse to run when
`PREFLIGHT_DIR` equals the config directory, with a message saying so.

## Phase 2: `config.json` for settings

### Schema

```json
{
  "version": 1,
  "op":       { "account": "my.1password.com" },
  "projects": { "dirs": ["~/projects", "~/work", "~/src"] },
  "aws":      { "default_profile": "" },
  "git":      { "main_branch": "main" },
  "gitea":    { "username": "", "host": "" },
  "checks":   { "aws": true, "gh": true, "ssh": true, "git_config": true },
  "optional_env_vars": ["NPM_TOKEN"],
  "owl":      { "omp_config": "$PREFLIGHT_STATE_DIR/owl/theme-catppuccin.omp.json" }
}
```

| Key | Shell variable | Read by |
|---|---|---|
| `op.account` | `OP_ACCOUNT` | `lib/onepassword.sh`, `lib/envsets.sh` |
| `projects.dirs` (joined with `:`) | `PROJ_DIRS` | `lib/project.sh` |
| `aws.default_profile` | `AWS_PROFILE_DEFAULT` | `lib/aws.sh`, `lib/preflight.sh` |
| `git.main_branch` | `GIT_MAIN_BRANCH` | `lib/git.sh` |
| `gitea.username`, `gitea.host` | `GITEA_USERNAME`, `GITEA_HOST` | `lib/preflight.sh` |
| `checks.*` (true/false to 1/0) | `_CHECK_AWS`, `_CHECK_GH`, `_CHECK_SSH`, `_CHECK_GIT_CONFIG` | `lib/preflight.sh` |
| `optional_env_vars` (joined with space) | `_OPTIONAL_ENV_VARS` | `lib/preflight.sh` |
| `owl.omp_config` | `OWL_OMP_CONFIG` | `init.sh`, `lib/owl.sh` |

An empty `owl.omp_config` means Oh My Posh integration is off; the shipped value above is the bundled theme.

The shell variable names do not change, so no library needs editing beyond the loader.

### Loader

A new `lib/config.sh` with `_pf_config_load`, called from `init.sh` where `accounts.sh` is sourced today.
One `jq` call produces `export` lines quoted with `@sh`, then they are evaluated. Measured cost is about 1 ms
per shell start over sourcing a file (2.6 ms against 1.7 ms including the process spawn), so no caching
layer. Python is not an option (about 20 ms).

Rules:

- **Environment wins, but only for variables you set.** A variable already in the environment is not
  overwritten by the file. This is how `AWS_PROFILE_DEFAULT` already behaves (`${X:-}`), and it is the usual
  precedence. The catch: a value the loader exported earlier looks exactly like one you set, so after you
  edit `config.json` and run `source ~/.bashrc` a naive check would keep the old value. The loader keeps a
  list of the names it exported (`_PF_CONFIG_MANAGED`, not exported) and lets the file update those.
  Prototyped and checked: user-set values stay put across reloads, loader-set values follow the file. The
  indirect lookup must be portable (`eval "[ -n \"\${$name+x}\" ]"`, not bash's `${!name+x}`, which zsh
  rejects). Known limit: a nested shell inherits the exported values but not the list, so it treats them as
  yours until you open a new terminal. Tmux panes, `bash -l` and `zsh -i` child shells all hit this, so
  `tests/config.sh` covers a nested shell explicitly: after editing the file, the child keeps the inherited
  value, and a fresh login shell picks up the new one. The behavior is documented in `docs/config.md`, not
  only here.
- **Path expansion.** A leading `~/` or `$HOME/` in a path value becomes `$HOME/`, and a leading
  `$PREFLIGHT_STATE_DIR/` or `$PREFLIGHT_CONFIG_DIR/` becomes the resolved directory. Nothing else is expanded.
- **A bad file never aborts the shell.** Invalid JSON prints one warning (path and `jq`'s error) and falls
  back to built-in defaults, and `preflight` reports it as a failed check.
- **`jq` is required.** It is an optional tool today (`lib/preflight.sh` tool list) and `install.sh` does not
  check for it, so Phase 2 promotes it: `install.sh` fails with an install hint when `jq` is missing (the same
  way it does for `git`), and the README moves it from the optional list to prerequisites. If `jq` goes
  missing afterwards, the loader prints one warning that no settings were loaded, uses built-in defaults, and
  `preflight` reports a failed check, not a note. The defaults include the placeholder
  `OP_ACCOUNT=my.1password.com`, so the warning must not be silent.
- **Unknown keys** are ignored with a warning in `preflight`, so a typo is visible.

### First run

The first-run picker copies `defaults/config.general.json` or `defaults/config.company.json` (the two profiles,
formerly `accounts.general.sh` and `accounts.company.sh`) to `$PREFLIGHT_CONFIG_DIR/config.json`. `EDITOR` and
`VISUAL` are not in the shipped files: nothing in the repo reads them, so they belong in the user's rc file or
`lib/local.sh`.

### Writers

`preflight`'s AWS profile picker edits the settings file with `sed -i` today. It moves to
`preflight config set aws.default_profile NAME`, which writes through `jq` to a temp file in the same
directory and renames it into place.

A small `preflight config` command: `path`, `get KEY`, `set KEY VALUE`, `edit`. No more than that in this
phase.

### Documentation without comments

JSON has no comments, and the templates carry a lot of documentation in theirs. That moves to
`docs/config.md`, `preflight config --help`, and a `defaults/config.schema.json` whose `description`
fields give editors hover help and validation.

### PowerShell (in scope for this phase)

`pwsh/` moves to the shared file in Phase 2, so the two implementations stop keeping separate copies.

What it reads today (`pwsh/Preflight.psm1`, `pwsh/config/accounts.ps1.template`):

- `OP_ACCOUNT`, defaulting to `change-me`. It already lets a preset environment variable win, which matches
  the rule above.
- `$script:OpEnvMap`, the `VAR -> op://` secret map, also defined in `accounts.ps1`. This is the env-set
  data, not a setting. Sharing the settings file alone would leave PowerShell with a second, hand-maintained
  list of secrets.

So Phase 2 covers both:

- PowerShell reads `config.json` with `ConvertFrom-Json`, through the same key table and the same
  environment-wins and path rules.
- PowerShell reads the same `envsets/*.tsv` and `.active`, with the same first-definition-wins and
  validation rules as `_op_env_entries`, and builds `OpEnvMap` from them. `accounts.ps1` and its template go
  away.
- That makes the `.tsv` format a cross-language contract. It gets a short spec in `docs/config.md`, and a
  shared fixture (one set of input files and the expected merged output) that both test suites check, so the
  implementations cannot drift.
- The per-secret account column (optional third TAB column, landed in #46) is part of the format the
  PowerShell port and the shared fixture implement.

Risk: PowerShell cannot be tested on the machine this was written on, so the PowerShell half needs a
Windows or `pwsh` run before merge. Say so in that PR's test plan rather than claiming it.

## Verified before writing this

- `jq` reads a settings file in about 1 ms more than sourcing a file; Python about 20 ms.
- `@sh` quoting survives a value with an apostrophe.
- A `jq`-generated `export` script respects a preset environment variable, joins lists with `:` and
  space, and expands a leading `~/`.

Not verified: the loader under zsh (not installed on the machine this was written on), and any of the
`preflight config` behavior, which does not exist yet. The repo has no CI workflows, so zsh coverage is a
manual run: each implementation PR states the zsh version it ran `tests/config.sh` under, or says it did not.

## What stays out of `config.json`

Env sets. They keep their own files (`envsets/*.tsv`, `.active`), for three reasons:

- A syntax error in one JSON file would take out the account, the project directories and every secret at
  once. Today a bad line in a `.tsv` is skipped.
- Separate files let a work set stay out of a dotfiles repo that holds the personal one.
- The per-secret account work changes the set format (an optional third column). This design does not touch
  it, so the two changes do not collide: Phase 1 only changes where `_op_envsets_dir` points.

Folding sets in later is possible: a `sets` key, with `.active` as a list, would make set writes a single
atomic rename.

## Test plan

A `tests/config.sh`, run under bash and zsh like `tests/op-env.sh`:

- directory resolution order, and the refusal when `PREFLIGHT_DIR` equals the config directory
- first run creates `config.json` from the chosen profile, and the state directory and base theme
- environment wins over the file, path expansion, boolean and list mapping
- a nested shell keeps an inherited value and a fresh shell picks up an edited file
- invalid JSON warns and continues; missing `jq` uses built-in defaults and warns
- `config set` is atomic and preserves other keys
- `uninstall` keeps config without `--purge`, and `--purge` refuses `$HOME` and the bare XDG directories

## Rollout

Two PRs, in order:

1. Phase 1: layout, resolver, `defaults/` rename, `uninstall`. Breaking for anyone who scripts against
   `~/.preflight/config`, so the PR is marked breaking and says the one existing install is moved by hand.
2. Phase 2: `config.json`, loader, `preflight config`, schema, `docs/config.md`, and the `pwsh/` port
   (settings and env sets, with the shared fixture).

With no migration path there is no reason to hold a release between them. Phase 1 still writes a sourced
`accounts.sh` to the new location, and Phase 2 replaces it with the JSON profiles.

Phase 2 may split into bash and PowerShell PRs if it gets large; the shared fixture lands with the first.

## Decisions

1. **Environment wins for every key, including `OP_ACCOUNT`.**
2. **`EDITOR` and `VISUAL` are dropped** from the templates and profiles.
3. **`config/` is renamed to `defaults/` in Phase 1.**
4. **`pwsh/` is included in Phase 2**, covering settings and env sets (above).
5. **`preflight config` ships in full** in Phase 2 (`path`, `get`, `set`, `edit`), not trimmed to the
   subcommands the AWS picker needs.
6. **No migration path.** No legacy mode, no `migrate` command, no fallback to the old locations.

## Still open

Nothing. The set format question was settled by #46: an optional third TAB column names a 1Password
account, and `op-load-env` groups entries by account.
