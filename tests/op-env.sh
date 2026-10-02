#!/usr/bin/env bash
# tests/op-env.sh - env sets + op-load-env, against a fake `op` in a scratch dir.
#
#   tests/op-env.sh            run under bash, and under zsh if it is installed
#
# Touches nothing outside a temp dir: PREFLIGHT_DIR and HOME are redirected and
# OP_BIN points at a stub, so no real 1Password session is needed. The libraries
# are sourced from both shells in real use, so this runs the same checks in each.

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
export HOME="$T/home" PREFLIGHT_DIR="$T/pf" OP_ACCOUNT=test OP_BIN="$T/op"
mkdir -p "$HOME" "$PREFLIGHT_DIR/config" "$PREFLIGHT_DIR/lib"

# Stub op: `inject` resolves {{ op://v/item/field }} to val-of-field and fails the
# whole batch if any reference mentions "broken"; `read` does the same per ref.
# FAKE_OP_INJECT_EXTRA="X=y" appends that line to inject output (what a secret value
# containing a newline looks like after substitution).
# FAKE_OP_SIGNED_OUT=1 makes `whoami` fail (and `signin` emit nothing useful).
cat > "$OP_BIN" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  whoami) [[ -z "$FAKE_OP_SIGNED_OUT" ]] ;;
  signin) exit 1 ;;
  inject) in=$(cat); grep -q broken <<<"$in" && exit 1
          sed -E 's/\{\{ op:\/\/[^}]*\/([^/ }]+) \}\}/val-of-\1/' <<<"$in"
          [[ -n "$FAKE_OP_INJECT_EXTRA" ]] && printf '%s\n' "$FAKE_OP_INJECT_EXTRA" ;;
  read)   ref="${@: -1}"; [[ "$ref" == *broken* ]] && exit 1; echo "val-of-${ref##*/}" ;;
esac
STUB
chmod +x "$OP_BIN"

