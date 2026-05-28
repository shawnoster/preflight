#!/usr/bin/env bash
# ~/.preflight/init.sh - Developer environment initialization
#
# Usage:
#   Source from .bashrc:  . "$HOME/.preflight/init.sh"
#   Or run standalone:    source ~/.preflight/init.sh

PREFLIGHT_DIR="${PREFLIGHT_DIR:-$HOME/.preflight}"

# Add bin/ to PATH so distributed scripts (light-remind, nanoleaf-*) are
# findable. Idempotent — safe to source multiple times.
case ":$PATH:" in
  *":$PREFLIGHT_DIR/bin:"*) ;;
  *) PATH="$PREFLIGHT_DIR/bin:$PATH" ;;
esac

# ── First-time setup: copy templates if config files don't exist ──────────────

if [[ ! -f "$PREFLIGHT_DIR/config/accounts.sh" ]] && [[ -f "$PREFLIGHT_DIR/config/accounts.sh.template" ]]; then
  echo "📋 Creating config/accounts.sh from template..."
  cp "$PREFLIGHT_DIR/config/accounts.sh.template" "$PREFLIGHT_DIR/config/accounts.sh"
  echo "✅ Created. Edit config/accounts.sh to customize your settings."
fi

if [[ ! -f "$PREFLIGHT_DIR/lib/1password.sh" ]] && [[ -f "$PREFLIGHT_DIR/lib/1password.sh.template" ]]; then
  echo "📋 Creating lib/1password.sh from template..."
  cp "$PREFLIGHT_DIR/lib/1password.sh.template" "$PREFLIGHT_DIR/lib/1password.sh"
  echo "✅ Created. Edit lib/1password.sh to customize your 1Password secrets."
fi

if [[ ! -f "$PREFLIGHT_DIR/config/owl.sh" ]] && [[ -f "$PREFLIGHT_DIR/config/owl.sh.template" ]]; then
  echo "📋 Creating config/owl.sh from template..."
  cp "$PREFLIGHT_DIR/config/owl.sh.template" "$PREFLIGHT_DIR/config/owl.sh"
  echo "✅ Created. Edit config/owl.sh to set your Oh My Posh config path."
  echo "   If you previously had owl setup in ~/.bashrc, you can remove those lines —"
  echo "   init.sh now handles _owl_theme_load, _owl_splash, and oh-my-posh init."
fi

# ── Source all library scripts ────────────────────────────────────────────────

for lib in "$PREFLIGHT_DIR/lib"/*.sh; do
  [[ -f "$lib" ]] && source "$lib"
done

# ── Source config (non-secret environment setup) ──────────────────────────────

[[ -f "$PREFLIGHT_DIR/config/accounts.sh" ]] && source "$PREFLIGHT_DIR/config/accounts.sh"
[[ -f "$PREFLIGHT_DIR/config/owl.sh" ]]      && source "$PREFLIGHT_DIR/config/owl.sh"

# ── Owl theme + splash ────────────────────────────────────────────────────────

# Load active theme colors (exported as OWL_BODY/EYES/TEXT/SUB for preflight.sh)
_owl_theme_load

# Show MOTD once per interactive top-level shell
[[ $- == *i* ]] && [[ $SHLVL -eq 1 ]] && _owl_splash

# Initialize Oh My Posh if configured and available
if [[ -n "${OWL_OMP_CONFIG:-}" ]] && [[ -f "$OWL_OMP_CONFIG" ]] && command -v oh-my-posh &>/dev/null; then
  eval "$(oh-my-posh init bash --config "$OWL_OMP_CONFIG")"
fi

# ── Optional: print loaded status ────────────────────────────────────────────

if [[ "${PREFLIGHT_VERBOSE:-0}" == "1" ]]; then
  echo "✅ Developer environment loaded from $PREFLIGHT_DIR"
fi
