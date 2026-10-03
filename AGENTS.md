# AGENTS.md — preflight

> Developer shell utility library providing fzf-powered AWS, Git, Docker, and 1Password shortcuts sourced into a developer's shell environment.

## What This Repo Does

`preflight` is a collection of Bash scripts installed under `~/.preflight/` (configurable via `PREFLIGHT_DIR`) and sourced via `init.sh` in a developer's `.bashrc` or `.zshrc`. It adds interactive shell functions for common daily tasks: fuzzy AWS profile switching and SSO login, pretty Git log/branch/stash selection with fzf, Docker container management, 1Password CLI sign-in helpers, project navigation utilities, and the OOO shell theme engine. Not a deployable service — it's a dotfiles-style developer ergonomics package.

## Two Checkouts: Template Repo vs. Working Install

There are two copies of this code on disk, and they serve different roles. Know which one you're editing before you change anything.

- **The template (source) repo** — wherever you cloned it (e.g. `~/dev/code/preflight`; the source checkout location is arbitrary — only the working install path is fixed by default). This is the git working tree people clone and install from. Tracked files live here: `lib/*.sh`, the profiles and schema under `defaults/` (`defaults/config.general.json`, `defaults/config.company.json`, `defaults/config.schema.json`), `init.sh`, `install.sh`, docs, and this `AGENTS.md`. Everything here must stay **generic** — no personal secrets, no work-specific account references, no machine-specific paths. **All tracked changes (and all PRs) are made here.**
- **`~/.preflight` — the working install (`PREFLIGHT_DIR`).** This is what `init.sh` actually sources at shell startup. It is a disposable clone: it holds no user data. On first load `init.sh` copies a committed profile (`defaults/config.<name>.json`) to its **live counterpart outside the clone**, `PREFLIGHT_CONFIG_DIR/config.json` (default `~/.config/preflight`, beside `envsets/*.tsv`). `lib/config.sh` loads it into the shell variables (see "Settings" below). Owl state lives in `PREFLIGHT_STATE_DIR` (default `~/.local/state/preflight`). Both are resolved once by `lib/paths.sh` (override variables, then `XDG_CONFIG_HOME` / `XDG_STATE_HOME`, then the defaults), which refuses a `PREFLIGHT_DIR` equal to either. Those live files are where the user's **work-specific** bits live: real `op://` secret references (in env sets), the `OP_ACCOUNT` sign-in address, AWS profile defaults, etc. Because they live outside the repo, personal config can never land in the template, and `preflight update` / `uninstall` (without `--purge`) never touch them.

`~/.preflight` is itself a clone of the same repo, so its *tracked* files can be edited and committed — but doing so risks drift between the two checkouts and accidentally committing local config. **Default to editing tracked files in the source checkout and opening a PR;** treat `~/.preflight` as a runtime install whose only intentional local edits are the gitignored live files.

**No separate source checkout on this machine?** Check before assuming one exists — don't guess a path like `~/dev/code/preflight` and treat its absence as "must not apply here." If `~/.preflight` really is the only clone, it's still not a license to commit tracked-file changes straight to its local `main`: `git fetch origin` first (main may have moved — another machine or a prior session may have pushed since this clone last pulled), then branch off `origin/main` (not local `main`, which `fetch` alone does not update — fast-forward it too if you want it current, but branch from the remote ref regardless), commit there, push, and open a PR from that branch, exactly as if this were the source checkout. Never land a tracked-file change directly on local `main` in any checkout, single or not.

Note that `init.sh` (on every shell load) copies a profile to `config.json` only when the live file is **missing**:

```bash
if [[ ! -f "$PREFLIGHT_CONFIG_DIR/config.json" ]]; then
  cp "$_pf_pick" "$PREFLIGHT_CONFIG_DIR/config.json"
fi
```

Missing-file copying is the only behavior: it never overwrites an existing live file, so a change to a profile does not retroactively rewrite an already-generated `config.json` — the user sets the new value with `preflight config set` (or deletes the file to regenerate it). Say so in the PR's upgrade notes when you change a profile. Preflight carries no migration or legacy code paths: when a layout changes, the PR's upgrade notes tell the user what to do by hand.

