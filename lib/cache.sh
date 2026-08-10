#!/usr/bin/env bash
# lib/cache.sh — cache expensive shell initialization
#
# Many tools ship a `tool init <shell>` command whose output you are expected to
# eval on every shell start:
#
#     eval "$(oh-my-posh init bash --config "$theme")"
#
# That is a fork + exec + parse on every single shell. A handful of tools doing
# it adds up to more startup latency than everything else in a shell profile
# combined. The fix is generate-once / source-thereafter, regenerating only when
# the inputs change.
#
# The one rule that matters: the cache-*hit* path must not fork. Deciding
# freshness with `stat`, `date` or `tool --version` reintroduces exactly the
# subprocess being avoided. So freshness is decided with `-nt`, a bash builtin:
# the cache is valid while it is newer than every input file it was built from.

PREFLIGHT_CACHE_DIR="${PREFLIGHT_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/preflight}"

# _preflight_cache_eval <name> <generator-fn> [input-file...]
#
# Sources $PREFLIGHT_CACHE_DIR/<name>.bash, regenerating it via <generator-fn>
# when it is missing, empty, or older than any <input-file>.
#
# On generation failure it falls back to running <generator-fn> live, so a
# broken cache degrades to the old behaviour rather than to a broken prompt.
_preflight_cache_eval() {
  local name=$1 generator=$2
  shift 2

  local cache="$PREFLIGHT_CACHE_DIR/$name.bash"
  local fresh=1 input

  [[ -s "$cache" ]] || fresh=0
  if (( fresh )); then
    for input in "$@"; do
      # Missing input: can't prove staleness, so keep the cache rather than
      # regenerating on every shell.
      [[ -e "$input" ]] || continue
      if [[ "$input" -nt "$cache" ]]; then
        fresh=0
        break
      fi
    done
  fi

  if (( ! fresh )); then
    mkdir -p "$PREFLIGHT_CACHE_DIR" 2>/dev/null
    local tmp="$cache.$$.tmp"
    if "$generator" >"$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
      mv -f "$tmp" "$cache"
    else
      rm -f "$tmp"
      # Generation failed — run it live so this shell still gets its prompt.
      local live
      live=$("$generator" 2>/dev/null) && [[ -n "$live" ]] && eval "$live"
      return
    fi
  fi

  source "$cache"
}

# Regenerate every cache entry on the next shell.
preflight-cache-clear() {
  rm -rf "${PREFLIGHT_CACHE_DIR:?}"
  echo "🧹 preflight cache cleared: $PREFLIGHT_CACHE_DIR"
}

# ── Generators ───────────────────────────────────────────────────────────────

# oh-my-posh embeds a fresh POSH_SESSION_ID UUID in its init output, which is
# the one line that must NOT be cached — every shell sharing a session id would
# make oh-my-posh treat separate terminals as the same session. It is set once
# and never read back by the script itself, so dropping it here and exporting a
# per-shell value before sourcing (see init.sh) is safe.
_preflight_omp_generate() {
  oh-my-posh init bash --config "$OWL_OMP_CONFIG" \
    | grep -v '^export POSH_SESSION_ID='
}
