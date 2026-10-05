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

# Add bin/ to PATH so distributed scripts (git-credential-op) are
# findable. Idempotent — safe to source multiple times.
case ":$PATH:" in
  *":$PREFLIGHT_DIR/bin:"*) ;;
  *) PATH="$PREFLIGHT_DIR/bin:$PATH" ;;
esac

# ~/.local/bin holds oh-my-posh and the npiperelay bridge preflight installs. A login
# shell sources .bashrc (and so this file) from ~/.profile, and Ubuntu's stock
# ~/.profile does that *before* it adds ~/.local/bin to PATH, so without this the
# `command -v oh-my-posh` check below silently skips the prompt. Guarded, so it is
# a no-op when PATH is already right and never creates duplicates on re-source.
if [[ -d "$HOME/.local/bin" ]]; then
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) PATH="$HOME/.local/bin:$PATH" ;;
  esac
fi

# Point SSH at the 1Password agent bridge when it exists (docs/wsl-ssh-setup.md).
# ~/.profile covers login shells and scripts, but zsh and non-login Bash never read
# it, so interactive shells that source this file get the export here. An agent
# that something else already configured is left alone.
if [[ -z "${SSH_AUTH_SOCK:-}" && -S "$HOME/.1password/agent.sock" ]]; then
  export SSH_AUTH_SOCK="$HOME/.1password/agent.sock"
fi

# ── First-time setup: create config.json from a profile if there is none yet ─
# Never prompts: a new shell must not block on a question. The general profile is
# the default; PREFLIGHT_PROFILE=company (set before sourcing this file) picks
# another defaults/config.<name>.json.

if [[ ! -f "$PREFLIGHT_CONFIG_DIR/config.json" ]]; then
  _pf_pick="$PREFLIGHT_DIR/defaults/config.${PREFLIGHT_PROFILE:-general}.json"
  if [[ ! -f "$_pf_pick" || "${PREFLIGHT_PROFILE:-general}" == schema ]]; then
    echo "⚠️  preflight: no profile '${PREFLIGHT_PROFILE}' in $PREFLIGHT_DIR/defaults — using general." >&2
    _pf_pick="$PREFLIGHT_DIR/defaults/config.general.json"
  fi
  if [[ -f "$_pf_pick" ]]; then
    cp "$_pf_pick" "$PREFLIGHT_CONFIG_DIR/config.json"
    echo "📋 Created $PREFLIGHT_CONFIG_DIR/config.json from $(basename "$_pf_pick")."
    echo "   Change settings with: preflight config set KEY VALUE  (or: preflight config init)"
  fi
  unset _pf_pick
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

# ── Load settings (config.json; see docs/config.md) ───────────────────────────

_pf_config_load

# ── Plugins ───────────────────────────────────────────────────────────────────

# Opt-in extras that change how the shell looks or behaves beyond the core helpers
# (see plugins/README.md). Nothing loads by default: name them in config.json
# ("plugins": ["owl"]) or `preflight config set plugins owl`. Each one is
# plugins/<name>/plugin.sh. A missing or broken plugin warns and never blocks the shell.
_pf_plugins_load() {
  local name file rest="${PREFLIGHT_PLUGINS:-}"
  # Split on ':' by hand: `read -a` is Bash-only and zsh does not word-split a bare $var.
  while [[ -n "$rest" ]]; do
    name="${rest%%:*}"
    if [[ "$rest" == *:* ]]; then rest="${rest#*:}"; else rest=""; fi
    [[ -n "$name" ]] || continue
    if [[ ! "$name" =~ ^[a-z][a-z0-9-]*$ ]]; then
      echo "⚠️  preflight: ignoring plugin '$name' (names are lowercase letters, digits and -)"
      continue
    fi
    file="$PREFLIGHT_DIR/plugins/$name/plugin.sh"
    if [[ ! -f "$file" ]]; then
      echo "⚠️  preflight: plugin '$name' not found ($file)"
      continue
    fi
    source "$file" || echo "⚠️  preflight: plugin '$name' failed to load"
  done
}
_pf_plugins_load
unset -f _pf_plugins_load

# ── Optional: print loaded status ────────────────────────────────────────────

if [[ "${PREFLIGHT_VERBOSE:-0}" == "1" ]]; then
  echo "✅ Developer environment loaded from $PREFLIGHT_DIR"
fi
