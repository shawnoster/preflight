#!/usr/bin/env bash
# ~/.dev/lib/aws.sh - AWS CLI utilities
#
# Requires: aws cli, fzf

aws-help() {
  cat <<'EOF'
AWS CLI Utilities
=================

Available Commands:
-------------------

aws-help
  Display this help message.

awsp [profile]
  Switch AWS profile. Pass a profile name directly or pick interactively with fzf.
  Sets the AWS_PROFILE environment variable without logging in.
  Example: awsp guild-prod-readonly

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

# Switch AWS profile — pass a name directly or pick interactively
switch-aws-profile() {
  local profile="${1:-}"

  if [[ -z "$profile" ]]; then
    if [[ ! -t 0 ]]; then
      echo "Usage: awsp <profile>" >&2
      return 1
    fi
    profile=$(aws configure list-profiles | fzf --prompt="Select AWS Profile > ")
  fi

  if [[ -n "$profile" ]]; then
    export AWS_PROFILE="$profile"
    echo "✅ Switched to AWS profile: $AWS_PROFILE"
  else
    echo "⚠️  No profile selected."
  fi
}

alias awsp='switch-aws-profile'

# Show current AWS identity
aws-whoami() {
  if [[ -z "$AWS_PROFILE" ]]; then
    echo "⚠️  AWS_PROFILE not set"
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

  if [[ -z "$profile" ]]; then
    if [[ ! -t 0 ]]; then
      echo "Usage: aws-login <profile>" >&2
      return 1
    fi
    profile=$(aws configure list-profiles | fzf --prompt="Select profile for SSO login > ")
    [[ -z "$profile" ]] && return 0
  fi

  export AWS_PROFILE="$profile"
  echo "📍 Profile: $AWS_PROFILE"
  aws sso login --profile "$profile"
}
