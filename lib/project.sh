#!/usr/bin/env bash
# ~/.preflight/lib/project.sh - Project navigation and build utilities
#
# Requires: fzf, jq

project-help() {
  cat <<'EOF'
Project Navigation and Build Utilities
=======================================

Available Commands:
-------------------

project-help
  Display this help message.

bake [target]
  Fuzzy-find and run Makefile targets. Pass target name to skip fzf.

yak [script]
  Fuzzy-find and run npm scripts from package.json. Pass script name to skip fzf.
  Searches current and parent directories for package.json.

poet [script]
  Fuzzy-find and run poetry scripts. Pass script name to skip fzf.
  Searches for pyproject.toml in current and parent directories.

proj [directory]
  Quick jump to project directories. Pass path to skip fzf.
  Configure via PROJ_DIRS environment variable (colon-separated paths).
  Default: $HOME/projects:$HOME/work:$HOME/src

serve [port]
  Start a quick local HTTP server on the given port (default: 8000).

Configuration:
--------------
PROJ_DIRS - Colon-separated list of directories to search for projects
  Default: $HOME/projects:$HOME/work:$HOME/src
  Set in config/accounts.sh

Requirements:
-------------
- fzf (for interactive selection)
- jq (for yak)
- python3 (for serve)
- make (for bake)
- npm (for yak)
- poetry (for poet)

EOF
}

# bake: fuzzy-find and run Makefile targets
bake() {
  if [[ ! -f Makefile ]]; then
    echo "⚠️  No Makefile found in current directory"
    return 1
  fi

  local target="${1:-}"

  if [[ -z "$target" ]]; then
    if [[ ! -t 0 ]]; then
      echo "Usage: bake <target>" >&2
      return 1
    fi
    target=$(awk -F: '
      /^[a-zA-Z0-9][^$#\/\t=]*:/ {
        if ($1 !~ /^[ \t]+/ && $1 !~ /^.PHONY$/) {
          split($1, tgts, " ")
          for (i in tgts) print tgts[i]
        }
      }
    ' Makefile | sort -u | fzf --prompt="Select make target > ")
  fi

  if [[ -n "$target" ]]; then
    history -s "make $target"
    make "$target"
  fi
}

# yak: fuzzy-find and run npm scripts from package.json
yak() {
  local pkg_json
  pkg_json=$(_find_up "package.json")

  if [[ -z "$pkg_json" ]]; then
    echo "⚠️  No package.json found in current or parent directories"
    return 1
  fi

  local script="${1:-}"

  if [[ -z "$script" ]]; then
    if [[ ! -t 0 ]]; then
      echo "Usage: yak <script>" >&2
      return 1
    fi
    script=$(jq -r '.scripts | keys[]' "$pkg_json" 2>/dev/null | sort -u | fzf --prompt="Select npm script > ")
  fi

  if [[ -n "$script" ]]; then
    history -s "npm run $script"
    (cd "$(dirname "$pkg_json")" && npm run "$script")
  fi
}

# poet: fuzzy-find and run poetry scripts
poet() {
  local pyproject
  pyproject=$(_find_up "pyproject.toml")

  if [[ -z "$pyproject" ]]; then
    echo "⚠️  No pyproject.toml found"
    return 1
  fi

  local script="${1:-}"

  if [[ -z "$script" ]]; then
    if [[ ! -t 0 ]]; then
      echo "Usage: poet <script>" >&2
      return 1
    fi
    script=$(sed -n '/^\[tool\.poetry\.scripts\]\|^\[project\.scripts\]/,/^\[/{/^\[/!p}' "$pyproject" \
      | grep -E '^[a-zA-Z0-9_-]+\s*=' \
      | cut -d'=' -f1 \
      | tr -d ' ' \
      | fzf --prompt="Select poetry script > ")
  fi

  if [[ -n "$script" ]]; then
    history -s "poetry run $script"
    (cd "$(dirname "$pyproject")" && poetry run "$script")
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
  local selected="${1:-}"

  if [[ -z "$selected" ]]; then
    if [[ ! -t 0 ]]; then
      echo "Usage: proj <directory>" >&2
      return 1
    fi
    local proj_dirs="${PROJ_DIRS:-$HOME/projects:$HOME/work:$HOME/src}"
    selected=$(echo "$proj_dirs" | tr ':' '\n' | while read -r dir; do
      [[ -d "$dir" ]] && find "$dir" -maxdepth 2 -type d -name ".git" 2>/dev/null | xargs -I{} dirname {}
    done | sort -u | fzf --prompt="Select project > ")
  fi

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
