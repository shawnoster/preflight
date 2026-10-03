#!/usr/bin/env bash
# ~/.preflight/lib/envsets.sh - Named sets of env vars backed by 1Password refs
#
# This is the only place that says WHICH secrets get loaded; lib/onepassword.sh
# just resolves whatever _op_env_entries hands it.
#
# A "set" is a named group of VAR -> op:// references (guild, personal, ...).
# Sets live in $PREFLIGHT_CONFIG_DIR/envsets/<set>.tsv (outside the clone, per-install), one
# `VAR<TAB>op://vault/item/field` line each. Active sets are listed in
# envsets/.active (absent = every set is active). Hand-editing a .tsv
# is fine.
#
# A line may carry a third column naming the 1Password account that holds the
# reference, so one set can span accounts (`op` resolves a reference against
# exactly one account per call, so the loader batches per account). The column
# is optional and defaults to $OP_ACCOUNT, which is why two-column lines — every
# line written before this existed — keep working untouched.
#
# Usage:
#   op-env add [set] [VAR] [op://ref] [account]   add/update a key (prompts for a missing set, VAR or ref — never the account)
#   op-env list [set]                   show sets and their keys
#   op-env rm [set] [VAR]               remove a key (fzf picker if omitted)
#   op-env use [set...]                 choose which sets op-load-env loads
#   op-env help

_op_envsets_dir() {
  # lib/paths.sh resolves the config dir; init.sh normally has already. Never build
  # a path from an empty value, which would point at /envsets.
  if [[ -z "${PREFLIGHT_CONFIG_DIR:-}" ]]; then
    source "${PREFLIGHT_DIR:-$HOME/.preflight}/lib/paths.sh" && _pf_resolve_dirs || return 1
  fi
  printf '%s' "$PREFLIGHT_CONFIG_DIR/envsets"
}

_op_envsets_ensure() {
  local d; d=$(_op_envsets_dir)
  [[ -d "$d" ]] || { mkdir -p "$d" && chmod 700 "$d"; }
}

# A reference must look like op://vault/item/field (an item may have a section, so
# more segments are fine). One definition, used by add and the loader.
_OP_REF_RE='^op://[^/]+/[^/]+/.+'
_op_envsets_valid_ref() { [[ "$1" =~ $_OP_REF_RE ]]; }

# An account is a sign-in address ("my-team.1password.com") under WSL desktop
# integration, or an `op account add` shorthand ("work") on native op — either way
# an unquoted word of letters, digits, dots, dashes and underscores.
_OP_ACCT_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
_op_envsets_valid_acct() { [[ "$1" =~ $_OP_ACCT_RE ]]; }

# The account column of the first line a set file gives VAR, verbatim — "" both when
# there is no line and when the line has no account column, which are different
# situations: "keep the default" versus "do not touch what is already there".
# Usage: _op_envsets_acct_of FILE VAR
_op_envsets_acct_of() {
  [[ -f "$1" ]] || return 0
  tr -d '\r' < "$1" | awk -F'\t' -v n="$2" '$1 == n { print $3; exit }'
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

# Write VAR<TAB>ref lines (read from stdin) into a set as ONE all-or-nothing change.
# The new set file and, when a brand-new set must be added to an explicit .active
# list, the new .active are both staged first and only then moved into place; if the
# second move fails the first is rolled back. A problem is detected before anything
# is touched where it can be (an unwritable .active), so a failure never leaves a
# half-created set that the loader would ignore.
# Editing a set the user deliberately deactivated does not reactivate it.
# Usage: printf 'VAR\tref\n' | _op_envsets_write set
_op_envsets_write() {
  local set="$1" dir file act lines names
  local tmp="" tmpa="" bak="" is_new=0 need_act=0
  dir=$(_op_envsets_dir); file="$dir/$set.tsv"; act="$dir/.active"
  lines=$(cat)
  [[ -n "$lines" ]] || return 0
  _op_envsets_ensure
  names=$(printf '%s\n' "$lines" | cut -f1)

  [[ -f "$file" ]] || is_new=1
  if [[ $is_new -eq 1 && -f "$act" ]] && ! tr -d '\r' < "$act" | grep -qxF -- "$set"; then
    need_act=1
    if [[ ! -w "$act" ]]; then
      echo "❌ Can't activate set '$set': $act is not writable. Nothing was changed." >&2
      echo "   Fix the file's permissions, or run: op-env use" >&2
      return 1
    fi
  fi

  tmp=$(mktemp "$dir/.tmp.XXXXXX") || return 1
  {
    # ENVIRON, not -v: a value holding newlines is rejected by some awks (mawk).
    [[ -f "$file" ]] && PF_NAMES="$names" awk -F'\t' \
      'BEGIN { n = split(ENVIRON["PF_NAMES"], a, "\n"); for (i = 1; i <= n; i++) skip[a[i]] = 1 } !($1 in skip)' "$file"
    printf '%s\n' "$lines"
  } > "$tmp" && chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }

  if [[ $need_act -eq 1 ]]; then
    tmpa=$(mktemp "$dir/.tmp.XXXXXX") || { rm -f "$tmp"; return 1; }
    { cp -p "$act" "$tmpa" \
      && { [[ -z "$(tail -c1 "$tmpa")" ]] || printf '\n' >> "$tmpa"; } \
      && printf '%s\n' "$set" >> "$tmpa"; } || { rm -f "$tmp" "$tmpa"; return 1; }
  fi

  if [[ -f "$file" ]]; then
    bak=$(mktemp "$dir/.tmp.XXXXXX") && cp -p "$file" "$bak" || { rm -f "$tmp" "$tmpa" "$bak"; return 1; }
  fi
  if ! mv "$tmp" "$file"; then
    rm -f "$tmp" "$tmpa" "$bak"; return 1
  fi
  if [[ $need_act -eq 1 ]] && ! mv "$tmpa" "$act"; then
    # Roll back the set file so we leave exactly what was there before.
    if [[ -n "$bak" ]]; then mv "$bak" "$file"; bak=""; else rm -f "$file"; fi
    rm -f "$tmpa" "$bak"
    echo "❌ Could not activate set '$set' (replacing $act failed). Nothing was changed." >&2
    return 1
  fi
  rm -f "$bak"
}

