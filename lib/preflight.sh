#!/usr/bin/env bash
# ~/.dev/lib/preflight.sh - Session startup and environment health check
#
# Usage:
#   preflight       - sign in, load secrets, refresh AWS, run health checks
#   preflight -u    - same + compare installed tools against latest stable versions

preflight() {
  local check_updates=false
  for arg in "$@"; do
    case "$arg" in -u|--updates) check_updates=true ;; esac
  done

  # Erase the Starship prompt line above our output (terminal only)
  [[ -t 1 ]] && printf '\033[1A\033[2K\r'

  echo "========================================"
  echo "          Preflight Check               "
  echo "========================================"
  echo ""

  local issues=0
  local updates_available=0

  # ── Secrets ───────────────────────────────────────────────────────────────

  if command -v op &>/dev/null; then
    op-load-env
  else
    echo "⚠️  1Password CLI not installed — skipping secret loading"
    ((issues++))
  fi

  # ── AWS Session ───────────────────────────────────────────────────────────

  echo ""
  echo "--- AWS Session ---"

  if command -v aws &>/dev/null; then
    if aws sts get-caller-identity &>/dev/null 2>&1; then
      echo "✅ AWS session active ($(aws sts get-caller-identity 2>/dev/null | jq -r '.Account' 2>/dev/null))"
    else
      echo "☁️  Refreshing AWS SSO..."
      aws-login
    fi
  else
    echo "❌ AWS CLI not installed"
    ((issues++))
  fi

  # ── Environment Variables ─────────────────────────────────────────────────

  echo ""
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

  # ── SSH ───────────────────────────────────────────────────────────────────

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

  # ── Installed Tools ───────────────────────────────────────────────────────

  echo ""
  if [[ "$check_updates" == true ]]; then
    echo "--- Installed Tools (checking latest versions...) ---"
  else
    echo "--- Installed Tools ---"
  fi

  declare -A _update_hints=(
    [sam]="pip install --upgrade aws-sam-cli"
    [docker]="sudo apt-get install --only-upgrade docker-ce"
    [terraform]="brew upgrade terraform  # or: releases.hashicorp.com/terraform"
    [gh]="sudo apt update && sudo apt install gh"
    [jq]="sudo apt install jq  # or: github.com/jqlang/jq/releases (apt may lag)"
    [fzf]="github.com/junegunn/fzf/releases  # apt version lags — download binary"
    [tmux]="sudo apt install tmux  # or build from: github.com/tmux/tmux/releases"
    [aya]="uv tool upgrade aya"
    [claude]="npm install -g @anthropic-ai/claude-code"
  )

  local tmpdir=""
  if [[ "$check_updates" == true ]] && command -v gh &>/dev/null; then
    tmpdir=$(mktemp -d)
    gh api repos/aws/aws-sam-cli/releases/latest \
      --jq '.tag_name | ltrimstr("v")' >"$tmpdir/sam" 2>/dev/null &
    gh api repos/moby/moby/releases/latest \
      --jq '.tag_name | ltrimstr("docker-v")' >"$tmpdir/docker" 2>/dev/null &
    gh api repos/hashicorp/terraform/releases/latest \
      --jq '.tag_name | ltrimstr("v")' >"$tmpdir/terraform" 2>/dev/null &
    gh api repos/cli/cli/releases/latest \
      --jq '.tag_name | ltrimstr("v")' >"$tmpdir/gh" 2>/dev/null &
    gh api repos/jqlang/jq/releases/latest \
      --jq '.tag_name | ltrimstr("jq-")' >"$tmpdir/jq" 2>/dev/null &
    gh api repos/junegunn/fzf/releases/latest \
      --jq '.tag_name | ltrimstr("v")' >"$tmpdir/fzf" 2>/dev/null &
    gh api repos/tmux/tmux/releases/latest \
      --jq '.tag_name' >"$tmpdir/tmux" 2>/dev/null &
    gh api repos/shawnoster/aya/releases/latest \
      --jq '.tag_name | ltrimstr("v")' >"$tmpdir/aya" 2>/dev/null &
    npm view @anthropic-ai/claude-code version >"$tmpdir/claude" 2>/dev/null &
    wait
  fi

  _pf_tool() {
    local name="$1" installed="$2" raw="$3" key="${4:-}"
    local latest=""

    if [[ "$check_updates" == true ]] && [[ -n "$key" ]] && [[ -n "$tmpdir" ]]; then
      latest=$(cat "$tmpdir/$key" 2>/dev/null | tr -d '[:space:]')
    fi

    if [[ -n "$latest" ]] && [[ "$installed" != "$latest" ]]; then
      echo "⚠️  $name: $installed → $latest available"
      local hint="${_update_hints[$key]:-}"
      [[ -n "$hint" ]] && echo "    Update: $hint"
      ((updates_available++))
    else
      echo "✅ $name: $raw"
    fi
  }

  local tools=(
    "sam:AWS SAM CLI:sam"
    "docker:Docker:docker"
    "kubectl:Kubernetes kubectl:"
    "terraform:Terraform:terraform"
    "gh:GitHub CLI:gh"
    "op:1Password CLI:"
    "jq:jq:jq"
    "fzf:fzf:fzf"
    "tmux:tmux:tmux"
    "claude:Claude Code:claude"
  )

  for item in "${tools[@]}"; do
    local cmd="${item%%:*}"
    local rest="${item#*:}"
    local name="${rest%%:*}"
    local key="${rest##*:}"

    if command -v "$cmd" &>/dev/null; then
      local raw installed
      raw=$("$cmd" --version 2>&1 | head -1 || "$cmd" -v 2>&1 | head -1 || echo "installed")
      installed=$(echo "$raw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)*' | head -1)
      [[ -z "$installed" ]] && installed="$raw"
      _pf_tool "$name" "$installed" "$raw" "$key"
    else
      echo "❌ $name not installed"
    fi
  done

  # aya: version via JSON subcommand
  if command -v aya &>/dev/null; then
    local aya_ver
    aya_ver=$(aya version 2>&1 | jq -r .version 2>/dev/null || echo "installed")
    _pf_tool "Aya CLI" "$aya_ver" "$aya_ver" "aya"
  else
    echo "❌ Aya CLI not installed"
  fi

  unset -f _pf_tool
  [[ -n "$tmpdir" ]] && rm -rf "$tmpdir"

  # ── Git Configuration ─────────────────────────────────────────────────────

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

  # ── Node.js ───────────────────────────────────────────────────────────────

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

  # ── Python ────────────────────────────────────────────────────────────────

  echo ""
  echo "--- Python ---"

  if command -v python3 &>/dev/null; then
    echo "✅ Python3: $(python3 --version)"
  elif command -v python &>/dev/null; then
    echo "✅ Python: $(python --version)"
  else
    echo "❌ Python not installed"
  fi

  # ── Summary ───────────────────────────────────────────────────────────────

  echo ""
  echo "========================================"
  if [[ $issues -gt 0 ]]; then
    echo "⚠️  Found $issues issue(s) — see above"
  else
    echo "✅ All systems go"
  fi
  if [[ $updates_available -gt 0 ]]; then
    echo "📦 $updates_available tool update(s) available — see above"
  fi
  if [[ "$check_updates" == false ]]; then
    echo "   Tip: run 'preflight -u' to check for updates"
  fi
  echo "========================================"
}
