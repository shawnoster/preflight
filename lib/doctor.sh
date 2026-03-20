#!/usr/bin/env bash
# ~/.dev/lib/doctor.sh - Developer environment diagnostics
#
# Checks: NPM_TOKEN, GITHUB_TOKEN, SSH, AWS profile, and common tools

doctor() {
  echo "========================================"
  echo "     Developer Environment Doctor      "
  echo "========================================"
  echo ""

  local issues=0

  echo "--- Environment Variables ---"
  
  if [[ -n "$NPM_TOKEN" ]]; then
    echo "✅ NPM_TOKEN is set"
  else
    echo "⚠️  NPM_TOKEN is not set"
    ((issues++))
  fi

  if [[ -n "$GITHUB_TOKEN" ]]; then
    echo "✅ GITHUB_TOKEN is set"
  else
    echo "⚠️  GITHUB_TOKEN is not set"
    ((issues++))
  fi

  if [[ -n "$AWS_PROFILE" ]]; then
    echo "✅ AWS_PROFILE is set: $AWS_PROFILE"
  else
    echo "⚠️  AWS_PROFILE is not set"
    ((issues++))
  fi

  echo ""
  echo "--- SSH ---"

  if [[ -n "$SSH_AUTH_SOCK" ]]; then
    echo "✅ SSH_AUTH_SOCK is set: $SSH_AUTH_SOCK"
    if ssh-add -l &>/dev/null; then
      echo "✅ SSH agent has keys loaded"
    else
      echo "⚠️  SSH agent running but no keys loaded"
    fi
  else
    echo "⚠️  SSH_AUTH_SOCK not set (ssh-agent not running?)"
    ((issues++))
  fi

  if [[ -f "$HOME/.ssh/id_ed25519" ]] || [[ -f "$HOME/.ssh/id_rsa" ]]; then
    echo "✅ SSH keys exist in ~/.ssh/"
  else
    echo "⚠️  No SSH keys found in ~/.ssh/"
    ((issues++))
  fi

  echo ""
  echo "--- AWS Authentication ---"

  if command -v aws &>/dev/null; then
    local aws_version
    aws_version=$(aws --version 2>&1)
    echo "✅ AWS CLI installed: $aws_version"
    
    if aws sts get-caller-identity &>/dev/null; then
      echo "✅ AWS authenticated"
      aws sts get-caller-identity 2>/dev/null | jq -r '.Arn' 2>/dev/null && echo "   $(aws sts get-caller-identity 2>/dev/null | jq -r '.UserId')"
    else
      echo "⚠️  AWS not authenticated (run 'aws-switch' or 'aws-login')"
      ((issues++))
    fi
  else
    echo "❌ AWS CLI not installed"
    ((issues++))
  fi

  echo ""
  echo "--- Installed Tools ---"

  local tools=(
    "sam:AWS SAM CLI"
    "docker:Docker"
    "kubectl:Kubernetes kubectl"
    "terraform:Terraform"
    "ansible:Ansible"
    "gh:GitHub CLI"
    "op:1Password CLI"
    "jq:jq"
    "fzf:fzf"
    "tmux:tmux"
    "starship:Starship prompt"
  )

  for item in "${tools[@]}"; do
    local cmd="${item%%:*}"
    local name="${item##*:}"
    
    if command -v "$cmd" &>/dev/null; then
      local version
      version=$("$cmd" --version 2>&1 | head -1 || "$cmd" -v 2>&1 | head -1 || echo "installed")
      echo "✅ $name: $version"
    else
      echo "❌ $name not installed"
    fi
  done

  echo ""
  echo "--- Git Configuration ---"

  if command -v git &>/dev/null; then
    echo "✅ Git installed: $(git --version)"
    
    if [[ -n "$(git config --global user.email)" ]]; then
      echo "✅ Git user.email: $(git config --global user.email)"
    else
      echo "⚠️  Git user.email not set"
    fi
    
    if [[ -n "$(git config --global user.name)" ]]; then
      echo "✅ Git user.name: $(git config --global user.name)"
    else
      echo "⚠️  Git user.name not set"
    fi
  else
    echo "❌ Git not installed"
  fi

  echo ""
  echo "--- Node.js ---"

  if command -v node &>/dev/null; then
    echo "✅ Node.js: $(node --version)"
    if command -v npm &>/dev/null; then
      echo "✅ npm: $(npm --version)"
    fi
  else
    echo "❌ Node.js not installed"
  fi

  echo ""
  echo "--- Python ---"

  if command -v python3 &>/dev/null; then
    echo "✅ Python3: $(python3 --version)"
  elif command -v python &>/dev/null; then
    echo "✅ Python: $(python --version)"
  else
    echo "❌ Python not installed"
  fi

  echo ""
  echo "========================================"
  if [[ $issues -gt 0 ]]; then
    echo "⚠️  Found $issues issue(s) - see above"
  else
    echo "✅ All checks passed!"
  fi
  echo "========================================"
}

alias dr='doctor'
