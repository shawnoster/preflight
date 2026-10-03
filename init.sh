#!/usr/bin/env bash
# ~/.preflight/init.sh - Developer environment initialization
#
# Usage:
#   Source from .bashrc:  . "$HOME/.preflight/init.sh"
#   Or run standalone:    source ~/.preflight/init.sh

PREFLIGHT_DIR="${PREFLIGHT_DIR:-$HOME/.preflight}"

# The install dir is a disposable clone; the user's own data lives outside it.
# Resolve the config and state directories once, before anything builds a path
# from them (lib/paths.sh). Refuses to continue if they would share the clone.
source "$PREFLIGHT_DIR/lib/paths.sh" && _pf_resolve_dirs || return 1
if ! mkdir -p "$PREFLIGHT_CONFIG_DIR"; then
  echo "⚠️  preflight: cannot create $PREFLIGHT_CONFIG_DIR (read-only, or something else is at that path)." >&2
  echo "   Set PREFLIGHT_CONFIG_DIR to a writable directory." >&2
  return 1
fi

# An install updated in place still has its env sets and owl state inside the clone, and
# an old accounts.sh / owl.sh, where nothing reads them any more. Say so instead of
# silently starting from built-in defaults (which would drop every env set and the
# account). While the owl state is there, seed nothing into the new state dir, so moving
# it over does not collide.
_pf_legacy=""
if [[ -f "$PREFLIGHT_DIR/config/accounts.sh" || -f "$PREFLIGHT_DIR/config/owl.sh" \
      || -d "$PREFLIGHT_DIR/config/envsets" || -d "$PREFLIGHT_DIR/state/owl" ]]; then
  [[ -d "$PREFLIGHT_DIR/state/owl" ]] && _pf_legacy=1
  echo "⚠️  preflight: settings from an older install are still inside $PREFLIGHT_DIR (config/, state/)." >&2
  echo "   Env sets and owl state now live outside the clone; settings live in config.json:" >&2
  echo "     mkdir -p \"$PREFLIGHT_CONFIG_DIR\" \"$PREFLIGHT_STATE_DIR\"" >&2
  [[ -d "$PREFLIGHT_DIR/config/envsets" ]] && echo "     mv \"$PREFLIGHT_DIR\"/config/envsets \"$PREFLIGHT_CONFIG_DIR\"/" >&2
  [[ -d "$PREFLIGHT_DIR/state/owl" ]] && echo "     mv \"$PREFLIGHT_DIR\"/state/owl \"$PREFLIGHT_STATE_DIR\"/" >&2
  if [[ -f "$PREFLIGHT_DIR/config/accounts.sh" || -f "$PREFLIGHT_DIR/config/owl.sh" ]]; then
    echo "   accounts.sh and owl.sh are no longer read: set their values with 'preflight config set'" >&2
    echo "   (docs/config.md maps each old variable to its key), then delete them." >&2
  fi
fi

# Add bin/ to PATH so distributed scripts (light-remind, nanoleaf-*) are
# findable. Idempotent — safe to source multiple times.
case ":$PATH:" in
  *":$PREFLIGHT_DIR/bin:"*) ;;
  *) PATH="$PREFLIGHT_DIR/bin:$PATH" ;;
esac

# Point SSH at the 1Password agent bridge when it exists (docs/wsl-ssh-setup.md).
# ~/.profile covers login shells and scripts, but zsh and non-login Bash never read
# it, so interactive shells that source this file get the export here. An agent
# that something else already configured is left alone.
if [[ -z "${SSH_AUTH_SOCK:-}" && -S "$HOME/.1password/agent.sock" ]]; then
  export SSH_AUTH_SOCK="$HOME/.1password/agent.sock"
fi

# ── First-time setup: pick a profile if there is no config.json yet ──────────

if [[ ! -f "$PREFLIGHT_CONFIG_DIR/config.json" ]]; then
  # NOTE: this file is *sourced*, so we are not inside a function — `local` is
  # an error here ("local: can only be used in a function"). Plain vars + an
  # explicit unset at the end instead.
  #
  # Profiles are defaults/config.<name>.json; the schema is not one.
  _pf_profiles=()
  for _pf_file in "$PREFLIGHT_DIR/defaults/config."*.json; do
    [[ -f "$_pf_file" ]] || continue
    _pf_base=$(basename "$_pf_file")
    [[ "$_pf_base" == "config.schema.json" ]] && continue
    _pf_profiles+=("$_pf_file")
  done
  _pf_pick=""
  [[ -f "$PREFLIGHT_DIR/defaults/config.general.json" ]] && _pf_pick="$PREFLIGHT_DIR/defaults/config.general.json"

  # Only prompt when there is a human to answer. A non-interactive shell (a
  # script sourcing .bashrc, a provisioning run) would otherwise block on
  # `read` or silently consume the caller's stdin.
  if [[ ${#_pf_profiles[@]} -gt 0 && $- == *i* ]]; then
    echo "🔧 First-time setup — pick a config profile:"
    for _pf_idx in "${!_pf_profiles[@]}"; do
      _pf_label=$(basename "${_pf_profiles[$_pf_idx]}" | sed 's/config\.\(.*\)\.json/\1/')
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
      _pf_pick="${_pf_profiles[$_pf_choice]}"
    else
      echo "   (invalid choice — using the general profile)"
    fi
  fi
  if [[ -n "$_pf_pick" ]]; then
    cp "$_pf_pick" "$PREFLIGHT_CONFIG_DIR/config.json"
    echo "📋 Created $PREFLIGHT_CONFIG_DIR/config.json from $(basename "$_pf_pick")."
    echo "   Change settings with: preflight config set KEY VALUE  (preflight config help)"
  fi
  # These are globals (see the `local` note above) — don't leak them into the
  # user's interactive shell.
  unset _pf_profiles _pf_file _pf_base _pf_idx _pf_label _pf_choice _pf_pick
fi

# Owl base theme: ensure the user-owned OMP copy that owl-theme patches exists
# (covers installs that predate the bundled theme, and `preflight update`).
# The state dir is the user's, so owl-theme is free to rewrite the palette. Never
# overwrites an existing copy — that one may hold the user's palette changes.
if [[ -z "$_pf_legacy" && ! -f "$PREFLIGHT_STATE_DIR/owl/theme-catppuccin.omp.json" ]] \
    && [[ -f "$PREFLIGHT_DIR/defaults/theme-catppuccin.omp.json" ]]; then
  mkdir -p "$PREFLIGHT_STATE_DIR/owl"
  cp "$PREFLIGHT_DIR/defaults/theme-catppuccin.omp.json" \
     "$PREFLIGHT_STATE_DIR/owl/theme-catppuccin.omp.json"
  echo "📋 Created $PREFLIGHT_STATE_DIR/owl/theme-catppuccin.omp.json (owl-theme base theme)"
fi

unset _pf_legacy

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

# ── Load settings (config.json; see docs/config.md) ───────────────────────────

_pf_config_load

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
