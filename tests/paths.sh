#!/usr/bin/env bash
# tests/paths.sh - config/state directory layout, first run, and uninstall --purge.
#
#   tests/paths.sh            run under bash, and under zsh if it is installed
#
# HOME is redirected to a scratch dir and the install is a copy of the repo there, so
# nothing real is read or deleted. The libraries are sourced from both shells in real
# use, so this runs the same checks in each.

if [[ -z "${PF_TEST_INNER:-}" ]]; then
  repo=$(cd "$(dirname "$0")/.." && pwd)
  rc=0
  for sh in bash zsh; do
    command -v "$sh" >/dev/null 2>&1 || { echo "== $sh: not installed, skipped"; continue; }
    echo "== $sh"
    PF_TEST_INNER=1 PF_REPO="$repo" "$sh" "$0" || rc=1
  done
  exit $rc
fi

# ── inner: runs in the shell under test ───────────────────────────────────────
R="$PF_REPO"
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
fails=0 passes=0
chk() { if eval "$2"; then passes=$((passes + 1)); else fails=$((fails + 1)); echo "FAIL: $1"; fi; }

# A fresh install: a copy of the code, a clean HOME, no overrides inherited.
fresh() {
  rm -rf "$T/home" "$T/pf"
  mkdir -p "$T/home" "$T/pf"
  cp -R "$R/lib" "$R/defaults" "$R/init.sh" "$T/pf/"
  unset PREFLIGHT_CONFIG_DIR PREFLIGHT_STATE_DIR PREFLIGHT_CACHE_DIR XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME
  # Settings a developer already has exported would win over config.json.
  unset OP_ACCOUNT PROJ_DIRS AWS_PROFILE_DEFAULT GIT_MAIN_BRANCH GITEA_USERNAME GITEA_HOST OWL_OMP_CONFIG _CHECK_AWS _CHECK_GH _CHECK_SSH _CHECK_GIT_CONFIG
  export HOME="$T/home" PREFLIGHT_DIR="$T/pf" PREFLIGHT_NO_SPLASH=1
}

source "$R/lib/paths.sh"

# ── resolution order ──────────────────────────────────────────────────────────
fresh; _pf_resolve_dirs
chk "default config dir"  '[[ "$PREFLIGHT_CONFIG_DIR" == "$HOME/.config/preflight" ]]'
chk "default state dir"   '[[ "$PREFLIGHT_STATE_DIR" == "$HOME/.local/state/preflight" ]]'

fresh; export XDG_CONFIG_HOME="$T/xc" XDG_STATE_HOME="$T/xs"; _pf_resolve_dirs
chk "XDG_CONFIG_HOME is used" '[[ "$PREFLIGHT_CONFIG_DIR" == "$T/xc/preflight" ]]'
chk "XDG_STATE_HOME is used"  '[[ "$PREFLIGHT_STATE_DIR" == "$T/xs/preflight" ]]'

export PREFLIGHT_CONFIG_DIR="$T/oc/" PREFLIGHT_STATE_DIR="$T/os"; _pf_resolve_dirs
chk "override beats XDG, trailing slash dropped" '[[ "$PREFLIGHT_CONFIG_DIR" == "$T/oc" ]]'
chk "state override beats XDG" '[[ "$PREFLIGHT_STATE_DIR" == "$T/os" ]]'

# ── code and data never share a directory ─────────────────────────────────────
fresh; export PREFLIGHT_CONFIG_DIR="$T/pf/"
out=$(_pf_resolve_dirs 2>&1); rc=$?
chk "config dir == PREFLIGHT_DIR is refused" '[[ $rc -ne 0 && "$out" == *"also the config or state directory"* ]]'
fresh; export PREFLIGHT_STATE_DIR="$T/pf"
out=$(_pf_resolve_dirs 2>&1); rc=$?
chk "state dir == PREFLIGHT_DIR is refused" '[[ $rc -ne 0 ]]'

# ── rm guard ──────────────────────────────────────────────────────────────────
fresh
for bad in "" "/" "$HOME" "$HOME/" "$HOME/.config" "$HOME/.local/state" "$HOME/.cache"; do
  chk "guard refuses '${bad:-<empty>}'" '! _pf_safe_rm_dir "$bad" 2>/dev/null'
done
export XDG_CONFIG_HOME="$T/xc"
chk "guard refuses a custom XDG_CONFIG_HOME itself" '! _pf_safe_rm_dir "$T/xc" 2>/dev/null'
chk "guard allows a preflight subdirectory" '_pf_safe_rm_dir "$T/xc/preflight"'

# ── first run (init.sh sourced non-interactively) ─────────────────────────────
fresh
out=$(source "$PREFLIGHT_DIR/init.sh" 2>&1 </dev/null)
chk "first run creates config.json in the config dir" 'jq -e . "$HOME/.config/preflight/config.json" >/dev/null'
chk "first run uses the general profile when non-interactive" 'cmp -s "$HOME/.config/preflight/config.json" "$R/defaults/config.general.json"'
chk "first run seeds the owl theme in the state dir"  '[[ -f "$HOME/.local/state/preflight/owl/theme-catppuccin.omp.json" ]]'
chk "first run writes nothing into the clone"         '[[ ! -e "$PREFLIGHT_DIR/config" && ! -e "$PREFLIGHT_DIR/state" ]]'
chk "first run loads the profile into the shell"      '[[ "$(source "$PREFLIGHT_DIR/init.sh" >/dev/null 2>&1 </dev/null; printf %s "$OWL_OMP_CONFIG")" == "$HOME/.local/state/preflight/owl/theme-catppuccin.omp.json" ]]'

