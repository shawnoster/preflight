# AGENTS.md — preflight

> Developer shell utility library providing fzf-powered AWS, Git, Docker, and 1Password shortcuts sourced into a developer's shell environment.

## What This Repo Does

`preflight` is a collection of Bash scripts installed under `~/.preflight/` (configurable via `PREFLIGHT_DIR`) and sourced via `init.sh` in a developer's `.bashrc` or `.zshrc`. It adds interactive shell functions for common daily tasks: fuzzy AWS profile switching and SSO login, pretty Git log/branch/stash selection with fzf, Docker container management, 1Password CLI sign-in helpers, project navigation utilities, and the OOO shell theme engine. Not a deployable service — it's a dotfiles-style developer ergonomics package.

## Two Checkouts: Template Repo vs. Working Install

There are two copies of this code on disk, and they serve different roles. Know which one you're editing before you change anything.

- **`~/dev/code/preflight` — the template (source) repo.** This is the git working tree people clone and install from. Tracked files live here: `lib/*.sh`, the `*.template` files (`lib/1password.sh.template`, `config/accounts.sh.template`, `config/owl.sh.template`), `init.sh`, `install.sh`, docs, and this `AGENTS.md`. Everything here must stay **generic** — no personal secrets, no Guild/work-specific account references, no machine-specific paths. **All tracked changes (and all PRs) are made here.**
- **`~/.preflight` — the working install (`PREFLIGHT_DIR`).** This is what `init.sh` actually sources at shell startup. On first load it copies the committed `*.template` files into their **live, gitignored** counterparts (`lib/1password.sh`, `config/accounts.sh`, `config/owl.sh`). Those live files are where the user's **Guild/work-specific** bits live: real `op://` secret references, the `OP_ACCOUNT` sign-in address, AWS profile defaults, etc. They are git-ignored precisely so personal config never lands in the template.

`~/.preflight` is itself a clone of the same repo, so its *tracked* files can be edited and committed — but doing so risks drift between the two checkouts and accidentally committing local config. **Default to editing tracked files in `~/dev/code/preflight` and opening a PR;** treat `~/.preflight` as a runtime install whose only intentional local edits are the gitignored live files. Note that `init.sh` only copies a `*.template` into its live counterpart when that live file **does not yet exist** (the copy is gated on `[[ ! -f <live file> ]]`); it never overwrites an existing one. So a template change does not retroactively rewrite an already-generated live file — the user hand-merges the new template content into their live file (or deletes the live file to regenerate it from scratch).

## Domains Covered

- **Session startup / self-management** — `lib/preflight.sh`: session health check (`preflight`), verbose mode (`preflight -v`), tool update check (`preflight -u`), self-update (`preflight update`), uninstall (`preflight uninstall`), opinionated git/SSH/AWS configuration (`preflight configure [--yes]`)
- **AWS** — `lib/aws.sh`: profile switching (`awsp`), SSO login (`aws-login`), identity check (`aws-whoami`)
- **Git** — `lib/git.sh`: fuzzy branch checkout (`gco`), pretty log (`glog`), stash management (`gstash` — pops by default, `--apply` to keep), WIP commits (`gwip`), GH PR creation (`gpr`)
- **Docker** — `lib/docker.sh`: container/image management utilities (`dex` tries bash first, falls back to sh)
- **1Password** — `lib/1password.sh.template`: sign-in, sign-out, secret fetching (`op-status`, `op-signin`). On first load `init.sh` copies the template to `lib/1password.sh` — the committed file is the template, not the live one.
- **Project navigation** — `lib/project.sh`: workspace/project switching helpers
- **OOO Theme Engine** — `lib/owl.sh`: shell MOTD splash (`_owl_splash`) and Oh My Posh theme switcher (`owl-theme`). 8 themes, each with a name, color palette for the splash, and hex palette for OMP. Theme state persists in `$PREFLIGHT_DIR/state/owl/current`. OMP integration is optional — configured via `config/owl.sh` (auto-copied from `config/owl.sh.template` on first load).

## Patterns & Tech

- **Stack**: Bash
- **Architecture**: Library of shell functions loaded via `init.sh` sourcing `lib/*.sh`; `config/accounts.sh.template`, `config/owl.sh.template` are committed and auto-copied to their live counterparts by `init.sh` on first load — edit the templates, not the generated copies
- **Key libraries**: `fzf` (interactive selection), `aws` CLI, `gh` CLI, `op` (1Password CLI), `git`, `docker`, `oh-my-posh` (optional, for `owl-theme`)
- **Notable patterns**: All functions are shell aliases/functions — no subcommand framework; `PREFLIGHT_DIR` env var controls install location (default `~/.preflight`); `PREFLIGHT_BRANCH` controls the branch used by `preflight update` (default `main`); `PREFLIGHT_VERBOSE=1` for load confirmation; `AWS_PROFILE_DEFAULT` sets the default AWS profile that `preflight` exports as `AWS_PROFILE` at session start; `OWL_OMP_CONFIG` in `config/owl.sh` points to the Oh My Posh JSON — leave empty to use owl themes without OMP

## When to Dive Deeper

Read this repo when working on:

- **Developer onboarding shell setup** — `init.sh` and `bashrc-snippet.sh` show exactly what to add to dotfiles; `install.sh` is the one-line curl installer
- **AWS SSO profile workflow issues** — `lib/aws.sh` has the profile switching and SSO login flow; `AWS_PROFILE_DEFAULT` in `config/accounts.sh` sets the session default
- **WSL SSH setup with 1Password** — `docs/wsl-ssh-setup.md` covers prerequisites; `preflight configure` automates the WSL-side steps
- **Adding new shell utilities for all engineers** — add a new `lib/<domain>.sh` file
- **1Password CLI integration for secrets** — `lib/1password.sh.template` has the sign-in flow for WSL/headless environments
- **Shell MOTD or theme customization** — `lib/owl.sh` has the theme engine and splash; `config/owl.sh.template` controls `OWL_OMP_CONFIG` and `OWL_THEME_DIR`

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
| 1Password utilities | `lib/1password.sh.template` (auto-copied to `lib/1password.sh` on first load) |
| Account/env config | `config/accounts.sh.template` (auto-copied to `config/accounts.sh` on first load) |
| Owl theme + OMP config | `config/owl.sh.template` (auto-copied to `config/owl.sh` on first load) |
| WSL SSH setup guide | `docs/wsl-ssh-setup.md` |

## Upstream / Downstream

- **Used by**: Individual Guild engineers who install it in their local shell environment
- **Depends on**: fzf, aws CLI, gh CLI, op (1Password CLI), docker, git — all must be installed locally

## Ownership

- **Team**: DevOps / Platform (or individual contributor)
- **Slack**: unknown
- **On-call**: N/A
