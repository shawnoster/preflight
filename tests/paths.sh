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
chk "config dir == PREFLIGHT_DIR is refused" '[[ $rc -ne 0 && "$out" == *"is the install directory"* ]]'
fresh; export PREFLIGHT_STATE_DIR="$T/pf"
out=$(_pf_resolve_dirs 2>&1); rc=$?
chk "state dir == PREFLIGHT_DIR is refused" '[[ $rc -ne 0 ]]'

# Aliases and nested paths are the same problem.
fresh; mkdir -p "$PREFLIGHT_DIR/sub"; ln -s "$PREFLIGHT_DIR" "$T/alias"
for spelling in "$T/pf/." "$T/pf/sub/.." "$T/alias" "$T/pf/config" "$T/alias/sub" "$T/pf/not/yet/created"; do
  fresh; mkdir -p "$PREFLIGHT_DIR/sub"; ln -s "$PREFLIGHT_DIR" "$T/alias"
  export PREFLIGHT_CONFIG_DIR="$spelling"
  out=$(_pf_resolve_dirs 2>&1); rc=$?
  chk "config dir '${spelling#$T/}' is refused" '[[ $rc -ne 0 ]]'
  unset PREFLIGHT_CONFIG_DIR
  export PREFLIGHT_STATE_DIR="$spelling"
  out=$(_pf_resolve_dirs 2>&1); rc=$?
  chk "state dir '${spelling#$T/}' is refused" '[[ $rc -ne 0 ]]'
done
fresh; mkdir -p "$T/pf-sibling"; ln -s "$T/pf" "$T/alias2"
export PREFLIGHT_CONFIG_DIR="$T/pf-sibling"
chk "a sibling that merely shares a prefix is allowed" '_pf_resolve_dirs'
fresh; export PREFLIGHT_DIR="$T/alias2"; export PREFLIGHT_CONFIG_DIR="$T/pf/config"
chk "PREFLIGHT_DIR given as a symlink is compared by real path" '! _pf_resolve_dirs 2>/dev/null'

# ── rm guard ──────────────────────────────────────────────────────────────────
fresh
for bad in "" "/" "$HOME" "$HOME/" "$HOME/.config" "$HOME/.local/state" "$HOME/.cache"; do
  chk "guard refuses '${bad:-<empty>}'" '! _pf_safe_rm_dir "$bad" 2>/dev/null'
done
export XDG_CONFIG_HOME="$T/xc"
chk "guard refuses a custom XDG_CONFIG_HOME itself" '! _pf_safe_rm_dir "$T/xc" 2>/dev/null'
unset XDG_CONFIG_HOME; mkdir -p "$HOME/x"; ln -s "$HOME" "$T/homelink"
for bad in "$HOME/." "$HOME/x/.." "$T/homelink" "$HOME/.config/." "$HOME/./.cache"; do
  chk "guard refuses the alias '${bad#$T/}'" '! _pf_safe_rm_dir "$bad" 2>/dev/null'
done
export XDG_CONFIG_HOME="$T/xc"
chk "guard allows a preflight subdirectory" '_pf_safe_rm_dir "$T/xc/preflight"'

# ── first run (init.sh sourced non-interactively) ─────────────────────────────
fresh
out=$(source "$PREFLIGHT_DIR/init.sh" 2>&1 </dev/null)
chk "first run creates accounts.sh in the config dir" '[[ -f "$HOME/.config/preflight/accounts.sh" ]]'
chk "first run creates owl.sh in the config dir"      '[[ -f "$HOME/.config/preflight/owl.sh" ]]'
chk "first run seeds the owl theme in the state dir"  '[[ -f "$HOME/.local/state/preflight/owl/theme-catppuccin.omp.json" ]]'
chk "first run writes nothing into the clone"         '[[ ! -e "$PREFLIGHT_DIR/config" && ! -e "$PREFLIGHT_DIR/state" ]]'
chk "owl.sh points the OMP theme at the state dir"    'grep -q "PREFLIGHT_STATE_DIR/owl/theme-catppuccin" "$HOME/.config/preflight/owl.sh"'

