# AGENTS.md — preflight

> Developer shell utility library providing fzf-powered AWS, Git, Docker, and 1Password shortcuts sourced into a developer's shell environment.

## What This Repo Does

`preflight` is a collection of Bash scripts installed under `~/.preflight/` (configurable via `PREFLIGHT_DIR`) and sourced via `init.sh` in a developer's `.bashrc` or `.zshrc`. It adds interactive shell functions for common daily tasks: fuzzy AWS profile switching and SSO login, pretty Git log/branch/stash selection with fzf, Docker container management, 1Password CLI sign-in helpers, project navigation utilities, and the OOO shell theme engine. Not a deployable service — it's a dotfiles-style developer ergonomics package.

## Two Checkouts: Template Repo vs. Working Install

There are two copies of this code on disk, and they serve different roles. Know which one you're editing before you change anything.

- **The template (source) repo** — wherever you cloned it (e.g. `~/dev/code/preflight`; the source checkout location is arbitrary — only the working install path is fixed by default). This is the git working tree people clone and install from. Tracked files live here: `lib/*.sh`, the `*.template` files and profiles under `defaults/` (`defaults/accounts.sh.template`, `defaults/owl.sh.template`), `init.sh`, `install.sh`, docs, and this `AGENTS.md`. Everything here must stay **generic** — no personal secrets, no work-specific account references, no machine-specific paths. **All tracked changes (and all PRs) are made here.**
- **`~/.preflight` — the working install (`PREFLIGHT_DIR`).** This is what `init.sh` actually sources at shell startup. It is a disposable clone: it holds no user data. On first load `init.sh` copies the committed `defaults/*.template` files into their **live counterparts outside the clone**, in `PREFLIGHT_CONFIG_DIR` (default `~/.config/preflight`: `accounts.sh`, `owl.sh`, `envsets/*.tsv`). Owl state lives in `PREFLIGHT_STATE_DIR` (default `~/.local/state/preflight`). Both are resolved once by `lib/paths.sh` (override variables, then `XDG_CONFIG_HOME` / `XDG_STATE_HOME`, then the defaults), which refuses a `PREFLIGHT_DIR` equal to either. Those live files are where the user's **work-specific** bits live: real `op://` secret references (in env sets), the `OP_ACCOUNT` sign-in address, AWS profile defaults, etc. Because they live outside the repo, personal config can never land in the template, and `preflight update` / `uninstall` (without `--purge`) never touch them.

`~/.preflight` is itself a clone of the same repo, so its *tracked* files can be edited and committed — but doing so risks drift between the two checkouts and accidentally committing local config. **Default to editing tracked files in the source checkout and opening a PR;** treat `~/.preflight` as a runtime install whose only intentional local edits are the gitignored live files.

**No separate source checkout on this machine?** Check before assuming one exists — don't guess a path like `~/dev/code/preflight` and treat its absence as "must not apply here." If `~/.preflight` really is the only clone, it's still not a license to commit tracked-file changes straight to its local `main`: `git fetch origin` first (main may have moved — another machine or a prior session may have pushed since this clone last pulled), then branch off `origin/main` (not local `main`, which `fetch` alone does not update — fast-forward it too if you want it current, but branch from the remote ref regardless), commit there, push, and open a PR from that branch, exactly as if this were the source checkout. Never land a tracked-file change directly on local `main` in any checkout, single or not.

Note that both `init.sh` (on every shell load) and `install.sh` (at install time) normally copy a `*.template` into its live counterpart only when the live file is **missing** *and* the template exists — e.g. for owl:

```bash
if [[ ! -f "$PREFLIGHT_CONFIG_DIR/owl.sh" ]] && [[ -f "$PREFLIGHT_DIR/defaults/owl.sh.template" ]]; then
  cp "$PREFLIGHT_DIR/defaults/owl.sh.template" "$PREFLIGHT_CONFIG_DIR/owl.sh"
fi
```

Missing-file copying is the only behavior: it never overwrites an existing live file, so a template change does not retroactively rewrite an already-generated live file — the user hand-merges the new template content into their live file (or deletes the live file to regenerate it from scratch). Say so in the PR's upgrade notes when you change a template. (The old sha256-based refresh of an untouched `owl.sh` was removed with the move to `PREFLIGHT_CONFIG_DIR`.) There is no migration from the old in-clone `config/` and `state/` locations; the README's upgrade note tells the user how to move them by hand.

## Domains Covered

