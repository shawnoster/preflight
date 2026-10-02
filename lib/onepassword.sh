#!/usr/bin/env bash
# ~/.preflight/lib/onepassword.sh - 1Password CLI utilities
#
# Generic helpers only: this file knows how to talk to 1Password, not which
# secrets you use. The VAR -> op:// reference lists live in env sets
# (lib/envsets.sh, config/envsets/<set>.tsv); op-load-env asks _op_env_entries
# for them. Nothing here needs editing per install.
#
# Load order: init.sh sources lib/*.sh by glob, and this file relies on sorting after
# a leftover pre-rename lib/1password.sh (digits sort before letters), so that the
# functions below replace that file's same-named ones. Don't rename it to sort earlier.
#
# ── Auth model ───────────────────────────────────────────────────────────────
# These helpers resolve an `op` binary (memoized in OP_BIN) and prefer the
# Windows op.exe when running under WSL. That lets secret reads be authorized by
# the *Windows* 1Password desktop app (Windows Hello / desktop unlock) — so no
# password is typed inside WSL. When op.exe isn't found (native Linux/macOS),
# they fall back to the platform `op` and the manual session-token sign-in.
#
# WSL prerequisites (one-time):
#   • Windows 1Password desktop app → Settings → Developer →
#     "Integrate with 1Password CLI" enabled.
#   • Windows 1Password CLI installed:  winget install AgileBits.1Password.CLI
# Native prerequisites:
#   • op installed, account added:  op account add --shorthand <your-account>
#
# ── Account reference ────────────────────────────────────────────────────────
# Set OP_ACCOUNT in config/accounts.sh:
#   • WSL + desktop op.exe → the sign-in ADDRESS (e.g. my.1password.com). The
#     desktop-fed op.exe does not carry a manual `op account add` shorthand.
#   • Native op → the shorthand you created with `op account add --shorthand`.
OP_ACCOUNT="${OP_ACCOUNT:-my.1password.com}"
# Initialised (not left unset) so these libs also work in a shell running `set -u`.
OP_BIN="${OP_BIN:-}"

