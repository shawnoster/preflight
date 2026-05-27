# AGENTS.md — preflight

> Developer shell utility library providing fzf-powered AWS, Git, Docker, and 1Password shortcuts sourced into a developer's shell environment.

## What This Repo Does

`preflight` is a collection of Bash scripts installed under `~/.preflight/` (configurable via `PREFLIGHT_DIR`) and sourced via `init.sh` in a developer's `.bashrc` or `.zshrc`. It adds interactive shell functions for common daily tasks: fuzzy AWS profile switching and SSO login, pretty Git log/branch/stash selection with fzf, Docker container management, 1Password CLI sign-in helpers, and project navigation utilities. Not a deployable service — it's a dotfiles-style developer ergonomics package.

## Domains Covered

- **Session startup / self-management** — `lib/preflight.sh`: session health check (`preflight`), verbose mode (`preflight -v`), tool update check (`preflight -u`), self-update (`preflight update`), uninstall (`preflight uninstall`), opinionated git/SSH/AWS configuration (`preflight configure [--yes]`)
- **AWS** — `lib/aws.sh`: profile switching (`awsp`), SSO login (`aws-login`), identity check (`aws-whoami`)
- **Git** — `lib/git.sh`: fuzzy branch checkout (`gco`), pretty log (`glog`), stash management (`gstash` — pops by default, `--apply` to keep), WIP commits (`gwip`), GH PR creation (`gpr`)
- **Docker** — `lib/docker.sh`: container/image management utilities (`dex` tries bash first, falls back to sh)
- **1Password** — `lib/1password.sh.template`: sign-in, sign-out, secret fetching (`op-status`, `op-signin`). On first load `init.sh` copies the template to `lib/1password.sh` — the committed file is the template, not the live one.
- **Project navigation** — `lib/project.sh`: workspace/project switching helpers

## Patterns & Tech

- **Stack**: Bash
- **Architecture**: Library of shell functions loaded via `init.sh` sourcing `lib/*.sh`; `config/accounts.sh.template` is committed and auto-copied to `config/accounts.sh` by `init.sh` on first load — edit the template, not the generated copy
- **Key libraries**: `fzf` (interactive selection), `aws` CLI, `gh` CLI, `op` (1Password CLI), `git`, `docker`
- **Notable patterns**: All functions are shell aliases/functions — no subcommand framework; `PREFLIGHT_DIR` env var controls install location (default `~/.preflight`); `PREFLIGHT_BRANCH` controls the branch used by `preflight update` (default `main`); `PREFLIGHT_VERBOSE=1` for load confirmation; `AWS_PROFILE_DEFAULT` sets the default AWS profile that `preflight` exports as `AWS_PROFILE` at session start

## When to Dive Deeper

Read this repo when working on:

- **Developer onboarding shell setup** — `init.sh` and `bashrc-snippet.sh` show exactly what to add to dotfiles; `install.sh` is the one-line curl installer
- **AWS SSO profile workflow issues** — `lib/aws.sh` has the profile switching and SSO login flow; `AWS_PROFILE_DEFAULT` in `config/accounts.sh` sets the session default
- **WSL SSH setup with 1Password** — `docs/wsl-ssh-setup.md` covers prerequisites; `preflight configure` automates the WSL-side steps
- **Adding new shell utilities for all engineers** — add a new `lib/<domain>.sh` file
- **1Password CLI integration for secrets** — `lib/1password.sh.template` has the sign-in flow for WSL/headless environments

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
| WSL SSH setup guide | `docs/wsl-ssh-setup.md` |

## Upstream / Downstream

- **Used by**: Individual Guild engineers who install it in their local shell environment
- **Depends on**: fzf, aws CLI, gh CLI, op (1Password CLI), docker, git — all must be installed locally

## Ownership

- **Team**: DevOps / Platform (or individual contributor)
- **Slack**: unknown
- **On-call**: N/A
