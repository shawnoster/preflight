#!/usr/bin/env bash
# ~/.preflight/lib/nanoleaf.sh - Nanoleaf token hand-off for the bin/nanoleaf-* scripts
#
# Hooks into op-load-env (lib/1password.sh) so the generic loader stays free of
# secret-specific logic. Nothing happens unless NANOLEAF_TOKEN is in the
# environment, i.e. an active env set maps it to an op:// reference.

# Sync NANOLEAF_TOKEN to ~/.config/nanoleaf-direct/env so cron jobs
# (light-remind --tone streak-pan / kitt-pan, etc.) can read it
# without needing a 1Password session. Preserves other lines in the
# file; replaces or appends the key line; keeps mode 0600.
#
# Atomicity: tempfile is created in the destination directory so the
# final mv is rename(2) on the same filesystem (atomic) rather than
# copy+delete from /tmp (which could leave a truncated file with
# partial secret content if interrupted). chmod 600 is applied to the
# tempfile before the rename so the secret is never world-readable.
# RETURN trap removes the tempfile on any early exit.
_op_sync_nanoleaf_env() {
  if [ -n "$NANOLEAF_TOKEN" ]; then
    local nl_env=~/.config/nanoleaf-direct/env
    local nl_dir
    nl_dir=$(dirname "$nl_env")
    mkdir -p "$nl_dir" || return 1
    local nl_tmp
    nl_tmp=$(mktemp "$nl_dir/.env.tmp.XXXXXX") || return 1
    trap 'rm -f "$nl_tmp"' RETURN
    { [ -f "$nl_env" ] && grep -v '^NANOLEAF_TOKEN=' "$nl_env"; \
      printf 'NANOLEAF_TOKEN=%s\n' "$NANOLEAF_TOKEN"; } > "$nl_tmp" || return 1
    chmod 600 "$nl_tmp" || return 1
    mv -f "$nl_tmp" "$nl_env" || return 1
    trap - RETURN
  fi
}

# Run after every op-load-env (registered once, even if this file is re-sourced).
case " ${_OP_AFTER_LOAD_HOOKS[*]} " in
  *" _op_sync_nanoleaf_env "*) ;;
  *) _OP_AFTER_LOAD_HOOKS+=(_op_sync_nanoleaf_env) ;;
esac
