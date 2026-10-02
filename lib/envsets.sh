#!/usr/bin/env bash
# ~/.preflight/lib/envsets.sh - Named sets of env vars backed by 1Password refs
#
# This is the only place that says WHICH secrets get loaded; lib/onepassword.sh
# just resolves whatever _op_env_entries hands it.
#
# A "set" is a named group of VAR -> op:// references (guild, personal, ...).
# Sets live in config/envsets/<set>.tsv (gitignored, per-install), one
# `VAR<TAB>op://vault/item/field` line each. Active sets are listed in
# config/envsets/.active (absent = every set is active). Hand-editing a .tsv
# is fine.
#
# Usage:
#   op-env add [set] [VAR] [op://ref]   add/update a key (prompts for what's missing)
#   op-env list [set]                   show sets and their keys
#   op-env rm [set] [VAR]               remove a key (fzf picker if omitted)
#   op-env use [set...]                 choose which sets op-load-env loads
#   op-env migrate [set]                move a legacy OP_SECRETS array into a set
#   op-env help

_op_envsets_dir() { printf '%s' "${PREFLIGHT_DIR:-$HOME/.preflight}/config/envsets"; }

_op_envsets_ensure() {
  local d; d=$(_op_envsets_dir)
  [[ -d "$d" ]] || { mkdir -p "$d" && chmod 700 "$d"; }
}

# Set names become file names, so restrict them to a safe alphabet.
_op_envsets_valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; }

# Names of existing sets, one per line.
_op_envsets_names() {
  local d; d=$(_op_envsets_dir)
  # find, not a glob: an unmatched *.tsv is an error in zsh (NOMATCH) on a fresh install.
  find "$d" -maxdepth 1 -type f -name '*.tsv' 2>/dev/null | sed 's|.*/||; s|\.tsv$||' | sort
}

# Active sets, one per line. With no .active file, every existing set is active.
_op_envsets_active() {
  local d; d=$(_op_envsets_dir)
  if [[ -f "$d/.active" ]]; then
    tr -d '\r' < "$d/.active" | grep -v '^[[:space:]]*$'
  else
    _op_envsets_names
  fi
}

