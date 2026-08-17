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
    # mktemp rather than "$cache.$$.tmp": the PID is predictable, collides
    # between containers sharing a cache dir, and is a symlink/clobber target
    # if PREFLIGHT_CACHE_DIR is pointed somewhere shared. This costs a fork,
    # but only on the generation path — which already forks the generator —
    # so the cache-*hit* path stays subprocess-free.
    local tmp
    if ! tmp=$(mktemp "$PREFLIGHT_CACHE_DIR/.$name.XXXXXX" 2>/dev/null); then
      local live
      live=$("$generator" 2>/dev/null) && [[ -n "$live" ]] && eval "$live"
      return
    fi
    if "$generator" >"$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
      # mktemp creates 0600; relax to the usual rw-r--r-- so the cache behaves
      # like an ordinary generated file, then rename atomically into place.
      chmod 644 "$tmp" 2>/dev/null
      mv -f "$tmp" "$cache"
    else
      rm -f -- "$tmp"
      # Generation failed — run it live so this shell still gets its prompt.
      local live
      live=$("$generator" 2>/dev/null) && [[ -n "$live" ]] && eval "$live"
      return
    fi
  fi

  # A cache that exists but is truncated or hand-edited would otherwise leave
  # the shell with no prompt and no explanation — generation-time fallback
  # above does not cover a file that is already on disk and broken.
  #
  # Exit status is the signal: a healthy init script sources cleanly, a
  # truncated one dies on a half-written function. If some future generator
  # legitimately ends on a non-zero command this will regenerate every shell —
  # slower, not broken, and the warning says why.
  if ! source "$cache"; then
    echo "⚠️  preflight: cached '$name' failed to load — discarding it" >&2
    rm -f -- "$cache"
    local live
    live=$("$generator" 2>/dev/null) && [[ -n "$live" ]] && eval "$live"
  fi
}

# Regenerate every cache entry on the next shell.
preflight-cache-clear() {
  local dir="${PREFLIGHT_CACHE_DIR:-}"

  # Guard explicitly rather than leaning on ${dir:?}. That aborts the command
  # in an interactive shell (the shell does survive), but *exits* a
  # non-interactive one outright — a hostile failure mode for a sourced
  # library. An explicit check also stops a stray `PREFLIGHT_CACHE_DIR=/`
  # from turning this into `rm -rf /`.
  if [[ -z "$dir" || "$dir" == "/" || "$dir" == "$HOME" ]]; then
    echo "preflight: refusing to clear suspicious cache dir '${dir:-<unset>}'" >&2
    return 1
  fi

  if [[ ! -d "$dir" ]]; then
    echo "🧹 preflight cache already empty: $dir"
    return 0
  fi

  rm -rf -- "$dir"
  echo "🧹 preflight cache cleared: $dir"
}

# Fork-free UUID. /proc is one read and better entropy; the fallback keeps the
# no-subprocess guarantee on platforms without it (macOS), where calling
# uuidgen would put a fork back on the cache-hit path. $RANDOM is not
# cryptographic, which is fine — this identifies a shell session, it is not a
# secret. Result in $_pf_uuid.
_preflight_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    read -r _pf_uuid < /proc/sys/kernel/random/uuid
    return 0
  fi
  local _h='' _var _i
  for ((_i = 0; _i < 32; _i++)); do
    printf -v _h '%s%x' "$_h" $(( RANDOM & 15 ))
  done
  printf -v _var '%x' $(( (16#${_h:16:1} & 3) | 8 ))   # RFC 4122 variant
  _pf_uuid="${_h:0:8}-${_h:8:4}-4${_h:13:3}-${_var}${_h:17:3}-${_h:20:12}"
}

# ── Generators ───────────────────────────────────────────────────────────────

# oh-my-posh embeds a fresh POSH_SESSION_ID UUID in its init output, which is
# the one line that must NOT be cached — every shell sharing a session id would
# make oh-my-posh treat separate terminals as the same session. It is set once
# and never read back by the script itself, so dropping it here and exporting a
# per-shell value before sourcing (see init.sh) is safe.
_preflight_omp_generate() {
  # Older oh-my-posh emits POSH_SESSION_ID on its own line; 26.x collapses
  # the whole init output into one line — `export POSH_SESSION_ID="...";
  # source $'...'` — so a whole-line grep -v strips 100% of the output on
  # that version, leaving an empty cache and a silently broken prompt.
  # Strip just the assignment prefix instead, wherever it starts a line.
  oh-my-posh init bash --config "$OWL_OMP_CONFIG" \
    | sed -E 's/^export POSH_SESSION_ID="[^"]*";?[[:space:]]*//'
}
