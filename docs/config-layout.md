# Config layout and settings file

Status: proposal. Nothing here is implemented.

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
3. Existing installs keep working with no action, and can migrate when they choose to.

Non-goals: changing the env set file format (`envsets/*.tsv`, `.active`), moving `pwsh/` config, changing
what any setting means.

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

Renaming the tracked `config/` directory to `defaults/` keeps "config" meaning only "the user's live
config".

## Phase 1: move (no format change)

Resolve the directories once, in `init.sh`, through one function, and export the result. Everything that
builds a path from `$PREFLIGHT_DIR/config` or `$PREFLIGHT_DIR/state` uses it instead:

- `init.sh`: profile picker, template copy, `source` of `accounts.sh` and `owl.sh`.
- `install.sh`: first-run copy.
- `lib/envsets.sh`: `_op_envsets_dir`.
- `lib/owl.sh`: `OWL_THEME_DIR` default.
- `lib/preflight.sh`: the AWS profile setter writes `accounts.sh` today, and `uninstall` (below).
- `tests/op-env.sh`: 8 `PREFLIGHT_DIR` references.

**Legacy mode.** If the new config directory has no config and `$PREFLIGHT_DIR/config/accounts.sh` exists,
the resolver returns the old locations. An existing install therefore behaves exactly as before until it
migrates. This is temporary, like the `lib/1password.sh` handling in #42: mark it in code and drop it after
a release cycle.

**`preflight migrate-config`.** Copies `accounts.sh`, `owl.sh`, `envsets/` and `state/owl/` to the new
locations, verifies the copies, and leaves the originals in place. It prints what to delete and does not
delete it. It is idempotent and refuses to overwrite an existing destination file without `--force`.
Nothing migrates automatically.

**`preflight uninstall`.** Removes code only. It prints where config, state and cache live, and removes
them only with `--purge`. In legacy mode the config is inside the directory being removed, so `uninstall`
must say so and ask first.

**Collision to fix.** The README documents `PREFLIGHT_DIR=~/.config/preflight` as an install location. That
would put code and config in one directory. Change the example, and treat `PREFLIGHT_DIR` equal to the
config directory as legacy mode with a warning.

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
  "owl":      { "omp_config": "" }
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
  yours until you open a new terminal.
- **`~` expansion.** A leading `~/` or `$HOME/` in a path value becomes `$HOME/`. Nothing else is expanded.
- **A bad file never aborts the shell.** Invalid JSON, or `jq` missing, prints one warning (path and `jq`'s
  error), falls back to built-in defaults, and `preflight` reports it as an issue.
- **Unknown keys** are ignored with a warning in `preflight`, so a typo is visible.

### Writers

`preflight`'s AWS profile picker edits the settings file with `sed -i` today. It moves to
`preflight config set aws.default_profile NAME`, which writes through `jq` to a temp file in the same
directory and renames it into place.

A small `preflight config` command: `path`, `get KEY`, `set KEY VALUE`, `edit`, `migrate`. No more than that
in this phase.

### Documentation without comments

JSON has no comments, and the templates carry a lot of documentation in theirs. That moves to
`docs/config.md`, `preflight config --help`, and a `defaults/config.schema.json` whose `description`
fields give editors hover help and validation.

### Migrating `accounts.sh`

`preflight config migrate` sources the old `accounts.sh` and `owl.sh` in a subshell and reads the known
variables, instead of parsing text. It writes `config.json` and reports any variable the file set that is
not in the table above. `EDITOR` and `VISUAL` are two such: nothing in the repo reads them, so they are
shell environment setup, not preflight config, and belong in `lib/local.sh` or the user's rc file. The old
files are kept. While `config.json` is absent, `accounts.sh` is still sourced (legacy mode).

The profiles (`accounts.general.sh`, `accounts.company.sh`) become `defaults/config.general.json` and
`defaults/config.company.json`. The first-run picker copies the chosen one.

The `init.sh` sha256 migration for `config/owl.sh` stays while legacy mode exists, then goes with it.

### PowerShell

Out of scope here. The schema avoids anything PowerShell cannot read with `ConvertFrom-Json`, so
`pwsh/` can drop `accounts.ps1` for the shared file in a follow-up. This is the strongest reason to use
JSON, so it should follow soon after.

## Verified before writing this

- `jq` reads a settings file in about 1 ms more than sourcing a file; Python about 20 ms.
- `@sh` quoting survives a value with an apostrophe.
- A `jq`-generated `export` script respects a preset environment variable, joins lists with `:` and
  space, and expands a leading `~/`.

Not verified: the loader under zsh (not installed on the machine this was written on), and any of the
migration or `preflight config` behavior, which does not exist yet.

## Behavior changes

Only one is visible to existing users: `OP_ACCOUNT` from `accounts.sh` today overrides the environment,
and under "environment wins" it would not. Someone with `OP_ACCOUNT` exported in their rc file and a
different value in `accounts.sh` would start resolving against a different account after migrating.
`preflight config migrate` compares the two and warns when they differ.

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

- directory resolution order, and `PREFLIGHT_DIR` equal to the config directory
- legacy fallback, and no files written in legacy mode
- `migrate-config` is idempotent, keeps originals, refuses to overwrite without `--force`
- environment wins over the file, `~` expansion, boolean and list mapping
- invalid JSON and missing `jq` warn and continue
- `config set` is atomic and preserves other keys
- `uninstall` keeps config without `--purge`

## Rollout

Two PRs, in order:

1. Phase 1: layout, resolver, legacy mode, `migrate-config`, `uninstall`. Breaking for anyone who scripts
   against `~/.preflight/config`, so the PR is marked breaking and carries upgrade notes.
2. Phase 2: `config.json`, loader, `preflight config`, schema, `docs/config.md`.

## Open questions

1. Environment wins for every key, including `OP_ACCOUNT`? (Proposed: yes, with the migration warning.)
2. Drop `EDITOR` and `VISUAL` from the templates entirely? (Proposed: yes.)
3. Rename `config/` to `defaults/` in Phase 1, or leave it until Phase 2?
4. `pwsh/` in Phase 2, or the follow-up?
5. Is `preflight config` too much CLI for one PR? `get`/`set` are needed by the AWS picker; `edit`/`path`
   are convenience.
