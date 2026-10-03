#!/usr/bin/env bash
# lib/config.sh — settings live in $PREFLIGHT_CONFIG_DIR/config.json
#
#   _pf_config_load        read config.json into shell variables (called by init.sh)
#   preflight config ...   path | get KEY | set KEY VALUE | edit | check | help
#
# One table below drives everything: the loader, the built-in defaults, the type
# handling of `config set`, the `check` report, and (via tests/config.sh) the schema
# and shipped profiles. Add a setting by adding a row and a schema entry.
#
# Columns: key | shell variable | type | export | built-in default
#   type    s string, p path, b boolean (1/0), pl path list joined ':', sl list joined ' '
#   export  x = exported, - = shell variable only
# '|' separates the columns, not TAB: `read` collapses runs of whitespace separators,
# which would swallow every empty default.
_PF_CONFIG_TABLE='op.account|OP_ACCOUNT|s|x|my.1password.com
projects.dirs|PROJ_DIRS|pl|x|~/projects:~/work:~/src
aws.default_profile|AWS_PROFILE_DEFAULT|s|x|
git.main_branch|GIT_MAIN_BRANCH|s|x|main
gitea.username|GITEA_USERNAME|s|x|
gitea.host|GITEA_HOST|s|x|
checks.aws|_CHECK_AWS|b|-|1
checks.gh|_CHECK_GH|b|-|1
checks.ssh|_CHECK_SSH|b|-|1
checks.git_config|_CHECK_GIT_CONFIG|b|-|1
optional_env_vars|_OPTIONAL_ENV_VARS|sl|-|
owl.omp_config|OWL_OMP_CONFIG|p|x|$PREFLIGHT_STATE_DIR/owl/theme-catppuccin.omp.json'

# Names the loader has set (not exported). A variable that is already set but is not on
# this list was set by you, and wins over the file. A nested shell inherits the exported
# values but not this list, so it treats them as yours until you open a new terminal.
# Kept across re-sourcing: init.sh sources every lib again on `source ~/.bashrc`, and
# resetting the list then would make every value the loader exported look like yours.
_PF_CONFIG_MANAGED="${_PF_CONFIG_MANAGED:- }"

# ok | missing | nojq | invalid, with the reason in _PF_CONFIG_ERROR. `preflight` reports it.
_PF_CONFIG_STATUS=ok
_PF_CONFIG_ERROR=""

# Expand a leading ~/ or $HOME/ to $HOME/, and a leading $PREFLIGHT_STATE_DIR/ or
# $PREFLIGHT_CONFIG_DIR/ to the resolved directory. Nothing else is expanded. The jq
# filter below does the same (px); tests/config.sh checks they agree. Result in _pf_cfg_out.
_pf_config_expand() {
  local v="$1"
  case "$v" in
    "~/"*)                      v="$HOME/${v#"~/"}" ;;
    '$HOME/'*)                  v="$HOME/${v#'$HOME/'}" ;;
    '$PREFLIGHT_STATE_DIR/'*)   v="${PREFLIGHT_STATE_DIR:-}/${v#'$PREFLIGHT_STATE_DIR/'}" ;;
    '$PREFLIGHT_CONFIG_DIR/'*)  v="${PREFLIGHT_CONFIG_DIR:-}/${v#'$PREFLIGHT_CONFIG_DIR/'}" ;;
  esac
  _pf_cfg_out="$v"
}

# _pf_config_set VAR EXPORT VALUE — the only place a setting becomes a variable.
_pf_config_set() {
  local var="$1" exp="$2" val="$3"
  case "$_PF_CONFIG_MANAGED" in
    *" $var "*) ;;
    *)
      # Portable indirect test (bash's ${!var+x} is a zsh error). Already set by you.
      if eval "[ -n \"\${$var+x}\" ]"; then return 0; fi
      _PF_CONFIG_MANAGED="$_PF_CONFIG_MANAGED$var "
      ;;
  esac
  eval "$var=\$val"
  [[ "$exp" == x ]] && export "$var"
  return 0
}

