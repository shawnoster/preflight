#!/usr/bin/env bash
# ~/.preflight/lib/preflight.sh - Session startup and environment health check
#
# Usage:
#   preflight            - sign in, load secrets, refresh AWS, run health checks
#   preflight -u         - same + compare installed tools against latest stable versions
#   preflight update     - pull latest changes from the upstream repo
#   preflight uninstall  - remove preflight and undo shell profile changes
#   preflight configure        - interactively apply recommended settings (git globals, etc.)
#   preflight configure --yes  - apply all without prompting

preflight() {
  # Dispatch subcommands before doing anything else
  case "${1:-}" in
    update)         _preflight_update;        return ;;
    uninstall)      _preflight_uninstall;     return ;;
    configure)      _preflight_configure "${@:2}";     return ;;
  esac

  local check_updates=false
  for arg in "$@"; do
    case "$arg" in -u|--updates) check_updates=true ;; esac
  done

  # Optionally erase the previous terminal line (opt-in for Starship users).
  [[ -t 1 && "${PREFLIGHT_ERASE_PREVIOUS_LINE:-}" == "1" ]] && printf '\033[1A\033[2K\r'

  # ── Header ────────────────────────────────────────────────────────────────
  # Colors: inherit from owl-theme if available, otherwise tasteful defaults
  local R='\033[0m'
  local B E T S
  if [[ -n "${OWL_BODY:-}" ]]; then
    B="\033[38;2;${OWL_BODY}m"
    E="\033[38;2;${OWL_EYES}m"
    T="\033[38;2;${OWL_TEXT}m"
    S="\033[38;2;${OWL_SUB}m"
  else
    B="\033[38;2;100;140;200m"   # slate blue body
    E="\033[38;2;240;240;255m"   # near-white eyes
    T="\033[38;2;200;210;230m"   # light text
    S="\033[38;2;120;130;150m"   # muted subtext
  fi

  printf "\n"
  printf "  ${B}    __${R}\n"
  printf "  ${B}   ( ${E}o${B}>${R}\n"
  printf "  ${B}   ///\\${R}\n"
  printf "  ${B}   \\V_/_${R}   ${T}Preflight Check${R}\n"
  printf "  ${S}  ─────────────────────────────────${R}\n"
  printf "\n"

  local issues=0
  local updates_available=0

  # ── Secrets ───────────────────────────────────────────────────────────────

  echo "--- Secrets ---"
  echo ""

  if command -v op &>/dev/null; then
    if ! op-load-env; then
      echo "⚠️  1Password sign-in or secret loading failed"
      ((issues++))
    fi
  else
    echo "⚠️  1Password CLI not installed — skipping secret loading"
    ((issues++))
  fi

  # ── AWS Session ───────────────────────────────────────────────────────────

  echo ""
  echo "--- AWS Session ---"

  if command -v aws &>/dev/null; then
    local aws_identity
    aws_identity=$(aws sts get-caller-identity 2>/dev/null)
    if [[ -n "$aws_identity" ]]; then
      echo "✅ AWS session active ($(echo "$aws_identity" | jq -r '.Account' 2>/dev/null))"
    else
      echo "☁️  Refreshing AWS SSO..."
      if aws-login; then
        aws_identity=$(aws sts get-caller-identity 2>/dev/null)
        if [[ -n "$aws_identity" ]]; then
          echo "✅ AWS session active ($(echo "$aws_identity" | jq -r '.Account' 2>/dev/null))"
        else
          echo "❌ AWS SSO refresh did not produce an active session"
          ((issues++))
        fi
      else
        echo "❌ AWS SSO refresh failed"
        ((issues++))
      fi
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

  # Detect platform for context-appropriate update hints
  local _os
  if [[ "$(uname -s)" == "Darwin" ]]; then
    _os="mac"
  elif grep -qi microsoft /proc/version 2>/dev/null; then
    _os="wsl"
  else
    _os="linux"
  fi

  declare -A _update_hints
  case "$_os" in
    mac)
      _update_hints=(
        [sam]="brew upgrade aws-sam-cli"
        [docker]="brew upgrade --cask docker"
        [terraform]="brew upgrade hashicorp/tap/terraform"
        [gh]="brew upgrade gh"
        [jq]="brew upgrade jq"
        [fzf]="brew upgrade fzf"
        [tmux]="brew upgrade tmux"
        [claude]="claude update"
        [uv]="uv self update"
      )
      ;;
    wsl|linux)
      _update_hints=(
        [sam]="sudo ./sam-installation/install --update  # re-run native installer with --update"
        [docker]="sudo apt update && sudo apt install docker-ce docker-ce-cli containerd.io"
        [terraform]="sudo apt update && sudo apt install terraform  # requires HashiCorp apt repo"
        [gh]="sudo apt update && sudo apt install gh  # requires GitHub apt repo"
        [jq]="sudo apt update && sudo apt install jq"
        [fzf]="github.com/junegunn/fzf/releases  # apt lags — download binary"
        [tmux]="github.com/tmux/tmux-builds  # apt lags — use static prebuilt binary"
        [claude]="claude update"
        [uv]="uv self update"
      )
      ;;
  esac

  local tmpdir=""
  if [[ "$check_updates" == true ]] && command -v gh &>/dev/null; then
    tmpdir=$(mktemp -d)
    (
      set +m  # suppress job control start/done notifications
      gh api repos/aws/aws-sam-cli/releases/latest \
        --jq '.tag_name | ltrimstr("v")' >"$tmpdir/sam" 2>/dev/null &
      gh api repos/moby/moby/releases/latest \
        --jq '.tag_name | ltrimstr("v")' >"$tmpdir/docker" 2>/dev/null &
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
      npm view @anthropic-ai/claude-code version >"$tmpdir/claude" 2>/dev/null &
      gh api repos/astral-sh/uv/releases/latest \
        --jq '.tag_name | ltrimstr("v")' >"$tmpdir/uv" 2>/dev/null &
      wait
    )
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
    "uv:uv:uv"
  )

  for item in "${tools[@]}"; do
    local cmd="${item%%:*}"
    local rest="${item#*:}"
    local name="${rest%%:*}"
    local key="${rest##*:}"

    if command -v "$cmd" &>/dev/null; then
      local raw installed version_output
      if version_output=$("$cmd" --version 2>&1); then
        raw=$(printf '%s\n' "$version_output" | head -1)
      elif version_output=$("$cmd" -V 2>&1); then
        raw=$(printf '%s\n' "$version_output" | head -1)
      else
        raw="installed"
      fi
      installed=$(echo "$raw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)*[a-zA-Z0-9]*' | head -1)
      [[ -z "$installed" ]] && installed="$raw"
      _pf_tool "$name" "$installed" "$raw" "$key"
    else
      echo "❌ $name not installed"
    fi
  done

  unset -f _pf_tool
  unset _update_hints
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
      ((issues++))
    fi

    if [[ -n "$(git config --global user.name)" ]]; then
      echo "✅ Git user.name: $(git config --global user.name)"
    else
      echo "⚠️  Git user.name not set"
      ((issues++))
    fi

    # ── fetch hygiene ──────────────────────────────────────────────────────
    if [[ "$(git config --global fetch.prune)" == "true" ]]; then
      echo "✅ fetch.prune = true"
    else
      echo "⚠️  fetch.prune not set — stale remote branches accumulate"
      echo "   Fix: git config --global fetch.prune true"
      ((issues++))
    fi

    # ── push safety ────────────────────────────────────────────────────────
    local push_default
    push_default=$(git config --global push.default 2>/dev/null)
    if [[ "$push_default" == "matching" ]]; then
      echo "⚠️  push.default = matching — can push unintended branches"
      echo "   Fix: git config --global push.default simple"
      ((issues++))
    fi

    if [[ "$(git config --global push.autoSetupRemote)" == "true" ]]; then
      echo "✅ push.autoSetupRemote = true"
    else
      echo "⚠️  push.autoSetupRemote not set — new branches require manual upstream"
      echo "   Fix: git config --global push.autoSetupRemote true"
      ((issues++))
    fi

    # ── pull / rebase strategy ─────────────────────────────────────────────
    local pull_rebase
    pull_rebase=$(git config --global pull.rebase 2>/dev/null)
    if [[ "$pull_rebase" == "true" || "$pull_rebase" == "merges" || "$pull_rebase" == "interactive" ]]; then
      echo "✅ pull.rebase = $pull_rebase"
    else
      echo "⚠️  pull.rebase not set — diverged pulls create accidental merge commits"
      echo "   Fix: git config --global pull.rebase true"
      ((issues++))
    fi

    if [[ "$(git config --global rebase.autoStash)" == "true" ]]; then
      echo "✅ rebase.autoStash = true"
    else
      echo "⚠️  rebase.autoStash not set — rebase aborts on dirty working tree"
      echo "   Fix: git config --global rebase.autoStash true"
      ((issues++))
    fi

    # ── diff quality ───────────────────────────────────────────────────────
    local diff_algo
    diff_algo=$(git config --global diff.algorithm 2>/dev/null)
    if [[ "$diff_algo" == "histogram" ]]; then
      echo "✅ diff.algorithm = histogram"
    else
      echo "💡 diff.algorithm not set to histogram — diffs on reordered code can be misleading"
      echo "   Fix: git config --global diff.algorithm histogram"
    fi

    # ── merge conflict style ───────────────────────────────────────────────
    local conflict_style
    conflict_style=$(git config --global merge.conflictstyle 2>/dev/null)
    if [[ "$conflict_style" == "diff3" || "$conflict_style" == "zdiff3" ]]; then
      echo "✅ merge.conflictstyle = $conflict_style"
    else
      echo "💡 merge.conflictstyle not set — conflict markers hide the common ancestor"
      echo "   Fix: git config --global merge.conflictstyle zdiff3"
    fi

    # ── global gitignore ───────────────────────────────────────────────────
    local excludes_file
    excludes_file=$(git config --global core.excludesFile 2>/dev/null)
    if [[ -n "$excludes_file" && -f "$excludes_file" ]]; then
      echo "✅ core.excludesFile = $excludes_file"
    else
      echo "💡 core.excludesFile not set — OS/editor artifacts need per-repo .gitignore entries"
      echo "   Fix: git config --global core.excludesFile ~/.gitignore"
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

  if command -v uv &>/dev/null; then
    echo "✅ uv: $(uv --version)"
  else
    echo "❌ uv not installed"
    ((issues++))
  fi

  # ── Summary ───────────────────────────────────────────────────────────────

  echo ""
  printf "  ${S}─────────────────────────────────${R}\n"
  if [[ $issues -gt 0 ]]; then
    printf "  ⚠️  ${T}Found $issues issue(s) — see above${R}\n"
  else
    printf "  ✅ ${T}All systems go${R}\n"
  fi
  if [[ $updates_available -gt 0 ]]; then
    printf "  📦 ${T}$updates_available tool update(s) available — see above${R}\n"
  fi
  if [[ "$check_updates" == false ]]; then
    printf "  ${S}Tip: run 'preflight -u' to check for updates${R}\n"
  fi
  printf "  ${S}─────────────────────────────────${R}\n"
  printf "\n"
}

