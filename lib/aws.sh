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
  Display this help message.

awsp
  Fuzzy-select and switch AWS profile (alias for switch-aws-profile).
  Sets the AWS_PROFILE environment variable without logging in.

aws-whoami
  Show current AWS profile, region, and caller identity.

aws-login [profile]
  SSO login. Uses the given profile, falls back to $AWS_PROFILE,
  or offers fuzzy selection if neither is set.
  Also sets AWS_PROFILE to the resolved profile.
  Example: aws-login guild-dev

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

  local region
  region=$(aws configure get region 2>/dev/null)
  [[ -n "$region" ]] && echo "🌎 Region:  $region"

  aws sts get-caller-identity --output table 2>/dev/null || echo "❌ Not authenticated or no valid credentials"
}

# SSO login — with optional profile arg or fzf selection
aws-login() {
  local profile="${1:-$AWS_PROFILE}"

  # No profile given and none set — offer interactive selection
  if [[ -z "$profile" ]]; then
    profile=$(aws configure list-profiles | fzf --prompt="Select profile for SSO login > ")
    [[ -z "$profile" ]] && return 0
  fi

  export AWS_PROFILE="$profile"
  echo "📍 Profile: $AWS_PROFILE"
  aws sso login --profile "$profile"
}
