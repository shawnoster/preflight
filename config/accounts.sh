#!/usr/bin/env bash
# ~/.dev/config/accounts.sh - Non-secret configuration
#
# This file contains account identifiers and configuration.
# Do NOT put secrets here - use 1Password for those.

# 1Password account shorthand
export OP_ACCOUNT="my"

# Project directories for `proj` command (colon-separated)
export PROJ_DIRS="$HOME/projects:$HOME/work:$HOME/src"

# Default AWS profile (optional)
export AWS_PROFILE

# Default Git branch names
export GIT_MAIN_BRANCH="main"

# Editor preferences
export EDITOR="${EDITOR:-vim}"
export VISUAL="${VISUAL:-code}"
