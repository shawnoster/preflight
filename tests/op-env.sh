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
# FAKE_OP_SIGNED_OUT=1 makes `whoami` fail (and `signin` emit nothing useful).
cat > "$OP_BIN" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  whoami) [[ -z "$FAKE_OP_SIGNED_OUT" ]] ;;
  signin) exit 1 ;;
  inject) in=$(cat); grep -q broken <<<"$in" && exit 1
          sed -E 's/\{\{ op:\/\/[^}]*\/([^/ }]+) \}\}/val-of-\1/' <<<"$in" ;;
  read)   ref="${@: -1}"; [[ "$ref" == *broken* ]] && exit 1; echo "val-of-${ref##*/}" ;;
esac
STUB
chmod +x "$OP_BIN"

fails=0 passes=0
chk() { if eval "$2"; then passes=$((passes + 1)); else fails=$((fails + 1)); echo "FAIL: $1"; fi; }
sets="$PREFLIGHT_DIR/config/envsets"

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
chk "nanoleaf env file is mode 600" '[[ $(stat -c %a "$HOME/.config/nanoleaf-direct/env") == 600 ]]'
chk "set files are mode 600" '[[ $(stat -c %a "$sets/guild.tsv") == 600 ]]'

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

# ── hooks ─────────────────────────────────────────────────────────────────────
source "$R/lib/nanoleaf.sh"; source "$R/lib/onepassword.sh"
chk "after-load hook registered exactly once across re-sourcing" '[[ ${#_OP_AFTER_LOAD_HOOKS[@]} -eq 1 ]]'

echo "$passes passed, $fails failed"
[[ $fails -eq 0 ]]
