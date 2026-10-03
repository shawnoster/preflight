#!/usr/bin/env bash
# ~/.preflight/lib/nanoleaf.sh - Nanoleaf token hand-off for the bin/nanoleaf-* scripts
#
# Hooks into op-env load (lib/onepassword.sh) so the generic loader stays free of
# secret-specific logic. Nothing happens unless NANOLEAF_TOKEN is in the
# environment, i.e. an active env set maps it to an op:// reference.
#
# The copy is deliberately not removed again: if NANOLEAF_TOKEN later leaves the
# env sets, ~/.config/nanoleaf-direct/env keeps the last token so cron jobs that
# run without a 1Password session still work. Delete that line by hand to revoke it.

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
# The tempfile is removed on any failure path (no `trap ... RETURN`: zsh has no
# RETURN pseudo-signal, and this file is sourced from both shells).
_op_sync_nanoleaf_env() {
  [ -n "${NANOLEAF_TOKEN:-}" ] || return 0
  local nl_env=~/.config/nanoleaf-direct/env
  local nl_dir nl_tmp
  nl_dir=$(dirname "$nl_env")
  mkdir -p "$nl_dir" || return 1
  nl_tmp=$(mktemp "$nl_dir/.env.tmp.XXXXXX") || return 1
  if { [ -f "$nl_env" ] && grep -v '^NANOLEAF_TOKEN=' "$nl_env"; \
       printf 'NANOLEAF_TOKEN=%s\n' "$NANOLEAF_TOKEN"; } > "$nl_tmp" \
     && chmod 600 "$nl_tmp" \
     && mv -f "$nl_tmp" "$nl_env"; then
    return 0
  fi
  rm -f "$nl_tmp"
  return 1
}

# Run after every op-env load (registered once, even if this file is re-sourced).
case " ${_OP_AFTER_LOAD_HOOKS[*]:-} " in
  *" _op_sync_nanoleaf_env "*) ;;
  *) _OP_AFTER_LOAD_HOOKS+=(_op_sync_nanoleaf_env) ;;
esac