# Pick one of several lines: fzf when available, numbered prompt otherwise.
# Usage: _op_envsets_pick "prompt" <<< "$choices"   (prints the choice)
_op_envsets_pick() {
  local prompt="$1" choices reply out
  choices=$(cat)
  [[ -n "$choices" ]] || return 1
  if command -v fzf &>/dev/null && [[ -t 2 ]]; then
    printf '%s\n' "$choices" | fzf --prompt="$prompt " --height=40% --reverse
    return
  fi
  printf '%s\n' "$choices" | awk '{ printf "  %d) %s\n", NR, $0 }' >&2
  _pf_ask reply "  $prompt [number]: " </dev/tty || return 1
  [[ "$reply" =~ ^[0-9]+$ ]] || return 1
  out=$(printf '%s\n' "$choices" | awk -v n="$reply" 'NR == n')
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# Resolve a set name: use $1 if given, else pick an existing one or create new.
_op_envsets_choose_set() {
  local set="${1:-}"
  if [[ -z "$set" ]]; then
    local choices; choices=$( { _op_envsets_names; printf '%s\n' "guild" "personal"; } | awk 'NF && !seen[$0]++')
    choices+=$'\n'"+ new set..."
    set=$(printf '%s\n' "$choices" | _op_envsets_pick "Set:") || return 1
    if [[ "$set" == "+ new set..." ]]; then
      _pf_ask set "  New set name: " </dev/tty || return 1
    fi
  fi
  if ! _op_envsets_valid_name "$set"; then
    echo "❌ Invalid set name '$set' (use lowercase letters, digits, - or _)" >&2
    return 1
  fi
  printf '%s' "$set"
}

# Write (or replace) one VAR -> ref line in a set, creating the set if needed.
# Usage: _op_envsets_put set VAR ref
_op_envsets_put() {
  local set="$1" name="$2" ref="$3"
  _op_envsets_ensure
  local file is_new=0; file="$(_op_envsets_dir)/$set.tsv"
  [[ -f "$file" ]] || is_new=1
  local tmp; tmp=$(mktemp "$(_op_envsets_dir)/.tmp.XXXXXX") || return 1
  { [[ -f "$file" ]] && awk -F'\t' -v n="$name" '$1 != n' "$file"; printf '%s\t%s\n' "$name" "$ref"; } > "$tmp" \
    && chmod 600 "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }

  # Keep an explicit .active list consistent: a brand-new set should load, but
  # editing a set the user deliberately deactivated must not reactivate it.
  local act; act="$(_op_envsets_dir)/.active"
  if [[ $is_new -eq 1 && -f "$act" ]] && ! grep -qxF "$set" "$act"; then
    printf '%s\n' "$set" >> "$act" || {
      echo "❌ Saved the key, but could not activate set '$set' (write to $act failed). Fix the file, then run: op-env use" >&2
      return 1
    }
  fi
}

_op_env_add() {
  local set="${1:-}" name="${2:-}" ref="${3:-}"
  _op_envsets_ensure
  set=$(_op_envsets_choose_set "$set") || return 1

  if [[ -z "$name" ]]; then _pf_ask name "  Env var name: " </dev/tty || return 1; fi
  if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "❌ Invalid env var name '$name'" >&2; return 1
  fi
  if [[ "$name" == "GITHUB_TOKEN" || "$name" == "GH_TOKEN" ]]; then
    echo "⚠️  $name overrides gh CLI's stored auth for every gh call. Consider GH_PAT instead."
    local ok; _pf_ask ok "  Use it anyway? [y/N] " </dev/tty || ok=n
    [[ "$ok" =~ ^[Yy]$ ]] || return 1
  fi

  if [[ -z "$ref" ]]; then _pf_ask ref "  1Password reference (op://vault/item/field): " </dev/tty || return 1; fi
  if [[ ! "$ref" =~ ^op://[^/]+/[^/]+/.+ ]]; then
    echo "❌ Reference must look like op://vault/item/field" >&2; return 1
  fi

  _op_envsets_put "$set" "$name" "$ref" || return 1
  echo "✅ [$set] $name -> $ref"
  echo "   Load it now: op-load-env"
}

_op_env_list() {
  local only="${1:-}" set file line found=0 active
  active=$(_op_envsets_active)
  while IFS= read -r set; do
    [[ -n "$only" && "$set" != "$only" ]] && continue
    found=1
    file="$(_op_envsets_dir)/$set.tsv"
    if grep -qxF "$set" <<< "$active"; then echo "● $set (active)"; else echo "○ $set (inactive)"; fi
    while IFS=$'\t' read -r line ref; do
      ref=${ref%$'\r'}
      [[ -n "$line" ]] && printf '    %-28s %s\n' "$line" "$ref"
    done < "$file"
  done < <(_op_envsets_names)
  local legacy; legacy=$(_op_legacy_secrets)
  if [[ -z "$only" && -n "$legacy" ]]; then
    found=1
    echo "◆ OP_SECRETS array (legacy, from config/accounts.sh or lib/1password.sh) — move it with: op-env migrate"
    while IFS= read -r line; do
      printf '    %-28s %s\n' "${line%%$'\t'*}" "${line#*$'\t'}"
    done <<< "$legacy"
  fi
  if [[ $found -eq 0 ]]; then
    [[ -n "$only" ]] && { echo "❌ No such set: $only" >&2; return 1; }
    echo "No env sets yet. Create one with: op-env add"
  fi
}

_op_env_rm() {
  local set="${1:-}" name="${2:-}" file
  if [[ -z "$set" ]]; then
    set=$(_op_envsets_names | _op_envsets_pick "Set:") || return 1
  fi
  _op_envsets_valid_name "$set" || { echo "❌ Invalid set name '$set'" >&2; return 1; }
  file="$(_op_envsets_dir)/$set.tsv"
  [[ -f "$file" ]] || { echo "❌ No such set: $set" >&2; return 1; }
  if [[ -z "$name" ]]; then
    name=$(cut -f1 "$file" | _op_envsets_pick "Remove from $set:") || return 1
  fi
  if ! cut -f1 "$file" | grep -qxF "$name"; then
    echo "❌ $name not in $set" >&2; return 1
  fi
  local tmp; tmp=$(mktemp "$(_op_envsets_dir)/.tmp.XXXXXX") || return 1
  awk -F'\t' -v n="$name" '$1 != n' "$file" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$file" \
    || { rm -f "$tmp"; return 1; }
  echo "🗑️  Removed $name from $set"
  echo "   It is unset on the next op-load-env or op-clear-env, or now with: unset $name"
}

_op_env_use() {
  _op_envsets_ensure
  local chosen s
  if [[ $# -gt 0 ]]; then
    chosen=$(printf '%s\n' "$@")
  elif command -v fzf &>/dev/null && [[ -t 2 ]]; then
    chosen=$(_op_envsets_names | fzf -m --prompt="Active sets (Tab to multi-select): " --height=40% --reverse)
  else
    local answer=""
    _pf_ask answer "  Sets to activate (space-separated, available: $(_op_envsets_names | tr '\n' ' ')): " </dev/tty || return 1
    chosen=$(printf '%s\n' "$answer" | tr -s ' ' '\n')
  fi
  chosen=$(printf '%s\n' "$chosen" | awk 'NF')
  [[ -n "$chosen" ]] || { echo "No change."; return 0; }
  while IFS= read -r s; do
    _op_envsets_valid_name "$s" && [[ -f "$(_op_envsets_dir)/$s.tsv" ]] || { echo "❌ No such set: $s" >&2; return 1; }
  done <<< "$chosen"
  printf '%s\n' "$chosen" > "$(_op_envsets_dir)/.active" \
    || { echo "❌ Could not save the active sets to $(_op_envsets_dir)/.active" >&2; return 1; }
  echo "✅ Active sets: $(printf '%s\n' "$chosen" | paste -sd' ' -)"
}

# Move a legacy OP_SECRETS array (config/accounts.sh, or a leftover per-install
# lib/1password.sh) into a set. Keys the set already has are left alone.
_op_env_migrate() {
  local set="${1:-default}" line name ref file moved=0 legacy
  legacy=$(_op_legacy_secrets)
  if [[ -z "$legacy" ]]; then
    echo "Nothing to migrate: no OP_SECRETS array is defined."
    return 0
  fi
  _op_envsets_valid_name "$set" || { echo "❌ Invalid set name '$set'" >&2; return 1; }
  file="$(_op_envsets_dir)/$set.tsv"
  while IFS= read -r line; do
    name="${line%%$'\t'*}"; ref="${line#*$'\t'}"
    if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ || "$ref" != op://* ]]; then
      echo "⚠️  Skipped malformed entry: $name"; continue
    fi
    if [[ -f "$file" ]] && cut -f1 "$file" | grep -qxF "$name"; then
      echo "   $name already in [$set], left as is"; continue
    fi
    _op_envsets_put "$set" "$name" "$ref" || return 1
    echo "✅ [$set] $name -> $ref"
    moved=$((moved + 1))
  done <<< "$legacy"
  echo ""
  echo "Moved $moved key(s). Now remove the old list so the set is the only source:"
  echo "  - an OP_SECRETS=( ... ) block in config/accounts.sh: delete the block"
  if [[ -f "${PREFLIGHT_DIR:-$HOME/.preflight}/lib/1password.sh" ]]; then
    echo "  - lib/1password.sh is a leftover from before the rename to lib/onepassword.sh:"
    echo "    delete it (${PREFLIGHT_DIR:-$HOME/.preflight}/lib/1password.sh) if it holds nothing else you need"
  fi
}

_op_env_help() {
  cat <<'EOF'
op-env manages named env sets backed by 1Password references.

  op-env add [set] [VAR] [op://ref]   Add or update a key (prompts for the rest)
  op-env list [set]                   Show sets and keys (● active, ○ inactive)
  op-env rm [set] [VAR]               Remove a key
  op-env use [set...]                 Choose active sets (fzf multi-select if omitted)
  op-env migrate [set]                Move a legacy OP_SECRETS array into a set
  op-env help                         This message

Sets (e.g. guild, personal) are stored in config/envsets/<set>.tsv, one
`VAR<TAB>op://vault/item/field` per line, and are the only list of secrets
op-load-env and op-clear-env use.
EOF
}

op-env() {
  case "${1:-help}" in
    add)          shift; _op_env_add "$@" ;;
    list|ls)      shift; _op_env_list "$@" ;;
    rm|remove)    shift; _op_env_rm "$@" ;;
    use)          shift; _op_env_use "$@" ;;
    migrate)      shift; _op_env_migrate "$@" ;;
    help|-h|--help) _op_env_help ;;
    *) echo "❌ Unknown op-env command: $1" >&2; _op_env_help >&2; return 1 ;;
  esac
}