# An existing accounts.sh is never overwritten.
echo '# mine' > "$HOME/.config/preflight/accounts.sh"
out=$(source "$PREFLIGHT_DIR/init.sh" 2>&1 </dev/null)
chk "second run keeps an edited accounts.sh" '[[ "$(cat "$HOME/.config/preflight/accounts.sh")" == "# mine" ]]'

# init.sh refuses a config dir that is the clone, and creates nothing there.
fresh; export PREFLIGHT_CONFIG_DIR="$PREFLIGHT_DIR"
out=$(source "$PREFLIGHT_DIR/init.sh" 2>&1 </dev/null); rc=$?
chk "init.sh stops on a shared config dir" '[[ $rc -ne 0 && "$out" == *"is the install directory"* && ! -e "$PREFLIGHT_DIR/accounts.sh" ]]'

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
chk "uninstall keeps the config dir"         '[[ -f "$HOME/.config/preflight/accounts.sh" ]]'
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
for args in "--purge typo" "typo" "--purge --purge" "--purge=1"; do
  out=$(run_uninstall y $args)
  chk "uninstall '$args' is rejected and deletes nothing" '[[ "$out" == *"Usage: preflight uninstall"* && -d "$PREFLIGHT_DIR" && -f "$HOME/.config/preflight/accounts.sh" ]]'
done

# Only PREFLIGHT_CONFIG_DIR in the environment: --purge still resolves the state dir.
fresh
( source "$PREFLIGHT_DIR/init.sh" >/dev/null 2>&1 </dev/null )
out=$( ( source "$PREFLIGHT_DIR/init.sh" >/dev/null 2>&1 </dev/null; unset PREFLIGHT_STATE_DIR; printf 'y\n' | preflight uninstall --purge ) 2>&1 )
chk "--purge with only the config dir set resolves the state dir" '[[ "$out" != *"refusing"* && ! -e "$HOME/.local/state/preflight" && ! -e "$HOME/.config/preflight" ]]'

# preflight-cache-clear works when cache.sh is sourced without init.sh.
fresh; mkdir -p "$HOME/.cache/preflight"; echo x > "$HOME/.cache/preflight/c"
out=$( ( unset -f _pf_safe_rm_dir; source "$PREFLIGHT_DIR/lib/cache.sh"; PREFLIGHT_CACHE_DIR="$HOME/.cache/preflight"; preflight-cache-clear ) 2>&1 ); rc=$?
chk "cache.sh alone can still clear the cache" '[[ $rc -eq 0 && ! -e "$HOME/.cache/preflight" ]]'

# A protected PREFLIGHT_DIR is refused before any shell profile is edited.
fresh
( source "$PREFLIGHT_DIR/init.sh" >/dev/null 2>&1 </dev/null )
mkdir -p "$HOME/.config"
printf 'export KEEP=1\n# Preflight — developer environment\n[[ -f "$HOME/.preflight/init.sh" ]] && source "$HOME/.preflight/init.sh"\n' > "$HOME/.bashrc"
before=$(cat "$HOME/.bashrc")
out=$( ( source "$PREFLIGHT_DIR/init.sh" >/dev/null 2>&1 </dev/null; PREFLIGHT_DIR="$HOME/.config"; printf 'y\n' | preflight uninstall ) 2>&1 )
chk "uninstall with a protected PREFLIGHT_DIR refuses" '[[ "$out" == *"refusing to remove"* ]]'
chk "...and leaves the shell profile untouched"     '[[ "$(cat "$HOME/.bashrc")" == "$before" ]]'
chk "...and deletes nothing"                         '[[ -d "$HOME/.config" && -f "$HOME/.config/preflight/accounts.sh" ]]'