- **Session startup / self-management** — `lib/preflight.sh`: session health check (`preflight`), verbose mode (`preflight -v`), tool update check (`preflight -u`), self-update (`preflight update`), uninstall (`preflight uninstall [--purge]`), opinionated git/SSH/AWS configuration (`preflight configure [--yes]`)
- **AWS** — `lib/aws.sh`: profile switching (`awsp`), SSO login (`aws-login`), identity check (`aws-whoami`)
- **Git** — `lib/git.sh`: fuzzy branch checkout (`gco`), pretty log (`glog`), stash management (`gstash` — pops by default, `--apply` to keep), WIP commits (`gwip`), GH PR creation (`gpr`)
- **Docker** — `lib/docker.sh`: container/image management utilities (`dex` tries bash first, falls back to sh)
- **PostgreSQL** — `lib/postgres.sh`: cluster start/stop (`pg-up`, `pg-down`) for clusters set to `manual` in `start.conf`. Goes through `pg_ctlcluster`, which self-redirects to `systemctl` when systemd is running and the caller is root, so one code path covers systemd and non-systemd hosts. Debian/Ubuntu only — needs `postgresql-common`.
- **1Password** — `lib/onepassword.sh`: generic, data-agnostic helpers (`op-status`, `op-signin`, `op-load-env`, `op-clear-env`, `op-new`, `op-import-csv`). It is a plain tracked file and must never name a specific secret; after-load side effects register through `_OP_AFTER_LOAD_HOOKS` (e.g. `lib/nanoleaf.sh`).
- **Env sets** — `lib/envsets.sh`: `op-env add|list|rm|use|migrate`. The only place that defines which secrets load: named sets of `VAR → op://` refs in `$PREFLIGHT_CONFIG_DIR/envsets/<set>.tsv`. `_op_env_entries` is the contract between it and `op-load-env`/`op-clear-env`; it passes lines through as written, so a set line may carry an optional third TAB column naming a 1Password account (absent = `$OP_ACCOUNT`), and `op-load-env` groups entries by that account and runs one `op inject` per account. A legacy `OP_SECRETS` array in an older `accounts.sh` is still honored until `op-env migrate` moves it.
- **Project navigation** — `lib/project.sh`: workspace/project switching helpers
- **Paths** — `lib/paths.sh`: `_pf_resolve_dirs` (exports `PREFLIGHT_CONFIG_DIR` / `PREFLIGHT_STATE_DIR`, refuses a layout that shares the clone) and `_pf_safe_rm_dir` (the guard every `rm -rf` of a directory goes through, including `preflight uninstall --purge`)
- **Prompting** — `lib/prompt.sh`: `_pf_ask`, the Bash/zsh-portable replacement for `read -p`
- **OOO Theme Engine** — `lib/owl.sh`: shell MOTD splash (`_owl_splash`) and Oh My Posh theme switcher (`owl-theme`). 8 themes, each with a name, color palette for the splash, and hex palette for OMP. Theme state persists in `$PREFLIGHT_STATE_DIR/owl/current`. OMP integration is optional — configured via `$PREFLIGHT_CONFIG_DIR/owl.sh` (auto-copied from `defaults/owl.sh.template` on first load).

## Patterns & Tech

- **Stack**: Bash
- **Architecture**: Library of shell functions loaded via `init.sh` sourcing `lib/*.sh`; `defaults/accounts.sh.template`, `defaults/owl.sh.template` are committed and auto-copied to their live counterparts in `PREFLIGHT_CONFIG_DIR` by `init.sh` on first load — edit the templates, not the generated copies
- **Key libraries**: `fzf` (interactive selection), `aws` CLI, `gh` CLI, `op` (1Password CLI), `git`, `docker`, `oh-my-posh` (optional, for `owl-theme`)
- **Notable patterns**: Libraries are sourced from both Bash and zsh, so avoid Bash-only constructs: prompt with `_pf_ask` (`lib/prompt.sh`) instead of `read -p`, and do not use `read -a`, `mapfile`/`readarray` or relying on 0-based array indexes. A prompt whose empty answer means yes must treat a failed read as a decline (`_pf_ask reply "..." || reply=n`). All functions are shell aliases/functions — no subcommand framework; `PREFLIGHT_DIR` env var controls install location (default `~/.preflight`); `PREFLIGHT_BRANCH` controls the branch used by `preflight update` (default `main`); `PREFLIGHT_VERBOSE=1` for load confirmation; `AWS_PROFILE_DEFAULT` sets the default AWS profile that `preflight` exports as `AWS_PROFILE` at session start; `OWL_OMP_CONFIG` in `owl.sh` (in `PREFLIGHT_CONFIG_DIR`) points to the Oh My Posh JSON — leave empty to use owl themes without OMP

## When to Dive Deeper

Read this repo when working on:

- **Developer onboarding shell setup** — `init.sh` and `bashrc-snippet.sh` show exactly what to add to dotfiles; `install.sh` is the one-line curl installer
- **AWS SSO profile workflow issues** — `lib/aws.sh` has the profile switching and SSO login flow; `AWS_PROFILE_DEFAULT` in `accounts.sh` (in `PREFLIGHT_CONFIG_DIR`) sets the session default
- **WSL SSH setup with 1Password** — `docs/wsl-ssh-setup.md` covers prerequisites; `preflight configure` installs the systemd + npiperelay agent bridge and migrates off the old `ssh.exe` aliases
- **Adding new shell utilities for all engineers** — add a new `lib/<domain>.sh` file
- **1Password CLI integration for secrets** — `lib/onepassword.sh` has the sign-in flow for WSL/headless environments; `lib/envsets.sh` has the list of secrets
- **Shell MOTD or theme customization** — `lib/owl.sh` has the theme engine and splash; `defaults/owl.sh.template` controls `OWL_OMP_CONFIG` and `OWL_THEME_DIR`

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
| Account/env config | `defaults/accounts.sh.template` (auto-copied to `$PREFLIGHT_CONFIG_DIR/accounts.sh` on first load) |
| Owl theme + OMP config | `defaults/owl.sh.template` (auto-copied to `$PREFLIGHT_CONFIG_DIR/owl.sh` on first load) |
| Config/state directories, safe-rm guard | `lib/paths.sh` |
| WSL SSH setup guide | `docs/wsl-ssh-setup.md` |
| Tests (env sets, `op-load-env`; bash + zsh, fake `op`) | `tests/op-env.sh` |
| Tests (directory layout, first run, `uninstall --purge`; bash + zsh) | `tests/paths.sh` |

## Upstream / Downstream

- **Used by**: Developers who install it in their local shell environment
- **Depends on**: fzf, aws CLI, gh CLI, op (1Password CLI), docker, git — all must be installed locally

## Ownership

- **Team**: DevOps / Platform (or individual contributor)
- **Slack**: unknown
- **On-call**: N/A
