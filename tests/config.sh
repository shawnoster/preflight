#!/usr/bin/env bash
# tests/config.sh - config.json loader, `preflight config`, and table/schema/profile drift.
#
#   tests/config.sh            run under bash, and under zsh if it is installed
#
# HOME and the config/state directories are redirected to a scratch dir, so nothing real
# is read or written. The libraries are sourced from both shells in real use, so this
# runs the same checks in each.

if [[ -z "${PF_TEST_INNER:-}" ]]; then
  repo=$(cd "$(dirname "$0")/.." && pwd)
  rc=0
  for sh in bash zsh; do
    command -v "$sh" >/dev/null 2>&1 || { echo "== $sh: not installed, skipped"; continue; }
    echo "== $sh"
    PF_TEST_INNER=1 PF_REPO="$repo" PF_SHELL="$sh" "$sh" "$0" || rc=1
  done
  exit $rc
fi

# ── inner: runs in the shell under test ───────────────────────────────────────
R="$PF_REPO"
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
fails=0 passes=0
chk() { if eval "$2"; then passes=$((passes + 1)); else fails=$((fails + 1)); echo "FAIL: $1"; fi; }

export HOME="$T/home" PREFLIGHT_DIR="$R" PREFLIGHT_CONFIG_DIR="$T/cfg" PREFLIGHT_STATE_DIR="$T/state"
mkdir -p "$HOME" "$PREFLIGHT_CONFIG_DIR"
CFG="$PREFLIGHT_CONFIG_DIR/config.json"
source "$R/lib/paths.sh"
source "$R/lib/config.sh"

MANAGED="OP_ACCOUNT PROJ_DIRS AWS_PROFILE_DEFAULT GIT_MAIN_BRANCH GITEA_USERNAME GITEA_HOST _CHECK_AWS _CHECK_GH _CHECK_SSH _CHECK_GIT_CONFIG _OPTIONAL_ENV_VARS OWL_OMP_CONFIG"
# Forget every setting, as a brand-new shell would see it.
reset() {
  local v
  for v in $MANAGED; do unset "$v"; done
  _PF_CONFIG_MANAGED=" "
}
# Quiet load; warnings from the loader land in $warn.
load() { warn=$(_pf_config_load 2>&1 >/dev/null); _pf_config_load >/dev/null 2>&1; }
put() { printf '%s\n' "$1" > "$CFG"; }