# Write (or replace) one VAR -> ref line in a set, creating the set if needed. The
# account column is written only when given, so updating a reference never rewrites
# a two-column line into three.
# Usage: _op_envsets_put set VAR ref [account]
_op_envsets_put() {
  local line="$2"$'\t'"$3"
  if [[ -n "${4:-}" ]]; then line+=$'\t'"$4"; fi
  printf '%s\n' "$line" | _op_envsets_write "$1"
}

_op_env_add() {
  local set="${1:-}" name="${2:-}" ref="${3:-}" acct="${4:-}"
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
  if ! _op_envsets_valid_ref "$ref"; then
    echo "❌ Reference must look like op://vault/item/field" >&2; return 1
  fi

  # The account is an optional 4th argument and is never prompted for: it is rare
  # enough that a prompt would make every add cost an extra Enter, and `add` does
  # no 1Password I/O to infer it from. Left out on an update, it keeps whatever the
  # line already said — changing a reference must not quietly move the secret to
  # another account, or to the default one.
  if [[ -z "$acct" ]]; then
    acct=$(_op_envsets_acct_of "$(_op_envsets_dir)/$set.tsv" "$name")
  fi
  if [[ -n "$acct" ]] && ! _op_envsets_valid_acct "$acct"; then
    echo "❌ Invalid account '$acct' (letters, digits, dots, dashes and underscores)" >&2; return 1
  fi

  _op_envsets_put "$set" "$name" "$ref" "$acct" || return 1
  echo "✅ [$set] $name -> $ref"
  [[ -n "$acct" ]] && echo "   account: $acct"
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
    while IFS=$'\t' read -r line ref acct; do
      ref=${ref%$'\r'}
      acct=${acct%$'\r'}
      [[ -n "$line" ]] || continue
      # The account only when it differs from the default, so a single-account
      # install's output is unchanged by this feature.
      if [[ -n "$acct" && "$acct" != "${OP_ACCOUNT:-}" ]]; then
        printf '    %-28s %s  [account: %s]\n' "$line" "$ref" "$acct"
      else
        printf '    %-28s %s\n' "$line" "$ref"
      fi
    done < "$file"
  done < <(_op_envsets_names)
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

_op_env_help() {
  cat <<'EOF'
op-env manages named env sets backed by 1Password references.

  op-env add [set] [VAR] [op://ref] [account]   Add or update a key (prompts for a missing set/VAR/ref)
  op-env list [set]                   Show sets and keys (● active, ○ inactive)
  op-env rm [set] [VAR]               Remove a key
  op-env use [set...]                 Choose active sets (fzf multi-select if omitted)
  op-env help                         This message

Sets (e.g. guild, personal) are stored in envsets/<set>.tsv, one
`VAR<TAB>op://vault/item/field` per line, and are the only list of secrets
op-load-env and op-clear-env use.

A line may add a third TAB-separated column: the 1Password account that holds the
reference (a sign-in address like my-team.1password.com, or an `op account add`
shorthand). Leave it out to use $OP_ACCOUNT. Use it when a reference lives in a
different account than your other secrets — op resolves each reference against one
account per call, so op-load-env batches one `op inject` per account:

  op-env add guild ATLASSIAN_TOKEN op://Employee/Some\ Item/credential my-team.1password.com

Re-adding a key without an account keeps the one already on the line.
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

# Everything op-load-env / op-clear-env need to know: one `VAR<TAB>op://ref` line
# per secret, from the active sets, carrying an optional third `TABaccount` column
# when the set names one (otherwise $OP_ACCOUNT). The first definition of a name wins (sets are read
# in the order of envsets/.active, or alphabetically when that file is absent);
# anything that isn't a valid variable name, an op:// reference, or a well-formed
# account is dropped. CRs are stripped so a set edited on Windows (CRLF) still
# resolves.
#
# Lines are passed through as written, so a two-column line stays two columns: the
# loader distinguishes the shapes, and a set with no account column reads exactly as
# it did before this existed.
_op_env_entries() {
  local set file
  {
    while IFS= read -r set; do
      _op_envsets_valid_name "$set" || continue
      file="$(_op_envsets_dir)/$set.tsv"
      [[ -f "$file" ]] && awk 1 "$file"
    done < <(_op_envsets_active)
  } | tr -d '\r' | awk -F'\t' -v re="$_OP_REF_RE" -v acre="$_OP_ACCT_RE" \
      'NF <= 3 && $1 ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && $2 ~ re && ($3 == "" || $3 ~ acre) && !seen[$1]++'
}
