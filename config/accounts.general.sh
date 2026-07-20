#!/usr/bin/env bash
# ~/.preflight/config/accounts.general.sh — General development profile
#
# Intended for individual developers: Gitea, GitHub PATs, minimal tooling.
# Selected on first-time setup, or copy manually:
#   cp config/accounts.general.sh config/accounts.sh
# Then edit accounts.sh with your real op:// references and values.

# ── 1Password account reference ──────────────────────────────────────────────
# See lib/1password.sh for the auth model. Examples: "my.1password.com", "my".
export OP_ACCOUNT="my.1password.com"

# ── 1Password secrets (override lib/1password.sh.template default) ───────────
# Format: VAR_NAME<TAB>op://vault/item/field. op-load-env and op-clear-env both
# iterate this array, so listing a secret here registers it for load and clear.
OP_SECRETS=(
  $'GITHUB_TOKEN\top://Private/GitHub - PAT/credential'
  $'GITEA_TOKEN\top://Private/Gitea - Personal/pat'
)

# ── Optional env var warnings in preflight ───────────────────────────────────
# Space-separated list of variable names. Preflight warns if any are unset.
_OPTIONAL_ENV_VARS=""

# ── Gitea credential helper ──────────────────────────────────────────────────
# When GITEA_TOKEN is loaded, preflight writes https://USERNAME:TOKEN@HOST
# to ~/.git-credentials.
export GITEA_USERNAME=""
export GITEA_HOST=""

# ── Preflight check toggles ──────────────────────────────────────────────────
# Set to 0 to skip a check section entirely. Default is 1 (checked).
# AWS off by default for individual dev.
_CHECK_AWS=0
_CHECK_GH=1
_CHECK_SSH=1
_CHECK_GIT_CONFIG=1

# ── Project directories for `proj` command ───────────────────────────────────
export PROJ_DIRS="$HOME/dev:$HOME/src"

# ── Git defaults ─────────────────────────────────────────────────────────────
export GIT_MAIN_BRANCH="main"

# ── Editor preferences ───────────────────────────────────────────────────────
export EDITOR="${EDITOR:-vim}"
export VISUAL="${VISUAL:-code}"