# Resolve the op binary once (memoized in OP_BIN). Under WSL, prefer the Windows
# op.exe for desktop-app integration; otherwise use the native op. op.exe is
# only considered under WSL so a stray Windows binary on a native system can't
# be selected by mistake.
_op_resolve_bin() {
  [[ -n "$OP_BIN" ]] && return 0
  local p
  if [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    if command -v op.exe >/dev/null 2>&1; then
      OP_BIN="$(command -v op.exe)"
    else
      for p in /mnt/c/Users/*/AppData/Local/Microsoft/WinGet/Packages/AgileBits.1Password.CLI_*/op.exe \
               /mnt/c/Users/*/AppData/Local/Microsoft/WinGet/Links/op.exe \
               "/mnt/c/Program Files/1Password CLI/op.exe"; do
        [[ -x "$p" ]] && { OP_BIN="$p"; break; }
      done
    fi
  fi
  # Native op (non-WSL, or WSL without op.exe found).
  [[ -z "$OP_BIN" ]] && OP_BIN="$(command -v op 2>/dev/null)"
  [[ -n "$OP_BIN" ]]
}

# Display help for all 1Password commands
op-help() {
  cat <<'EOF'
1Password CLI Utilities
========================

Available Commands:
-------------------

op-help
  Display this help message showing all available 1Password commands.

op-status
  Check if you are currently signed in to 1Password.

op-signin [account]
  Sign in to 1Password. Under WSL desktop integration this triggers the
  Windows desktop unlock; on native op it runs the session-token flow.
  Arguments:
    account - Optional. Account address/shorthand (default: $OP_ACCOUNT)

op-new [--dry-run]
  Interactively create a new 1Password item (login, api-credential, password,
  or secure-note). Prints the op:// reference path(s) when done, ready to
  register with op-env add.
  Options:
    --dry-run  Show the JSON template that would be created (concealed values
               masked), without writing anything

op-import-csv <csv-path> [--vault <vault>] [--tag <tag>] [--dry-run]
              [--has-header] [--no-header] [--columns <spec>]
  Import a CSV of Login items into 1Password. Each row becomes a Login.
  Columns default to: title,url,username,password,notes.
  Secrets are passed via per-row JSON templates (mode 0600) — never via
  command-line args — to keep them out of process args and shell history.
  Options:
    --vault <name>     Destination vault. If omitted, prompts (default:
                       'Private').
    --tag <tag>        Tag to apply to every imported item (repeatable).
    --has-header       Treat row 1 as a header (auto-detected if first
                       cell looks like a title field name).
    --no-header        Force-treat row 1 as data.
    --columns <spec>   Comma list mapping CSV columns to fields. Valid
                       names: title,url,username,password,notes,skip.
                       Default: title,url,username,password,notes
    --dry-run          Show what would be created without calling op.

op-load-env
  Load the active env sets' secrets from 1Password into environment variables.
  Signs in to every account the active sets name, then resolves each account's
  secrets in one `op inject` call (a single-account set is a single call). Under
  WSL the sign-in step triggers the desktop unlock; native op uses the cached
  session. Falls back to per-secret reads for an account whose batch fails.

op-env [add|list|rm|use|migrate]
  Manage named env sets (guild, personal, ...) of VAR -> op:// references.
  This is where the list of secrets lives. Run `op-env help` for details.

op-clear-env
  Unset every variable op-load-env set (and any the active sets define).

Configuration:
--------------
Default account: $OP_ACCOUNT
Set OP_ACCOUNT in config/accounts.sh to override.
EOF
}

# Check if signed in to 1Password
op-status() {
  _op_resolve_bin || { echo "❌ 1Password CLI not found (need op.exe or op on PATH)"; return 1; }
  echo "🔧 op binary: $OP_BIN"
  echo "🔑 account:   $OP_ACCOUNT"
  if "$OP_BIN" whoami --account "$OP_ACCOUNT" >/dev/null 2>&1; then
    echo "✅ Signed in to 1Password ($OP_ACCOUNT)"
    return 0
  elif [[ "$OP_BIN" == *op.exe ]]; then
    echo "ℹ️  No active session — the desktop app will prompt on first secret read"
    return 1
  else
    echo "❌ Not signed in — run op-signin ($OP_ACCOUNT)"
    return 1
  fi
}

# Sign in to 1Password. With the Windows desktop integration there is no session
# token to manage; one authorized call warms the session for this terminal. The
# native op falls back to the manual session-token flow.
op-signin() {
  local account="${1:-$OP_ACCOUNT}"
  _op_resolve_bin || { echo "❌ 1Password CLI not found (need op.exe or op on PATH)"; return 1; }

  if "$OP_BIN" whoami --account "$account" >/dev/null 2>&1; then
    echo "✅ Already signed in to 1Password ($account)"
    return 0
  fi

  echo "🔐 Signing in to 1Password ($account)..."
  if [[ "$OP_BIN" == *op.exe ]]; then
    # Desktop-app integration: trigger Windows Hello / desktop unlock.
    local out
    if out=$("$OP_BIN" vault list --account "$account" 2>&1); then
      echo "✅ 1Password ready ($account)"
      return 0
    fi
    echo "❌ 1Password CLI error:"
    printf '%s\n' "$out" | sed 's/^/   /'
    echo "   Checklist: app running · 'Integrate with 1Password CLI' enabled (Settings → Developer) · OP_ACCOUNT=$account correct · app unlocked."
    return 1
  fi

  # Native CLI: manual session-token flow.
  eval "$("$OP_BIN" signin --account "$account")"
  if "$OP_BIN" whoami --account "$account" >/dev/null 2>&1; then
    echo "✅ Signed in to 1Password ($account)"
    return 0
  else
    echo "❌ Failed to sign in to 1Password"
    return 1
  fi
}

# Variables op-load-env exported last time (newline-separated). Lets the next
# load unset anything that has since been removed from the env sets, and lets
# op-clear-env clear them even if the definition is already gone.
_OP_LOADED_VARS="${_OP_LOADED_VARS:-}"

# Functions to call after op-load-env finishes, whether or not every secret
# loaded. Register with:  _OP_AFTER_LOAD_HOOKS+=(my_function)
declare -p _OP_AFTER_LOAD_HOOKS &>/dev/null || _OP_AFTER_LOAD_HOOKS=()

# Load secrets into environment variables.
#
# This function is data-agnostic: _op_env_entries (lib/envsets.sh) supplies the
# list, one `VAR<TAB>op://ref` line per secret, optionally followed by a
# `TABaccount` column. Nothing here names a particular secret.
#
# `op` resolves a reference against exactly one account per call, so entries are
# grouped by the account they resolve against (their own column, else
# $OP_ACCOUNT) and each group becomes one `op inject` call.
op-load-env() {
  if ! declare -f _op_env_entries >/dev/null; then
    echo "❌ No env source loaded (lib/envsets.sh is missing)"
    return 1
  fi

  local _op_entries _op_names _op_line _op_stale
  _op_entries=$(_op_env_entries)
  _op_names=$(printf '%s\n' "$_op_entries" | cut -f1 | awk 'NF')

  # Anything a previous load set that the sets no longer define is stale: unset
  # it so a removed or deactivated secret can't outlive its definition. This is
  # safe before signing in, since it depends only on the definitions.
  while IFS= read -r _op_stale; do
    [[ -n "$_op_stale" ]] || continue
    grep -qxF -- "$_op_stale" <<< "$_op_names" || unset "$_op_stale"
  done <<< "$_OP_LOADED_VARS"

  # Nothing to load: return before resolving `op` or signing in, so a machine
  # with no secrets configured never triggers a desktop unlock.
  if [[ -z "$_op_names" ]]; then
    _OP_LOADED_VARS=""
    echo "ℹ️  No secrets configured — add one with: op-env add"
    return 0
  fi

  _op_resolve_bin || { echo "❌ 1Password CLI not found (need op.exe or op on PATH)"; return 1; }

  # `op` resolves a reference against exactly one account per call, so a set that
  # names more than one account is resolved as one batch per account. An entry with
  # no account column belongs to $OP_ACCOUNT. First-appearance order, so a
  # single-account set resolves in one call exactly as it always did.
  local _op_accts
  _op_accts=$(printf '%s\n' "$_op_entries" | awk -F'\t' -v def="$OP_ACCOUNT" \
    '{ a = ($3 == "" ? def : $3); if (!(a in seen)) { seen[a] = 1; print a } }')

  # Every account needs a session before anything is exported. Native op fails
  # every read silently without one; op.exe needs its desktop unlock triggered
  # (op-signin does that with `vault list`). Each account is established up front
  # rather than lazily inside the loop below: a sign-in that fails after some
  # accounts loaded would leave the loaded-vars memory describing secrets that
  # only half resolved.
  local _op_acct
  while IFS= read -r _op_acct; do
    [[ -n "$_op_acct" ]] || continue
    "$OP_BIN" whoami --account "$_op_acct" >/dev/null 2>&1 || op-signin "$_op_acct" || return 1
  done <<< "$_op_accts"

  # Only now record what this load manages. If sign-in failed above, the
  # previous list stays, so op-clear-env still knows what is in the environment.
  _OP_LOADED_VARS="$_op_names"

  # No header here — when run under `preflight` the orchestrator prints the
  # "--- Secrets ---" section header. Standalone callers still get the
  # per-secret ✅/⚠️ lines below.

  # Batch resolve each account's secrets in ONE `op inject` call instead of one read
  # per secret. Each op invocation pays a fixed startup + auth round-trip cost (and,
  # under WSL with op.exe, a WSL→Windows process-spawn cost on top), so
  # collapsing N invocations into 1 is the bulk of the speedup. `op inject`
  # reads a template from stdin and substitutes {{ op://… }} references inline.
  # Unlike `op run --env-file -- bash -c …`, it spawns no shell child — so it is
  # safe with op.exe under WSL (the `op run` child would have been a Windows
  # process, not WSL bash). Uses $OP_BIN so op.exe is honored when present.
  #
  # Framing: one `<tag>VAR={{ op://… }}` line per secret, where <tag> is random
  # for this call. A record starts at a line beginning with the tag; any other line
  # is a continuation of the previous value. So a secret whose value contains a
  # newline (even one that looks like `OTHER=x`) stays inside its own record: it
  # cannot forge a boundary, because it can't know the tag, and multi-line values
  # load intact. (A fixed `VAR=` framing let such a value overwrite another secret.)
  # The tag spans the whole load, so the per-account split cannot be used to forge
  # a boundary either.
  local _op_tag
  _op_tag="@@pf$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')${RANDOM}${RANDOM}@@"

  local _op_resolved _op_failed=0 _op_lines _op_label _op_rest _op_ref _op_template
  local _op_name="" _op_val="" _op_have=0 _op_rec
  # Only say which account a secret came from when the load actually spans more than
  # one, so a single-account install's output is unchanged by all of this.
  local _op_multi=0
  if [[ $(printf '%s\n' "$_op_accts" | awk 'NF' | wc -l) -gt 1 ]]; then _op_multi=1; fi

  # Split the output into tagged records (see the framing note above) and export
  # each. _op_pf_flush applies the record collected so far.
  _op_pf_flush() {
    [[ $_op_have -eq 1 ]] || return 0
    if [[ -n "$_op_val" ]]; then
      export "$_op_name"="$_op_val"
      echo "✅ $_op_name${_op_label:+ (via $_op_label)}"
    else
      # Clear any value left from a prior load so a stale/rotated token isn't
      # silently reused (or re-persisted by an after-load hook).
      unset "$_op_name"
      echo "⚠️  $_op_name (failed to load${_op_label:+, via $_op_label})"
      _op_failed=$((_op_failed + 1))
    fi
    _op_have=0; _op_name=""; _op_val=""
  }

  while IFS= read -r _op_acct; do
    [[ -n "$_op_acct" ]] || continue
    # Re-derive this account's entries instead of grouping in the shell: the counts
    # are tiny, and awk keeps the grouping in one readable place (and works the
    # same in bash and zsh, which do not agree on associative arrays).
    _op_lines=$(printf '%s\n' "$_op_entries" | awk -F'\t' -v def="$OP_ACCOUNT" -v want="$_op_acct" \
      '($3 == "" ? def : $3) == want')
    _op_label=""; if [[ $_op_multi -eq 1 ]]; then _op_label="$_op_acct"; fi

    _op_template=""
    while IFS= read -r _op_line; do
      [[ -n "$_op_line" ]] || continue
      # Everything after the first tab is ref, then an optional account column.
      # A two-column line has no second tab, and %% leaves it untouched.
      _op_rest="${_op_line#*$'\t'}"
      _op_ref="${_op_rest%%$'\t'*}"
      _op_template+="${_op_tag}${_op_line%%$'\t'*}={{ ${_op_ref} }}"$'\n'
    done <<< "$_op_lines"

    # `op inject` is all-or-nothing per account: one unresolvable reference fails that
    # account's whole batch. It also exits 0 while substituting an EMPTY value for a
    # reference it could not resolve — seen with --account against a second account
    # under the desktop app, where `op read --account` for the same reference
    # succeeds. So an empty record counts as a failed batch, not as a secret that
    # legitimately resolved to nothing: it sends this account down the per-secret
    # fallback, which re-reads it and reports the broken reference by name. (The
    # other accounts are unaffected — their batches still run.)
    local _op_batch_failed=0 _op_empty=0
    if ! _op_resolved=$(printf '%s' "$_op_template" \
          | "$OP_BIN" inject --account "$_op_acct" 2>/dev/null); then
      _op_batch_failed=1
    else
      _op_empty=$(printf '%s\n' "$_op_resolved" | awk -v t="$_op_tag" \
        'substr($0, 1, length(t)) == t && substr($0, length(t) + 1) ~ /^[^=]*=$/ { c++ } END { print c + 0 }')
      [[ "$_op_empty" -gt 0 ]] && _op_batch_failed=1
    fi

    if [[ $_op_batch_failed -eq 1 ]]; then
      echo "⚠️  Batch resolve failed${_op_label:+ for $_op_label} — falling back to per-secret reads"
      local _op_name2 _op_val2
      while IFS= read -r _op_line; do
        [[ -n "$_op_line" ]] || continue
        _op_name2="${_op_line%%$'\t'*}"
        _op_rest="${_op_line#*$'\t'}"
        _op_ref="${_op_rest%%$'\t'*}"
        # </dev/null: op must not swallow the entries this loop is reading.
        _op_val2="$("$OP_BIN" read --account "$_op_acct" "$_op_ref" 2>/dev/null </dev/null)"
        if [[ -n "$_op_val2" ]]; then
          export "$_op_name2"="$_op_val2"
          echo "✅ $_op_name2${_op_label:+ (via $_op_label)}"
        else
          # Clear any value left from a prior load so a stale/rotated token isn't
          # silently reused (or re-persisted by an after-load hook).
          unset "$_op_name2"
          echo "⚠️  $_op_name2 (failed to load${_op_label:+, via $_op_label})"
          _op_failed=$((_op_failed + 1))
        fi
      done <<< "$_op_lines"
    else
      while IFS= read -r _op_rec; do
        if [[ "$_op_rec" == "$_op_tag"* ]]; then
          _op_pf_flush
          _op_rec="${_op_rec#"$_op_tag"}"
          _op_name="${_op_rec%%=*}"
          _op_val="${_op_rec#*=}"
          _op_have=1
        elif [[ $_op_have -eq 1 ]]; then
          _op_val+=$'\n'"$_op_rec"
        fi
      done <<< "$_op_resolved"
      _op_pf_flush
    fi
  done <<< "$_op_accts"
  unset -f _op_pf_flush

  local _op_hook
  for _op_hook in "${_OP_AFTER_LOAD_HOOKS[@]}"; do
    declare -f "$_op_hook" >/dev/null && "$_op_hook"
  done

  [[ "$_op_failed" -gt 0 ]] && return 1
  return 0
}

# Interactively create a new 1Password item and print its op:// reference path(s)
op-new() {
  # Parse args before authenticating so -h/--help and bad flags don't trigger
  # a sign-in / desktop unlock.
  local dry_run=false
  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry_run=true ;;
      -h|--help)
        echo "Usage: op-new [--dry-run]"
        echo "  Interactively create a 1Password item (login, api-credential,"
        echo "  password, or secure-note). Prints op:// reference paths when done."
        return 0
        ;;
      *)
        echo "❌ Unknown argument: $arg"
        echo "Usage: op-new [--dry-run]"
        return 2
        ;;
    esac
  done

  _op_resolve_bin || { echo "❌ 1Password CLI not found (need op.exe or op on PATH)"; return 1; }
  if ! command -v jq >/dev/null 2>&1; then
    echo "❌ 'jq' is required for op-new (secrets are passed via a JSON template)"
    return 1
  fi
  if ! "$OP_BIN" whoami --account "$OP_ACCOUNT" >/dev/null 2>&1; then
    op-signin "$OP_ACCOUNT" || return 1
  fi

  # Title
  local title
  _pf_ask title "Item title: "
  [[ -z "$title" ]] && { echo "❌ Title required"; return 1; }

  # Vault
  local vault
  _pf_ask vault "Vault [Private]: "
  vault="${vault:-Private}"

  # Type
  echo "Type:"
  echo "  1) login           (username + password)"
  echo "  2) api-credential  (single credential field)"
  echo "  3) password        (password only)"
  echo "  4) secure-note"
  local choice
  _pf_ask choice "Choice [2]: "
  choice="${choice:-2}"

  # Build a JSON template rather than passing secrets as assignment statements:
  # op's own docs warn that assignment-statement values are visible to other
  # processes (e.g. via ps/proc). Secrets live in the template; only
  # --generate-password (not a secret) stays a flag. Mirrors op-import-csv.
  local template gen_password=false
  case "$choice" in
    1)
      local username password
      _pf_ask username "Username (blank = REPLACE_ME): "
      [[ -z "$username" ]] && username="REPLACE_ME"
      _pf_ask -s password "Password (blank = REPLACE_ME, 'generate' = auto-generate): "
      echo
      if [[ "$password" == "generate" ]]; then
        gen_password=true
        template=$(jq -n --arg t "$title" --arg u "$username" \
          '{title:$t, category:"LOGIN",
            fields:[{id:"username",type:"STRING",purpose:"USERNAME",label:"username",value:$u}]}')
      else
        [[ -z "$password" ]] && password="REPLACE_ME"
        template=$(jq -n --arg t "$title" --arg u "$username" --arg p "$password" \
          '{title:$t, category:"LOGIN",
            fields:[{id:"username",type:"STRING",purpose:"USERNAME",label:"username",value:$u},
                    {id:"password",type:"CONCEALED",purpose:"PASSWORD",label:"password",value:$p}]}')
      fi
      ;;
    2)
      local credential
      _pf_ask -s credential "Credential value (blank = REPLACE_ME): "
      echo
      [[ -z "$credential" ]] && credential="REPLACE_ME"
      template=$(jq -n --arg t "$title" --arg c "$credential" \
        '{title:$t, category:"API_CREDENTIAL",
          fields:[{id:"credential",type:"CONCEALED",label:"credential",value:$c}]}')
      ;;
    3)
      local password
      _pf_ask -s password "Password value (blank = REPLACE_ME): "
      echo
      [[ -z "$password" ]] && password="REPLACE_ME"
      template=$(jq -n --arg t "$title" --arg p "$password" \
        '{title:$t, category:"PASSWORD",
          fields:[{id:"password",type:"CONCEALED",purpose:"PASSWORD",label:"password",value:$p}]}')
      ;;
    4)
      local notes
      _pf_ask notes "Notes (optional): "
      template=$(jq -n --arg t "$title" --arg n "$notes" \
        '{title:$t, category:"SECURE_NOTE",
          fields:(if $n != "" then [{id:"notesPlain",type:"STRING",purpose:"NOTES",label:"notesPlain",value:$n}] else [] end)}')
      ;;
    *)
      echo "❌ Invalid choice"
      return 1
      ;;
  esac

  local gen_flag=()
  [[ "$gen_password" == true ]] && gen_flag=(--generate-password)

  if [[ "$dry_run" == true ]]; then
    local extra=""
    [[ "$gen_password" == true ]] && extra=" (--generate-password)"
    echo "Would create in vault '$vault'$extra:"
    # Mask concealed values so secrets never reach the terminal.
    printf '%s\n' "$template" | jq '(.fields[] | select(.type=="CONCEALED") | .value) |= "********"'
    return 0
  fi

  echo "Creating item..."
  local tmpl_file
  tmpl_file=$(mktemp "${TMPDIR:-/tmp}/op-new.XXXXXX") || { echo "❌ could not create temp file"; return 1; }
  chmod 600 "$tmpl_file"
  printf '%s\n' "$template" > "$tmpl_file"

  # Same stdin-vs-template split as op-import-csv: op.exe refuses --template
  # alongside the stdin handle WSL hands it, so feed via `-`; native op uses
  # --template with </dev/null.
  local output rc
  if [[ "$OP_BIN" == *op.exe ]]; then
    output=$("$OP_BIN" item create --account "$OP_ACCOUNT" --vault "$vault" "${gen_flag[@]}" - < "$tmpl_file" 2>&1)
  else
    output=$("$OP_BIN" item create --account "$OP_ACCOUNT" --vault "$vault" "${gen_flag[@]}" --template "$tmpl_file" </dev/null 2>&1)
  fi
  rc=$?

  if command -v shred >/dev/null 2>&1; then
    shred -u "$tmpl_file" 2>/dev/null || rm -f "$tmpl_file"
  else
    rm -f "$tmpl_file"
  fi

  if [[ $rc -ne 0 ]]; then
    echo "❌ Failed to create item:"
    echo "$output"
    return 1
  fi

  echo "✅ Created: $title (vault: $vault)"
  echo ""
  echo "Reference paths — register with op-env add:"
  case "$choice" in
    1)
      echo "  op://$vault/$title/username"
      echo "  op://$vault/$title/password"
      ;;
    2)
      echo "  op://$vault/$title/credential"
      ;;
    3)
      echo "  op://$vault/$title/password"
      ;;
  esac
}

# Import a CSV file as Login items into a 1Password vault.
#
# Default column layout for a typical credentials export:
#   title, url, username, password, notes
#
# Secrets are passed via per-row JSON templates (mode 0600) rather than
# CLI assignment statements, because `op item create` argv is visible to
# other processes and gets logged to shell history.
op-import-csv() {
  _op_resolve_bin || { echo "❌ 1Password CLI not found (need op.exe or op on PATH)"; return 1; }
  if ! command -v jq >/dev/null 2>&1; then
    echo "❌ 'jq' is required for op-import-csv"
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "❌ 'python3' is required for safe CSV parsing"
    return 1
  fi

  local csv_path=""
  local vault=""
  local dry_run=false
  local force_header=""   # "" | "yes" | "no"
  local columns_spec="title,url,username,password,notes"
  local -a tags=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vault)       [[ $# -ge 2 ]] || { echo "❌ --vault requires a value"; return 2; }; vault="$2"; shift 2 ;;
      --vault=*)     vault="${1#*=}"; shift ;;
      --tag)         [[ $# -ge 2 ]] || { echo "❌ --tag requires a value"; return 2; }; tags+=("$2"); shift 2 ;;
      --tag=*)       tags+=("${1#*=}"); shift ;;
      --dry-run)     dry_run=true; shift ;;
      --has-header)  force_header="yes"; shift ;;
      --no-header)   force_header="no"; shift ;;
      --columns)     [[ $# -ge 2 ]] || { echo "❌ --columns requires a value"; return 2; }; columns_spec="$2"; shift 2 ;;
      --columns=*)   columns_spec="${1#*=}"; shift ;;
      -h|--help)
        cat <<'EOF'
op-import-csv <csv-path> [--vault <vault>] [--tag <tag>] [--dry-run]
              [--has-header] [--no-header] [--columns <spec>]

Imports each CSV row as a Login item in 1Password. Default column layout:
  title,url,username,password,notes
Use --columns to remap (valid names: title,url,username,password,notes,skip).
Secrets are passed via temporary JSON templates (chmod 0600), not CLI args.
EOF
        return 0
        ;;
      --) shift; break ;;
      -*)
        echo "❌ Unknown flag: $1"
        return 2
        ;;
      *)
        if [[ -z "$csv_path" ]]; then
          csv_path="$1"
        else
          echo "❌ Unexpected argument: $1"
          return 2
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$csv_path" ]]; then
    echo "Usage: op-import-csv <csv-path> [--vault <vault>] [--tag <tag>] [--dry-run]"
    return 2
  fi
  if [[ ! -f "$csv_path" ]]; then
    echo "❌ CSV not found: $csv_path"
    return 1
  fi

  # Sign-in handled the same way as op-load-env.
  if ! "$OP_BIN" whoami --account "$OP_ACCOUNT" >/dev/null 2>&1; then
    op-signin "$OP_ACCOUNT" || return 1
  fi

  # Resolve destination vault.
  if [[ -z "$vault" ]]; then
    echo "Choose destination vault:"
    echo "  1) Private              (default — your personal vault)"
    echo "  2) Shared               (a shared/team vault)"
    echo "  3) <other>              (type a vault name)"
    local choice
    _pf_ask choice "Choice [1]: "
    case "${choice:-1}" in
      1) vault="Private" ;;
      2) vault="Shared" ;;
      3) _pf_ask vault "Vault name: " ;;
      *) vault="${choice}" ;;  # treat raw input as a vault name
    esac
  fi
  if [[ -z "$vault" ]]; then
    echo "❌ Vault required"
    return 1
  fi

  # Verify the vault exists and we can see it.
  if ! "$OP_BIN" vault get "$vault" --account "$OP_ACCOUNT" </dev/null >/dev/null 2>&1; then
    echo "❌ Vault '$vault' not visible to account '$OP_ACCOUNT'"
    return 1
  fi

  # Validate columns spec.
  # Like the read -a this replaced: one trailing comma is ignored, an empty spec has
  # nothing to validate, and a lone comma is an empty column name, which is rejected.
  local c _cols_in="${columns_spec%,}"
  while [[ -n "$columns_spec" ]] && IFS= read -r c; do
    case "$c" in
      title|url|username|password|notes|skip) ;;
      *)
        echo "❌ Invalid column name '$c' in --columns. Valid: title,url,username,password,notes,skip"
        return 2
        ;;
    esac
  done < <(printf '%s\n' "$_cols_in" | tr ',' '\n')

  # Parse CSV with python's csv module (handles quoted fields, embedded
  # commas/newlines, CRLF, BOMs). Emits one record per row, fields joined by
  # the ASCII unit separator (\x1f) so empty interior fields survive bash's
  # `read` (see the join in the python below). Each output line:
  #   <title>\x1f<url>\x1f<username>\x1f<password>\x1f<notes>
  local parsed
  parsed=$(
    OP_CSV_PATH="$csv_path" \
    OP_CSV_COLS="$columns_spec" \
    OP_CSV_HEADER="$force_header" \
    python3 - <<'PYEOF'
import csv, os, sys

path = os.environ["OP_CSV_PATH"]
cols = os.environ["OP_CSV_COLS"].split(",")
header_mode = os.environ.get("OP_CSV_HEADER", "")  # "", "yes", "no"

# Read with utf-8-sig to strip BOM if present.
with open(path, "r", encoding="utf-8-sig", newline="") as f:
    rows = list(csv.reader(f))

if not rows:
    sys.exit(0)

# Auto-detect header when not forced.
def looks_like_header(row, cols):
    # Header if first cell exactly matches a known column name (case-insensitive).
    if not row:
        return False
    first = row[0].strip().lower()
    return first in {"title", "name", "item", "label"}

if header_mode == "yes":
    rows = rows[1:]
elif header_mode == "no":
    pass
else:
    if rows and looks_like_header(rows[0], cols):
        rows = rows[1:]

slots = ["title", "url", "username", "password", "notes"]
out = []
for r in rows:
    # Skip entirely blank rows.
    if not any((c or "").strip() for c in r):
        continue
    vals = {k: "" for k in slots}
    for i, name in enumerate(cols):
        if name == "skip":
            continue
        if i < len(r):
            vals[name] = r[i]
    # Join with the ASCII unit separator (\x1f), not a tab: bash `read` with
    # IFS=$'\t' treats tab as whitespace and collapses consecutive tabs, which
    # silently drops empty interior fields (e.g. a blank url) and shifts every
    # later column left. \x1f is non-whitespace, so empty fields round-trip.
    line = "\x1f".join((vals[k] or "").replace("\x1f", " ").replace("\r", "")
                     .replace("\n", " ") for k in slots)
    out.append(line)

sys.stdout.write("\n".join(out))
PYEOF
  )
  local parse_rc=$?

  # Distinguish a parser failure (non-zero exit) from a legitimately empty
  # file. Without this, a malformed CSV or read error would leave $parsed empty
  # and get silently reported as "No data rows found" with a success return.
  if [[ $parse_rc -ne 0 ]]; then
    echo "❌ CSV parse failed (python exit $parse_rc) for $csv_path"
    return 1
  fi

  if [[ -z "$parsed" ]]; then
    echo "⚠️  No data rows found in $csv_path"
    return 0
  fi

  local total=0 created=0 failed=0 skipped=0
  local title url username password notes

  # jq filter to build a 1Password Login template safely.
  # Pass tags as a JSON array via --argjson so they round-trip cleanly.
  local tags_json='[]'
  if [[ ${#tags[@]} -gt 0 ]]; then
    tags_json=$(printf '%s\n' "${tags[@]}" | jq -R . | jq -s .)
  fi

  echo ""
  echo "📥 Importing into vault: $vault"
  $dry_run && echo "    (dry-run — no items will be created)"
  echo ""

  while IFS=$'\x1f' read -r title url username password notes; do
    total=$((total + 1))

    if [[ -z "$title" && -z "$username" && -z "$password" ]]; then
      echo "  [$total] (skipped — empty row)"
      skipped=$((skipped + 1))
      continue
    fi

    # Default title if missing.
    if [[ -z "$title" ]]; then
      title="Imported $(date +%Y-%m-%d) #${total}"
    fi

    # Build the template JSON via jq to escape everything safely.
    local template
    template=$(jq -n \
      --arg title "$title" \
      --arg url "$url" \
      --arg username "$username" \
      --arg password "$password" \
      --arg notes "$notes" \
      --argjson tags "$tags_json" \
      '{
         title: $title,
         category: "LOGIN",
         tags: $tags,
         fields: ([
           { id: "username", type: "STRING",    purpose: "USERNAME", label: "username", value: $username },
           { id: "password", type: "CONCEALED", purpose: "PASSWORD", label: "password", value: $password },
           ( if $notes != "" then
               { id: "notesPlain", type: "STRING", purpose: "NOTES", label: "notesPlain", value: $notes }
             else empty end )
         ]),
         urls: ( if $url != "" then [ { label: "website", primary: true, href: $url } ] else [] end )
       }')

    if $dry_run; then
      echo "  [$total] would create: $title"
      [[ -n "$url" ]]      && echo "         url:      $url"
      [[ -n "$username" ]] && echo "         username: $username"
      [[ -n "$password" ]] && echo "         password: ********"
      [[ -n "$notes" ]]    && echo "         notes:    ${notes:0:80}$([[ ${#notes} -gt 80 ]] && echo '…')"
      created=$((created + 1))
      continue
    fi

    # Write template to a 0600 temp file, hand it to `op item create`,
    # then shred/remove it.
    local tmpl_file
    tmpl_file=$(mktemp "${TMPDIR:-/tmp}/op-import.XXXXXX") || {
      echo "  [$total] ❌ FAILED:  $title (could not create temp file)"
      failed=$((failed + 1))
      continue
    }
    chmod 600 "$tmpl_file"
    printf '%s\n' "$template" > "$tmpl_file"

    # op.exe (WSL→Windows) always sees a stdin handle and refuses --template
    # ("cannot create an item from template and stdin at the same time"), so
    # feed the template on stdin via the `-` positional. Native op keeps the
    # --template path (and </dev/null so it never blocks waiting on stdin).
    local op_out op_rc
    if [[ "$OP_BIN" == *op.exe ]]; then
      op_out=$("$OP_BIN" item create \
        --account "$OP_ACCOUNT" \
        --vault "$vault" \
        - < "$tmpl_file" 2>&1)
    else
      op_out=$("$OP_BIN" item create \
        --account "$OP_ACCOUNT" \
        --vault "$vault" \
        --template "$tmpl_file" </dev/null 2>&1)
    fi
    op_rc=$?

    # Best-effort secure delete.
    if command -v shred >/dev/null 2>&1; then
      shred -u "$tmpl_file" 2>/dev/null || rm -f "$tmpl_file"
    else
      rm -f "$tmpl_file"
    fi

    if [[ $op_rc -eq 0 ]]; then
      echo "  [$total] ✅ created: $title"
      created=$((created + 1))
    else
      echo "  [$total] ❌ FAILED:  $title"
      echo "         $(printf '%s' "$op_out" | head -1)"
      failed=$((failed + 1))
    fi
  done <<< "$parsed"

  echo ""
  echo "──────────────────────────────"
  echo "Total rows:  $total"
  if $dry_run; then
    echo "Would create: $created"
  else
    echo "Created:     $created"
  fi
  echo "Skipped:     $skipped"
  echo "Failed:      $failed"
  echo "Vault:       $vault"
  $dry_run && echo "Mode:        dry-run (nothing was sent to 1Password)"
  echo "──────────────────────────────"

  if [[ $failed -gt 0 ]]; then
    return 1
  fi
  return 0
}

# Clear the variables op-load-env set, plus any the active env sets define.
op-clear-env() {
  local _op_names _op_var
  _op_names=$( {
      declare -f _op_env_entries >/dev/null && _op_env_entries | cut -f1
      printf '%s\n' "$_OP_LOADED_VARS"
    } | awk 'NF && !seen[$0]++')
  while IFS= read -r _op_var; do
    [[ -n "$_op_var" ]] && unset "$_op_var"
  done <<< "$_op_names"
  _OP_LOADED_VARS=""
  echo "🧹 Secure environment variables cleared."
}
