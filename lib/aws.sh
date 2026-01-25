#!/usr/bin/env bash
# ~/.dev/lib/aws.sh - AWS CLI utilities
#
# Requires: aws cli, fzf

# Display help for all AWS commands
aws-help() {
  cat <<'EOF'
AWS CLI Utilities
=================

Available Commands:
-------------------

aws-help
  Display this help message showing all available AWS commands.

switch-aws-profile
  Interactively select and switch AWS profile using fzf.
  Sets the AWS_PROFILE environment variable.

awsp
  Alias for switch-aws-profile.

aws-whoami
  Show current AWS identity and profile information.
  Displays the AWS_PROFILE and runs sts get-caller-identity.

aws-login [profile]
  Perform SSO login for specified profile.
  Arguments:
    profile - Optional. AWS profile name (default: $AWS_PROFILE)
  Example: aws-login guild-dev

aws-sso-switch
  Interactively select profile and perform SSO login.
  Combines profile switching with SSO authentication.

Common Aliases:
---------------
awsp - Quick access to switch-aws-profile

Configuration:
--------------
Default profile: $AWS_PROFILE (set in config/accounts.sh)

Requirements:
-------------
- AWS CLI v2 (for SSO support)
- fzf (for interactive selection)
- Profiles configured in ~/.aws/config

EOF
}

# Switch AWS profile interactively
switch-aws-profile() {
  local profile
  profile=$(aws configure list-profiles | fzf --prompt="Select AWS Profile > ")

  if [[ -n "$profile" ]]; then
    export AWS_PROFILE="$profile"
    echo "✅ Switched to AWS profile: $AWS_PROFILE"
  else
    echo "⚠️ No profile selected."
  fi
}

# Alias for quick access
alias awsp='switch-aws-profile'

# Show current AWS identity
aws-whoami() {
  if [[ -z "$AWS_PROFILE" ]]; then
    echo "⚠️ AWS_PROFILE not set"
  else
    echo "📍 Profile: $AWS_PROFILE"
  fi
  aws sts get-caller-identity 2>/dev/null || echo "❌ Not authenticated or no valid credentials"
}

# Quick SSO login for current profile
aws-login() {
  local profile="${1:-$AWS_PROFILE}"
  if [[ -z "$profile" ]]; then
    echo "⚠️ No profile specified and AWS_PROFILE not set"
    echo "Usage: aws-login <profile> or set AWS_PROFILE first"
    return 1
  fi
  aws sso login --profile "$profile"
}

# List and switch to an SSO session
aws-sso-switch() {
  local profile
  profile=$(aws configure list-profiles | fzf --prompt="Select profile for SSO login > ")
  if [[ -n "$profile" ]]; then
    export AWS_PROFILE="$profile"
    aws sso login --profile "$profile"
  fi
}