# Apply the built-in default of every row (no file, no jq, or a file that does not parse).
_pf_config_apply_defaults() {
  local k var type exp def rest part out
  while IFS='|' read -r k var type exp def; do
    [[ -n "$k" ]] || continue
    case "$type" in
      pl)
        out="" rest="$def"
        while [[ -n "$rest" ]]; do
          part="${rest%%:*}"
          if [[ "$rest" == *:* ]]; then rest="${rest#*:}"; else rest=""; fi
          _pf_config_expand "$part"
          out="${out:+$out:}$_pf_cfg_out"
        done
        def="$out" ;;
      p) _pf_config_expand "$def"; def="$_pf_cfg_out" ;;
    esac
    _pf_config_set "$var" "$exp" "$def"
  done <<< "$_PF_CONFIG_TABLE"
}

# The jq program. Input: config.json. Arguments: $t (the table as JSON), $home, $state,
# $cfg. Output: one `_pf_config_set VAR EXPORT VALUE` line per row, shell-quoted with
# @sh, which the loader evaluates. (Parameters are named $ty, not $type: a def parameter
# `type` would shadow jq's builtin of the same name.) A key that is missing, or has the wrong type, takes
# the built-in default for that key alone; it never poisons the others.
_PF_CONFIG_FILTER='
def px: sub("^(~|\\$HOME)/"; $home + "/")
      | sub("^\\$PREFLIGHT_STATE_DIR/"; $state + "/")
      | sub("^\\$PREFLIGHT_CONFIG_DIR/"; $cfg + "/");
def def_of($ty; $d):
  if $ty == "pl" then ($d | split(":") | map(select(length > 0) | px) | join(":"))
  elif $ty == "p" then ($d | px)
  else $d end;
def val_of($ty; $v):
  if $ty == "s" then (if ($v | type) == "string" then $v else error("type") end)
  elif $ty == "p" then (if ($v | type) == "string" then ($v | px) else error("type") end)
  elif $ty == "b" then (if $v == true then "1" elif $v == false then "0" else error("type") end)
  elif $ty == "pl" then (if ($v | type) == "array" then ($v | map(select(type == "string") | px) | join(":")) else error("type") end)
  elif $ty == "sl" then (if ($v | type) == "array" then ($v | map(select(type == "string")) | join(" ")) else error("type") end)
  else error("type") end;
. as $c
| $t[] | . as [$k, $var, $type, $exp, $d]
| (try ($c | getpath($k | split("."))) catch null) as $v
| (def_of($type; $d)) as $dv
| (if $v == null then $dv else (try val_of($type; $v) catch $dv) end) as $val
| "_pf_config_set \($var | @sh) \($exp | @sh) \($val | @sh)"'

# The table as a JSON array of rows, for the filter's $t.
_pf_config_table_json() {
  local k var type exp def out=""
  while IFS='|' read -r k var type exp def; do
    [[ -n "$k" ]] || continue
    out="$out[\"$k\",\"$var\",\"$type\",\"$exp\",\"$def\"],"
  done <<< "$_PF_CONFIG_TABLE"
  _pf_cfg_out="[${out%,}]"
}

_pf_config_file() {
  if [[ -z "${PREFLIGHT_CONFIG_DIR:-}" ]]; then
    source "${PREFLIGHT_DIR:-$HOME/.preflight}/lib/paths.sh" && _pf_resolve_dirs || return 1
  fi
  _pf_cfg_file="$PREFLIGHT_CONFIG_DIR/config.json"
}

