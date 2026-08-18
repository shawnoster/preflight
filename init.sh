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
  # NOTE: this file is *sourced*, so we are not inside a function — `local` is
  # an error here ("local: can only be used in a function"). It used to appear
  # seven times below, which meant a fresh install greeted the user with seven
  # error messages. Plain vars + an explicit unset at the end instead.
  #
  # Collect available profiles (files matching accounts.*.sh, excluding .template and itself)
  _pf_profiles=()
  for _pf_file in "$PREFLIGHT_DIR/config/accounts."*.sh; do
    [[ -f "$_pf_file" ]] || continue
    _pf_base=$(basename "$_pf_file")
    [[ "$_pf_base" == "accounts.sh" || "$_pf_base" == "accounts.sh.template" ]] && continue
    _pf_profiles+=("$_pf_file")
  done

  # Only prompt when there is a human to answer. A non-interactive shell (a
  # script sourcing .bashrc, a provisioning run) would otherwise block on
  # `read` or silently consume the caller's stdin.
  if [[ ${#_pf_profiles[@]} -gt 0 && $- == *i* ]]; then
    echo "🔧 First-time setup — pick a config profile:"
    for _pf_idx in "${!_pf_profiles[@]}"; do
      _pf_label=$(basename "${_pf_profiles[$_pf_idx]}" | sed 's/accounts\.\(.*\)\.sh/\1/')
      printf "  %d) %s\n" "$((_pf_idx + 1))" "$_pf_label"
    done
    printf "  Choice [1-%d]: " "${#_pf_profiles[@]}"
    read -r _pf_choice
    # Validate as a plain integer before arithmetic, so stray input can't reach
    # the arithmetic evaluator.
    if [[ "$_pf_choice" =~ ^[0-9]+$ ]]; then
      _pf_choice=$((_pf_choice - 1))
    else
      _pf_choice=-1
    fi
    if [[ $_pf_choice -ge 0 && $_pf_choice -lt ${#_pf_profiles[@]} ]]; then
      cp "${_pf_profiles[$_pf_choice]}" "$PREFLIGHT_DIR/config/accounts.sh"
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
  # These are globals (see the `local` note above) — don't leak them into the
  # user's interactive shell.
  unset _pf_profiles _pf_file _pf_base _pf_idx _pf_label _pf_choice
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

# A fixed path in a world-writable /tmp is both a symlink-clobber target and a
# collision between concurrent shells; mktemp gives a private file per shell.
_pf_lib_err=$(mktemp 2>/dev/null) || _pf_lib_err=/dev/null
for lib in "$PREFLIGHT_DIR/lib"/*.sh; do
  if [[ -f "$lib" ]]; then
    if ! source "$lib" 2>"$_pf_lib_err"; then
      echo "⚠️  preflight: failed to load $(basename "$lib")"
      head -5 "$_pf_lib_err" 2>/dev/null | sed 's/^/   /'
    fi
  fi
done
[[ "$_pf_lib_err" != /dev/null ]] && rm -f "$_pf_lib_err"
unset _pf_lib_err lib

# ── Source config (non-secret environment setup) ──────────────────────────────

[[ -f "$PREFLIGHT_DIR/config/accounts.sh" ]] && source "$PREFLIGHT_DIR/config/accounts.sh"
[[ -f "$PREFLIGHT_DIR/config/owl.sh" ]]      && source "$PREFLIGHT_DIR/config/owl.sh"

# ── Owl theme + splash ────────────────────────────────────────────────────────

# Load active theme colors (exported as OWL_BODY/EYES/TEXT/SUB for preflight.sh)
# Guarded: lib sourcing above tolerates a failed owl.sh, so this must too —
# otherwise a broken owl.sh turns into a command-not-found on every shell.
declare -F _owl_theme_load >/dev/null && _owl_theme_load

# Show MOTD once per interactive session.
#
# This used to gate on `$SHLVL -eq 1`, which never fires under WSL + VS Code
# (the login shell already starts at SHLVL 3), so the splash silently stopped
# appearing. An exported marker is the right test: a genuinely new terminal
# starts with a clean environment and shows it once, while nested shells,
# subshells and tmux panes inherit the marker and stay quiet.
# Set PREFLIGHT_NO_SPLASH=1 to suppress it entirely.
if [[ $- == *i* && -z "${PREFLIGHT_SPLASH_SHOWN:-}" && -z "${PREFLIGHT_NO_SPLASH:-}" ]]; then
  export PREFLIGHT_SPLASH_SHOWN=1
  declare -F _owl_splash >/dev/null && _owl_splash
fi

# Initialize Oh My Posh if configured and available.
#
# `oh-my-posh init bash` costs ~55ms of subprocess on *every* shell, which is
# why this used to route through _preflight_cache_eval (generate once, source
# the cached script after — see PR #31 for a real bug that path had on
# oh-my-posh 26.x). Even with that fixed, the cache-hit path still produces a
# wrong prompt: on a clean cache, sourcing the cached omp-init script renders
# oh-my-posh's own fallback theme instead of $OWL_OMP_CONFIG on the first
# prompt of a new shell — reproduced 3/3 on a clean `~/.cache/oh-my-posh` +
# `~/.cache/preflight`, every time, regardless of _preflight_omp_generate's
# output being correct and non-empty. A live, uncached
# `eval "$(oh-my-posh init bash --config ...)")` — the same call `owl-theme`
# makes — has not failed once across the same repro. The exact internal
# oh-my-posh mechanism this depends on wasn't pinned down (a subshell/pipe
# theory didn't hold up under testing), but the cache-vs-live split is
# solid and repeatable, so skip the cache for this one and always eval live.
if [[ -n "${OWL_OMP_CONFIG:-}" ]] && [[ -f "$OWL_OMP_CONFIG" ]] && command -v oh-my-posh &>/dev/null; then
  eval "$(oh-my-posh init bash --config "$OWL_OMP_CONFIG")"
fi

# ── Optional: print loaded status ────────────────────────────────────────────

if [[ "${PREFLIGHT_VERBOSE:-0}" == "1" ]]; then
  echo "✅ Developer environment loaded from $PREFLIGHT_DIR"
fi
