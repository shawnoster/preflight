#!/usr/bin/env bash
# ~/.dev/init.sh - Developer environment initialization
#
# Usage:
#   Source from .bashrc:  . "$HOME/.dev/init.sh"
#   Or run standalone:    source ~/.dev/init.sh

DEV_DIR="${DEV_DIR:-$HOME/.dev}"

# First-time setup: Copy templates if config files don't exist
if [[ ! -f "$DEV_DIR/config/accounts.sh" ]] && [[ -f "$DEV_DIR/config/accounts.sh.template" ]]; then
  echo "📋 Creating config/accounts.sh from template..."
  cp "$DEV_DIR/config/accounts.sh.template" "$DEV_DIR/config/accounts.sh"
  echo "✅ Created. Edit config/accounts.sh to customize your settings."
fi

if [[ ! -f "$DEV_DIR/lib/1password.sh" ]] && [[ -f "$DEV_DIR/lib/1password.sh.template" ]]; then
  echo "📋 Creating lib/1password.sh from template..."
  cp "$DEV_DIR/lib/1password.sh.template" "$DEV_DIR/lib/1password.sh"
  echo "✅ Created. Edit lib/1password.sh to customize your 1Password secrets."
fi

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