# Read config.json into shell variables. Never aborts the shell: a missing file, a
# missing jq, or invalid JSON falls back to the built-in defaults, with a warning for
# the last two (the built-in OP_ACCOUNT is a placeholder, so that must not be silent).
_pf_config_load() {
  local out rc
  _PF_CONFIG_STATUS=ok _PF_CONFIG_ERROR=""
  _pf_config_file || { _pf_config_apply_defaults; return 0; }

  if [[ ! -f "$_pf_cfg_file" ]]; then
    _PF_CONFIG_STATUS=missing
    _PF_CONFIG_ERROR="$_pf_cfg_file does not exist"
  elif ! command -v jq >/dev/null 2>&1; then
    _PF_CONFIG_STATUS=nojq
    _PF_CONFIG_ERROR="jq is not installed, so $_pf_cfg_file was not read"
    echo "⚠️  preflight: jq is not installed — no settings were loaded from $_pf_cfg_file (built-in defaults in use)" >&2
  else
    _pf_config_table_json
    out=$(jq -r --argjson t "$_pf_cfg_out" --arg home "$HOME" \
            --arg state "${PREFLIGHT_STATE_DIR:-}" --arg cfg "${PREFLIGHT_CONFIG_DIR:-}" \
            "$_PF_CONFIG_FILTER" "$_pf_cfg_file" 2>/dev/null)
    rc=$?
    if [[ $rc -eq 0 ]]; then
      # stdout only: nothing jq prints on stderr is ever evaluated as shell.
      eval "$out"
      return 0
    fi
    # Only now, on the failure path, ask jq what is wrong with the file.
    out=$(jq empty "$_pf_cfg_file" 2>&1)
    [[ -n "$out" ]] || out="the settings filter failed (jq exit $rc)"
    _PF_CONFIG_STATUS=invalid
    _PF_CONFIG_ERROR="$_pf_cfg_file: $out"
    echo "⚠️  preflight: could not read $_pf_cfg_file (built-in defaults in use):" >&2
    echo "   ${out%%$'\n'*}" >&2
  fi
  _pf_config_apply_defaults
  return 0
}

# ── preflight config ──────────────────────────────────────────────────────────

# Row for KEY in the table: sets _pf_row_var, _pf_row_type, _pf_row_def. Returns 1 if unknown.
_pf_config_row() {
  local k var type exp def
  while IFS='|' read -r k var type exp def; do
    if [[ "$k" == "$1" ]]; then
      _pf_row_var="$var" _pf_row_type="$type" _pf_row_def="$def"
      return 0
    fi
  done <<< "$_PF_CONFIG_TABLE"
  return 1
}

_pf_config_keys() {
  local k rest
  while IFS='|' read -r k rest; do [[ -n "$k" ]] && printf '  %s\n' "$k"; done <<< "$_PF_CONFIG_TABLE"
}

_pf_config_help() {
  cat <<EOF
Usage: preflight config <command>

  path             Print the settings file ($PREFLIGHT_CONFIG_DIR/config.json)
  get KEY          Print a setting (the built-in default if the file does not set it)
  set KEY VALUE    Write a setting, keeping the others; applies to this shell too
  edit             Open the file in \${VISUAL:-\${EDITOR:-vi}}, then check it
  check            Report invalid JSON, unknown keys and wrongly typed values
  help             Show this help

Keys:
$(_pf_config_keys)

Lists (projects.dirs: ':' separated; optional_env_vars: space separated) and
booleans (true/false, 1/0, yes/no) are written as JSON arrays and booleans.
A variable you have already set in your environment wins over the file.
Reference: docs/config.md
EOF
}

