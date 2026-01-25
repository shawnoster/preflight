#!/usr/bin/env bash
# ~/.dev/lib/1password.sh - 1Password CLI utilities
#
# Requires: op (1Password CLI) installed and account added
# Setup:    op account add --shorthand guild_education

# Default account (can be overridden in config/accounts.sh)
OP_ACCOUNT="${OP_ACCOUNT:-guild_education}"

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
  export ATLASSIAN_API_TOKEN=$(op read --account "$OP_ACCOUNT" "op://Employee/Atlassian - VSCode/credential")
  export ATLASSIAN_EMAIL=$(op read --account "$OP_ACCOUNT" "op://Employee/Atlassian - VSCode/username")
  export ATLASSIAN_SERVER_URL=$(op read --account "$OP_ACCOUNT" "op://Employee/Atlassian - VSCode/hostname")
  export DATADOG_API_KEY=$(op read --account "$OP_ACCOUNT" "op://Employee/Datadog - API Key - Self-Serve Workflow/credential")
  export DATADOG_APP_KEY=$(op read --account "$OP_ACCOUNT" "op://Employee/Datadog - App Key - Self-Serve Script/credential")
  export GITHUB_TOKEN=$(op read --account "$OP_ACCOUNT" "op://Employee/GitHub PAT - Local Development/credential")
  export GITHUB_PERSONAL_ACCESS_TOKEN=$GITHUB_TOKEN
  export NPM_TOKEN=$(op read --account "$OP_ACCOUNT" "op://Employee/npm - token - Local Development/credential")
  export PACT_READONLY_PASSWORD=$(op read --account "$OP_ACCOUNT" "op://Engineering Tools - Dev/Pact Broker - Readonly/password")
  export SONAR_TOKEN=$(op read --account "$OP_ACCOUNT" "op://Employee/SonarQube - Docker/token")

  echo "✅ Environment variables set."
  echo "--- Loaded environment variables:"
  echo "ATLASSIAN_API_TOKEN"
  echo "ATLASSIAN_EMAIL"
  echo "ATLASSIAN_SERVER_URL"
  echo "DATADOG_API_KEY"
  echo "DATADOG_APP_KEY"
  echo "GITHUB_TOKEN"
  echo "NPM_TOKEN"
  echo "PACT_READONLY_PASSWORD"
  echo "SONAR_TOKEN"
}

# Clear sensitive environment variables
op-clear-env() {
  unset GITHUB_TOKEN ATLASSIAN_API_KEY ATLASSIAN_API_USER ATLASSIAN_SERVER_URL
  unset NPM_TOKEN PACT_READONLY_PASSWORD SONAR_TOKEN
  unset DATADOG_API_KEY DATADOG_APP_KEY
  echo "🧹 Secure environment variables cleared."
}
