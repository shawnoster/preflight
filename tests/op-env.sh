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
# find, not a glob: an unmatched glob is an error in zsh.
clean_sets() { find "$sets" -maxdepth 1 -type f \( -name '*.tsv' -o -name .active \) -delete 2>/dev/null; }
any_sets() { [ -n "$(find "$sets" -maxdepth 1 -type f -name '*.tsv' 2>/dev/null)" ]; }
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
printf 'KEEP_ME\top://v/i/k\n' > "$sets/x.tsv"; clean_sets
op-load-env >/dev/null
printf 'OTHER\top://v/i/o\n' > "$sets/x.tsv"
FAKE_OP_SIGNED_OUT=1 op-load-env >/dev/null 2>&1; rc=$?
chk "failed sign-in: rc 1" '[[ $rc -ne 0 ]]'
chk "failed sign-in: old list remembered, so clear still works" 'op-clear-env >/dev/null; [[ -z "${KEEP_ME:-}" ]]'
clean_sets

# ── CRLF edits (WSL users editing from Windows) ───────────────────────────────
printf 'CRLF_VAR\top://v/i/f\r\n' > "$sets/w.tsv"
printf 'w\r\n' > "$sets/.active"
op-load-env >/dev/null
chk "CRLF .tsv and .active: value has no CR" '[[ "$CRLF_VAR" == val-of-f ]]'
chk "CRLF: list output has no CR" '[[ "$(op-env list)" != *$'"'"'\r'"'"'* ]]'
clean_sets

# ── ordering: first definition wins, in .active order ─────────────────────────
printf 'DUP\top://v/i/first\n'  > "$sets/a.tsv"
printf 'DUP\top://v/i/second\n' > "$sets/b.tsv"
chk "no .active: alphabetical, a wins" '[[ "$(_op_env_entries)" == *first* ]]'
printf 'b\na\n' > "$sets/.active"
chk ".active order decides: b wins" '[[ "$(_op_env_entries)" == *second* ]]'
clean_sets

# ── hand-edited garbage is ignored ────────────────────────────────────────────
printf 'ok1\top://v/i/k\nnot a name\top://v/i/k\nnoref\tx\n\n' > "$sets/junk.tsv"
echo "no_such_set" >> "$sets/.active"; echo "junk" >> "$sets/.active"
chk "garbage lines dropped, good line kept" '[[ "$(_op_env_entries)" == "ok1"$'"'"'\t'"'"'"op://v/i/k" ]]'
clean_sets

# ── legacy OP_SECRETS + migrate ───────────────────────────────────────────────
OP_SECRETS=($'LEGACY_A\top://v/i/a' $'bad name\top://v/i/z' $'NOREF\tnotop')
op-load-env >/dev/null
chk "legacy array loads, invalid entries dropped" '[[ "$LEGACY_A" == val-of-a && -z "${NOREF:-}" ]]'
out=$(op-env migrate legacy 2>&1)
chk "migrate wrote the valid key" 'grep -q "^LEGACY_A	op://v/i/a" "$sets/legacy.tsv"'
chk "migrate skipped the malformed ones" '! grep -q "bad name\|NOREF" "$sets/legacy.tsv"'
unset OP_SECRETS; op-load-env >/dev/null
chk "loads from the set once the array is gone" '[[ "$LEGACY_A" == val-of-a ]]'
clean_sets

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

# ── interactive prompts (need a real tty: they read /dev/tty) ─────────────────
# Drive `op-env` through a pty, feeding answers as typed input. Skipped without python3.
# Usage: tty_run "answers (\n-separated)" <shell snippet>   -> prints what the shell printed
tty_run() {
  PF_ANS="$1" PF_SNIP="$2" PF_SHELL="${ZSH_VERSION:+zsh}" PF_LIBS="$R/lib" python3 - <<'PY'
import os, pty, sys, select, time
ans = os.environ["PF_ANS"].encode().decode("unicode_escape").encode()
sh = os.environ["PF_SHELL"] or "bash"
snip = 'for f in "$PF_LIBS"/*.sh; do source "$f"; done; ' + os.environ["PF_SNIP"]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sh, [sh, "-c", snip])
os.write(fd, ans)
out = b""; end = time.time() + 15
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            d = os.read(fd, 4096)
        except OSError:
            break
        if not d:
            break
        out += d
    else:
        done, _ = os.waitpid(pid, os.WNOHANG)
        if done:
            break