# An existing config.json is never overwritten.
echo '{"version":1,"op":{"account":"mine"}}' > "$HOME/.config/preflight/config.json"
out=$(source "$PREFLIGHT_DIR/init.sh" 2>&1 </dev/null)
chk "second run keeps an edited config.json" '[[ "$(jq -r .op.account "$HOME/.config/preflight/config.json")" == mine ]]'
chk "second run loads the edited value"      '[[ "$(source "$PREFLIGHT_DIR/init.sh" >/dev/null 2>&1 </dev/null; printf %s "$OP_ACCOUNT")" == mine ]]'

# Re-sourcing init.sh in the SAME shell (source ~/.bashrc) must still pick up edits:
# the managed list has to survive the libs being sourced again.
fresh
source "$PREFLIGHT_DIR/init.sh" >/dev/null 2>&1 </dev/null
echo '{"version":1,"git":{"main_branch":"first"}}' > "$HOME/.config/preflight/config.json"
source "$PREFLIGHT_DIR/init.sh" >/dev/null 2>&1 </dev/null
chk "same-shell reload: first value loaded" '[[ "$GIT_MAIN_BRANCH" == first ]]'
echo '{"version":1,"git":{"main_branch":"second"}}' > "$HOME/.config/preflight/config.json"
source "$PREFLIGHT_DIR/init.sh" >/dev/null 2>&1 </dev/null
chk "same-shell reload: edited value follows the file" '[[ "$GIT_MAIN_BRANCH" == second ]]'

# init.sh refuses a config dir that is the clone, and creates nothing there.
fresh; export PREFLIGHT_CONFIG_DIR="$PREFLIGHT_DIR"
out=$(source "$PREFLIGHT_DIR/init.sh" 2>&1 </dev/null); rc=$?
chk "init.sh stops on a shared config dir" '[[ $rc -ne 0 && "$out" == *"also the config or state directory"* && ! -e "$PREFLIGHT_DIR/config.json" ]]'

# ── uninstall ─────────────────────────────────────────────────────────────────
# Run in a subshell: uninstall unsets preflight's own functions.
run_uninstall() {  # $1 = answer, rest = args
  local ans="$1"; shift
  ( source "$PREFLIGHT_DIR/init.sh" >/dev/null 2>&1 </dev/null; printf '%s\n' "$ans" | preflight uninstall "$@" ) 2>&1
}

fresh
( source "$PREFLIGHT_DIR/init.sh" >/dev/null 2>&1 </dev/null )
mkdir -p "$HOME/.cache/preflight"; echo x > "$HOME/.cache/preflight/c"
out=$(run_uninstall y)
chk "uninstall removes the clone"            '[[ ! -d "$PREFLIGHT_DIR" ]]'
chk "uninstall keeps the config dir"         '[[ -f "$HOME/.config/preflight/config.json" ]]'
chk "uninstall keeps the state dir"          '[[ -d "$HOME/.local/state/preflight/owl" ]]'
chk "uninstall keeps the cache dir"          '[[ -f "$HOME/.cache/preflight/c" ]]'
chk "uninstall says where the kept data is"  '[[ "$out" == *"$HOME/.config/preflight"* ]]'

fresh
( source "$PREFLIGHT_DIR/init.sh" >/dev/null 2>&1 </dev/null )
mkdir -p "$HOME/.cache/preflight"; echo x > "$HOME/.cache/preflight/c"
out=$(run_uninstall y --purge)
chk "--purge removes the config dir" '[[ ! -e "$HOME/.config/preflight" ]]'
chk "--purge removes the state dir"  '[[ ! -e "$HOME/.local/state/preflight" ]]'
chk "--purge removes the cache dir"  '[[ ! -e "$HOME/.cache/preflight" ]]'
chk "--purge leaves the rest of ~/.config" '[[ -d "$HOME/.config" ]]'

fresh
( source "$PREFLIGHT_DIR/init.sh" >/dev/null 2>&1 </dev/null )
mkdir -p "$HOME/.config/other-app"; echo keep > "$HOME/.config/other-app/f"
out=$( ( export PREFLIGHT_CONFIG_DIR="$HOME/.config"; source "$PREFLIGHT_DIR/init.sh" >/dev/null 2>&1 </dev/null; printf 'y\n' | preflight uninstall --purge ) 2>&1 )
chk "--purge refuses the bare XDG config dir" '[[ "$out" == *"refusing to remove"* && -f "$HOME/.config/other-app/f" && -d "$PREFLIGHT_DIR" ]]'

fresh
( source "$PREFLIGHT_DIR/init.sh" >/dev/null 2>&1 </dev/null )
out=$(run_uninstall n --purge)
chk "declining uninstall deletes nothing" '[[ -d "$PREFLIGHT_DIR" && -f "$HOME/.config/preflight/config.json" ]]'

echo "$passes passed, $fails failed"
[[ $fails -eq 0 ]]
