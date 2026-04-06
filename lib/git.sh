#!/usr/bin/env bash
# ~/.dev/lib/git.sh - Git utilities and shortcuts
#
# Requires: git, fzf

git-help() {
  cat <<'EOF'
Git Utilities and Shortcuts
============================

Available Commands:
-------------------

git-help
  Display this help message.

gco [branch]
  Fuzzy select and checkout a branch. Pass branch name directly to skip fzf.

glog
  Pretty git log. Interactive with fzf preview in a terminal, plain log otherwise.

gstash [stash-ref]
  Fuzzy select and apply a stash. Pass a stash ref (e.g. stash@{0}) to skip fzf.

gpr
  Create a pull request using GitHub CLI (opens browser).

gwip [message]
  Quick work-in-progress commit. Skips pre-commit hooks.
  Example: gwip "adding feature X" → "WIP: adding feature X"

gunwip
  Undo last WIP commit, keeping changes staged.

gclean [main_branch]
  Remove merged branches locally. Switches to main, pulls, deletes merged.

gsync [main_branch]
  Sync fork with upstream: fetch, merge, push.

Common Aliases:
---------------
gs   - git status
ga   - git add
gc   - git commit
gp   - git push
gpl  - git pull
gd   - git diff
gds  - git diff --staged

Requirements:
-------------
- git
- fzf (for interactive selection)
- gh (GitHub CLI, optional, for gpr)

EOF
}

# gco: fuzzy checkout branch
gco() {
  local branch="${1:-}"

  if [[ -z "$branch" ]]; then
    if [[ ! -t 0 ]]; then
      echo "Usage: gco <branch>" >&2
      return 1
    fi
    branch=$(git branch --all | grep -v HEAD | sed 's/^..//' | sed 's/remotes\/origin\///' | sort -u | fzf --prompt="Checkout branch > ")
  fi

  [[ -n "$branch" ]] && git checkout "$branch"
}

# glog: pretty git log with fzf preview
glog() {
  if [[ ! -t 0 ]]; then
    git log --oneline
    return
  fi
  git log --oneline --color=always | fzf --ansi --preview 'git show --color=always {1}' --preview-window=right:60%
}

# gstash: fuzzy select and apply stash
gstash() {
  local stash="${1:-}"

  if [[ -z "$stash" ]]; then
    if [[ ! -t 0 ]]; then
      echo "Usage: gstash <stash-ref>" >&2
      return 1
    fi
    stash=$(git stash list | fzf --prompt="Select stash > " | cut -d: -f1)
  fi

  [[ -n "$stash" ]] && git stash apply "$stash"
}

# gpr: create PR (GitHub CLI)
gpr() {
  if ! command -v gh &>/dev/null; then
    echo "⚠️  GitHub CLI (gh) not installed"
    return 1
  fi
  gh pr create --web
}

# gwip: quick work-in-progress commit
gwip() {
  git add -A
  git commit -m "WIP: ${1:-work in progress}" --no-verify
}

# gunwip: undo last WIP commit (keeps changes staged)
gunwip() {
  if git log -1 --pretty=%B | grep -q "^WIP:"; then
    git reset --soft HEAD~1
    echo "✅ Undid WIP commit"
  else
    echo "⚠️  Last commit is not a WIP commit"
  fi
}

# gclean: remove merged branches
gclean() {
  local main_branch="${1:-main}"
  git checkout "$main_branch" 2>/dev/null || git checkout master
  git pull
  git branch --merged | grep -v "^\*\|main\|master\|develop" | xargs -r git branch -d
  echo "✅ Cleaned merged branches"
}

# gsync: sync fork with upstream
gsync() {
  local main_branch="${1:-main}"
  git fetch upstream
  git checkout "$main_branch"
  git merge upstream/"$main_branch"
  git push origin "$main_branch"
}

# Common aliases
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gpl='git pull'
alias gd='git diff'
alias gds='git diff --staged'