sys.stdout.write(out.decode(errors="replace").replace("\r", ""))
PY
}

if command -v python3 >/dev/null 2>&1; then
  export PF_LIBS="$R/lib"
  # A PATH with the tools the libs need but no fzf, so the pickers use the numbered menu
  # (fzf would take over a pty). bash/zsh are linked too since tty_run execs them by name.
  nofzf="$T/nofzf"; mkdir -p "$nofzf"
  for c in bash zsh python3 awk sed grep cut sort find mktemp chmod mv rm cat tr paste stat dirname head; do
    p=$(command -v "$c" 2>/dev/null) && [[ "$p" == /* ]] && ln -sf "$p" "$nofzf/$c"
  done
  clean_sets
  out=$(PATH="$nofzf" tty_run '2\nPROMPTED_VAR\nop://v/i/p\n' 'op-env add')
  chk "prompts: add picks a set from the menu, then asks for var and ref" 'grep -q "^PROMPTED_VAR	op://v/i/p" "$sets/personal.tsv" 2>/dev/null'
  clean_sets

  out=$(PATH="$nofzf" tty_run '3\nnewset\nMENU_VAR\nop://v/i/m\n' 'op-env add')
  chk "prompts: '+ new set...' asks for a name" 'grep -q "^MENU_VAR	op://v/i/m" "$sets/newset.tsv" 2>/dev/null'
  clean_sets

  printf 'A1\top://v/i/a\n' > "$sets/one.tsv"; printf 'B1\top://v/i/b\n' > "$sets/two.tsv"
  PATH="$nofzf" tty_run 'two\n' 'op-env use' >/dev/null
  chk "prompts: op-env use reads the sets to activate" '[[ "$(cat "$sets/.active" 2>/dev/null)" == "two" ]]'
  clean_sets

  out=$(tty_run 'n\n' 'op-env add x GITHUB_TOKEN op://v/i/g; echo "rc=$?"')
  chk "prompts: declining the GITHUB_TOKEN warning adds nothing" '[[ "$out" == *"rc=1"* && ! -e "$sets/x.tsv" ]]'
  out=$(tty_run 'y\n' 'op-env add x GITHUB_TOKEN op://v/i/g; echo "rc=$?"')
  chk "prompts: confirming the GITHUB_TOKEN warning adds it" 'grep -q "^GITHUB_TOKEN" "$sets/x.tsv" 2>/dev/null'
  clean_sets

  # No terminal at all: must fail cleanly, not hang or write anything.
  out=$(op-env add </dev/null 2>&1); rc=$?
  chk "prompts: no tty -> fails, writes nothing" '[[ $rc -ne 0 ]] && ! any_sets'
fi
# ── a secret value with a newline must not set other variables ────────────────
printf 'REAL\top://v/i/r\n' > "$sets/n.tsv"
export FAKE_OP_INJECT_EXTRA='EVIL_PATH=/tmp/evil'
op-load-env > "$T/out" 2>&1; rc=$?
unset FAKE_OP_INJECT_EXTRA
chk "newline injection: unrequested name not exported" '[[ -z "${EVIL_PATH:-}" ]]'
chk "newline injection: reported as a failure" '[[ $rc -eq 1 && "$(cat "$T/out")" == *"unexpected output"* ]]'
chk "newline injection: the real secret still loads" '[[ "$REAL" == val-of-r ]]'
op-clear-env >/dev/null; clean_sets

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
clean_sets; OP_SECRETS=()

# ── hooks ─────────────────────────────────────────────────────────────────────
source "$R/lib/nanoleaf.sh"; source "$R/lib/onepassword.sh"
chk "after-load hook registered exactly once across re-sourcing" '[[ ${#_OP_AFTER_LOAD_HOOKS[@]} -eq 1 ]]'

echo "$passes passed, $fails failed"
[[ $fails -eq 0 ]]
