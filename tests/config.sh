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
source "$R/lib/prompt.sh"
source "$R/lib/config.sh"

MANAGED="OP_ACCOUNT PROJ_DIRS AWS_PROFILE_DEFAULT GIT_MAIN_BRANCH _CHECK_AWS _CHECK_GH _CHECK_SSH _CHECK_GIT_CONFIG OWL_OMP_CONFIG PREFLIGHT_PLUGINS"
# Forget every setting, as a brand-new shell would see it.
reset() {
  local v
  for v in $(echo "$MANAGED"); do unset "$v"; done
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
for v in $(echo "$MANAGED"); do eval "[ -n \"\${$v+x}\" ]" && leaked="$leaked $v"; done
chk "sourcing the libs sets no config variable:$leaked" '[[ -z "$leaked" ]]'
reset

# ── built-in defaults (no file) ───────────────────────────────────────────────
reset; rm -f "$CFG"; _pf_config_load
chk "no file: status is missing"            '[[ "$_PF_CONFIG_STATUS" == missing ]]'
chk "no file: built-in OP_ACCOUNT"          '[[ "$OP_ACCOUNT" == my.1password.com ]]'
chk "no file: PROJ_DIRS expanded"           '[[ "$PROJ_DIRS" == "$HOME/projects:$HOME/work:$HOME/src" ]]'
chk "no file: checks default to 1"          '[[ "$_CHECK_AWS" == 1 && "$_CHECK_GIT_CONFIG" == 1 ]]'
chk "no file: OWL_OMP_CONFIG is the bundled theme" '[[ "$OWL_OMP_CONFIG" == "$PREFLIGHT_STATE_DIR/owl/theme-catppuccin.omp.json" ]]'
fallback_dump=$(for v in $(echo "$MANAGED"); do eval "printf '%s=%s\n' $v \"\$$v\""; done)

# The jq path must give the same values as the shell fallback for an empty object.
reset; put '{}'; _pf_config_load
jq_dump=$(for v in $(echo "$MANAGED"); do eval "printf '%s=%s\n' $v \"\$$v\""; done)
chk "jq defaults equal shell fallback defaults" '[[ "$jq_dump" == "$fallback_dump" ]]'
chk "empty object: status ok" '[[ "$_PF_CONFIG_STATUS" == ok ]]'

# ── a profile ─────────────────────────────────────────────────────────────────
reset; cp "$R/defaults/config.company.json" "$CFG"; _pf_config_load
chk "company: list joined with :"           '[[ "$PROJ_DIRS" == "$HOME/projects:$HOME/work:$HOME/src" ]]'
chk "company: string value"                 '[[ "$AWS_PROFILE_DEFAULT" == my-dev-profile ]]'
chk "company: true -> 1"                    '[[ "$_CHECK_AWS" == 1 ]]'
reset; cp "$R/defaults/config.general.json" "$CFG"; _pf_config_load
chk "general: false -> 0"                   '[[ "$_CHECK_AWS" == 0 ]]'
chk "general: OWL_OMP_CONFIG expanded from \$PREFLIGHT_STATE_DIR" '[[ "$OWL_OMP_CONFIG" == "$PREFLIGHT_STATE_DIR/owl/theme-catppuccin.omp.json" ]]'
chk "exported: OP_ACCOUNT"                  '$PF_SHELL -c '"'"'[ -n "$OP_ACCOUNT" ]'"'"' 2>/dev/null'
chk "not exported: _CHECK_AWS"              '! $PF_SHELL -c '"'"'[ -n "${_CHECK_AWS+x}" ]'"'"''

# ── value handling ────────────────────────────────────────────────────────────
reset; put '{"op":{"account":"it'"'"'s \"x\" $(echo no)"},"projects":{"dirs":["~/a","$HOME/b","/c","$OTHER/d"]},"git":{"main_branch":"trunk"}}'
_pf_config_load
chk "quotes, apostrophes and \$() survive verbatim" '[[ "$OP_ACCOUNT" == "it'"'"'s \"x\" \$(echo no)" ]]'
chk "path expansion: ~/, \$HOME/, absolute; other \$VAR untouched" '[[ "$PROJ_DIRS" == "$HOME/a:$HOME/b:/c:\$OTHER/d" ]]'
chk "other keys fall back to defaults"      '[[ "$_CHECK_SSH" == 1 && -z "$AWS_PROFILE_DEFAULT" ]]'

# A list with any non-string element is wrong-typed as a whole, not filtered.
reset; put '{"op":{"account":"acct"},"projects":{"dirs":["~/custom",7]}}'
_pf_config_load
chk "mixed list: falls back as a whole, not the valid element alone" '[[ "$PROJ_DIRS" == "$HOME/projects:$HOME/work:$HOME/src" && "$OP_ACCOUNT" == acct ]]'
out=$(_pf_config_check)
chk "mixed list: check reports a wrong type" '[[ "$out" == *"wrong type for projects.dirs"* ]]'

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

# jq's stderr is never evaluated as shell, even when jq succeeds.
reset; cp "$R/defaults/config.company.json" "$CFG"
mkdir -p "$T/fakebin"; REALJQ=$(command -v jq)
printf '#!/bin/sh\necho "touch %s/pwned" >&2\nexec "%s" "$@"\n' "$T" "$REALJQ" > "$T/fakebin/jq"; chmod +x "$T/fakebin/jq"
OLDPATH=$PATH; PATH="$T/fakebin:$PATH"; _pf_config_load 2>/dev/null; PATH=$OLDPATH
chk "jq stderr is not run as shell"         '[[ ! -e "$T/pwned" && "$AWS_PROFILE_DEFAULT" == my-dev-profile ]]'

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
reset; AWS_PROFILE_DEFAULT=""; put '{"aws":{"default_profile":"h"}}'; _pf_config_load
chk "a user-set empty value still wins"     '[[ -z "$AWS_PROFILE_DEFAULT" ]]'

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
chk "config get list"                       '[[ "$(_pf_config_cmd get projects.dirs)" == "~/projects:~/work:~/src" ]]'
chk "config get falls back to the default"  'jq "del(.git)" "$CFG" > "$T/x" && mv "$T/x" "$CFG"; [[ "$(_pf_config_cmd get git.main_branch)" == main ]]'
# get prints what set accepts, including false, empty strings and lists.
put '{"version":1,"checks":{"aws":false,"gh":true},"aws":{"default_profile":""},"projects":{"dirs":["~/a","~/b"]}}'
chk "get prints false for a false boolean"  '[[ "$(_pf_config_cmd get checks.aws)" == false ]]'
chk "get prints true for a true boolean"    '[[ "$(_pf_config_cmd get checks.gh)" == true ]]'
chk "get prints an empty string value as empty (not the default)" 'put "{\"git\":{\"main_branch\":\"\"}}"; [[ -z "$(_pf_config_cmd get git.main_branch)" ]]'
put '{"version":1,"checks":{"aws":false},"projects":{"dirs":["~/a","~/b"]}}'
chk "get prints a list ':'-joined, entries unexpanded" '[[ "$(_pf_config_cmd get projects.dirs)" == "~/a:~/b" ]]'
chk "get output round-trips through set"    'v=$(_pf_config_cmd get projects.dirs); _pf_config_cmd set projects.dirs "$v" >/dev/null; [[ "$(jq -c .projects.dirs "$CFG")" == "[\"~/a\",\"~/b\"]" ]]'
chk "get of an absent bool falls back to the default as true/false" 'put "{}"; [[ "$(_pf_config_cmd get checks.ssh)" == true ]]'
cp "$R/defaults/config.company.json" "$CFG"
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
_pf_config_cmd set projects.dirs "" >/dev/null
chk "set empty list writes []"              '[[ "$(jq -c .projects.dirs "$CFG")" == "[]" ]]'
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

reset; cp "$R/defaults/config.company.json" "$CFG"; OP_ACCOUNT=mine; export OP_ACCOUNT; _pf_config_load
out=$(_pf_config_cmd set op.account other 2>&1)
chk "set warns when your own variable keeps winning" '[[ "$out" == *"keeps the \$OP_ACCOUNT you set"* && "$OP_ACCOUNT" == mine ]]'
chk "set does not warn for a loader-set variable"    'reset; out=$(_pf_config_cmd set git.main_branch z 2>&1); [[ "$out" != *"Note:"* ]]'
unset OP_ACCOUNT

# set takes exactly KEY VALUE; an unquoted multi-word value is refused, not truncated.
cp "$R/defaults/config.company.json" "$CFG"; before=$(cat "$CFG")
out=$(_pf_config_cmd set projects.dirs ~/a ~/b 2>&1); rc=$?
chk "set with extra arguments fails and writes nothing" '[[ $rc -ne 0 && "$out" == *"Usage"* && "$(cat "$CFG")" == "$before" ]]'
out=$(_pf_config_cmd set git.main_branch 2>&1); rc=$?
chk "set with no value fails"                          '[[ $rc -ne 0 && "$(cat "$CFG")" == "$before" ]]'

# get does not report the default for a file it cannot read.
printf '{ broken' > "$CFG"
out=$(_pf_config_cmd get git.main_branch 2>&1); rc=$?
chk "get on invalid JSON is an error, not the default" '[[ $rc -ne 0 && "$out" != main && "$out" == *"cannot read"* ]]'
cp "$R/defaults/config.company.json" "$CFG"
PATH_SAVE=$PATH; PATH="$T/empty"
out=$(_pf_config_cmd get git.main_branch 2>&1); rc=$?
PATH=$PATH_SAVE
chk "get without jq is an error, not the default"      '[[ $rc -ne 0 && "$out" == *"jq is required"* ]]'
rm -f "$CFG"
chk "get with no file still falls back to the default" '[[ "$(_pf_config_cmd get git.main_branch)" == main ]]'
cp "$R/defaults/config.company.json" "$CFG"

# A symlinked config.json is edited at its target; the link stays a link.
reset; mkdir -p "$T/dotfiles"; cp "$R/defaults/config.company.json" "$T/dotfiles/config.json"
rm -f "$CFG"; ln -s "$T/dotfiles/config.json" "$CFG"
_pf_config_cmd set git.main_branch viasymlink >/dev/null
chk "set through a symlink keeps the link"      '[[ -L "$CFG" ]]'
chk "set through a symlink writes the target"   '[[ "$(jq -r .git.main_branch "$T/dotfiles/config.json")" == viasymlink ]]'
rm -f "$CFG"; ln -s "../dotfiles/config.json" "$CFG"
chk "a relative symlink is followed too"        '_pf_config_cmd set git.main_branch rel >/dev/null 2>&1; [[ -L "$CFG" && "$(jq -r .git.main_branch "$T/dotfiles/config.json")" == rel ]]'
chk "set through a symlink leaves no temp files" '[[ -z "$(find "$T/dotfiles" -name ".config.*")" ]]'
rm -f "$CFG"

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
printf '#!/bin/sh\necho "$@" > "%s/edited"\n' "$T" > "$T/ed"; chmod +x "$T/ed"
EDITOR="$T/ed" VISUAL="" _pf_config_cmd edit >/dev/null 2>&1
chk "edit runs the editor (VISUAL empty -> EDITOR) on the file" '[[ "$(cat "$T/edited" 2>/dev/null)" == "$CFG" ]]'
VISUAL="$T/ed --wait" EDITOR="" _pf_config_cmd edit >/dev/null 2>&1
chk "edit splits a multi-word editor (VISUAL wins)" '[[ "$(cat "$T/edited" 2>/dev/null)" == "--wait $CFG" ]]'

# The help text is an unquoted heredoc (it expands the config path), so a backtick in it would run a command.
help_out=$(_pf_config_help 2>&1)
chk "config help prints the get line intact"        '[[ "$help_out" == *"get KEY          Print a setting in the form"* && "$help_out" == *"accepts (the built-in default if unset)"* ]]'
chk "config help runs no command (no environment dump)" '[[ "$help_out" != *"BASH="* && "$help_out" != *"BASH_VERSION"* && $(printf "%s\n" "$help_out" | wc -l) -lt 40 ]]'
chk "config help has no backtick left to run"       '[[ "$(sed -n "/^_pf_config_help()/,/^EOF/p" "$R/lib/config.sh")" != *"\`"* ]]'

# ── preflight config apply (formerly `preflight configure`) ──────────────────
# The implementation changes real state (git globals, the user's systemd socket, downloads), so it is
# stubbed here: this only checks that the subcommand is wired up and passes its arguments through.
chk "config help lists apply"                '[[ "$(_pf_config_help)" == *"apply [--yes]"* ]]'
_pf_config_apply() { echo "stub apply: $*"; }
chk "config apply forwards its arguments" '[[ "$(_pf_config_cmd apply --yes)" == "stub apply: --yes" && "$(_pf_config_cmd apply)" == "stub apply: " ]]'
unset -f _pf_config_apply
out=$( (source "$R/lib/preflight.sh"; _pf_config_apply --yse) 2>&1 ); rc=$?   # refused before anything is touched
chk "config apply: an unknown argument prints the usage and does nothing" '[[ $rc -ne 0 && "$out" == *"Usage: preflight config apply"* ]]'

# ── preflight config init ─────────────────────────────────────────────────────
# Answers are fed with --stdin, one per line in table order: op.account, projects.dirs,
# aws.default_profile, git.main_branch, checks.aws, checks.gh,
# checks.ssh, checks.git_config, owl.omp_config, plugins. Called in the current shell (process
# substitution, not a pipe) so the loader's variables can be checked afterwards.
init_with() { _pf_config_init --stdin < <(printf '%s\n' "$@") >"$T/init.out" 2>&1; }
KEEP=""   # an empty line keeps the current value
reset; cp "$R/defaults/config.company.json" "$CFG"; _pf_config_load; before=$(cat "$CFG")
init_with "$KEEP" "$KEEP" "$KEEP" "$KEEP" "$KEEP" "$KEEP" "$KEEP" "$KEEP" "$KEEP" "$KEEP"; rc=$?
chk "init: all Enter keeps everything and writes nothing" '[[ $rc -eq 0 && "$(cat "$CFG")" == "$before" && "$(cat "$T/init.out")" == *"No changes"* ]]'

init_with "new.1password.com" "~/x:~/y" "-" "trunk" "no" "$KEEP" "yes" "$KEEP" "-" "owl"; rc=$?
chk "init: succeeds"                          '[[ $rc -eq 0 ]]'
chk "init: string, list and clear are written" '[[ "$(jq -r .op.account "$CFG")" == new.1password.com && "$(jq -c .projects.dirs "$CFG")" == "[\"~/x\",\"~/y\"]" && "$(jq -r .aws.default_profile "$CFG")" == "" && "$(jq -r .git.main_branch "$CFG")" == trunk ]]'
chk "init: yes/no become JSON booleans"       '[[ "$(jq -c .checks "$CFG")" == "{\"aws\":false,\"gh\":true,\"ssh\":true,\"git_config\":true}" ]]'
chk "init: - clears the Oh My Posh path"      '[[ "$(jq -r .owl.omp_config "$CFG")" == "" ]]'
chk "init: plugins are written as a JSON array" '[[ "$(jq -c .plugins "$CFG")" == "[\"owl\"]" && "$PREFLIGHT_PLUGINS" == owl ]]'
chk "init: kept keys and version are untouched" '[[ "$(jq -r .version "$CFG")" == 1 && "$(jq -r .checks.gh "$CFG")" == true ]]'
chk "init: the shell picks up the new values" '[[ "$OP_ACCOUNT" == new.1password.com && "$GIT_MAIN_BRANCH" == trunk && "$_CHECK_AWS" == 0 ]]'
chk "init: reports how many changed"          '[[ "$(cat "$T/init.out")" == *"changed in"* ]]'
chk "init: leaves no temp files"              '[[ -z "$(find "$PREFLIGHT_CONFIG_DIR" -maxdepth 1 -name ".config.*")" ]]'
chk "init: the result passes check"           '_pf_config_check >/dev/null'

# The current value is shown as the default.
init_with "$KEEP" "$KEEP" "$KEEP" "$KEEP" "$KEEP" "$KEEP" "$KEEP" "$KEEP" "$KEEP" "$KEEP"
chk "init: prompts show the current value"    '[[ "$(cat "$T/init.out")" == *"[new.1password.com]"* && "$(cat "$T/init.out")" == *"[~/x:~/y]"* && "$(cat "$T/init.out")" == *"[no]"* ]]'

# Stopping part-way writes nothing, even after some answers were given.
before=$(cat "$CFG")
init_with "changed.1password.com" "~/z"; rc=$?
chk "init: input ending part-way fails"       '[[ $rc -ne 0 && "$(cat "$T/init.out")" == *"no changes were written"* ]]'
chk "init: ...and leaves the file untouched"  '[[ "$(cat "$CFG")" == "$before" && "$OP_ACCOUNT" == new.1password.com ]]'
chk "init: ...and stops at the first missing answer (does not keep prompting)" '[[ "$(grep -c "Input ended" "$T/init.out")" == 1 && "$(grep -c "^[a-z_.]*: " "$T/init.out")" == 3 ]]'

# A bad yes/no stops it, and writes nothing.
init_with "x" "$KEEP" "$KEEP" "$KEEP" "maybe"; rc=$?
chk "init: a bad yes/no is refused with the key named, nothing written" '[[ $rc -ne 0 && "$(cat "$T/init.out")" == *"not yes or no for checks.aws"* && "$(cat "$CFG")" == "$before" ]]'
init_with "$KEEP" "$KEEP" "$KEEP" "$KEEP" "-"; rc=$?
chk "init: - is not an answer to a yes/no question" '[[ $rc -ne 0 && "$(cat "$CFG")" == "$before" ]]'

# No terminal and no --stdin: refuse rather than hang.
out=$(_pf_config_init </dev/null 2>&1); rc=$?
chk "init: without a terminal or --stdin it refuses" '[[ $rc -ne 0 && "$out" == *"needs a terminal"* ]]'
out=$(_pf_config_init --bogus 2>&1); rc=$?
chk "init: unknown argument prints the usage" '[[ $rc -ne 0 && "$out" == *"Usage: preflight config init"* ]]'

# An invalid file is refused, not overwritten.
printf '{ broken' > "$CFG"
init_with "a" ; rc=$?
chk "init: invalid JSON is refused and left alone" '[[ $rc -ne 0 && "$(cat "$CFG")" == "{ broken" && "$(cat "$T/init.out")" == *"not valid JSON"* ]]'

# No file yet: only the answered keys are written, plus the version.
reset; rm -f "$CFG"
init_with "fresh.1password.com" "$KEEP" "$KEEP" "$KEEP" "$KEEP" "$KEEP" "$KEEP" "$KEEP" "$KEEP" "$KEEP"; rc=$?
chk "init: with no file, creates it with just version and the answered key" '[[ $rc -eq 0 && "$(jq -c . "$CFG")" == "{\"version\":1,\"op\":{\"account\":\"fresh.1password.com\"}}" ]]'

# The "your own variable keeps winning" note is built from a newline-delimited list, so it works where an
# unquoted expansion is not word-split (zsh). IFS set to a newline alone reproduces that in bash: with the
# old space-separated list a loader-set variable was reported as shadowed, and several came out as one.
reset; cp "$R/defaults/config.company.json" "$CFG"; _pf_config_load
OLDIFS=$IFS; IFS=$'\n'
out=$(_pf_config_cmd set git.main_branch zsh1 2>&1)
IFS=$OLDIFS
chk "set: no false 'keeps' note for a loader-set variable when the shell does not word-split" '[[ "$out" != *"Note:"* ]]'
reset; cp "$R/defaults/config.company.json" "$CFG"; GIT_MAIN_BRANCH=mine; export GIT_MAIN_BRANCH; OP_ACCOUNT=mine2; export OP_ACCOUNT; _pf_config_load
OLDIFS=$IFS; IFS=$'\n'
out=$(_pf_config_write_many git.main_branch zsh2 op.account other 2>&1 )
IFS=$OLDIFS
chk "write_many: one note per shadowed variable, each correctly named, without word-splitting" '[[ "$out" == *"keeps the \$GIT_MAIN_BRANCH you set"* && "$out" == *"keeps the \$OP_ACCOUNT you set"* && "$out" != *"\$ GIT"* ]]'
unset GIT_MAIN_BRANCH OP_ACCOUNT

# A symlinked config.json is edited at its target.
reset; mkdir -p "$T/dots"; cp "$R/defaults/config.company.json" "$T/dots/config.json"; rm -f "$CFG"; ln -s "$T/dots/config.json" "$CFG"
init_with "linked.1password.com" "$KEEP" "$KEEP" "$KEEP" "$KEEP" "$KEEP" "$KEEP" "$KEEP" "$KEEP" "$KEEP"
chk "init: through a symlink keeps the link and writes the target" '[[ -L "$CFG" && "$(jq -r .op.account "$T/dots/config.json")" == linked.1password.com ]]'
rm -f "$CFG"

# Every key has its own prompt text (the fallback is the bare key).
missing=""
while IFS='|' read -r k rest; do
  [[ -n "$k" ]] || continue
  [[ "$(_pf_config_prompt_text "$k")" != "$k" ]] || missing="$missing $k"
done <<< "$_PF_CONFIG_TABLE"
chk "every key has a prompt text:$missing" '[[ -z "$missing" ]]'

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
    pl)   want=array ;;
  esac
  [[ "$stype" == "$want" ]] || bad="$bad $k(type)"
  case "$type" in
    b)  [[ "$sdef" == "true" && "$def" == 1 || "$sdef" == "false" && "$def" == 0 ]] || bad="$bad $k(default)" ;;
    pl) [[ "$(printf '%s' "$sdef" | tr '\001' ':')" == "$def" ]] || bad="$bad $k(default)" ;;
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