**Settings.** `lib/config.sh` holds one table (key, shell variable, type, export flag, default) that drives the loader, the built-in defaults, `preflight config set|get|check`, and `tests/config.sh`'s drift check against `defaults/config.schema.json` and both profiles. To add a setting: add a row, a schema entry, a value in both profiles, and a line in `docs/config.md`. A variable that is already set when the file loads wins over it, so **no library may assign a setting variable at load time** (not even `X="${X:-default}"`): it would look user-set and the file could never change it. `tests/config.sh` fails if one does. `jq` is required.

## Domains Covered

- **Session startup / self-management** — `lib/preflight.sh`: session health check (`preflight`), verbose mode (`preflight -v`), tool update check (`preflight -u`), self-update (`preflight update`), uninstall (`preflight uninstall [--purge]`), opinionated git/SSH/AWS configuration (`preflight configure [--yes]`)
- **AWS** — `lib/aws.sh`: profile switching (`awsp`), SSO login (`aws-login`), identity check (`aws-whoami`)
- **Git** — `lib/git.sh`: fuzzy branch checkout (`gco`), pretty log (`glog`), stash management (`gstash` — pops by default, `--apply` to keep), WIP commits (`gwip`), GH PR creation (`gpr`)
- **Docker** — `lib/docker.sh`: container/image management utilities (`dex` tries bash first, falls back to sh)
- **PostgreSQL** — `lib/postgres.sh`: cluster start/stop (`pg-up`, `pg-down`) for clusters set to `manual` in `start.conf`. Goes through `pg_ctlcluster`, which self-redirects to `systemctl` when systemd is running and the caller is root, so one code path covers systemd and non-systemd hosts. Debian/Ubuntu only — needs `postgresql-common`.
- **1Password** — `lib/onepassword.sh`: generic, data-agnostic helpers (`op-status`, `op-signin`, `op-new`, `op-import-csv`; the loading and clearing code is `_op_env_load` / `_op_env_clear`, run only through `op-env load` / `op-env clear`). It is a plain tracked file and must never name a specific secret; after-load side effects register through `_OP_AFTER_LOAD_HOOKS` (e.g. `lib/nanoleaf.sh`).
- **Env sets** — `lib/envsets.sh`: `op-env load|clear|add|list|rm|use`. The only place that defines which secrets load: named sets of `VAR → op://` refs in `$PREFLIGHT_CONFIG_DIR/envsets/<set>.tsv`. `_op_env_entries` is the contract between it and `op-env load`/`clear`; with set names it reads just those sets, and the plain call must keep producing the same output (the PowerShell port and the shared fixture depend on it). A plain load is authoritative (unsets what is no longer defined); a named-set load is additive and skips that pass, and `op-env clear <set>` unsets only what that set supplied (`_op_env_sources` tracks which set supplied each loaded variable); it passes lines through as written, so a set line may carry an optional third TAB column naming a 1Password account (absent = `$OP_ACCOUNT`), and `op-env load` groups entries by that account and runs one `op inject` per account. `tests/fixtures/envsets/` plus `tests/fixtures/envsets.expected` are the shared contract for the `.tsv` format, checked by `tests/op-env.sh`.
- **Project navigation** — `lib/project.sh`: workspace/project switching helpers
- **Paths** — `lib/paths.sh`: `_pf_resolve_dirs` (exports `PREFLIGHT_CONFIG_DIR` / `PREFLIGHT_STATE_DIR`, refuses a layout that shares the clone) and `_pf_safe_rm_dir` (the guard every `rm -rf` of a directory goes through, including `preflight uninstall --purge`)
- **Prompting** — `lib/prompt.sh`: `_pf_ask`, the Bash/zsh-portable replacement for `read -p`
- **OOO Theme Engine** — `lib/owl.sh`: shell MOTD splash (`_owl_splash`) and Oh My Posh theme switcher (`owl-theme`). 8 themes, each with a name, color palette for the splash, and hex palette for OMP. Theme state persists in `$PREFLIGHT_STATE_DIR/owl/current`. OMP integration is optional — configured via the `owl.omp_config` key in `config.json`.

## Patterns & Tech