fresh
( source "$PREFLIGHT_DIR/init.sh" >/dev/null 2>&1 </dev/null )
out=$(run_uninstall n --purge)
chk "declining uninstall deletes nothing" '[[ -d "$PREFLIGHT_DIR" && -f "$HOME/.config/preflight/accounts.sh" ]]'

# An install updated in place: settings still inside the clone are reported, not ignored.
fresh; mkdir -p "$PREFLIGHT_DIR/config/envsets" "$PREFLIGHT_DIR/state/owl"
echo 'export OP_ACCOUNT=legacy' > "$PREFLIGHT_DIR/config/accounts.sh"
out=$(source "$PREFLIGHT_DIR/init.sh" 2>&1 </dev/null)
chk "legacy in-clone settings: warns and says how to move them" '[[ "$out" == *"still inside $PREFLIGHT_DIR"* && "$out" == *"mv "* ]]'
chk "legacy: creates nothing in the new locations" '[[ ! -e "$HOME/.config/preflight/accounts.sh" && ! -e "$HOME/.local/state/preflight/owl" ]]'
chk "legacy: no first-run prompt text"            '[[ "$out" != *"First-time setup"* ]]'
mkdir -p "$HOME/.config/preflight" "$HOME/.local/state/preflight"
mv "$PREFLIGHT_DIR/config/accounts.sh" "$HOME/.config/preflight/"
out=$(source "$PREFLIGHT_DIR/init.sh" 2>&1 </dev/null)
chk "after moving accounts.sh the warning is gone" '[[ "$out" != *"still inside"* ]]'

# A config dir that cannot be created stops init with a message.
fresh; touch "$T/afile"; export PREFLIGHT_CONFIG_DIR="$T/afile/cfg"
out=$(source "$PREFLIGHT_DIR/init.sh" 2>&1 </dev/null); rc=$?
chk "unwritable config dir: init stops with a message" '[[ $rc -ne 0 && "$out" == *"cannot create"* ]]'
unset PREFLIGHT_CONFIG_DIR

# lib/owl.sh sourced on its own stops on a refused layout and leaves OWL_THEME_DIR unset.
fresh; export PREFLIGHT_CONFIG_DIR="$PREFLIGHT_DIR"
out=$( (source "$R/lib/owl.sh" 2>&1; echo "rc=$? dir=[${OWL_THEME_DIR:-}]") 2>&1 )
chk "owl.sh stops on a refused layout and sets no theme dir" '[[ "$out" == *"is the install directory"* && "$out" == *"rc=1 dir=[]"* ]]'
unset PREFLIGHT_CONFIG_DIR

# ── install.sh refuses a shared layout before touching anything ──────────────
# Clones this repo's current branch from disk, so only runs inside a git checkout on a
# branch (the clone has the committed install.sh and lib/paths.sh, not uncommitted edits).
branch=$(git -C "$R" branch --show-current 2>/dev/null)
if [[ -n "$branch" ]] && command -v git >/dev/null 2>&1; then
  fresh; unset PREFLIGHT_DIR
  inst() { env -i PATH="$PATH" HOME="$HOME" SHELL=/bin/bash PREFLIGHT_REPO="$R" PREFLIGHT_BRANCH="$branch" "$@" bash "$R/install.sh" 2>&1; }
  out=$(inst PREFLIGHT_DIR="$HOME/.config/preflight"); rc=$?
  chk "install into the config dir fails" '[[ $rc -ne 0 && "$out" == *"Nothing was installed"* ]]'
  chk "install rolls the clone back"      '[[ ! -e "$HOME/.config/preflight" ]]'
  chk "install left the shell profile alone" '[[ ! -e "$HOME/.bashrc" && ! -e "$HOME/.profile" ]]'
  out=$(inst); rc=$?
  chk "re-running with the default location installs" '[[ $rc -eq 0 && -f "$HOME/.preflight/init.sh" && -d "$HOME/.config/preflight" ]]'
else
  echo "skipped: install.sh checks (not on a git branch)"
fi

echo "$passes passed, $fails failed"
[[ $fails -eq 0 ]]