# The legacy OP_SECRETS array, one entry per line (nothing if it is unset or empty).
# Checks with declare -p first: since this PR nothing defines the array by default,
# and reading an unset array aborts a shell running `set -u`.
_op_legacy_secrets() {
  declare -p OP_SECRETS &>/dev/null || return 0
  [[ ${#OP_SECRETS[@]} -gt 0 ]] || return 0
  printf '%s\n' "${OP_SECRETS[@]}"
}

# Everything op-load-env / op-clear-env need to know: one `VAR<TAB>op://ref` line
# per secret, from the active sets. An OP_SECRETS array still defined by an older
# config/accounts.sh is honored too (and wins on a name clash) until it is moved
# with `op-env migrate`. The first definition of a name wins (sets are read in the
# order of config/envsets/.active, or alphabetically when that file is absent);
# anything that isn't a valid variable name or an op:// reference is dropped.
# CRs are stripped so a set edited on Windows (CRLF) still resolves.
_op_env_entries() {
  local set file
  {
    _op_legacy_secrets
    while IFS= read -r set; do
      _op_envsets_valid_name "$set" || continue
      file="$(_op_envsets_dir)/$set.tsv"
      [[ -f "$file" ]] && awk 1 "$file"
    done < <(_op_envsets_active)
  } | tr -d '\r' | awk -F'\t' '$1 ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && $2 ~ /^op:\/\// && !seen[$1]++'
}