- **Stack**: Bash
- **Architecture**: Library of shell functions loaded via `init.sh` sourcing `lib/*.sh`; `defaults/config.<profile>.json` are committed and one is copied to `PREFLIGHT_CONFIG_DIR/config.json` by `init.sh` on first load — edit the profiles, not the generated copy
- **Key libraries**: `fzf` (interactive selection), `aws` CLI, `gh` CLI, `op` (1Password CLI), `git`, `docker`, `oh-my-posh` (optional, for `owl-theme`)
- **Notable patterns**: Libraries are sourced from both Bash and zsh, so avoid Bash-only constructs: prompt with `_pf_ask` (`lib/prompt.sh`) instead of `read -p`, and do not use `read -a`, `mapfile`/`readarray` or relying on 0-based array indexes. A prompt whose empty answer means yes must treat a failed read as a decline (`_pf_ask reply "..." || reply=n`). All functions are shell aliases/functions — no subcommand framework; `PREFLIGHT_DIR` env var controls install location (default `~/.preflight`); `PREFLIGHT_BRANCH` controls the branch used by `preflight update` (default `main`); `PREFLIGHT_VERBOSE=1` for load confirmation; `AWS_PROFILE_DEFAULT` (`aws.default_profile` in `config.json`) sets the default AWS profile that `preflight` exports as `AWS_PROFILE` at session start; `OWL_OMP_CONFIG` (`owl.omp_config`) points to the Oh My Posh JSON — leave empty to use owl themes without OMP

## When to Dive Deeper

Read this repo when working on:

- **Developer onboarding shell setup** — `init.sh` and `bashrc-snippet.sh` show exactly what to add to dotfiles; `install.sh` is the one-line curl installer
- **AWS SSO profile workflow issues** — `lib/aws.sh` has the profile switching and SSO login flow; `aws.default_profile` in `config.json` sets the session default
- **WSL SSH setup with 1Password** — `docs/wsl-ssh-setup.md` covers prerequisites; `preflight configure` installs the systemd + npiperelay agent bridge 
- **Adding new shell utilities for all engineers** — add a new `lib/<domain>.sh` file
- **1Password CLI integration for secrets** — `lib/onepassword.sh` has the sign-in flow for WSL/headless environments; `lib/envsets.sh` has the list of secrets
- **Shell MOTD or theme customization** — `lib/owl.sh` has the theme engine and splash; the `owl.omp_config` key controls `OWL_OMP_CONFIG`; `OWL_THEME_DIR` is environment-only

**Skip this repo when**: You need CI/CD automation, GitHub Actions, deployed tooling, or anything that runs outside a developer's local shell.

## Key Entry Points

| What you want to understand | Where to look |
|-----------------------------|---------------|
| Shell initialization | `init.sh` |
| One-line install | `install.sh` |
| How to add to dotfiles | `bashrc-snippet.sh` |
| Session health check + subcommands | `lib/preflight.sh` |
| AWS utilities | `lib/aws.sh` |
| Git utilities | `lib/git.sh` |
| PostgreSQL cluster control | `lib/postgres.sh` |
| 1Password utilities | `lib/onepassword.sh` |
| Which secrets load (`op-env`) | `lib/envsets.sh` (data in `$PREFLIGHT_CONFIG_DIR/envsets/*.tsv`, outside the clone) |
| Account/env config | `lib/config.sh` (table + loader + `preflight config`), `docs/config.md`, `defaults/config.*.json` (profile auto-copied to `$PREFLIGHT_CONFIG_DIR/config.json` on first load) |
| Owl theme + OMP config | `owl.omp_config` in `config.json`; base theme in `defaults/theme-catppuccin.omp.json` |
| Config/state directories, safe-rm guard | `lib/paths.sh` |
| PowerShell settings + env sets (`pwsh/lib/00-paths.ps1`, `01-config.ps1`, `02-envsets.ps1`; same formats as bash) | `pwsh/README.md`, tested by `tests/config.ps1` (run from `tests/config.sh` when `pwsh` is installed) |
| WSL SSH setup guide | `docs/wsl-ssh-setup.md` |
| Tests (env sets, `op-env load`/`clear`; bash + zsh, fake `op`) | `tests/op-env.sh` |
| Tests (directory layout, first run, `uninstall --purge`; bash + zsh) | `tests/paths.sh` |
| Tests (`config.json` loader, `preflight config`, table/schema/profile drift; bash + zsh) | `tests/config.sh` |

## Upstream / Downstream

- **Used by**: Developers who install it in their local shell environment
- **Depends on**: fzf, aws CLI, gh CLI, op (1Password CLI), docker, git — all must be installed locally

## Ownership

- **Team**: DevOps / Platform (or individual contributor)
- **Slack**: unknown
- **On-call**: N/A