# ── PowerShell side (skipped without pwsh; run once, from the bash pass) ─────
# The PowerShell loader and the bash loader must produce the same settings from the same
# config.json, and the PowerShell suite (env sets, Import-OpEnv, the installer) must pass.
if [[ "$PF_SHELL" == bash ]] && command -v pwsh >/dev/null 2>&1; then
  # Only exported rows exist on the PowerShell side (the _CHECK_* flags are bash-only shell variables).
  bash_dump() {
    local k var type exp def
    reset; _pf_config_load >/dev/null 2>&1
    while IFS='|' read -r k var type exp def; do
      [[ "$exp" == x ]] || continue
      eval "printf '%s=%s\\n' $var \"\${$var-}\""
    done <<< "$_PF_CONFIG_TABLE"
  }
  ps_dump() {
    env -u OP_ACCOUNT -u PROJ_DIRS -u AWS_PROFILE_DEFAULT -u GIT_MAIN_BRANCH -u OWL_OMP_CONFIG \
      pwsh -NoProfile -File "$R/tests/config-dump.ps1" -Repo "$R" 2>&1
  }
  i=0
  while IFS= read -r case_json; do
    i=$((i + 1))
    if [[ "$case_json" == @* ]]; then cp "$R/${case_json#@}" "$CFG"; else printf '%s' "$case_json" > "$CFG"; fi
    want=$(bash_dump); got=$(ps_dump)
    chk "bash and PowerShell loaders agree on case $i: ${case_json:0:60}" '[[ "$want" == "$got" ]]'
    [[ "$want" == "$got" ]] || { echo "--- bash"; echo "$want"; echo "--- pwsh"; echo "$got"; }
  done <<'CASES'
{}
@defaults/config.company.json
@defaults/config.general.json
{"op":{"account":"it's \"x\" $(echo no) `y`"},"git":{"main_branch":"trunk"}}
{"projects":{"dirs":["~/a","$HOME/b","/c","$OTHER/d"]}}
{"projects":{"dirs":[]}}
{"projects":{"dirs":["~/one"]}}
{"projects":{"dirs":["~/custom",7]}}
{"projects":{"dirs":"nope"},"op":{"account":"kept"},"git":"flat","checks":{"aws":"yes"}}
{"owl":{"omp_config":"$HOME/x/theme.json"},"gitea":{"username":"u","host":"h"}}
{"owl":{"omp_config":"$PREFLIGHT_CONFIG_DIR/theme.json"},"aws":{"default_profile":"p"}}
{"owl":{"omp_config":""}}
{"op":"flat"}
CASES
  rm -f "$CFG"

  psout=$(mkdir -p "$T/pwhome" && env -u OP_ACCOUNT -u PROJ_DIRS -u AWS_PROFILE_DEFAULT -u GIT_MAIN_BRANCH -u OWL_OMP_CONFIG \
            -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u PREFLIGHT_CONFIG_DIR -u PREFLIGHT_STATE_DIR HOME="$T/pwhome" \
            pwsh -NoProfile -File "$R/tests/config.ps1" -Repo "$R" 2>&1)
  echo "$psout" | grep -a '^FAIL\|^  error' 
  ps_line=$(echo "$psout" | grep -a ' passed, ' | tail -1)
  ps_pass=${ps_line%% passed*}; ps_fail=${ps_line#*, }; ps_fail=${ps_fail%% failed*}
  chk "PowerShell suite ran ($ps_line)" '[[ "$ps_pass" =~ ^[0-9]+$ && "$ps_pass" -gt 0 ]]'
  chk "PowerShell suite: no failures"   '[[ "$ps_fail" == 0 ]]'
else
  echo "skipped: PowerShell checks (pwsh not installed, or not the bash pass)"
fi

echo "$passes passed, $fails failed"
[[ $fails -eq 0 ]]
