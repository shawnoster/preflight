#!/usr/bin/env bash
# ~/.dev/init.sh - Developer environment initialization
# 
# Usage:
#   Source from .bashrc:  . "$HOME/.dev/init.sh"
#   Or run standalone:    source ~/.dev/init.sh

DEV_DIR="${DEV_DIR:-$HOME/.dev}"

# Source all library scripts
for lib in "$DEV_DIR/lib"/*.sh; do
  [[ -f "$lib" ]] && source "$lib"
done

# Source config (non-secret environment setup)
[[ -f "$DEV_DIR/config/accounts.sh" ]] && source "$DEV_DIR/config/accounts.sh"

# Optional: Print loaded status
if [[ "${DEV_VERBOSE:-0}" == "1" ]]; then
  echo "✅ Developer environment loaded from $DEV_DIR"
fi