# Report problems with config.json, one per line. Returns the number found.
_pf_config_check() {
  local n=0 out line
  _pf_config_file || return 1
  if [[ ! -f "$_pf_cfg_file" ]]; then
    echo "$_pf_cfg_file does not exist"; return 1
  fi
  command -v jq >/dev/null 2>&1 || { echo "jq is not installed"; return 1; }
  if ! out=$(jq -e . "$_pf_cfg_file" 2>&1 >/dev/null); then
    echo "invalid JSON: ${out%%$'\n'*}"; return 1
  fi
  _pf_config_table_json
  out=$(jq -r --argjson t "$_pf_cfg_out" '
    . as $c
    | ($t | map(.[0] | split("."))) as $kp
    | ([paths(if type == "object" or type == "array" then length == 0 else true end)
          | map(select(type == "string"))
          | select(length > 0)
          | select(. as $p | ($kp | any(. == $p or .[:($p | length)] == $p)) | not)
          | join(".")] | unique | map(select(. != "version" and . != "$schema")) | .[] | "unknown key: \(.)"),
      ($t[] | . as [$k, $var, $type]
        | (try ($c | getpath($k | split("."))) catch null) as $v
        | select($v != null)
        | select(
            (($type == "s" or $type == "p") and ($v | type) != "string")
            or ($type == "b" and ($v | type) != "boolean")
            or (($type == "pl" or $type == "sl") and (($v | type) != "array" or ($v | any(type != "string"))))
          )
        | "wrong type for \($k)")' "$_pf_cfg_file" 2>&1)
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    echo "$line"; n=$((n + 1))
  done <<< "$out"
  return $((n > 0 ? 1 : 0))
}

_pf_config_set_cmd() {
  local key="${1:-}" val="${2-}" file dir tmp base err var
  if [[ $# -lt 2 ]]; then echo "Usage: preflight config set KEY VALUE" >&2; return 1; fi
  if ! _pf_config_row "$key"; then
    echo "preflight config: unknown key '$key'. Keys:" >&2; _pf_config_keys >&2; return 1
  fi
  command -v jq >/dev/null 2>&1 || { echo "preflight config: jq is required" >&2; return 1; }
  _pf_config_file || return 1
  file="$_pf_cfg_file"; dir="${file%/*}"
  mkdir -p "$dir" || return 1

  base='{"version":1}'
  if [[ -f "$file" ]]; then
    if ! jq -e . "$file" >/dev/null 2>&1; then
      echo "preflight config: $file is not valid JSON; fix it (preflight config edit) first. Nothing was changed." >&2
      return 1
    fi
    base=$(cat "$file")
  fi

  tmp=$(mktemp "$dir/.config.XXXXXX") || return 1
  # stderr into $err, stdout into the temp file (order matters: 2>&1 first).
  if ! err=$(printf '%s\n' "$base" | jq --arg key "$key" --arg type "$_pf_row_type" --arg v "$val" '
        setpath($key | split(".");
          if $type == "b" then
            ($v | ascii_downcase
              | if . == "true" or . == "1" or . == "yes" or . == "on" then true
                elif . == "false" or . == "0" or . == "no" or . == "off" then false
                else error("expected true or false") end)
          elif $type == "pl" then ($v | split(":") | map(select(length > 0)))
          elif $type == "sl" then ($v | [splits("[[:space:]]+")] | map(select(length > 0)))
          else $v end)' 2>&1 >"$tmp"); then
    echo "preflight config: could not set $key: ${err%%$'\n'*}" >&2
    rm -f "$tmp"; return 1
  fi
  chmod 644 "$tmp" 2>/dev/null
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  var="$_pf_row_var"
  _pf_config_load
  echo "✅ $key set in $file"
  case "$_PF_CONFIG_MANAGED" in
    *" $var "*) ;;
    *) echo "   Note: this shell keeps the \$$var you set outside the file; a new terminal picks up the file's value." >&2 ;;
  esac
}

_pf_config_cmd() {
  local sub="${1:-help}"
  case "$sub" in
    path)   _pf_config_file && printf '%s\n' "$_pf_cfg_file" ;;
    get)
      [[ -n "${2:-}" ]] || { echo "Usage: preflight config get KEY" >&2; return 1; }
      _pf_config_row "$2" || { echo "preflight config: unknown key '$2'" >&2; return 1; }
      _pf_config_file || return 1
      local got=""
      if [[ -f "$_pf_cfg_file" ]] && command -v jq >/dev/null 2>&1; then
        got=$(jq -r --arg key "$2" 'getpath($key | split(".")) // empty
                | if type == "array" then join(" ") else tostring end' "$_pf_cfg_file" 2>/dev/null)
      fi
      if [[ -n "$got" ]] || { [[ -f "$_pf_cfg_file" ]] && jq -e --arg key "$2" 'getpath($key | split(".")) != null' "$_pf_cfg_file" >/dev/null 2>&1; }; then
        printf '%s\n' "$got"
      else
        printf '%s\n' "$_pf_row_def"
      fi ;;
    set)    _pf_config_set_cmd "${@:2}" ;;
    edit)
      _pf_config_file || return 1
      [[ -f "$_pf_cfg_file" ]] || { echo "preflight config: $_pf_cfg_file does not exist" >&2; return 1; }
      # eval so a multi-word editor ("code --wait") splits in zsh too.
      eval "${VISUAL:-${EDITOR:-vi}} \"\$_pf_cfg_file\""
      _pf_config_check || echo "⚠️  Fix the problems above; settings load with built-in defaults until you do." >&2
      _pf_config_load ;;
    check)
      if _pf_config_check; then _pf_config_file; echo "✅ $_pf_cfg_file is valid"; else return 1; fi ;;
    help|-h|--help) _pf_config_help ;;
    *) echo "preflight config: unknown command '$sub'" >&2; _pf_config_help >&2; return 1 ;;
  esac
}
