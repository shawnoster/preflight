#!/usr/bin/env bash
# ~/.dev/lib/project.sh - Project navigation and build utilities
#
# Requires: fzf, jq

# Display help for all Project commands
project-help() {
  cat <<'EOF'
Project Navigation and Build Utilities
=======================================

Available Commands:
-------------------

project-help
  Display this help message showing all available project commands.

bake
  Fuzzy-find and run Makefile targets.
  Parses Makefile in current directory and presents targets interactively.
  Adds selected command to shell history.

yak
  Fuzzy-find and run npm scripts from package.json.
  Searches current and parent directories for package.json.
  Runs scripts in the directory containing package.json.

poet
  Fuzzy-find and run poetry scripts.
  Searches for pyproject.toml in current and parent directories.
  Extracts scripts from [tool.poetry.scripts] or [project.scripts].

proj
  Quick jump to project directories.
  Searches for git repositories in configured project directories.
  Configure via PROJ_DIRS environment variable (colon-separated paths).
  Default: $HOME/projects:$HOME/work:$HOME/src

serve [port]
  Start a quick local HTTP server.
  Arguments:
    port - Optional. Port number (default: 8000)
  Example: serve 3000
  Serves current directory on http://localhost:<port>

Configuration:
--------------
PROJ_DIRS - Colon-separated list of directories to search for projects
  Default: $HOME/projects:$HOME/work:$HOME/src
  Set in config/accounts.sh

Requirements:
-------------
- fzf (for interactive selection)
- jq (for yak - npm script parsing)
- python3 (for serve command)
- make (for bake command)
- npm (for yak command)
- poetry (for poet command)

EOF
}

# bake: fuzzy-find and run Makefile targets
bake() {
  if [[ ! -f Makefile ]]; then
    echo "⚠️ No Makefile found in current directory"
    return 1
  fi

  local selected_target
  selected_target=$(awk -F: '
    /^[a-zA-Z0-9][^$#\/\t=]*:/ {
      if ($1 !~ /^[ \t]+/ && $1 !~ /^.PHONY$/) {
        split($1, tgts, " ")
        for (i in tgts) print tgts[i]
      }
    }
  ' Makefile | sort -u | fzf --prompt="Select make target > ")

  if [[ -n "$selected_target" ]]; then
    history -s "make $selected_target"
    make "$selected_target"
  fi
}

# yak: fuzzy-find and run npm scripts from package.json
yak() {
  # Find nearest package.json (current or parent dirs)
  local pkg_json
  pkg_json=$(_find_up "package.json")

  if [[ -z "$pkg_json" ]]; then
    echo "⚠️ No package.json found in current or parent directories"
    return 1
  fi

  local selected_script
  selected_script=$(jq -r '.scripts | keys[]' "$pkg_json" 2>/dev/null | sort -u | fzf --prompt="Select npm script > ")
  
  if [[ -n "$selected_script" ]]; then
    history -s "npm run $selected_script"
    (cd "$(dirname "$pkg_json")" && npm run "$selected_script")
  fi
}

# poetry-run: fuzzy-find and run poetry scripts
poet() {
  local pyproject
  pyproject=$(_find_up "pyproject.toml")

  if [[ -z "$pyproject" ]]; then
    echo "⚠️ No pyproject.toml found"
    return 1
  fi

  # Extract script names from [tool.poetry.scripts] or [project.scripts]
  local selected_script
  selected_script=$(grep -A 100 '^\[tool.poetry.scripts\]\|^\[project.scripts\]' "$pyproject" \
    | grep -E '^[a-zA-Z0-9_-]+\s*=' \
    | cut -d'=' -f1 \
    | tr -d ' ' \
    | fzf --prompt="Select poetry script > ")

  if [[ -n "$selected_script" ]]; then
    history -s "poetry run $selected_script"
    (cd "$(dirname "$pyproject")" && poetry run "$selected_script")
  fi
}

# Helper: find file in current or parent directories
_find_up() {
  local target="$1"
  local dir="$PWD"
  
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/$target" ]]; then
      echo "$dir/$target"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

# proj: quick jump to project directories
proj() {
  local proj_dirs="${PROJ_DIRS:-$HOME/projects:$HOME/work:$HOME/src}"
  local selected
  
  selected=$(echo "$proj_dirs" | tr ':' '\n' | while read -r dir; do
    [[ -d "$dir" ]] && find "$dir" -maxdepth 2 -type d -name ".git" 2>/dev/null | xargs -I{} dirname {}
  done | sort -u | fzf --prompt="Select project > ")

  if [[ -n "$selected" ]]; then
    cd "$selected" || return 1
    echo "📂 $(pwd)"
  fi
}

# serve: quick local HTTP server
serve() {
  local port="${1:-8000}"
  echo "🌐 Serving on http://localhost:$port"
  python3 -m http.server "$port"
}
