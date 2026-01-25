#!/usr/bin/env bash
# ~/.dev/lib/1password.sh - 1Password CLI utilities
#
# Requires: op (1Password CLI) installed and account added
# Setup:    op account add --shorthand guild_education

# Default account (can be overridden in config/accounts.sh)
OP_ACCOUNT="${OP_ACCOUNT:-my}"

# Display help for all 1Password commands
op-help() {
  cat <<'EOF'
1Password CLI Utilities
========================

Available Commands:
-------------------

op-help
  Display this help message showing all available 1Password commands.

op-status
  Check if you are currently signed in to 1Password.
  Returns: ✅ if signed in, ❌ if not signed in

op-signin [account]
  Sign in to 1Password account.
  Arguments:
    account - Optional. Account shorthand (default: $OP_ACCOUNT)
  Example: op-signin guild_education

op-load-env
  Load secrets from 1Password into environment variables.
  Automatically signs in if not already authenticated.
  Sets the following environment variables:
    - ATLASSIAN_API_TOKEN
    - ATLASSIAN_EMAIL
    - ATLASSIAN_SERVER_URL
    - DATADOG_API_KEY
    - DATADOG_APP_KEY
    - GITHUB_TOKEN / GITHUB_PERSONAL_ACCESS_TOKEN
    - NPM_TOKEN
    - PACT_READONLY_PASSWORD
    - SONAR_TOKEN

op-clear-env
  Clear all sensitive environment variables loaded by op-load-env.

Configuration:
--------------
Default account: $OP_ACCOUNT
Set OP_ACCOUNT in config/accounts.sh to override.

Requirements:
-------------
- 1Password CLI (op) must be installed
- Account must be added: op account add --shorthand guild_education

EOF
}

# Check if signed in to 1Password
op-status() {
  if op whoami --account "$OP_ACCOUNT" >/dev/null 2>&1; then
    echo "✅ Signed in to 1Password ($OP_ACCOUNT)"
    return 0
  else
    echo "❌ Not signed in to 1Password ($OP_ACCOUNT)"
    return 1
  fi
}

# Sign in to 1Password (manual session token flow for WSL/headless)
op-signin() {
  local account="${1:-$OP_ACCOUNT}"

  if op whoami --account "$account" >/dev/null 2>&1; then
    echo "✅ Already signed in to 1Password ($account)"
    return 0
  fi

  echo "🔐 Signing in to 1Password ($account)..."
  eval $(op signin --account "$account")

  if op whoami --account "$account" >/dev/null 2>&1; then
    echo "✅ Signed in to 1Password ($account)"
    return 0
  else
    echo "❌ Failed to sign in to 1Password"
    return 1
  fi
}

# Load secrets into environment variables
op-load-env() {
  # Ensure we're signed in (will prompt if not)
  if ! op whoami --account "$OP_ACCOUNT" >/dev/null 2>&1; then
    op-signin "$OP_ACCOUNT" || return 1
  fi

  echo "🔑 Fetching secrets from 1Password..."

  # Secure variables, pulled from 1Password
  export GITHUB_TOKEN=$(op read --account "$OP_ACCOUNT" "op://Private/GitHub - PAT - Personal Development/credential")

  echo "✅ Environment variables set."
}

# Clear sensitive environment variables
op-clear-env() {
  unset GITHUB_TOKEN
  echo "🧹 Secure environment variables cleared."
}
