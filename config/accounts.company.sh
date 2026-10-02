#!/usr/bin/env bash
# ~/.preflight/config/accounts.company.sh — Company development profile
#
# Intended for team/company environments: AWS, NPM, SAM, full toolchain.
# Selected on first-time setup, or copy manually:
#   cp config/accounts.company.sh config/accounts.sh
# Then edit accounts.sh with your real values, and register secrets with `op-env add`.

# ── 1Password account reference ──────────────────────────────────────────────
# See lib/onepassword.sh for the auth model. Examples: "my.1password.com", "work".
export OP_ACCOUNT="my.1password.com"

# ── 1Password secrets ────────────────────────────────────────────────────────
# The list of secrets does not live in this file. Register VAR -> op:// pairs
# with `op-env add`; they are stored in config/envsets/<set>.tsv and loaded by
# op-load-env. For example:
#   op-env add default NPM_TOKEN 'op://Private/npmjs/credential'
# Run `op-env help` for the rest. (A legacy OP_SECRETS=( ... ) array here still
# works; `op-env migrate` moves it into a set.)

# ── Optional env var warnings in preflight ───────────────────────────────────
# Space-separated list of variable names. Preflight warns if any are unset.
_OPTIONAL_ENV_VARS="NPM_TOKEN"

# ── Gitea credential helper ──────────────────────────────────────────────────
# When GITEA_TOKEN is loaded, preflight writes https://USERNAME:TOKEN@HOST
# to ~/.git-credentials.
export GITEA_USERNAME=""
export GITEA_HOST=""

# ── Preflight check toggles ──────────────────────────────────────────────────
# Set to 0 to skip a check section entirely. Default is 1 (checked).
_CHECK_AWS=1
_CHECK_GH=1
_CHECK_SSH=1
_CHECK_GIT_CONFIG=1

# ── Project directories for `proj` command ───────────────────────────────────
export PROJ_DIRS="$HOME/projects:$HOME/work:$HOME/src"

# ── Default AWS profile ──────────────────────────────────────────────────────
# Used by preflight at session start if AWS_PROFILE is not already set.
export AWS_PROFILE_DEFAULT="${AWS_PROFILE_DEFAULT:-my-dev-profile}"

# ── Git defaults ─────────────────────────────────────────────────────────────
export GIT_MAIN_BRANCH="main"

# ── Editor preferences ───────────────────────────────────────────────────────
export EDITOR="${EDITOR:-vim}"
export VISUAL="${VISUAL:-code}"
