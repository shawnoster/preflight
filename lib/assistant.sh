#!/usr/bin/env bash
# ~/.dev/lib/assistant.sh - Assistant launcher shortcuts

# ace: jump to guild control-plane root and launch Claude
ace() {
  local target="$HOME/guild"

  if [[ ! -d "$target" ]]; then
    echo "❌ Target directory not found: $target"
    return 1
  fi

  cd "$target" || return 1
  echo "📂 $(pwd)"

  if command -v claude >/dev/null 2>&1; then
    echo "🚀 Launching: claude"
    claude
    return $?
  fi

  echo "❌ 'claude' is not installed or not on PATH."
  return 127
}
