#!/usr/bin/env bash
# lib/paths.sh — where preflight keeps the user's own data
#
# ~/.preflight is a disposable clone (code, defaults, templates). Everything the
# user owns lives outside it, so `preflight update` and `uninstall` cannot touch it:
#
#   PREFLIGHT_CONFIG_DIR   config.json, envsets/         default ~/.config/preflight
#   PREFLIGHT_STATE_DIR    owl/ (current theme, patched OMP)  default ~/.local/state/preflight
#
# Priority for each: the PREFLIGHT_*_DIR override, then XDG_CONFIG_HOME /
# XDG_STATE_HOME, then the default.

# Canonical form of a path, for comparing two spellings of one place: relative paths made
# absolute, "//", "." and ".." collapsed, and symlinks resolved on the nearest existing
# ancestor (so a path that does not exist yet still compares correctly). Never touches
# the filesystem beyond a `cd -P` in a subshell. Result in _pf_canon_out.
_pf_canon() {
  local p="$1" head rest="" rem seg out=""
  [[ "$p" == /* ]] || p="$PWD/$p"
  head="$p"
  while [[ "$head" != "/" && ! -d "$head" ]]; do
    rest="/${head##*/}$rest"
    head="${head%/*}"
    [[ -n "$head" ]] || head="/"
  done
  head=$(cd -P -- "$head" 2>/dev/null && pwd -P) || head="${head:-/}"
  [[ "$head" == "/" ]] && head=""
  rem="${head#/}${rest}"
  rem="${rem#/}"
  while [[ -n "$rem" ]]; do
    seg="${rem%%/*}"
    if [[ "$rem" == */* ]]; then rem="${rem#*/}"; else rem=""; fi
    case "$seg" in
      ""|.) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$seg" ;;
    esac
  done
  _pf_canon_out="${out:-/}"
}

# Resolve and export both directories. Returns 1 (with a message) when either is the
# install directory or inside it, under any spelling (trailing slash, ".", "..", a
# symlink): code and user data must not share a directory, or `uninstall` and
# `preflight update` would treat the user's files as the clone's own.
_pf_resolve_dirs() {
  local code="${PREFLIGHT_DIR:-$HOME/.preflight}"
  local cfg="${PREFLIGHT_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/preflight}"
  local state="${PREFLIGHT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/preflight}"

  # The exported values keep the spelling you gave, minus trailing slashes.
  while [[ "$code" == */ && "$code" != "/" ]]; do code="${code%/}"; done
  while [[ "$cfg" == */ && "$cfg" != "/" ]]; do cfg="${cfg%/}"; done
  while [[ "$state" == */ && "$state" != "/" ]]; do state="${state%/}"; done

  local c_code c_cfg c_state
  _pf_canon "$code";  c_code="$_pf_canon_out"
  _pf_canon "$cfg";   c_cfg="$_pf_canon_out"
  _pf_canon "$state"; c_state="$_pf_canon_out"

  if [[ "$c_cfg" == "$c_code" || "$c_cfg" == "$c_code"/* \
     || "$c_state" == "$c_code" || "$c_state" == "$c_code"/* ]]; then
    echo "⚠️  preflight: the config or state directory is the install directory (PREFLIGHT_DIR, $code) or inside it." >&2
    echo "   Keep the install and your config apart: use the default PREFLIGHT_DIR=~/.preflight," >&2
    echo "   or set PREFLIGHT_CONFIG_DIR / PREFLIGHT_STATE_DIR to somewhere outside it." >&2
    return 1
  fi

  export PREFLIGHT_CONFIG_DIR="$cfg" PREFLIGHT_STATE_DIR="$state"
}

# Is it safe to `rm -rf` this directory? Refuses empty, /, $HOME, and the shared
# XDG roots themselves, so a mistyped PREFLIGHT_CONFIG_DIR=~/.config (or an unset
# variable) cannot delete every application's config. Prints the reason on stderr.
_pf_safe_rm_dir() {
  local dir="${1:-}" bad c_dir
  if [[ -z "$dir" ]]; then
    echo "preflight: refusing to remove suspicious directory '<unset>'" >&2
    return 1
  fi
  # Compare canonical forms, so "$HOME/.", "$HOME/x/.." or a symlink to $HOME are caught.
  _pf_canon "$dir"; c_dir="$_pf_canon_out"
  for bad in "/" "$HOME" "${XDG_CONFIG_HOME:-$HOME/.config}" \
             "${XDG_STATE_HOME:-$HOME/.local/state}" "${XDG_CACHE_HOME:-$HOME/.cache}"; do
    _pf_canon "$bad"
    if [[ "$c_dir" == "$_pf_canon_out" ]]; then
      echo "preflight: refusing to remove suspicious directory '$dir'" >&2
      return 1
    fi
  done
}