fails=0 passes=0
chk() { if eval "$2"; then passes=$((passes + 1)); else fails=$((fails + 1)); echo "FAIL: $1"; fi; }
sets="$PREFLIGHT_DIR/config/envsets"
# GNU stat first, BSD/macOS stat as the fallback.
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# Load the libs the way init.sh does: by glob, in order.
load_libs() { local f; for f in "$R"/lib/*.sh; do source "$f" || echo "SOURCE FAIL $f"; done; }
cp "$R"/lib/*.sh "$PREFLIGHT_DIR/lib/" 2>/dev/null
load_libs

# ── empty ─────────────────────────────────────────────────────────────────────
out=$(op-load-env 2>&1); rc=$?
chk "empty load: rc 0 and hint" '[[ $rc -eq 0 && "$out" == *"op-env add"* ]]'
out=$(FAKE_OP_SIGNED_OUT=1 op-load-env 2>&1); rc=$?
chk "empty load never signs in" '[[ $rc -eq 0 ]]'

# ── add / list / load ─────────────────────────────────────────────────────────
op-env add guild NPM_TOKEN 'op://Private/npmjs/credential' >/dev/null
op-env add personal GITEA_TOKEN 'op://Private/Gitea - Personal/pat' >/dev/null
op-env add personal NANOLEAF_TOKEN 'op://Private/nano/token' >/dev/null
chk "list shows keys" '[[ "$(op-env list)" == *NPM_TOKEN*GITEA_TOKEN*NANOLEAF_TOKEN* ]]'
op-load-env >/dev/null
chk "loads a plain ref" '[[ "$NPM_TOKEN" == val-of-credential ]]'
chk "loads a ref containing spaces" '[[ "$GITEA_TOKEN" == val-of-pat ]]'
chk "nanoleaf hook wrote the token" 'grep -q "NANOLEAF_TOKEN=val-of-token" "$HOME/.config/nanoleaf-direct/env"'
chk "nanoleaf env file is mode 600" '[[ $(mode "$HOME/.config/nanoleaf-direct/env") == 600 ]]'
chk "set files are mode 600" '[[ $(mode "$sets/guild.tsv") == 600 ]]'

# ── use / rm / stale handling ─────────────────────────────────────────────────
op-env use guild >/dev/null; op-load-env >/dev/null
chk "deactivated set is unset on next load" '[[ -z "${GITEA_TOKEN:-}" && -n "${NPM_TOKEN:-}" ]]'
op-env use guild personal >/dev/null; op-load-env >/dev/null
op-env rm personal GITEA_TOKEN >/dev/null; op-load-env >/dev/null
chk "removed key is unset on next load" '[[ -z "${GITEA_TOKEN:-}" && -n "${NANOLEAF_TOKEN:-}" ]]'

# ── broken reference -> per-secret fallback ───────────────────────────────────
op-env add guild BAD 'op://v/broken/x' >/dev/null
out=$(op-load-env 2>&1); rc=$?
chk "fallback: rc 1" '[[ $rc -eq 1 ]]'
chk "fallback: reports the bad one" '[[ "$out" == *"BAD (failed to load)"* && "$out" == *"NPM_TOKEN"* ]]'
op-load-env >/dev/null
chk "fallback: the others still load" '[[ -n "${NPM_TOKEN:-}" && -z "${BAD:-}" ]]'
op-env rm guild BAD >/dev/null

# ── clear ─────────────────────────────────────────────────────────────────────
op-clear-env >/dev/null
chk "op-clear-env clears everything loaded" '[[ -z "${NPM_TOKEN:-}${NANOLEAF_TOKEN:-}" ]]'
op-load-env >/dev/null; rm "$sets/guild.tsv"; op-clear-env >/dev/null
chk "op-clear-env works after the definition is gone" '[[ -z "${NPM_TOKEN:-}" ]]'

# ── failed sign-in keeps the previous list ────────────────────────────────────
printf 'KEEP_ME\top://v/i/k\n' > "$sets/x.tsv"; rm -f "$sets/.active" "$sets/personal.tsv"
op-load-env >/dev/null
printf 'OTHER\top://v/i/o\n' > "$sets/x.tsv"
FAKE_OP_SIGNED_OUT=1 op-load-env >/dev/null 2>&1; rc=$?
chk "failed sign-in: rc 1" '[[ $rc -ne 0 ]]'
chk "failed sign-in: old list remembered, so clear still works" 'op-clear-env >/dev/null; [[ -z "${KEEP_ME:-}" ]]'
rm -f "$sets"/*.tsv "$sets/.active"

# ── CRLF edits (WSL users editing from Windows) ───────────────────────────────
printf 'CRLF_VAR\top://v/i/f\r\n' > "$sets/w.tsv"
printf 'w\r\n' > "$sets/.active"
op-load-env >/dev/null
chk "CRLF .tsv and .active: value has no CR" '[[ "$CRLF_VAR" == val-of-f ]]'
chk "CRLF: list output has no CR" '[[ "$(op-env list)" != *$'"'"'\r'"'"'* ]]'
rm -f "$sets"/*.tsv "$sets/.active"

# ── ordering: first definition wins, in .active order ─────────────────────────
printf 'DUP\top://v/i/first\n'  > "$sets/a.tsv"
printf 'DUP\top://v/i/second\n' > "$sets/b.tsv"
chk "no .active: alphabetical, a wins" '[[ "$(_op_env_entries)" == *first* ]]'
printf 'b\na\n' > "$sets/.active"
chk ".active order decides: b wins" '[[ "$(_op_env_entries)" == *second* ]]'
rm -f "$sets"/*.tsv "$sets/.active"

# ── hand-edited garbage is ignored ────────────────────────────────────────────
printf 'ok1\top://v/i/k\nnot a name\top://v/i/k\nnoref\tx\n\n' > "$sets/junk.tsv"
echo "no_such_set" >> "$sets/.active"; echo "junk" >> "$sets/.active"
chk "garbage lines dropped, good line kept" '[[ "$(_op_env_entries)" == "ok1"$'"'"'\t'"'"'"op://v/i/k" ]]'
rm -f "$sets"/*.tsv "$sets/.active"

# ── legacy OP_SECRETS + migrate ───────────────────────────────────────────────
OP_SECRETS=($'LEGACY_A\top://v/i/a' $'bad name\top://v/i/z' $'NOREF\tnotop')
op-load-env >/dev/null
chk "legacy array loads, invalid entries dropped" '[[ "$LEGACY_A" == val-of-a && -z "${NOREF:-}" ]]'
out=$(op-env migrate legacy 2>&1)
chk "migrate wrote the valid key" 'grep -q "^LEGACY_A	op://v/i/a" "$sets/legacy.tsv"'
chk "migrate skipped the malformed ones" '! grep -q "bad name\|NOREF" "$sets/legacy.tsv"'
unset OP_SECRETS; op-load-env >/dev/null
chk "loads from the set once the array is gone" '[[ "$LEGACY_A" == val-of-a ]]'
rm -f "$sets"/*.tsv "$sets/.active"

# ── migrate safety (Copilot review) ───────────────────────────────────────────
# A: malformed refs are skipped, not migrated (op://broken is not op://vault/item/field)
OP_SECRETS=($'OKREF\top://v/i/f' $'SHORT\top://broken' $'NOSLASH\top://v/i/')
out=$(op-env migrate m1 2>&1)
chk "migrate: valid ref moved" 'grep -q "^OKREF	op://v/i/f" "$sets/m1.tsv"'
chk "migrate: op://broken and op://v/i/ skipped" '! grep -q "SHORT\|NOSLASH" "$sets/m1.tsv"'
chk "loader drops a malformed ref too" '[[ "$(printf "SHORT\top://broken\n" > "$sets/bad.tsv"; _op_env_entries)" != *SHORT* ]]'
unset OP_SECRETS; rm -f "$sets"/*.tsv "$sets/.active"

# B: a different ref already in the set -> stop, change nothing, --force overwrites
OP_SECRETS=($'API\top://v/legacy/key')
printf 'API\top://v/other/key\n' > "$sets/m2.tsv"
before=$(cat "$sets/m2.tsv")
out=$(op-env migrate m2 2>&1); rc=$?
chk "conflict: migrate refuses" '[[ $rc -ne 0 && "$out" == *"different references"* && "$out" == *API* ]]'
chk "conflict: the set file is untouched" '[[ "$(cat "$sets/m2.tsv")" == "$before" ]]'
chk "conflict: what loads is still the legacy value" '[[ "$(_op_env_entries)" == *v/legacy/key* ]]'
out=$(op-env migrate m2 --force 2>&1); rc=$?
chk "conflict: --force takes the legacy ref" '[[ $rc -eq 0 ]] && grep -q "^API	op://v/legacy/key" "$sets/m2.tsv"'
unset OP_SECRETS
chk "conflict: after --force, deleting the legacy array changes nothing" '[[ "$(_op_env_entries)" == *v/legacy/key* ]]'
rm -f "$sets"/*.tsv "$sets/.active"

# B2: same ref already there is fine, and re-running is idempotent
OP_SECRETS=($'SAME\top://v/i/s')
op-env migrate m3 >/dev/null 2>&1; out=$(op-env migrate m3 2>&1); rc=$?
chk "re-running migrate is a no-op success" '[[ $rc -eq 0 && "$out" == *"same reference"* ]]'
unset OP_SECRETS; rm -f "$sets"/*.tsv "$sets/.active"

# C: an existing destination that is not active would silently drop the keys
printf 'LIVE\top://v/i/l\n' > "$sets/live.tsv"; printf 'DEST\top://v/i/d\n' > "$sets/dest.tsv"; printf 'live\n' > "$sets/.active"
OP_SECRETS=($'LEG\top://v/i/leg')
out=$(op-env migrate dest 2>&1); rc=$?
chk "inactive destination: migrate refuses" '[[ $rc -ne 0 && "$out" == *"not active"* ]]'
chk "inactive destination: nothing written" '! grep -q LEG "$sets/dest.tsv"'
out=$(op-env migrate live 2>&1); rc=$?
chk "active destination: migrate works" '[[ $rc -eq 0 ]] && grep -q "^LEG" "$sets/live.tsv"'
unset OP_SECRETS; rm -f "$sets"/*.tsv "$sets/.active"

# D: another active set would override the migrated value once the legacy list is gone
printf 'SH\top://v/other/sh\n' > "$sets/a.tsv"; printf 'a\nnew\n' > "$sets/.active"
OP_SECRETS=($'SH\top://v/legacy/sh')
out=$(op-env migrate new 2>&1); rc=$?
chk "shadowed by an earlier set: migrate refuses" '[[ $rc -ne 0 && "$out" == *"would override"* && ! -e "$sets/new.tsv" ]]'
unset OP_SECRETS; rm -f "$sets"/*.tsv "$sets/.active"

# ── upgrade: a leftover pre-rename lib/1password.sh must keep working ──────────
# Old file: defined its own op-load-env and an OP_SECRETS array. It sorts before
# onepassword.sh, so the new functions must win while its array is still honored.
cat > "$PREFLIGHT_DIR/lib/1password.sh" <<'OLD'
op-load-env() { echo "OLD LOADER RAN"; }
OP_SECRETS=( $'OLD_LIST_VAR\top://v/i/old' )
OLD
unset -f op-load-env op-env op-clear-env; OP_SECRETS=()
for f in "$PREFLIGHT_DIR"/lib/*.sh; do source "$f"; done
op-load-env > "$T/out" 2>&1   # not $(...): that would load into a subshell
out=$(cat "$T/out")
chk "upgrade: new loader overrides the old file's" '[[ "$out" != *"OLD LOADER RAN"* ]]'
chk "upgrade: old OP_SECRETS still loads" '[[ "$OLD_LIST_VAR" == val-of-old ]]'
out=$(op-env migrate 2>&1)
chk "upgrade: migrate tells the user to delete the leftover file" '[[ "$out" == *"lib/1password.sh is a leftover"* ]]'
rm -f "$PREFLIGHT_DIR/lib/1password.sh"

# ── a secret value with a newline must not set other variables ────────────────
printf 'REAL\top://v/i/r\n' > "$sets/n.tsv"
export FAKE_OP_INJECT_EXTRA='EVIL_PATH=/tmp/evil'
op-load-env > "$T/out" 2>&1; rc=$?
unset FAKE_OP_INJECT_EXTRA
chk "newline injection: unrequested name not exported" '[[ -z "${EVIL_PATH:-}" ]]'
chk "newline injection: reported as a failure" '[[ $rc -eq 1 && "$(cat "$T/out")" == *"unexpected output"* ]]'
chk "newline injection: the real secret still loads" '[[ "$REAL" == val-of-r ]]'
op-clear-env >/dev/null; rm -f "$sets"/*.tsv "$sets/.active"

# ── set -u (no OP_SECRETS, OP_BIN unset): nothing may hit an unbound variable ──
# OP_SECRETS is unset on a fresh install, so these paths must not read it bare.
printf 'SU\top://v/i/su\n' > "$sets/su.tsv"
unset OP_SECRETS
su=$( ( set -u
        op-load-env 2>&1
        [ "${SU:-}" = val-of-su ] || echo "SU-NOT-LOADED"
        op-env list 2>&1; op-env migrate 2>&1; op-clear-env 2>&1
        OP_BIN= ; op-status 2>&1 ) 2>&1 )
chk "set -u: no unbound-variable errors" '[[ "$su" != *"unbound variable"* && "$su" != *"parameter not set"* ]]'
chk "set -u: op-load-env still loads from the set" '[[ "$su" != *"SU-NOT-LOADED"* && "$su" != *"No secrets configured"* ]]'
rm -f "$sets"/*.tsv "$sets/.active"; OP_SECRETS=()

# ── hooks ─────────────────────────────────────────────────────────────────────
source "$R/lib/nanoleaf.sh"; source "$R/lib/onepassword.sh"
chk "after-load hook registered exactly once across re-sourcing" '[[ ${#_OP_AFTER_LOAD_HOOKS[@]} -eq 1 ]]'

echo "$passes passed, $fails failed"
[[ $fails -eq 0 ]]