# ── preflight update ──────────────────────────────────────────────────────────

_preflight_update() {
  local dir="${PREFLIGHT_DIR:-$HOME/.preflight}"

  printf "  \\033[38;2;${OWL_SUB:-120;130;150}m─────────────────────────────────\\033[0m\\n"
  printf "  \\033[1mPreflight Update\\033[0m\\n"
  printf "  \\033[38;2;${OWL_SUB:-120;130;150}m─────────────────────────────────\\033[0m\\n"
  echo ""

  if [[ ! -d "$dir/.git" ]]; then
    echo "❌ $dir is not a git repository"
    echo "   If you installed manually (not via install.sh), updates must be done manually."
    return 1
  fi

  # Warn about uncommitted changes to tracked files — gitignored files are safe
  local dirty
  dirty=$(git -C "$dir" status --porcelain 2>/dev/null | grep -v '^??' || true)
  if [[ -n "$dirty" ]]; then
    echo "⚠️  Uncommitted changes to tracked files detected:"
    echo "$dirty" | sed 's/^/   /'
    echo ""
    echo "   These files may conflict with upstream changes."
    echo "   Consider moving customizations to lib/local.sh (which is gitignored)."
    echo ""
    read -r -p "   Continue with update anyway? [y/N] " reply
    echo ""
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "Update cancelled."; return 0; }
  fi

  # Resolve branch once — used consistently for rev-parse, pull, and error messages
  local branch
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  # If detached HEAD or on a feature branch, switch to the configured target branch
  local target_branch="${PREFLIGHT_BRANCH:-main}"
  if [[ "$branch" != "$target_branch" ]]; then
    echo "ℹ️  Switching from '$branch' to '$target_branch' for update..."
    git -C "$dir" checkout "$target_branch" 2>&1 | sed 's/^/  /' || {
      echo "❌ Could not switch to '$target_branch'. Aborting."
      return 1
    }
    branch="$target_branch"
  fi

  # Fetch and check if there's anything new
  echo "Fetching from origin..."
  git -C "$dir" fetch origin 2>&1 | sed 's/^/  /'

  local current_sha upstream_sha
  current_sha=$(git -C "$dir" rev-parse HEAD)
  upstream_sha=$(git -C "$dir" rev-parse "origin/$branch")

  if [[ "$current_sha" == "$upstream_sha" ]]; then
    echo ""
    echo "✅ Already up to date."
    printf "  \\033[38;2;${OWL_SUB:-120;130;150}m─────────────────────────────────\\033[0m\\n"
    return 0
  fi

  # Show what's incoming
  echo ""
  echo "New commits:"
  git -C "$dir" log --oneline "${current_sha}..${upstream_sha}" | sed 's/^/  /'
  echo ""

  # Pull — capture output separately so git's exit code isn't masked by sed
  local pull_output
  if pull_output=$(git -C "$dir" pull --ff-only origin "$branch" 2>&1); then
    echo "$pull_output" | sed 's/^/  /'
    echo ""
    echo "✅ Updated successfully."
    echo ""
    echo "   Reload your shell to pick up changes:"
    echo "     source ~/.bashrc   (or open a new terminal)"
  else
    echo "$pull_output" | sed 's/^/  /'
    echo ""
    echo "❌ Pull failed (non-fast-forward). Your local branch has diverged."
    echo "   To reset to upstream:  git -C $dir reset --hard origin/$branch"
    echo "   To inspect:            git -C $dir log --oneline HEAD...origin/$branch"
    return 1
  fi

  printf "  \\033[38;2;${OWL_SUB:-120;130;150}m─────────────────────────────────\\033[0m\\n"
}

