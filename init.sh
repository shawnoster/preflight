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

# ── First-time setup: pick a profile if config doesn't exist ────────────────

if [[ ! -f "$PREFLIGHT_DIR/config/accounts.sh" ]]; then
  # Collect available profiles (files matching accounts.*.sh, excluding .template and itself)
  local _pf_profiles=()
  local _pf_file
  for _pf_file in "$PREFLIGHT_DIR/config/accounts."*.sh; do
    [[ -f "$_pf_file" ]] || continue
    local _pf_base
    _pf_base=$(basename "$_pf_file")
    [[ "$_pf_base" == "accounts.sh" || "$_pf_base" == "accounts.sh.template" ]] && continue
    _pf_profiles+=("$_pf_file")
  done

  if [[ ${#_pf_profiles[@]} -gt 0 ]]; then
    echo "🔧 First-time setup — pick a config profile:"
    local _pf_idx
    for _pf_idx in "${!_pf_profiles[@]}"; do
      local _pf_label
      _pf_label=$(basename "${_pf_profiles[$_pf_idx]}" | sed 's/accounts\.\(.*\)\.sh/\1/')
      printf "  %d) %s\n" "$((_pf_idx + 1))" "$_pf_label"
    done
    printf "  Choice [1-%d]: " "${#_pf_profiles[@]}"
    local _pf_choice
    read -r _pf_choice
    _pf_choice=$((_pf_choice - 1))
    if [[ $_pf_choice -ge 0 && $_pf_choice -lt ${#_pf_profiles[@]} ]]; then
      cp "${_pf_profiles[$_pf_choice]}" "$PREFLIGHT_DIR/config/accounts.sh"
      local _pf_label
      _pf_label=$(basename "${_pf_profiles[$_pf_choice]}" | sed 's/accounts\.\(.*\)\.sh/\1/')
      echo "📋 Created config/accounts.sh from $_pf_label profile."
      echo "   Edit it to customize your settings."
    else
      cp "$PREFLIGHT_DIR/config/accounts.sh.template" "$PREFLIGHT_DIR/config/accounts.sh"
      echo "📋 Created config/accounts.sh from template (invalid choice)."
    fi
  elif [[ -f "$PREFLIGHT_DIR/config/accounts.sh.template" ]]; then
    cp "$PREFLIGHT_DIR/config/accounts.sh.template" "$PREFLIGHT_DIR/config/accounts.sh"
    echo "📋 Creating config/accounts.sh from template..."
    echo "✅ Created. Edit config/accounts.sh to customize your settings."
  fi
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
  if [[ -f "$lib" ]]; then
    if ! source "$lib" 2>/tmp/_preflight_lib_err; then
      echo "⚠️  preflight: failed to load $(basename "$lib")"
      cat /tmp/_preflight_lib_err 2>/dev/null | head -5 | sed 's/^/   /'
      rm -f /tmp/_preflight_lib_err
    fi
  fi
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
