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
# XDG_STATE_HOME, then the default. The cache already follows XDG (lib/cache.sh).

# Resolve and export both directories. Returns 1 (with a message) when either would
# be the install directory itself: code and user data must not share a directory,
# or `uninstall` and `preflight update` would see the user's files as their own.
_pf_resolve_dirs() {
  local code="${PREFLIGHT_DIR:-$HOME/.preflight}"
  local cfg="${PREFLIGHT_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/preflight}"
  local state="${PREFLIGHT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/preflight}"

  # Compare without trailing slashes ("~/x/" and "~/x" are the same directory).
  while [[ "$code" == */ && "$code" != "/" ]]; do code="${code%/}"; done
  while [[ "$cfg" == */ && "$cfg" != "/" ]]; do cfg="${cfg%/}"; done
  while [[ "$state" == */ && "$state" != "/" ]]; do state="${state%/}"; done

  if [[ "$cfg" == "$code" || "$state" == "$code" ]]; then
    echo "⚠️  preflight: PREFLIGHT_DIR ($code) is also the config or state directory." >&2
    echo "   Keep the install and your config apart: use the default PREFLIGHT_DIR=~/.preflight," >&2
    echo "   or set PREFLIGHT_CONFIG_DIR / PREFLIGHT_STATE_DIR to somewhere else." >&2
    return 1
  fi

  export PREFLIGHT_CONFIG_DIR="$cfg" PREFLIGHT_STATE_DIR="$state"
}

# Is it safe to `rm -rf` this directory? Refuses empty, /, $HOME, and the shared
# XDG roots themselves, so a mistyped PREFLIGHT_CONFIG_DIR=~/.config (or an unset
# variable) cannot delete every application's config. Prints the reason on stderr.
_pf_safe_rm_dir() {
  local dir="${1:-}"
  while [[ "$dir" == */ && "$dir" != "/" ]]; do dir="${dir%/}"; done
  local bad
  for bad in "" "/" "$HOME" "${XDG_CONFIG_HOME:-$HOME/.config}" \
             "${XDG_STATE_HOME:-$HOME/.local/state}" "${XDG_CACHE_HOME:-$HOME/.cache}"; do
    while [[ "$bad" == */ && "$bad" != "/" ]]; do bad="${bad%/}"; done
    if [[ "$dir" == "$bad" ]]; then
      echo "preflight: refusing to remove suspicious directory '${1:-<unset>}'" >&2
      return 1
    fi
  done
}
