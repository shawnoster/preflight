#!/usr/bin/env bash
# ~/.preflight/lib/envsets.sh - Named sets of env vars backed by 1Password refs
#
# A "set" is a named group of VAR -> op:// references (guild, personal, ...).
# Sets live in config/envsets/<set>.tsv (gitignored, per-install), one
# `VAR<TAB>op://vault/item/field` line each. Active sets are listed in
# config/envsets/.active; op-load-env / op-clear-env merge them into OP_SECRETS.
#
# Usage:
#   op-env add [set] [VAR] [op://ref]   add/update a key (prompts for what's missing)
#   op-env list [set]                   show sets and their keys
#   op-env rm [set] [VAR]               remove a key (fzf picker if omitted)
#   op-env use [set...]                 choose which sets op-load-env loads
#   op-env help

_op_envsets_dir() { printf '%s' "${PREFLIGHT_DIR:-$HOME/.preflight}/config/envsets"; }

_op_envsets_ensure() {
  local d; d=$(_op_envsets_dir)
  [[ -d "$d" ]] || { mkdir -p "$d" && chmod 700 "$d"; }
}

# Names of existing sets, one per line.
_op_envsets_names() {
  local d f; d=$(_op_envsets_dir)
  for f in "$d"/*.tsv; do
    [[ -f "$f" ]] && basename "$f" .tsv
  done
}

# Active sets, one per line. With no .active file, every existing set is active.
_op_envsets_active() {
  local d; d=$(_op_envsets_dir)
  if [[ -f "$d/.active" ]]; then
    grep -v '^[[:space:]]*$' "$d/.active"
  else
    _op_envsets_names
  fi
}

# Pick one of several lines: fzf when available, numbered prompt otherwise.
# Usage: _op_envsets_pick "prompt" <<< "$choices"   (prints the choice)
_op_envsets_pick() {
  local prompt="$1" choices reply i
  choices=$(cat)
  [[ -n "$choices" ]] || return 1
  if command -v fzf &>/dev/null && [[ -t 2 ]]; then
    printf '%s\n' "$choices" | fzf --prompt="$prompt " --height=40% --reverse
    return
  fi
  local -a opts; mapfile -t opts <<< "$choices"
  for i in "${!opts[@]}"; do printf '  %d) %s\n' "$((i + 1))" "${opts[$i]}" >&2; done
  read -r -p "  $prompt [1-${#opts[@]}]: " reply </dev/tty
  [[ "$reply" =~ ^[0-9]+$ && reply -ge 1 && reply -le ${#opts[@]} ]] || return 1
  printf '%s\n' "${opts[$((reply - 1))]}"
}

# Resolve a set name: use $1 if given, else pick an existing one or create new.
_op_envsets_choose_set() {
  local set="${1:-}"
  if [[ -z "$set" ]]; then
    local choices; choices=$( { _op_envsets_names; printf '%s\n' "guild" "personal"; } | awk 'NF && !seen[$0]++')
    choices+=$'\n'"+ new set..."
    set=$(printf '%s\n' "$choices" | _op_envsets_pick "Set:") || return 1
    if [[ "$set" == "+ new set..." ]]; then
      read -r -p "  New set name: " set </dev/tty
    fi
  fi
  if [[ ! "$set" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    echo "❌ Invalid set name '$set' (use lowercase letters, digits, - or _)" >&2
    return 1
  fi
  printf '%s' "$set"
}

_op_env_add() {
  local set="${1:-}" name="${2:-}" ref="${3:-}"
  _op_envsets_ensure
  set=$(_op_envsets_choose_set "$set") || return 1

  [[ -n "$name" ]] || read -r -p "  Env var name: " name </dev/tty
  if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "❌ Invalid env var name '$name'" >&2; return 1
  fi
  if [[ "$name" == "GITHUB_TOKEN" || "$name" == "GH_TOKEN" ]]; then
    echo "⚠️  $name overrides gh CLI's stored auth for every gh call. Consider GH_PAT instead."
    local ok; read -r -p "  Use it anyway? [y/N] " ok </dev/tty
    [[ "$ok" =~ ^[Yy]$ ]] || return 1
  fi

  [[ -n "$ref" ]] || read -r -p "  1Password reference (op://vault/item/field): " ref </dev/tty
  if [[ ! "$ref" =~ ^op://[^/]+/[^/]+/.+ ]]; then
    echo "❌ Reference must look like op://vault/item/field" >&2; return 1
  fi

  local file; file="$(_op_envsets_dir)/$set.tsv"
  local tmp; tmp=$(mktemp "$(_op_envsets_dir)/.tmp.XXXXXX") || return 1
  { [[ -f "$file" ]] && awk -F'\t' -v n="$name" '$1 != n' "$file"; printf '%s\t%s\n' "$name" "$ref"; } > "$tmp" \
    && chmod 600 "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }

  # Keep an explicit .active list consistent: a brand-new set should load.
  local act; act="$(_op_envsets_dir)/.active"
  if [[ -f "$act" ]] && ! grep -qxF "$set" "$act"; then
    printf '%s\n' "$set" >> "$act"
  fi
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
      [[ -n "$line" ]] && printf '    %-28s %s\n' "$line" "$ref"
    done < "$file"
  done < <(_op_envsets_names)
  [[ $found -eq 1 ]] || echo "No env sets yet. Create one with: op-env add"
}

_op_env_rm() {
  local set="${1:-}" name="${2:-}" file
  if [[ -z "$set" ]]; then
    set=$(_op_envsets_names | _op_envsets_pick "Set:") || return 1
  fi
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
  unset "$name"
  echo "🗑️  Removed $name from $set"
}

_op_env_use() {
  _op_envsets_ensure
  local -a chosen=("$@")
  if [[ ${#chosen[@]} -eq 0 ]]; then
    if command -v fzf &>/dev/null; then
      mapfile -t chosen < <(_op_envsets_names | fzf -m --prompt="Active sets (Tab to multi-select): " --height=40% --reverse)
    else
      read -r -p "  Sets to activate (space-separated; have: $(_op_envsets_names | tr '\n' ' ')): " -a chosen </dev/tty
    fi
  fi
  [[ ${#chosen[@]} -gt 0 ]] || { echo "No change."; return 0; }
  local s
  for s in "${chosen[@]}"; do
    [[ -f "$(_op_envsets_dir)/$s.tsv" ]] || { echo "❌ No such set: $s" >&2; return 1; }
  done
  printf '%s\n' "${chosen[@]}" > "$(_op_envsets_dir)/.active"
  echo "✅ Active sets: ${chosen[*]}"
}

_op_env_help() {
  cat <<'EOF'
op-env — named env sets backed by 1Password references

  op-env add [set] [VAR] [op://ref]   Add or update a key (prompts for the rest)
  op-env list [set]                   Show sets and keys (● active, ○ inactive)
  op-env rm [set] [VAR]               Remove a key
  op-env use [set...]                 Choose active sets (fzf multi-select if omitted)
  op-env help                         This message

Sets (e.g. guild, personal) are stored in config/envsets/<set>.tsv and loaded
by op-load-env alongside OP_SECRETS from config/accounts.sh.
EOF
}

op-env() {
  case "${1:-help}" in
    add)          shift; _op_env_add "$@" ;;
    list|ls)      shift; _op_env_list "$@" ;;
    rm|remove)    shift; _op_env_rm "$@" ;;
    use)          shift; _op_env_use "$@" ;;
    help|-h|--help) _op_env_help ;;
    *) echo "❌ Unknown op-env command: $1" >&2; _op_env_help >&2; return 1 ;;
  esac
}

# Append active sets' entries to OP_SECRETS (skipping names already present),
# so op-load-env and op-clear-env treat them like any other secret.
_op_envsets_merge() {
  local set file name ref existing dup
  while IFS= read -r set; do
    file="$(_op_envsets_dir)/$set.tsv"
    [[ -f "$file" ]] || continue
    while IFS=$'\t' read -r name ref; do
      [[ -n "$name" && -n "$ref" ]] || continue
      dup=0
      for existing in "${OP_SECRETS[@]}"; do
        [[ "${existing%%$'\t'*}" == "$name" ]] && { dup=1; break; }
      done
      [[ $dup -eq 1 ]] || OP_SECRETS+=("$name"$'\t'"$ref")
    done < "$file"
  done < <(_op_envsets_active)
}
