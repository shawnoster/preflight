# Settings (`config.json`)

Settings live in one JSON file, `$PREFLIGHT_CONFIG_DIR/config.json` (default `~/.config/preflight/config.json`). It
is created on first load from a profile in `defaults/` (`config.general.json` or `config.company.json`), and
`preflight update` never touches it. Secrets are not settings: they live in env sets (`op-env`), see the README.

`jq` is required to read the file.

## Changing a setting

```bash
preflight config path                          # where the file is
preflight config get op.account
preflight config set op.account my-team.1password.com
preflight config set checks.aws false          # a JSON boolean
preflight config set projects.dirs "~/dev:~/src"   # a JSON array
preflight config edit                          # ${VISUAL:-${EDITOR:-vi}}, then checks the file
preflight config check                         # invalid JSON, unknown keys, wrongly typed values
```

`set` writes through `jq` to a temporary file in the same directory and renames it into place, so an interrupted
write never leaves a half-written file. It refuses an unknown key, a bad boolean, and a file that is not valid JSON
(fix it with `config edit` first). It applies the change to the current shell as well, unless you set that variable yourself, in which case it says so.

`config edit` checks the file when the editor returns, so a GUI editor needs its wait flag (`VISUAL="code --wait"`); without it the check runs against the unchanged file.

`defaults/config.schema.json` describes every key. Add `"$schema": "<path to it>"` to your file (or point your
editor's JSON settings at it) for hover help and validation; the loader ignores that key.

## Keys

| Key | Shell variable | Type | Default | Used by |
|---|---|---|---|---|
| `op.account` | `OP_ACCOUNT` | string | `my.1password.com` | 1Password helpers, env sets without an account column |
| `projects.dirs` | `PROJ_DIRS` | list (joined with `:`) | `~/projects`, `~/work`, `~/src` | `proj` |
| `aws.default_profile` | `AWS_PROFILE_DEFAULT` | string | empty | `preflight` sets `AWS_PROFILE` from it |
| `git.main_branch` | `GIT_MAIN_BRANCH` | string | `main` | git helpers |
| `gitea.username`, `gitea.host` | `GITEA_USERNAME`, `GITEA_HOST` | string | empty | HTTPS credential for Gitea |
| `checks.aws`, `checks.gh`, `checks.ssh`, `checks.git_config` | `_CHECK_AWS`, `_CHECK_GH`, `_CHECK_SSH`, `_CHECK_GIT_CONFIG` | boolean (to `1`/`0`) | all `true` | which `preflight` sections run |
| `owl.omp_config` | `OWL_OMP_CONFIG` | path | `$PREFLIGHT_STATE_DIR/owl/theme-catppuccin.omp.json` | Oh My Posh JSON that `owl-theme` patches; empty turns Oh My Posh off |

`op.account` is the sign-in address (`my-team.1password.com`) under WSL desktop integration, because the desktop-fed
`op.exe` does not carry a manual `op account add` shorthand. On native `op` it is the shorthand.

The variable names did not change, so no library needed editing beyond the loader. `OWL_THEME_DIR` has no key: it is
an environment variable only (default `$PREFLIGHT_STATE_DIR/owl`).

`EDITOR` and `VISUAL` are not settings of preflight. Set them in your shell's rc file.

## How it loads

`lib/config.sh` holds one table (key, variable, type, export flag, built-in default) that drives the loader, the
defaults, `config set`, `config check`, and a test that compares it with `defaults/config.schema.json` and both
profiles. `init.sh` calls `_pf_config_load` after the libraries load. It runs `jq` once and evaluates the exported
assignments it prints.

- **Your environment wins.** A variable that is already set when the file loads is not overwritten. This holds for
  every key, including `OP_ACCOUNT`.
- **Edits are picked up on reload.** The loader remembers the names it set (`_PF_CONFIG_MANAGED`, not exported), so
  after you edit `config.json` and run `source ~/.bashrc` the loader's own values follow the file while the ones you
  set yourself stay.
- **Nested shells are the exception.** A child shell inherits the exported values (`OP_ACCOUNT`, `PROJ_DIRS`, ...)
  but not the list, so it treats them as yours until you open a new terminal. Tmux panes, `bash -l` and `zsh -i`
  children all do this.
- **A key you remove** falls back to its built-in default on the next reload.
- **A wrong-typed value** (`"checks": {"aws": "yes"}`) takes the default for that key only. The other keys load.
- **Path expansion.** A leading `~/` or `$HOME/` becomes `$HOME/`, and a leading `$PREFLIGHT_STATE_DIR/` or
  `$PREFLIGHT_CONFIG_DIR/` becomes the resolved directory. Nothing else is expanded, so a stray `$VAR` stays text.
- **A bad file never aborts the shell.** Invalid JSON prints one warning (path and `jq`'s message) and the built-in
  defaults are used. If `jq` is missing, one warning says no settings were loaded. In both cases `preflight` reports
  a failed check rather than a note: the built-in `OP_ACCOUNT` is a placeholder, so running on it must not be silent.
- **Unknown keys** are reported by `preflight` (and `preflight config check`), so a typo is visible. They are
  otherwise ignored.

Startup cost is one `jq` process: measured at about 6 ms per shell on WSL2 with jq 1.8.1, against well under a
millisecond for sourcing a file.

## Converting an old `accounts.sh` / `owl.sh`

There is no automatic conversion. Pick the profile that is closest, then set what you had:

| In `accounts.sh` / `owl.sh` | Now |
|---|---|
| `export OP_ACCOUNT="x"` | `preflight config set op.account x` |
| `export PROJ_DIRS="$HOME/a:$HOME/b"` | `preflight config set projects.dirs "~/a:~/b"` |
| `export AWS_PROFILE_DEFAULT="p"` | `preflight config set aws.default_profile p` |
| `export GIT_MAIN_BRANCH="m"` | `preflight config set git.main_branch m` |
| `export GITEA_USERNAME` / `GITEA_HOST` | `preflight config set gitea.username …` / `gitea.host …` |
| `_CHECK_AWS=0` and the other `_CHECK_*` | `preflight config set checks.aws false` |
| `_OPTIONAL_ENV_VARS="A B"` | not a setting: variables are env-set entries (`op-env add SET VAR op://...`), and `preflight` checks every variable in the active sets |
| `export OWL_OMP_CONFIG="/path"` | `preflight config set owl.omp_config /path` |
| `export EDITOR=…`, `VISUAL=…`, other exports | your shell rc file, or `lib/local.sh` |

Anything else in `accounts.sh` that was code (an alias, an `export`) belongs in `lib/local.sh` now: the file is no
longer sourced.
