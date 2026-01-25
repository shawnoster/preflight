#!/usr/bin/env bash
# ~/.dev/lib/git.sh - Git utilities and shortcuts
#
# Requires: git, fzf

# Display help for all Git commands
git-help() {
  cat <<'EOF'
Git Utilities and Shortcuts
============================

Available Commands:
-------------------

git-help
  Display this help message showing all available Git commands.

gco
  Fuzzy select and checkout a branch.
  Shows both local and remote branches.

glog
  Pretty git log with fzf preview.
  Navigate commits and preview changes interactively.

gstash
  Fuzzy select and apply a stash.
  Interactive stash selection and application.

gpr
  Create a pull request using GitHub CLI.
  Opens browser to create PR (requires gh CLI).

gwip [message]
  Quick work-in-progress commit.
  Arguments:
    message - Optional. Commit message suffix (default: "work in progress")
  Example: gwip "adding feature X"
  Creates commit: "WIP: adding feature X"

gunwip
  Undo last WIP commit, keeping changes staged.
  Only works if the last commit message starts with "WIP:".

gclean [main_branch]
  Remove merged branches locally.
  Arguments:
    main_branch - Optional. Main branch name (default: main)
  Switches to main, pulls, and deletes merged branches.

gsync [main_branch]
  Sync fork with upstream repository.
  Arguments:
    main_branch - Optional. Main branch name (default: main)
  Fetches from upstream, merges, and pushes to origin.

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
- gh (GitHub CLI, optional, for gpr command)

EOF
}

# gco: fuzzy checkout branch
gco() {
  local branch
  branch=$(git branch --all | grep -v HEAD | sed 's/^..//' | sed 's/remotes\/origin\///' | sort -u | fzf --prompt="Checkout branch > ")
  if [[ -n "$branch" ]]; then
    git checkout "$branch"
  fi
}

# glog: pretty git log with fzf preview
glog() {
  git log --oneline --color=always | fzf --ansi --preview 'git show --color=always {1}' --preview-window=right:60%
}

# gstash: fuzzy select and apply stash
gstash() {
  local stash
  stash=$(git stash list | fzf --prompt="Select stash > " | cut -d: -f1)
  if [[ -n "$stash" ]]; then
    git stash apply "$stash"
  fi
}

# gpr: create PR (GitHub CLI)
gpr() {
  if ! command -v gh &>/dev/null; then
    echo "⚠️ GitHub CLI (gh) not installed"
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
    echo "⚠️ Last commit is not a WIP commit"
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
