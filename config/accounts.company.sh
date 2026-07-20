#!/usr/bin/env bash
# ~/.preflight/config/accounts.company.sh — Company development profile
#
# Intended for team/company environments: AWS, NPM, SAM, full toolchain.
# Selected on first-time setup, or copy manually:
#   cp config/accounts.company.sh config/accounts.sh
# Then edit accounts.sh with your real op:// references and values.

# ── 1Password account reference ──────────────────────────────────────────────
# See lib/1password.sh for the auth model. Examples: "my.1password.com", "work".
export OP_ACCOUNT="my.1password.com"

# ── 1Password secrets (override lib/1password.sh.template default) ───────────
# Format: VAR_NAME<TAB>op://vault/item/field. op-load-env and op-clear-env both
# iterate this array, so listing a secret here registers it for load and clear.
OP_SECRETS=(
  $'GITHUB_TOKEN\top://Private/GitHub - PAT/credential'
  $'NPM_TOKEN\top://Private/npmjs/credential'
)

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