# ── preflight uninstall ───────────────────────────────────────────────────────

_preflight_uninstall() {
  local dir="${PREFLIGHT_DIR:-$HOME/.preflight}"

  printf "  \\033[38;2;${OWL_SUB:-120;130;150}m─────────────────────────────────\\033[0m\\n"
  printf "  \\033[1mPreflight Uninstall\\033[0m\\n"
  printf "  \\033[38;2;${OWL_SUB:-120;130;150}m─────────────────────────────────\\033[0m\\n"
  echo ""
  echo "This will:"
  echo "  • Remove $dir"
  echo "  • Remove the preflight source line from your shell profile"
  echo ""
  read -r -p "Are you sure? [y/N] " reply
  echo ""
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "Uninstall cancelled."; return 0; }

  # Remove source line from whichever profile files contain it
  local profiles=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc"
                  "$HOME/.zshenv" "$HOME/.profile"
                  "${ZDOTDIR:-$HOME}/.zshrc")
  local cleaned=()

  for profile in "${profiles[@]}"; do
    [[ -f "$profile" ]] || continue
    if grep -qF 'preflight/init.sh' "$profile"; then
      local tmp
      tmp=$(mktemp)
      # Remove the comment line and source line; clean up any resulting blank lines
      grep -vF 'preflight/init.sh' "$profile" \
        | grep -v '# Preflight — developer environment' \
        > "$tmp" && mv "$tmp" "$profile" || rm -f "$tmp"
      cleaned+=("$profile")
      echo "✅ Removed source line from $profile"
    fi
  done

  if [[ ${#cleaned[@]} -eq 0 ]]; then
    echo "ℹ️  No shell profile contained a preflight source line."
  fi

  # Remove the directory
  if [[ -d "$dir" ]]; then
    rm -rf "$dir"
    echo "✅ Removed $dir"
  else
    echo "ℹ️  $dir not found — nothing to remove."
  fi

  echo ""
  echo "✅ Preflight uninstalled."
  echo "   Open a new terminal or run 'hash -r' to clear the command cache."
  printf "  \\033[38;2;${OWL_SUB:-120;130;150}m─────────────────────────────────\\033[0m\\n"

  # Self-destruct: unset all preflight functions from the current shell
  unset -f preflight _preflight_update _preflight_uninstall
}

# ── preflight configure ───────────────────────────────────────────────────────

_preflight_configure() {
  local auto=false
  [[ "${1:-}" == "--yes" ]] && auto=true

  if ! command -v git &>/dev/null; then
    echo "❌ git not found"
    return 1
  fi

  printf "  \\033[38;2;${OWL_SUB:-120;130;150}m─────────────────────────────────\\033[0m\\n"
  printf "  \\033[1mPreflight: Configure\\033[0m\\n"
  printf "  \\033[38;2;${OWL_SUB:-120;130;150}m─────────────────────────────────\\033[0m\\n"
  echo ""

  local applied=0 skipped=0 kept=0

  # Helper: prompt and set a git global
  # Usage: _pf_git_set KEY VALUE "why it matters" [emoji]
  _pf_git_set() {
    local key="$1" value="$2" reason="$3" icon="${4:-⚠️ }"
    local current
    current=$(git config --global "$key" 2>/dev/null || true)

    if [[ "$current" == "$value" ]]; then
      echo "✅ $key = $value (already set)"
      ((kept++))
      return
    fi

    if [[ -n "$current" ]]; then
      echo "$icon $key = $current"
      echo "   Recommended: $value"
      echo "   Reason: $reason"
    else
      echo "$icon $key not set"
      echo "   Recommended: $value"
      echo "   Reason: $reason"
    fi

    if [[ "$auto" == true ]]; then
      git config --global "$key" "$value"
      echo "   → Set to $value"
      ((applied++))
    else
      read -r -p "   Apply? [Y/n] " reply
      echo ""
      if [[ -z "$reply" || "$reply" =~ ^[Yy]$ ]]; then
        git config --global "$key" "$value"
        echo "   ✅ Set $key = $value"
        ((applied++))
      else
        echo "   Skipped."
        ((skipped++))
      fi
    fi
    echo ""
  }

  echo "--- Fetch / Remote Hygiene ---"
  echo ""
  _pf_git_set "fetch.prune"      "true"  "stale remote-tracking refs accumulate without this" "⚠️ "
  _pf_git_set "fetch.pruneTags"  "true"  "tags deleted on the remote silently persist locally" "💡"

  echo "--- Push Safety ---"
  echo ""
  _pf_git_set "push.autoSetupRemote" "true"   "new branches require manual --set-upstream without this" "⚠️ "
  _pf_git_set "push.followTags"      "true"   "annotated tags pointing to pushed commits are pushed automatically" "💡"

  echo "--- Pull / Rebase Strategy ---"
  echo ""
  _pf_git_set "pull.rebase"        "true"  "diverged pulls create accidental merge commits without this" "⚠️ "
  _pf_git_set "rebase.autoStash"   "true"  "rebase aborts on a dirty working tree without this" "⚠️ "
  _pf_git_set "rebase.autoSquash"  "true"  "fixup commits require --autosquash manually without this" "💡"

  echo "--- Diff / Log Quality ---"
  echo ""
  _pf_git_set "diff.algorithm"    "histogram" "myers (default) produces misleading diffs on reordered code" "💡"
  _pf_git_set "diff.colorMoved"   "default"   "visually distinguishes moved code from added/deleted lines" "💡"
  _pf_git_set "branch.sort"       "-committerdate" "sorts branches by recency instead of alphabetically" "💡"

  echo "--- Merge / Conflict Style ---"
  echo ""
  _pf_git_set "merge.conflictstyle" "zdiff3" "standard conflict markers hide the common ancestor" "💡"

  echo "--- Global Gitignore ---"
  echo ""
  local current_excludes
  current_excludes=$(git config --global core.excludesFile 2>/dev/null || true)
  if [[ -n "$current_excludes" && -f "$current_excludes" ]]; then
    echo "✅ core.excludesFile = $current_excludes (already set)"
    ((kept++))
    echo ""
  else
    local default_ignore="$HOME/.gitignore"
    echo "💡 core.excludesFile not set"
    echo "   Recommended: $default_ignore"
    echo "   Reason: OS/editor artifacts need per-repo .gitignore entries without this"

    if [[ "$auto" == true ]]; then
      git config --global core.excludesFile "$default_ignore"
      echo "   → Set to $default_ignore"
      ((applied++))
    else
      read -r -p "   Apply? [Y/n] " reply
      echo ""
      if [[ -z "$reply" || "$reply" =~ ^[Yy]$ ]]; then
        git config --global core.excludesFile "$default_ignore"
        echo "   ✅ Set core.excludesFile = $default_ignore"
        ((applied++))
        # Create the file if it doesn't exist yet
        if [[ ! -f "$default_ignore" ]]; then
          cat > "$default_ignore" <<'GITIGNORE'
# macOS
.DS_Store
.AppleDouble
.LSOverride

# Editor / IDE
.idea/
.vscode/
*.swp
*.swo
*~

# Python
__pycache__/
*.pyc
*.pyo
.venv/
.env

# Node
node_modules/
GITIGNORE
          echo "   ✅ Created $default_ignore with common entries"
        fi
      else
        echo "   Skipped."
        ((skipped++))
      fi
    fi
    echo ""
  fi

  # ── Summary ──────────────────────────────────────────────────────────────
  unset -f _pf_git_set

  printf "  \\033[38;2;${OWL_SUB:-120;130;150}m─────────────────────────────────\\033[0m\\n"
  echo "   Applied: $applied   Kept: $kept   Skipped: $skipped"
  if [[ $applied -gt 0 ]]; then
    echo ""
    echo "   Changes are global and take effect immediately."
    echo "   Review: git config --global --list"
  fi
  printf "  \\033[38;2;${OWL_SUB:-120;130;150}m─────────────────────────────────\\033[0m\\n"
}