# ── no library assigns a setting at load time ─────────────────────────────────
# A value assigned while the libs load looks like one you set, so config.json could
# never change it (this caught OP_ACCOUNT and OWL_OMP_CONFIG defaults).
reset
for f in "$R"/lib/*.sh; do source "$f" >/dev/null 2>&1; done
leaked=""
for v in $MANAGED; do eval "[ -n \"\${$v+x}\" ]" && leaked="$leaked $v"; done
chk "sourcing the libs sets no config variable:$leaked" '[[ -z "$leaked" ]]'
reset

# ── built-in defaults (no file) ───────────────────────────────────────────────
reset; rm -f "$CFG"; _pf_config_load
chk "no file: status is missing"            '[[ "$_PF_CONFIG_STATUS" == missing ]]'
chk "no file: built-in OP_ACCOUNT"          '[[ "$OP_ACCOUNT" == my.1password.com ]]'
chk "no file: PROJ_DIRS expanded"           '[[ "$PROJ_DIRS" == "$HOME/projects:$HOME/work:$HOME/src" ]]'
chk "no file: checks default to 1"          '[[ "$_CHECK_AWS" == 1 && "$_CHECK_GIT_CONFIG" == 1 ]]'
chk "no file: OWL_OMP_CONFIG is the bundled theme" '[[ "$OWL_OMP_CONFIG" == "$PREFLIGHT_STATE_DIR/owl/theme-catppuccin.omp.json" ]]'
fallback_dump=$(for v in $MANAGED; do eval "printf '%s=%s\n' $v \"\$$v\""; done)

# The jq path must give the same values as the shell fallback for an empty object.
reset; put '{}'; _pf_config_load
jq_dump=$(for v in $MANAGED; do eval "printf '%s=%s\n' $v \"\$$v\""; done)
chk "jq defaults equal shell fallback defaults" '[[ "$jq_dump" == "$fallback_dump" ]]'
chk "empty object: status ok" '[[ "$_PF_CONFIG_STATUS" == ok ]]'

# ── a profile ─────────────────────────────────────────────────────────────────
reset; cp "$R/defaults/config.company.json" "$CFG"; _pf_config_load
chk "company: list joined with :"           '[[ "$PROJ_DIRS" == "$HOME/projects:$HOME/work:$HOME/src" ]]'
chk "company: string value"                 '[[ "$AWS_PROFILE_DEFAULT" == my-dev-profile ]]'
chk "company: optional_env_vars joined with space" '[[ "$_OPTIONAL_ENV_VARS" == NPM_TOKEN ]]'
chk "company: true -> 1"                    '[[ "$_CHECK_AWS" == 1 ]]'
reset; cp "$R/defaults/config.general.json" "$CFG"; _pf_config_load
chk "general: false -> 0"                   '[[ "$_CHECK_AWS" == 0 ]]'
chk "general: empty list -> empty string"   '[[ -z "$_OPTIONAL_ENV_VARS" ]]'
chk "general: OWL_OMP_CONFIG expanded from \$PREFLIGHT_STATE_DIR" '[[ "$OWL_OMP_CONFIG" == "$PREFLIGHT_STATE_DIR/owl/theme-catppuccin.omp.json" ]]'
chk "exported: OP_ACCOUNT"                  '$PF_SHELL -c '"'"'[ -n "$OP_ACCOUNT" ]'"'"' 2>/dev/null'
chk "not exported: _CHECK_AWS"              '! $PF_SHELL -c '"'"'[ -n "${_CHECK_AWS+x}" ]'"'"''

# ── value handling ────────────────────────────────────────────────────────────
reset; put '{"op":{"account":"it'"'"'s \"x\" $(echo no)"},"projects":{"dirs":["~/a","$HOME/b","/c","$OTHER/d"]},"optional_env_vars":["A","B"],"git":{"main_branch":"trunk"}}'
_pf_config_load
chk "quotes, apostrophes and \$() survive verbatim" '[[ "$OP_ACCOUNT" == "it'"'"'s \"x\" \$(echo no)" ]]'
chk "path expansion: ~/, \$HOME/, absolute; other \$VAR untouched" '[[ "$PROJ_DIRS" == "$HOME/a:$HOME/b:/c:\$OTHER/d" ]]'
chk "space-joined list"                     '[[ "$_OPTIONAL_ENV_VARS" == "A B" ]]'
chk "other keys fall back to defaults"      '[[ "$_CHECK_SSH" == 1 && -z "$GITEA_HOST" ]]'

# A wrong-typed key takes its default alone.
reset; put '{"op":{"account":"acct"},"checks":{"aws":"yes"},"projects":{"dirs":"nope"},"git":"flat"}'
_pf_config_load
chk "wrong type: status still ok"           '[[ "$_PF_CONFIG_STATUS" == ok ]]'
chk "wrong type: bad bool -> default"       '[[ "$_CHECK_AWS" == 1 ]]'
chk "wrong type: bad list -> default"       '[[ "$PROJ_DIRS" == "$HOME/projects:$HOME/work:$HOME/src" ]]'
chk "wrong type: bad parent -> default"     '[[ "$GIT_MAIN_BRANCH" == main ]]'
chk "wrong type: good keys still load"      '[[ "$OP_ACCOUNT" == acct ]]'

# ── bad file, missing jq ──────────────────────────────────────────────────────
reset; printf '{ not json' > "$CFG"
warn=$(_pf_config_load 2>&1 >/dev/null); reset; _pf_config_load 2>/dev/null
chk "invalid JSON: warns with the path"     '[[ "$warn" == *"$CFG"* ]]'
chk "invalid JSON: status invalid, defaults in use" '[[ "$_PF_CONFIG_STATUS" == invalid && "$OP_ACCOUNT" == my.1password.com ]]'
chk "invalid JSON: error recorded for preflight"   '[[ -n "$_PF_CONFIG_ERROR" ]]'

reset; cp "$R/defaults/config.company.json" "$CFG"
mkdir -p "$T/empty"; OLDPATH=$PATH; PATH="$T/empty"
warn=$(_pf_config_load 2>&1 >/dev/null); reset; _pf_config_load 2>/dev/null
PATH=$OLDPATH
chk "no jq: warns that no settings were loaded" '[[ "$warn" == *"jq is not installed"* ]]'
chk "no jq: status nojq, built-in defaults"     '[[ "$_PF_CONFIG_STATUS" == nojq && "$AWS_PROFILE_DEFAULT" == "" ]]'

# ── environment wins, and reloads ─────────────────────────────────────────────
reset; put '{"op":{"account":"from-file"},"git":{"main_branch":"file-branch"}}'
OP_ACCOUNT=from-env; export OP_ACCOUNT
_pf_config_load
chk "env wins over the file"                '[[ "$OP_ACCOUNT" == from-env ]]'
chk "other keys still load"                 '[[ "$GIT_MAIN_BRANCH" == file-branch ]]'
put '{"op":{"account":"edited"},"git":{"main_branch":"edited-branch"}}'
_pf_config_load
chk "reload: user-set value stays"          '[[ "$OP_ACCOUNT" == from-env ]]'
chk "reload: loader-set value follows the file" '[[ "$GIT_MAIN_BRANCH" == edited-branch ]]'
put '{"op":{"account":"edited"}}'
_pf_config_load
chk "key removed from the file -> built-in default" '[[ "$GIT_MAIN_BRANCH" == main ]]'
reset; GITEA_HOST=""; put '{"gitea":{"host":"h"}}'; _pf_config_load
chk "a user-set empty value still wins"     '[[ -z "$GITEA_HOST" ]]'

# Nested shell: inherits exported values, not the managed list.
reset; put '{"git":{"main_branch":"v1"}}'; _pf_config_load
put '{"git":{"main_branch":"v2"}}'
child=$(PF_R="$R" "$PF_SHELL" -c 'source "$PF_R/lib/paths.sh"; source "$PF_R/lib/config.sh"; _pf_config_load; printf %s "$GIT_MAIN_BRANCH"' 2>/dev/null)
chk "nested shell keeps the inherited value" '[[ "$child" == v1 ]]'
fresh_shell=$(env -u GIT_MAIN_BRANCH PF_R="$R" "$PF_SHELL" -c 'source "$PF_R/lib/paths.sh"; source "$PF_R/lib/config.sh"; _pf_config_load; printf %s "$GIT_MAIN_BRANCH"' 2>/dev/null)
chk "a fresh shell picks up the edited file" '[[ "$fresh_shell" == v2 ]]'

# ── preflight config ──────────────────────────────────────────────────────────
reset; cp "$R/defaults/config.company.json" "$CFG"; _pf_config_load
chk "config path"                           '[[ "$(_pf_config_cmd path)" == "$CFG" ]]'
chk "config get string"                     '[[ "$(_pf_config_cmd get aws.default_profile)" == my-dev-profile ]]'
chk "config get list"                       '[[ "$(_pf_config_cmd get projects.dirs)" == "~/projects ~/work ~/src" ]]'
chk "config get falls back to the default"  'jq "del(.git)" "$CFG" > "$T/x" && mv "$T/x" "$CFG"; [[ "$(_pf_config_cmd get git.main_branch)" == main ]]'
chk "config get unknown key fails"          '! _pf_config_cmd get nope.key 2>/dev/null'

reset; cp "$R/defaults/config.company.json" "$CFG"; _pf_config_load
_pf_config_cmd set git.main_branch develop >/dev/null
chk "set string"                            '[[ "$(jq -r .git.main_branch "$CFG")" == develop ]]'
chk "set preserves other keys"              '[[ "$(jq -r .aws.default_profile "$CFG")" == my-dev-profile && "$(jq -r .version "$CFG")" == 1 ]]'
chk "set applies to this shell"             '[[ "$GIT_MAIN_BRANCH" == develop ]]'
_pf_config_cmd set checks.aws no >/dev/null
chk "set bool writes a JSON boolean"        '[[ "$(jq -c .checks.aws "$CFG")" == false && "$_CHECK_AWS" == 0 ]]'
_pf_config_cmd set projects.dirs "~/x:~/y" >/dev/null
chk "set list writes a JSON array"          '[[ "$(jq -c .projects.dirs "$CFG")" == "[\"~/x\",\"~/y\"]" ]]'
_pf_config_cmd set optional_env_vars "A  B" >/dev/null
chk "set space list writes a JSON array"    '[[ "$(jq -c .optional_env_vars "$CFG")" == "[\"A\",\"B\"]" ]]'
_pf_config_cmd set optional_env_vars "" >/dev/null
chk "set empty list writes []"              '[[ "$(jq -c .optional_env_vars "$CFG")" == "[]" ]]'
before=$(cat "$CFG")
out=$(_pf_config_cmd set checks.aws maybe 2>&1); rc=$?
chk "set rejects a bad boolean, file unchanged" '[[ $rc -ne 0 && "$(cat "$CFG")" == "$before" ]]'
out=$(_pf_config_cmd set not.a.key x 2>&1); rc=$?
chk "set rejects an unknown key"            '[[ $rc -ne 0 && "$out" == *"unknown key"* && "$(cat "$CFG")" == "$before" ]]'
chk "set leaves no temp files"              '[[ -z "$(find "$PREFLIGHT_CONFIG_DIR" -maxdepth 1 -name ".config.*")" ]]'
printf '{ broken' > "$CFG"
out=$(_pf_config_cmd set git.main_branch x 2>&1); rc=$?
chk "set refuses invalid JSON and leaves it alone" '[[ $rc -ne 0 && "$(cat "$CFG")" == "{ broken" ]]'
rm -f "$CFG"; reset
_pf_config_cmd set op.account fresh.1password.com >/dev/null
chk "set creates a missing file with version 1" '[[ "$(jq -r .version "$CFG")" == 1 && "$OP_ACCOUNT" == fresh.1password.com ]]'

# check
put '{"$schema":"x","version":1,"op":{"account":"a","typo":"b"},"checks":{"aws":"yes"},"projcts":{"dirs":[]}}'
out=$(_pf_config_check); rc=$?
chk "check ignores \$schema and version"   '[[ "$out" != *schema* && "$out" != *version* ]]'
chk "check reports unknown keys"            '[[ $rc -ne 0 && "$out" == *"unknown key: op.typo"* && "$out" == *"unknown key: projcts"* ]]'
chk "check reports a wrong type"            '[[ "$out" == *"wrong type for checks.aws"* ]]'
cp "$R/defaults/config.company.json" "$CFG"
chk "check passes a shipped profile"        '_pf_config_check >/dev/null'
printf 'nope' > "$CFG"
chk "check reports invalid JSON"            'out=$(_pf_config_check); [[ "$out" == "invalid JSON"* ]]'

# edit runs the editor on the file, then checks
cp "$R/defaults/config.company.json" "$CFG"
EDITOR="true" VISUAL="" _pf_config_cmd edit >/dev/null 2>&1
chk "edit runs the editor (VISUAL empty -> EDITOR)" '[[ $? -eq 0 ]]'

# ── table / schema / profiles cannot drift ────────────────────────────────────
SCHEMA="$R/defaults/config.schema.json"
schema_rows=$(jq -r 'def w($p): to_entries[] | . as $e | if $e.value.type == "object" then ($e.value.properties | w($p + $e.key + ".")) else "\($p + $e.key)|\($e.value.type)|\($e.value.default | if type == "array" then join("\u0001") else tostring end)" end;
  .properties | del(.version, ."$schema") | w("")' "$SCHEMA" | sort)
table_keys=$(while IFS='|' read -r k rest; do [[ -n "$k" ]] && echo "$k"; done <<< "$_PF_CONFIG_TABLE" | sort)
schema_keys=$(printf '%s\n' "$schema_rows" | cut -d'|' -f1)
chk "table keys == schema properties"       '[[ "$table_keys" == "$schema_keys" ]]'

bad=""
while IFS='|' read -r k var type exp def; do
  [[ -n "$k" ]] || continue
  row=$(printf '%s\n' "$schema_rows" | grep -F "$k|" | head -1)
  stype=$(printf '%s' "$row" | cut -d'|' -f2); sdef=$(printf '%s' "$row" | cut -d'|' -f3-)
  case "$type" in
    s|p)  want=string ;;
    b)    want=boolean ;;
    pl|sl) want=array ;;
  esac
  [[ "$stype" == "$want" ]] || bad="$bad $k(type)"
  case "$type" in
    b)  [[ "$sdef" == "true" && "$def" == 1 || "$sdef" == "false" && "$def" == 0 ]] || bad="$bad $k(default)" ;;
    pl) [[ "$(printf '%s' "$sdef" | tr '\001' ':')" == "$def" ]] || bad="$bad $k(default)" ;;
    sl) [[ "$(printf '%s' "$sdef" | tr '\001' ' ')" == "$def" ]] || bad="$bad $k(default)" ;;
    *)  [[ "$sdef" == "$def" ]] || bad="$bad $k(default)" ;;
  esac
  # The '|' column separator and JSON building assume plain values.
  case "$k$var$type$exp$def" in *\"*|*\\*) bad="$bad $k(unsafe char)" ;; esac
done <<< "$_PF_CONFIG_TABLE"
chk "table types and defaults match the schema:$bad" '[[ -z "$bad" ]]'

for prof in "$R"/defaults/config.*.json; do
  case "$prof" in *schema*) continue ;; esac
  cp "$prof" "$CFG"
  chk "profile $(basename "$prof") passes check" '_pf_config_check >/dev/null'
done

echo "$passes passed, $fails failed"
[[ $fails -eq 0 ]]
