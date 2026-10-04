#!/usr/bin/env bash
# tests/op-env.sh - env sets + op-env load, against a fake `op` in a scratch dir.
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
export HOME="$T/home" PREFLIGHT_DIR="$T/pf" PREFLIGHT_CONFIG_DIR="$T/cfg" PREFLIGHT_STATE_DIR="$T/state" OP_ACCOUNT=test OP_BIN="$T/op"
mkdir -p "$HOME" "$PREFLIGHT_CONFIG_DIR" "$PREFLIGHT_DIR/lib"

# Stub op: `inject` resolves {{ op://v/item/field }} to val-of-field and fails the
# whole batch if any reference mentions "broken"; `read` does the same per ref.
# FAKE_OP_INJECT_EXTRA="X=y" appends that line to inject output (what a secret value
# containing a newline looks like after substitution).
# FAKE_OP_MULTILINE=field makes that field resolve to a value containing a newline and a
# forged "SAFE=pwned" line.
# FAKE_OP_SIGNED_OUT=1 signs every account out.
# FAKE_OP_SIGNED_OUT_ACCT=<account> signs just that one out (the others still work).
# FAKE_OP_SIGNIN_OK_ACCT=<account> makes `signin` succeed for that account only, and
#   leaves it signed in afterwards (a signed-in-<account> marker beside the stub).
# FAKE_OP_SILENT_EMPTY_ACCT=<account> makes that account's `inject` exit 0 while
#   substituting empty values (real op.exe behaviour against a secondary account),
#   so the loader has to notice and re-read the account per secret.
# FAKE_OP_LOG=<file> records one "<verb> --account <account>" line per op call, so a
# test can assert which account each read was made against.
cat > "$OP_BIN" <<'STUB'
#!/usr/bin/env bash
acct_of() { local prev="" a="" x; for x in "$@"; do [[ "$prev" == "--account" ]] && a="$x"; prev="$x"; done; printf '%s' "$a"; }
log_call() { [[ -n "$FAKE_OP_LOG" ]] && printf '%s --account %s\n' "$1" "$2" >> "$FAKE_OP_LOG"; return 0; }
# FAKE_OP_NOVAULT_ACCT=<account>: inject and read against it fail the way real op does
# for a reference whose vault that account does not have (what a wrong OP_ACCOUNT gives).
novault() {
  [[ -n "$FAKE_OP_NOVAULT_ACCT" && "$(acct_of "$@")" == "$FAKE_OP_NOVAULT_ACCT" ]] || return 1
  # op's real wording: the reference and item come first, the reason last.
  printf '%s\n' "[ERROR] 2026/10/02 14:54:38 could not read secret 'op://Employee/Atlassian - API Token - Local Development/credential': could not get item Employee/Atlassian - API Token - Local Development: \"Employee\" isn't a vault in this account. Specify the vault with its ID or name." >&2
  return 0
}
case "$1" in
  whoami) a=$(acct_of "$@")
          [[ -e "$(dirname "$0")/signed-in-$a" ]] && exit 0
          [[ -n "$FAKE_OP_SIGNED_OUT_ACCT" && "$a" == "$FAKE_OP_SIGNED_OUT_ACCT" ]] && exit 1
          [[ -z "$FAKE_OP_SIGNED_OUT" ]] ;;
  # A successful signin leaves the account signed in, so the whoami that follows it
  # passes — as it does for real.
  signin) a=$(acct_of "$@"); log_call signin "$a"
          [[ "$a" == "$FAKE_OP_SIGNIN_OK_ACCT" ]] && { : > "$(dirname "$0")/signed-in-$a"; exit 0; }
          exit 1 ;;
  # op.exe's desktop unlock: `vault list` is what op-signin runs to trigger it.
  vault)  a=$(acct_of "$@"); log_call vault "$a"
          [[ -n "$FAKE_OP_SIGNED_OUT_ACCT" && "$a" == "$FAKE_OP_SIGNED_OUT_ACCT" ]] && exit 1
          exit 0 ;;
  inject) log_call inject "$(acct_of "$@")"
          novault "$@" && exit 1
          in=$(cat); grep -q broken <<<"$in" && exit 1
          # FAKE_OP_SILENT_EMPTY_ACCT=<account>: this account's batch exits 0 but
          # substitutes nothing — which real op.exe does for a reference in a second
          # account under desktop integration, where `op read --account` still works.
          if [[ -n "$FAKE_OP_SILENT_EMPTY_ACCT" && "$(acct_of "$@")" == "$FAKE_OP_SILENT_EMPTY_ACCT" ]]; then
            # Collapse "{{ ref }}" to nothing, so each record comes back NAME= with
            # an empty value — exit 0, no diagnostic, no secret.
            sed -E 's/=\{\{[^}]*\}\}/=/' <<<"$in"
            exit 0
          fi
          out=$(sed -E 's/\{\{ op:\/\/[^}]*\/([^/ }]+) \}\}/val-of-\1/' <<<"$in")
          # FAKE_OP_MULTILINE=field: that field's value is "x<newline>SAFE=pwned"
          if [[ -n "$FAKE_OP_MULTILINE" ]]; then out=${out//val-of-$FAKE_OP_MULTILINE/$'x\nSAFE=pwned'}; fi
          printf '%s\n' "$out"
          # (an if, not `[[ ]] && ...`: that would make inject exit 1 whenever the var is
          # empty and silently push every load onto the per-secret fallback path)
          if [[ -n "$FAKE_OP_INJECT_EXTRA" ]]; then printf '%s\n' "$FAKE_OP_INJECT_EXTRA"; fi ;;
  read)   log_call read "$(acct_of "$@")"
          novault "$@" && exit 1
          ref="${@: -1}"
          # A ref containing "emptyval": op exits 0 and prints nothing.
          [[ "$ref" == *emptyval* ]] && exit 0
          # FAKE_OP_READ_ERR: what a failing read writes to stderr (default: nothing).
          if [[ "$ref" == *broken* ]]; then
            if [[ -n "$FAKE_OP_READ_ERR" ]]; then printf '%s\n' "$FAKE_OP_READ_ERR" >&2; fi
            exit 1
          fi
          echo "val-of-${ref##*/}" ;;
esac
STUB
chmod +x "$OP_BIN"

fails=0 passes=0
chk() { if eval "$2"; then passes=$((passes + 1)); else fails=$((fails + 1)); echo "FAIL: $1"; fi; }
sets="$PREFLIGHT_CONFIG_DIR/envsets"
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
out=$(op-env load 2>&1); rc=$?
chk "empty load: rc 0 and hint" '[[ $rc -eq 0 && "$out" == *"op-env add"* ]]'
out=$(FAKE_OP_SIGNED_OUT=1 op-env load 2>&1); rc=$?
chk "empty load never signs in" '[[ $rc -eq 0 ]]'

# ── the happy path must be the single batch call, not the fallback ─────────────
mkdir -p "$sets"
printf 'BATCH1\top://v/i/b1\nBATCH2\top://v/i/b2\n' > "$sets/batch.tsv"
out=$(op-env load 2>&1)
chk "batch: no fallback message on success" '[[ "$out" != *"falling back"* ]]'
chk "batch: both loaded" '[[ "$out" == *"BATCH1"* && "$out" == *"BATCH2"* ]]'
op-env clear >/dev/null; clean_sets

# ── add / list / load ─────────────────────────────────────────────────────────
op-env add guild NPM_TOKEN 'op://Private/npmjs/credential' >/dev/null
op-env add personal GITEA_TOKEN 'op://Private/Gitea - Personal/pat' >/dev/null
op-env add personal NANOLEAF_TOKEN 'op://Private/nano/token' >/dev/null
chk "list shows keys" '[[ "$(op-env list)" == *NPM_TOKEN*GITEA_TOKEN*NANOLEAF_TOKEN* ]]'
op-env load >/dev/null
chk "loads a plain ref" '[[ "$NPM_TOKEN" == val-of-credential ]]'
chk "loads a ref containing spaces" '[[ "$GITEA_TOKEN" == val-of-pat ]]'
chk "nanoleaf hook wrote the token" 'grep -q "NANOLEAF_TOKEN=val-of-token" "$HOME/.config/nanoleaf-direct/env"'
chk "nanoleaf env file is mode 600" '[[ $(mode "$HOME/.config/nanoleaf-direct/env") == 600 ]]'
chk "set files are mode 600" '[[ $(mode "$sets/guild.tsv") == 600 ]]'

# ── use / rm / stale handling ─────────────────────────────────────────────────
op-env use guild >/dev/null; op-env load >/dev/null
chk "deactivated set is unset on next load" '[[ -z "${GITEA_TOKEN:-}" && -n "${NPM_TOKEN:-}" ]]'
op-env use guild personal >/dev/null; op-env load >/dev/null
op-env rm personal GITEA_TOKEN >/dev/null; op-env load >/dev/null
chk "removed key is unset on next load" '[[ -z "${GITEA_TOKEN:-}" && -n "${NANOLEAF_TOKEN:-}" ]]'

# ── broken reference -> per-secret fallback ───────────────────────────────────
op-env add guild BAD 'op://v/broken/x' >/dev/null
out=$(op-env load 2>&1); rc=$?
chk "fallback: rc 1" '[[ $rc -eq 1 ]]'
chk "fallback: reports the bad one" '[[ "$out" == *"BAD (failed to load)"* && "$out" == *"NPM_TOKEN"* ]]'
op-env load >/dev/null
chk "fallback: the others still load" '[[ -n "${NPM_TOKEN:-}" && -z "${BAD:-}" ]]'
op-env rm guild BAD >/dev/null

# ── clear ─────────────────────────────────────────────────────────────────────
op-env clear >/dev/null
chk "op-env clear clears everything loaded" '[[ -z "${NPM_TOKEN:-}${NANOLEAF_TOKEN:-}" ]]'
op-env load >/dev/null; rm "$sets/guild.tsv"; op-env clear >/dev/null
chk "op-env clear works after the definition is gone" '[[ -z "${NPM_TOKEN:-}" ]]'

# ── failed sign-in ────────────────────────────────────────────────────────────
# Start from a clean dir *before* creating the fixture, so KEEP_ME really loads.
clean_sets; printf 'KEEP_ME\top://v/i/k\n' > "$sets/x.tsv"
op-env load >/dev/null
chk "failed sign-in: precondition, KEEP_ME loaded" '[[ "$KEEP_ME" == val-of-k ]]'

# Definition unchanged: a failed sign-in must not disturb what is still defined.
FAKE_OP_SIGNED_OUT=1 op-env load >/dev/null 2>&1; rc=$?
chk "failed sign-in: rc 1" '[[ $rc -ne 0 ]]'
chk "failed sign-in: a still-defined variable stays set" '[[ "$KEEP_ME" == val-of-k ]]'
op-env clear >/dev/null
chk "failed sign-in: op-env clear then clears it" '[[ -z "${KEEP_ME:-}" ]]'

# List changed, then sign-in fails: the new list must not be recorded as loaded
# (nothing from it was), and the variable the old list set must still be cleared.
clean_sets; printf 'KEEP_ME\top://v/i/k\n' > "$sets/x.tsv"; op-env load >/dev/null
chk "failed sign-in: precondition, memory holds the loaded list" '[[ "$_OP_LOADED_VARS" == KEEP_ME ]]'
printf 'OTHER\top://v/i/o\n' > "$sets/x.tsv"
FAKE_OP_SIGNED_OUT=1 op-env load >/dev/null 2>&1
chk "failed sign-in: memory not advanced to a list that never loaded" '[[ "$_OP_LOADED_VARS" == KEEP_ME && -z "${OTHER:-}" ]]'
chk "failed sign-in: the removed variable was unset" '[[ -z "${KEEP_ME:-}" ]]'
op-env clear >/dev/null; clean_sets

# ── CRLF edits (WSL users editing from Windows) ───────────────────────────────
printf 'CRLF_VAR\top://v/i/f\r\n' > "$sets/w.tsv"
printf 'w\r\n' > "$sets/.active"
op-env load >/dev/null
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

# A malformed ref (op://broken is not op://vault/item/field) is dropped by the loader.
chk "loader drops a malformed ref" '[[ "$(printf "SHORT\top://broken\n" > "$sets/bad.tsv"; _op_env_entries)" != *SHORT* ]]'
clean_sets

# ── a failed secret says why (op's own error), not just "failed to load" ───────
# The loader used to discard op's stderr, so a wrong OP_ACCOUNT looked like a broken
# reference: "failed to load" with nothing to go on.
printf 'VAULTY\top://Employee/Item/credential\n' > "$sets/v.tsv"
out=$(FAKE_OP_NOVAULT_ACCT=test op-env load 2>&1); rc=$?
chk "error detail: op's message is shown" '[[ "$out" == *"isn'"'"'t a vault in this account"* ]]'
chk "error detail: names the account that was used" '[[ "$out" == *"account test"* ]]'
chk "error detail: the repeated reference and item lead-in is dropped" '[[ "$out" != *"could not read secret"* && "$out" != *"could not get item"* ]]'
chk "error detail: the reason survives the length cut" '[[ "$out" == *"Specify the vault with its ID or name"* ]]'
chk "error detail: op's log prefix and timestamp are dropped" '[[ "$out" != *"[ERROR]"* && "$out" != *"2026/10/02"* ]]'
chk "error detail: still a failure, variable unset" '[[ $rc -eq 1 && -z "${VAULTY:-}" ]]'
chk "error detail: the message sits under the warning" '[[ "$out" == *"VAULTY (failed to load)"*"account test: "* ]]'
clean_sets

# A reference that genuinely is wrong gets op's text; a good one next to it gets no detail.
printf 'GOODONE\top://v/i/good\nBADONE\top://v/broken/x\n' > "$sets/v.tsv"
out=$(FAKE_OP_READ_ERR='could not read secret: item not found' op-env load 2>&1)
chk "error detail: a bad reference shows op's error" '[[ "$out" == *"BADONE (failed to load)"* && "$out" == *"item not found"* ]]'
chk "error detail: a secret that loaded has no detail line" '[[ "$out" == *"GOODONE"* && "$out" != *"GOODONE (failed"* ]]'
chk "error detail: no secret value is ever printed" '[[ "$out" != *val-of-* ]]'
clean_sets

# Only the first line, with control characters stripped, and bounded in length.
printf 'BADONE\top://v/broken/x\n' > "$sets/v.tsv"
out=$(FAKE_OP_READ_ERR=$'first line \033[31mred\r\nSECOND LINE SHOULD NOT APPEAR' op-env load 2>&1)
chk "error detail: only the first line" '[[ "$out" == *"first line"* && "$out" != *"SECOND LINE"* ]]'
chk "error detail: control characters removed" '[[ "$out" != *$'"'"'\033'"'"'* && "$out" != *$'"'"'\r'"'"'* ]]'
long=$(printf 'x%.0s' $(seq 1 500))
out=$(FAKE_OP_READ_ERR="$long" op-env load 2>&1)
longest=$(printf '%s\n' "$out" | awk '{ if (length($0) > m) m = length($0) } END { print m }')
chk "error detail: a very long message is cut" '[[ "$longest" -lt 260 ]]'
clean_sets

# op exits 0 but prints nothing: say so instead of staying silent.
printf 'EMPTYV\top://v/broken-emptyval/f\n' > "$sets/v.tsv"
out=$(op-env load 2>&1)
chk "error detail: an empty value with exit 0 is called out" '[[ "$out" == *"EMPTYV (failed to load)"* && "$out" == *"empty value (exit 0)"* ]]'
clean_sets

# op fails and says nothing: still a line, with the exit status.
printf 'MUTE\top://v/broken/x\n' > "$sets/v.tsv"
out=$(op-env load 2>&1)
chk "error detail: a silent failure reports the exit status" '[[ "$out" == *"MUTE (failed to load)"* && "$out" == *"exited 1"* ]]'
clean_sets

# With several accounts, the detail names the account that failed, and the others load.
printf 'HOMEV\top://v/i/home\nWORKV\top://Employee/Item/credential\twork\n' > "$sets/v.tsv"
FAKE_OP_NOVAULT_ACCT=work op-env load > "$T/out" 2>&1   # not $(...): that loads into a subshell
out=$(cat "$T/out")
chk "error detail: multi-account names the failing account" '[[ "$out" == *"WORKV (failed to load, via work)"* && "$out" == *"account work: "* ]]'
chk "error detail: the healthy account still loaded" '[[ "$out" == *"HOMEV (via test)"* && "${HOMEV:-}" == val-of-home ]]'
op-env clear >/dev/null; clean_sets

# Capturing stderr must not leave files behind, and must not depend on a writable tmp.
printf 'BADONE\top://v/broken/x\n' > "$sets/v.tsv"
mkdir -p "$T/tmpd"; TMPDIR="$T/tmpd" FAKE_OP_READ_ERR='some error' op-env load >/dev/null 2>&1
chk "error detail: no temp files left behind" '[[ -z "$(find "$T/tmpd" -type f 2>/dev/null)" ]]'
out=$(TMPDIR="$T/does-not-exist" FAKE_OP_READ_ERR='some error' op-env load 2>&1); rc=$?
chk "error detail: still reports a failure when there is no usable tmp dir" '[[ $rc -eq 1 && "$out" == *"BADONE (failed to load)"* ]]'
clean_sets

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

  # No terminal at all: must fail cleanly, not hang or write anything. Redirecting
  # stdin is not enough: the process would still have a controlling terminal, /dev/tty
  # would open, and fzf would run because stderr is a tty. So start a new session with
  # stdin/stdout/stderr detached, which is what a cron job or a pipe has.
  notty_run() {
    PF_SNIP="$1" PF_SHELL="${ZSH_VERSION:+zsh}" PF_LIBS="$R/lib" python3 - <<'PY'
import os, subprocess, sys
sh = os.environ["PF_SHELL"] or "bash"
snip = 'for f in "$PF_LIBS"/*.sh; do source "$f"; done; ' + os.environ["PF_SNIP"]
try:
    r = subprocess.run([sh, "-c", snip], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, start_new_session=True, timeout=15)
    sys.stdout.write(r.stdout.decode(errors="replace") + "\nNOTTY_RC=%d\n" % r.returncode)
except subprocess.TimeoutExpired:
    sys.stdout.write("\nNOTTY_RC=TIMEOUT\n")
PY
  }
  out=$(notty_run 'op-env add; echo "cmd_rc=$?"')
  chk "no tty: op-env add does not hang" '[[ "$out" != *NOTTY_RC=TIMEOUT* ]]'
  chk "no tty: op-env add fails" '[[ "$out" == *"cmd_rc=1"* ]]'
  chk "no tty: writes nothing" '! any_sets'
  out=$(notty_run 'op-env add x FOO; echo "cmd_rc=$?"')
  chk "no tty: a missing ref is not invented" '[[ "$out" == *"cmd_rc=1"* ]] && ! any_sets'
  printf 'A1\top://v/i/a\n' > "$sets/one.tsv"
  out=$(notty_run 'op-env use; echo "cmd_rc=$?"')
  chk "no tty: op-env use fails without changing the active sets" '[[ "$out" == *"cmd_rc=1"* && ! -e "$sets/.active" ]]'
  clean_sets
fi

# ── writes are all-or-nothing (Copilot review) ────────────────────────────────
# An unwritable .active must stop a brand-new set before anything is created.
# (chmod does not bind root, so this one is skipped there.)
if [[ "$(id -u)" != 0 ]]; then
  printf 'old\n' > "$sets/old.tsv.tmp" && rm -f "$sets/old.tsv.tmp"
  printf 'O\top://v/i/o\n' > "$sets/old.tsv"; printf 'old\n' > "$sets/.active"; chmod 444 "$sets/.active"
  out=$(op-env add newset FOO op://v/i/f 2>&1); rc=$?
  chk "unwritable .active: op-env add fails" '[[ $rc -ne 0 && "$out" == *"not writable"* ]]'
  chk "unwritable .active: no half-created set" '[[ ! -e "$sets/newset.tsv" ]]'
  chk "unwritable .active: no stray temp files" '[[ -z "$(find "$sets" -name ".tmp.*" 2>/dev/null)" ]]'
  chk "unwritable .active: what loads is unchanged" '[[ "$(_op_env_entries | cut -f1 | tr "\n" " ")" == "O " ]]'
  chmod 644 "$sets/.active"
  # Once fixed, the same add works and activates the set.
  op-env add newset FOO op://v/i/f >/dev/null 2>&1; rc=$?
  chk "after fixing .active: add succeeds and activates the set" '[[ $rc -eq 0 ]] && grep -qx newset "$sets/.active" && grep -q "^FOO" "$sets/newset.tsv"'
  clean_sets
fi

op-env clear >/dev/null; clean_sets

# ── a secret value with a newline must not set other variables ────────────────
# A stray line after a record is part of that record's value, not a new variable.
printf 'REAL\top://v/i/r\n' > "$sets/n.tsv"
export FAKE_OP_INJECT_EXTRA='EVIL_PATH=/tmp/evil'
op-env load > "$T/out" 2>&1; rc=$?
unset FAKE_OP_INJECT_EXTRA
chk "newline value: unrequested name not exported" '[[ -z "${EVIL_PATH:-}" && $rc -eq 0 ]]'
want_real=$'val-of-r\nEVIL_PATH=/tmp/evil'
chk "newline value: kept intact inside its own secret" '[[ "$REAL" == "$want_real" ]]'
op-env clear >/dev/null; clean_sets

# Copilot's case: a multi-line value forges "SAFE=..." where SAFE is ALSO a requested
# secret. A name check alone can't tell them apart; the per-call record tag does.
printf 'SAFE\top://v/i/safefield\nEVIL\top://v/i/evilfield\n' > "$sets/f.tsv"
FAKE_OP_MULTILINE=evilfield op-env load >/dev/null 2>&1
chk "forged line cannot overwrite another requested secret" '[[ "$SAFE" == val-of-safefield ]]'
want_evil=$'x\nSAFE=pwned'
chk "the multi-line secret itself loads whole" '[[ "$EVIL" == "$want_evil" ]]'
# the same, with the forging secret FIRST (order must not matter)
printf 'EVIL\top://v/i/evilfield\nSAFE\top://v/i/safefield\n' > "$sets/f.tsv"
FAKE_OP_MULTILINE=evilfield op-env load >/dev/null 2>&1
chk "forged line cannot overwrite a secret that comes later" '[[ "$SAFE" == val-of-safefield ]]'
op-env clear >/dev/null; clean_sets

# ── set -u (OP_BIN unset): nothing may hit an unbound variable ──
printf 'SU\top://v/i/su\n' > "$sets/su.tsv"
su=$( ( set -u
        op-env load 2>&1
        [ "${SU:-}" = val-of-su ] || echo "SU-NOT-LOADED"
        op-env list 2>&1; op-env clear 2>&1
        OP_BIN= ; op-status 2>&1 ) 2>&1 )
chk "set -u: no unbound-variable errors" '[[ "$su" != *"unbound variable"* && "$su" != *"parameter not set"* ]]'
chk "set -u: op-env load still loads from the set" '[[ "$su" != *"SU-NOT-LOADED"* && "$su" != *"No secrets configured"* ]]'
clean_sets

# ── per-secret account: one set spanning two 1Password accounts ────────────────
# `op` resolves a reference against exactly one account per call, so entries naming
# different accounts cannot share one `op inject`. op-env load groups by account and
# issues one batch each. A line with no third column means $OP_ACCOUNT, so the
# two-column lines every install already has are unaffected.
op-env clear >/dev/null; clean_sets
export FAKE_OP_LOG="$T/oplog"

printf 'DEF\top://v/i/d\nALT\top://v/i/a\twork\n' > "$sets/acct.tsv"
: > "$FAKE_OP_LOG"
op-env load > "$T/out" 2>&1; rc=$?
out=$(cat "$T/out")
chk "two accounts: both secrets load" '[[ $rc -eq 0 && "$DEF" == val-of-d && "$ALT" == val-of-a ]]'
chk "two accounts: one inject per account" '[[ $(grep -c "^inject " "$FAKE_OP_LOG") -eq 2 ]]'
chk "two accounts: a two-column line uses \$OP_ACCOUNT" 'grep -qx "inject --account test" "$FAKE_OP_LOG"'
chk "two accounts: a third column selects its own account" 'grep -qx "inject --account work" "$FAKE_OP_LOG"'
chk "two accounts: neither batch went through per-secret reads" '! grep -q "^read " "$FAKE_OP_LOG"'
chk "two accounts: output says where each secret came from" '[[ "$out" == *"DEF (via test)"* && "$out" == *"ALT (via work)"* ]]'

# Accounts are visited in order of first appearance, so a single-account load is
# still exactly one call and its output carries no "(via ...)" decoration.
clean_sets; printf 'ONE\top://v/i/o\n' > "$sets/one.tsv"
: > "$FAKE_OP_LOG"
op-env load > "$T/out" 2>&1
out=$(cat "$T/out")
chk "one account: still a single inject" '[[ $(grep -c "^inject " "$FAKE_OP_LOG") -eq 1 ]]'
chk "one account: output is unchanged (no account decoration)" '[[ "$out" == *"✅ ONE"* && "$out" != *"(via"* ]]'

# A bad reference only poisons its own account's batch. The other account must still
# resolve through the fast path, and the fallback reads must target the account that
# actually failed.
clean_sets
printf 'DEF_BAD\top://v/broken/d\nALT\top://v/i/a\twork\n' > "$sets/acct.tsv"
: > "$FAKE_OP_LOG"
op-env load > "$T/out" 2>&1; rc=$?
out=$(cat "$T/out")
chk "one account broken: the other still loads" '[[ "$ALT" == val-of-a && -z "${DEF_BAD:-}" ]]'
chk "one account broken: rc 1" '[[ $rc -eq 1 ]]'
chk "one account broken: the good account still used the batch path" 'grep -qx "inject --account work" "$FAKE_OP_LOG"'
chk "one account broken: fallback reads targeted the failing account" 'grep -qx "read --account test" "$FAKE_OP_LOG" && ! grep -qx "read --account work" "$FAKE_OP_LOG"'
chk "one account broken: the message names the account" '[[ "$out" == *"Batch resolve failed for test"* && "$out" == *"DEF_BAD (failed to load, via test)"* ]]'
op-env clear >/dev/null

# An `op inject` that exits 0 while substituting an empty value is a failed batch, not
# a secret that resolved to nothing — real op.exe does this against a second account
# under desktop integration, where the per-secret read for the same reference works.
# Without this the value is silently treated as absent, and (worse) a genuinely empty
# secret and an unresolvable one are indistinguishable.
clean_sets
printf 'SILENT\top://v/i/s\twork\nQUIET\top://v/i/q\twork\n' > "$sets/acct.tsv"
: > "$FAKE_OP_LOG"
FAKE_OP_SILENT_EMPTY_ACCT=work op-env load > "$T/out" 2>&1; rc=$?
out=$(cat "$T/out")
chk "silent empty batch: fell back to per-secret reads" 'grep -qx "read --account work" "$FAKE_OP_LOG"'
chk "silent empty batch: both secrets still load" '[[ "$SILENT" == val-of-s && "$QUIET" == val-of-q ]]'
chk "silent empty batch: rc 0 (recovered, nothing actually failed)" '[[ $rc -eq 0 ]]'
chk "silent empty batch: says it fell back" '[[ "$out" == *"Batch resolve failed"* ]]'
chk "silent empty batch: does not report a failure for a secret it recovered" '[[ "$out" != *"SILENT (failed to load"* && "$out" != *"QUIET (failed to load"* ]]'
op-env clear >/dev/null

# A malformed account column is dropped rather than passed to op as a flag value, and
# a line with more columns than the format allows is dropped too.
clean_sets
printf 'BADACCT\top://v/i/z\tnot a valid acct!\nEXTRA\top://v/i/x\twork\tsurplus\nGOOD\top://v/i/g\nNAMED\top://v/i/n\twork\n' > "$sets/acct.tsv"
chk "malformed account column is dropped" '[[ "$(_op_env_entries)" != *BADACCT* ]]'
chk "an over-long line is dropped" '[[ "$(_op_env_entries)" != *EXTRA* ]]'
chk "the well-formed lines survive, account column and all" '[[ "$(_op_env_entries)" == *"GOOD"$'"'"'\t'"'"'"op://v/i/g"* && "$(_op_env_entries)" == *"NAMED"$'"'"'\t'"'"'"op://v/i/n"$'"'"'\t'"'"'"work" ]]'

# Each account needs its own session on native op. If one cannot be established the
# load must fail *before* recording anything, so op-env clear still knows what is set.
clean_sets
printf 'SESS\top://v/i/s\nSESSA\top://v/i/sa\twork\n' > "$sets/acct.tsv"
op-env clear >/dev/null
FAKE_OP_SIGNED_OUT_ACCT=work op-env load >/dev/null 2>&1; rc=$?
chk "unreachable account: rc 1" '[[ $rc -ne 0 ]]'
chk "unreachable account: loaded-vars memory not advanced" '[[ -z "${_OP_LOADED_VARS}" && -z "${SESS:-}" ]]'
# …and sign-in is attempted for that account, not just the default one. The account
# stays signed out until `signin` runs (the stub flips it then), so a load that never
# calls signin cannot pass this.
: > "$FAKE_OP_LOG"
FAKE_OP_SIGNED_OUT_ACCT=work FAKE_OP_SIGNIN_OK_ACCT=work op-env load >/dev/null 2>&1; rc=$?
chk "sign-in is attempted for the named account" 'grep -qx "signin --account work" "$FAKE_OP_LOG"'
chk "sign-in is not attempted for an account that is already signed in" '! grep -qx "signin --account test" "$FAKE_OP_LOG"'
chk "after that sign-in the whole set loads" '[[ $rc -eq 0 && "$SESSA" == val-of-sa && "$SESS" == val-of-s ]]'
rm -f "$T"/signed-in-*
op-env clear >/dev/null

# op.exe has no `signin`: op-signin unlocks via `vault list`. A second account that
# cannot be unlocked must still fail the load before anything is exported, rather than
# the first account's variables landing while the second quietly fails.
mkdir -p "$T/winbin"; cp "$OP_BIN" "$T/winbin/op.exe"
: > "$FAKE_OP_LOG"
( OP_BIN="$T/winbin/op.exe" FAKE_OP_SIGNED_OUT_ACCT=work; export FAKE_OP_SIGNED_OUT_ACCT
  op-env load >/dev/null 2>&1; rc=$?
  echo "$rc|${SESS:-}|${SESSA:-}|${_OP_LOADED_VARS}" > "$T/exe-result" )
IFS='|' read -r exe_rc exe_sess exe_sessa exe_memory < "$T/exe-result"
chk "op.exe: every account is checked up front (unlock tried for the second)" 'grep -qx "vault --account work" "$FAKE_OP_LOG"'
chk "op.exe: a second account that cannot unlock fails the load" '[[ $exe_rc -ne 0 ]]'
chk "op.exe: nothing from the first account was exported" '[[ -z "$exe_sess" && -z "$exe_sessa" && -z "$exe_memory" ]]'
chk "op.exe: no inject ran before the failure" '! grep -q "^inject " "$FAKE_OP_LOG"'
unset FAKE_OP_SIGNED_OUT_ACCT FAKE_OP_SIGNIN_OK_ACCT

# ── add / list / rm with an account ────────────────────────────────────────────
clean_sets; op-env clear >/dev/null
op-env add guild WORK_TOKEN 'op://Other/Item/credential' work >/dev/null
chk "add writes the account as a third column" 'grep -qx "WORK_TOKEN$(printf "\t")op://Other/Item/credential$(printf "\t")work" "$sets/guild.tsv"'
chk "list shows the account when it is not the default" '[[ "$(op-env list)" == *"WORK_TOKEN"* && "$(op-env list)" == *"[account: work]"* ]]'
# Re-adding without an account must keep the one already on the line: silently falling
# back to $OP_ACCOUNT would move the secret to a different account.
op-env add guild WORK_TOKEN 'op://Other/Item/credential2' >/dev/null
chk "re-adding without an account keeps the existing account" 'grep -qx "WORK_TOKEN$(printf "\t")op://Other/Item/credential2$(printf "\t")work" "$sets/guild.tsv"'
# Naming the default account explicitly is not decoration, and is not shown as one.
op-env add guild SAME_TOKEN 'op://Other/Item/c' test >/dev/null
chk "an account equal to \$OP_ACCOUNT is stored but not displayed" '[[ "$(op-env list)" == *SAME_TOKEN* && "$(op-env list)" != *"[account: test]"* ]]'
out=$(op-env add guild NOPE 'op://Other/Item/c' 'bad account!' 2>&1); rc=$?
chk "add rejects a malformed account" '[[ $rc -ne 0 && "$out" == *"Invalid account"* ]]'
chk "a rejected add writes nothing" '! grep -q NOPE "$sets/guild.tsv"'
chk "rm removes a key that carries an account" 'op-env rm guild WORK_TOKEN >/dev/null && ! grep -q WORK_TOKEN "$sets/guild.tsv"'
# op-env clear only cares about names, so the account column must not confuse it.
op-env clear >/dev/null
chk "op-env clear clears a secret defined with an account" '[[ -z "${SAME_TOKEN:-}" ]]'

# Two-column lines must come out of op-env add exactly as they always did, or every
# existing install's set files churn on the next edit.
clean_sets
op-env add guild PLAIN 'op://v/i/p' >/dev/null
chk "add without an account still writes exactly the two-column line" '[[ "$(cat "$sets/guild.tsv"; echo x)" == "$(printf "PLAIN\top://v/i/p\nx")" ]]'
unset FAKE_OP_LOG; clean_sets; op-env clear >/dev/null

# ── hooks ─────────────────────────────────────────────────────────────────────
source "$R/lib/nanoleaf.sh"; source "$R/lib/onepassword.sh"
chk "after-load hook registered exactly once across re-sourcing" '[[ ${#_OP_AFTER_LOAD_HOOKS[@]} -eq 1 ]]'

# ── op-env load / clear (named sets) ──────────────────────────────────────────
# `op-env load` is op-env load; with set names it loads just those sets, adds to what is loaded,
# unsets nothing, and works on an inactive set. A plain load stays authoritative.
export FAKE_OP_LOG="$T/oplog"
op-env clear >/dev/null 2>&1; clean_sets; mkdir -p "$sets"
oplog_reset() { : > "$FAKE_OP_LOG"; }
oplog_count() { grep -c . "$FAKE_OP_LOG" 2>/dev/null || true; }
mkset() { local name=$1; shift; printf '%s\n' "$@" > "$sets/$name.tsv"; }
mkset a $'A1\top://v/i/a1'
mkset b $'B1\top://v/i/b1' $'B2\top://v/i/b2'

# The plain forms: what `op-env load` and `op-env clear` print and do with no set names.
oplog_reset
out=$(op-env load 2>&1); rc=$?
chk "plain load: rc 0, a line per secret with no label (single account)" '[[ $rc -eq 0 && "$out" == *"✅ A1"* && "$out" == *"✅ B1"* && "$out" == *"✅ B2"* && "$out" != *"via "* ]]'
out=$(op-env clear 2>&1)
chk "plain clear: the usual message" '[[ "$out" == *"Secure environment variables cleared"* && -z "${A1:-}${B1:-}${B2:-}" ]]'

# A subset is additive: the other set's variables stay, and so does the memory of them.
op-env load >/dev/null 2>&1
chk "full load: all three set" '[[ "$A1" == val-of-a1 && "$B1" == val-of-b1 && "$B2" == val-of-b2 ]]'
unset B1 B2
op-env load b >/dev/null 2>&1
chk "subset load: the named set's variables come back" '[[ "$B1" == val-of-b1 && "$B2" == val-of-b2 ]]'
chk "subset load: the other set's variable is untouched"  '[[ "$A1" == val-of-a1 ]]'
chk "subset load: the loaded-vars memory still lists every set" '[[ "$_OP_LOADED_VARS" == *A1* && "$_OP_LOADED_VARS" == *B1* && "$_OP_LOADED_VARS" == *B2* ]]'
chk "subset load: names are not duplicated in the memory"       '[[ $(printf "%s\n" "$_OP_LOADED_VARS" | grep -cx B1) -eq 1 ]]'

# Subset clear: only the named set's variables, and the memory keeps the rest.
op-env clear b >/dev/null 2>&1
chk "subset clear: the named set's variables are unset"  '[[ -z "${B1:-}${B2:-}" ]]'
chk "subset clear: the other set stays loaded"           '[[ "$A1" == val-of-a1 ]]'
chk "subset clear: the memory keeps only what is still loaded" '[[ "$_OP_LOADED_VARS" == A1 ]]'
out=$(op-env clear b 2>&1)
chk "subset clear: names the sets in its message"        '[[ "$out" == *"b"* && "$out" != *"Secure environment variables cleared"* ]]'
op-env clear >/dev/null 2>&1
chk "a later full clear still clears what is left"       '[[ -z "${A1:-}" && -z "$_OP_LOADED_VARS" ]]'

# A subset load unsets nothing, even when other loaded variables are no longer defined.
op-env load >/dev/null 2>&1
rm "$sets/a.tsv"
op-env load b >/dev/null 2>&1
chk "subset load: a variable whose set is gone is not unset (only a full load does that)" '[[ "$A1" == val-of-a1 ]]'
op-env load >/dev/null 2>&1
chk "a plain load is authoritative: the same variable is unset now" '[[ -z "${A1:-}" && "$B1" == val-of-b1 ]]'
op-env clear >/dev/null 2>&1; mkset a $'A1\top://v/i/a1'

# An inactive set: naming it loads it, with a note; the next plain load unsets it again.
printf 'a\n' > "$sets/.active"
oplog_reset
out=$(op-env load b 2>&1)
op-env load b >/dev/null 2>&1
chk "inactive set: loads when named"                  '[[ "$B1" == val-of-b1 && "$B2" == val-of-b2 ]]'
chk "inactive set: says it is not active, and how to keep it" '[[ "$out" == *"not active"* && "$out" == *"op-env use b"* ]]'
chk "inactive set: an active set gives no such note"  '[[ "$(op-env load a 2>&1)" != *"not active"* ]]'
op-env load >/dev/null 2>&1
chk "inactive set: the next plain load unsets it (documented)" '[[ -z "${B1:-}${B2:-}" && "$A1" == val-of-a1 ]]'
op-env clear >/dev/null 2>&1; rm -f "$sets/.active"

# Bad names stop before anything changes or signs in.
op-env load >/dev/null 2>&1; before="$_OP_LOADED_VARS"; oplog_reset
for bad in nope Bad "../x" "a b"; do
  out=$(op-env load "$bad" 2>&1); rc=$?
  chk "load '$bad' fails with the name in the message" '[[ $rc -ne 0 && "$out" == *"Nothing was changed"* ]]'
done
out=$(op-env load a nope 2>&1); rc=$?
chk "load: one bad name among good ones loads none of them" '[[ $rc -ne 0 && "$(oplog_count)" == 0 && "$_OP_LOADED_VARS" == "$before" ]]'
out=$(op-env clear nope 2>&1); rc=$?
chk "clear: an unknown set fails and unsets nothing"       '[[ $rc -ne 0 && "$A1" == val-of-a1 && "$_OP_LOADED_VARS" == "$before" ]]'
chk "bad names: no op call was made (no sign-in either)"   '[[ "$(oplog_count)" == 0 ]]'
op-env clear >/dev/null 2>&1

# A failed sign-in during a subset load leaves the memory and the environment as they were.
op-env load a >/dev/null 2>&1; before="$_OP_LOADED_VARS"
FAKE_OP_SIGNED_OUT=1 op-env load b >/dev/null 2>&1; rc=$?
chk "subset load: a failed sign-in fails"               '[[ $rc -ne 0 ]]'
chk "subset load: ...sets nothing from the set"         '[[ -z "${B1:-}${B2:-}" ]]'
chk "subset load: ...and leaves the memory unchanged"   '[[ "$_OP_LOADED_VARS" == "$before" && "$A1" == val-of-a1 ]]'
op-env clear >/dev/null 2>&1

# A set may be called "note" (a legal name): it is validated like any other, not read as a flag.
oplog_reset
out=$(op-env clear note 2>&1); rc=$?
chk "clear note (no such set): fails with the name, like any other set" '[[ $rc -ne 0 && "$out" == *"No env set"*note* ]]'
out=$(op-env load a note 2>&1); rc=$?
chk "load a note (no such set): fails, nothing loaded, no op call"      '[[ $rc -ne 0 && "$out" == *"No env set"*note* && "$(oplog_count)" == 0 ]]'
mkset note $'N1\top://v/i/n1'
op-env load note >/dev/null 2>&1
chk "a real set called note loads by name"  '[[ "$N1" == val-of-n1 ]]'
op-env clear note >/dev/null 2>&1
chk "...and clears by name"                '[[ -z "${N1:-}" ]]'
rm "$sets/note.tsv"; op-env clear >/dev/null 2>&1

# Provenance: a variable two sets define belongs to the first (as the loader decides), so clearing the
# other set does not remove it.
mkset s1 $'SHARED\top://v/i/from-s1' $'ONLY1\top://v/i/only1'
mkset s2 $'SHARED\top://v/i/from-s2' $'ONLY2\top://v/i/only2'
op-env load s1 s2 >/dev/null 2>&1
chk "shared variable: the first set named supplies it" '[[ "$SHARED" == val-of-from-s1 && "$ONLY1" == val-of-only1 && "$ONLY2" == val-of-only2 ]]'
op-env clear s2 >/dev/null 2>&1
chk "clear the set that lost: its own variable goes"           '[[ -z "${ONLY2:-}" ]]'
chk "clear the set that lost: the shared variable stays"       '[[ "$SHARED" == val-of-from-s1 && "$ONLY1" == val-of-only1 ]]'
chk "clear the set that lost: the shared one stays in the memory" '[[ "$_OP_LOADED_VARS" == *SHARED* && "$_OP_LOADED_VARS" != *ONLY2* ]]'
op-env clear s1 >/dev/null 2>&1
chk "clear the set that won: the shared variable goes now"     '[[ -z "${SHARED:-}${ONLY1:-}" && -z "$_OP_LOADED_VARS" ]]'

# Loading the losing set by name afterwards makes it the supplier of that variable.
op-env load s1 s2 >/dev/null 2>&1
op-env load s2 >/dev/null 2>&1
chk "a later named load re-points the variable at the set that just loaded it" '[[ "$SHARED" == val-of-from-s2 ]]'
op-env clear s1 >/dev/null 2>&1
chk "...so clearing s1 leaves it"   '[[ "$SHARED" == val-of-from-s2 && -z "${ONLY1:-}" ]]'
op-env clear s2 >/dev/null 2>&1
chk "...and clearing s2 removes it" '[[ -z "${SHARED:-}" ]]'

# A plain load records the same provenance (first active set wins).
op-env load >/dev/null 2>&1
op-env clear s2 >/dev/null 2>&1
chk "after a plain load, clearing the losing active set keeps the shared variable" '[[ "$SHARED" == val-of-from-s1 && -z "${ONLY2:-}" ]]'
op-env clear >/dev/null 2>&1

# A variable that was never loaded (exported by hand) is not cleared by naming a set that defines it.
ONLY1=mine; export ONLY1
op-env clear s1 >/dev/null 2>&1
chk "clear <set> does not unset a same-named variable it never loaded" '[[ "$ONLY1" == mine ]]'
unset ONLY1; rm "$sets/s1.tsv" "$sets/s2.tsv"

# Several sets, in the order given; the first definition wins.
mkset c $'B1\top://v/i/from-c' $'C1\top://v/i/c1'
op-env load c b >/dev/null 2>&1
chk "several sets: the first one named wins a clash"  '[[ "$B1" == val-of-from-c && "$B2" == val-of-b2 && "$C1" == val-of-c1 ]]'
op-env clear c b >/dev/null 2>&1
chk "several sets: clear takes them all"              '[[ -z "${B1:-}${B2:-}${C1:-}" ]]'
rm "$sets/c.tsv"

# An empty set: nothing to load, nothing signed in.
: > "$sets/empty.tsv"; oplog_reset
out=$(op-env load empty 2>&1); rc=$?
chk "an empty set loads nothing, says so, and makes no op call" '[[ $rc -eq 0 && "$out" == *"No secrets in: empty"* && "$(oplog_count)" == 0 ]]'
rm "$sets/empty.tsv"

# After-load hooks run after a named-set load too.
_hooks_saved=("${_OP_AFTER_LOAD_HOOKS[@]}")
HOOK_RAN=0
_test_hook() { HOOK_RAN=$((HOOK_RAN + 1)); }
_OP_AFTER_LOAD_HOOKS+=(_test_hook)
op-env load a >/dev/null 2>&1
chk "hooks: a named-set load runs the after-load hooks" '[[ $HOOK_RAN -eq 1 ]]'
op-env load >/dev/null 2>&1
chk "hooks: and so does a plain load"                   '[[ $HOOK_RAN -eq 2 ]]'
_OP_AFTER_LOAD_HOOKS=("${_hooks_saved[@]}")
op-env clear >/dev/null 2>&1

# Help, and the old names are gone: `op-env load` / `op-env clear` are the only entry points.
chk "op-env help documents load and clear" '[[ "$(op-env help)" == *"op-env load [set...]"* && "$(op-env help)" == *"op-env clear [set...]"* ]]'
chk "op-load-env and op-clear-env no longer exist" '! declare -f op-load-env >/dev/null 2>&1 && ! declare -f op-clear-env >/dev/null 2>&1 && ! command -v op-load-env >/dev/null 2>&1 && ! command -v op-clear-env >/dev/null 2>&1'
chk "the implementations are internal (op-env dispatches to them)" 'declare -f _op_env_load >/dev/null && declare -f _op_env_clear >/dev/null'
chk "op-env help does not mention the removed names" '[[ "$(op-env help)" != *"op-load-env"* && "$(op-env help)" != *"op-clear-env"* ]]'
clean_sets; unset FAKE_OP_LOG

# Tab completion: the candidates are shared, each shell has a thin wrapper.
printf 'A\top://v/i/a\n' > "$sets/alpha.tsv"; printf 'B\top://v/i/b\n' > "$sets/beta.tsv"
cands() { _op_env_candidates "$@" | tr '\n' ' '; }
chk "completion: no subcommand yet offers the subcommands" '[[ "$(cands "" 0)" == "load clear add list rm use help " ]]'
chk "completion: load offers the set names, for every argument" '[[ "$(cands load 0)" == "alpha beta " && "$(cands load 3)" == "alpha beta " ]]'
chk "completion: clear and use offer them too" '[[ "$(cands clear 0)" == "alpha beta " && "$(cands use 1)" == "alpha beta " ]]'
chk "completion: list and rm take one set name" '[[ "$(cands list 0)" == "alpha beta " && -z "$(cands list 1)" && "$(cands rm 0)" == "alpha beta " && -z "$(cands rm 1)" ]]'
chk "completion: add offers nothing (it may create a set)" '[[ -z "$(cands add 0)" ]]'
if [[ -n "${ZSH_VERSION:-}" ]]; then
  compadd() { local a; for a; do [[ "$a" == -- ]] || printf '%s ' "$a"; done; }   # stand-in for the zsh builtin: print what would be offered
  words=(op-env ""); CURRENT=2
  chk "completion (zsh): the subcommands" '[[ "$(_op_env_complete_zsh)" == "load clear add list rm use help " ]]'
  words=(op-env load ""); CURRENT=3
  chk "completion (zsh): set names after load" '[[ "$(_op_env_complete_zsh)" == "alpha beta " ]]'
  words=(op-env list alpha ""); CURRENT=4
  chk "completion (zsh): list takes just one" '[[ -z "$(_op_env_complete_zsh)" ]]'
  unset -f compadd
  # Registered on the first prompt when compinit runs after this file is sourced.
  zout=$( autoload -Uz compinit; compinit -u -d "$T/zcompdump" >/dev/null 2>&1; _op_env_register_zsh; printf '%s' "${_comps[op-env]}" )
  chk "completion (zsh): registers with compdef once compinit has run" '[[ "$zout" == _op_env_complete_zsh ]]'
else
  COMP_WORDS=(op-env l); COMP_CWORD=1; _op_env_complete_bash
  chk "completion (bash): subcommands filtered by what is typed" '[[ "${COMPREPLY[*]}" == "load list" ]]'
  COMP_WORDS=(op-env load al); COMP_CWORD=2; _op_env_complete_bash
  chk "completion (bash): set names filtered by what is typed" '[[ "${COMPREPLY[*]}" == alpha ]]'
  chk "completion (bash): registered for op-env" '[[ "$(complete -p op-env)" == *_op_env_complete_bash* ]]'
fi
chk "op-env help has examples and mentions completion" '[[ "$(op-env help)" == *"Examples:"* && "$(op-env help)" == *"Tab completes"* ]]'
clean_sets

# ── shared fixture ────────────────────────────────────────────────────────────
# tests/fixtures/envsets/ plus envsets.expected is the contract for the .tsv format
# (first definition wins, CRs stripped, malformed lines skipped, .active order, an
# optional third column). The PowerShell port reads the same files and must produce the
# same merged output, so the two implementations cannot drift.
clean_sets; export OP_ACCOUNT=default.1password.com
cp -R "$R/tests/fixtures/envsets/." "$sets/"
got=$(_op_env_entries)
chk "shared fixture: merged entries match the expected file" '[[ "$got" == "$(cat "$R/tests/fixtures/envsets.expected")" ]]'
rm -rf "$sets"; mkdir -p "$sets"

# ── bash and PowerShell op-env write the same bytes (skipped without pwsh; bash pass only) ─────────
# One sequence of add / rm / use (valid and invalid) runs through bash `op-env` and PowerShell `op-env`, each in
# its own directory. Every file, its mode, and the output of `list` must then be identical: the write-side
# version of the loader comparison in tests/config.sh.
if [[ -n "${BASH_VERSION:-}" ]] && command -v pwsh >/dev/null 2>&1 && stat -c '%a' / >/dev/null 2>&1; then
  par="$T/parity"; rm -rf "$par"; mkdir -p "$par/bash" "$par/ps"
  cat > "$par/seq.txt" <<'SEQ'
add|guild|NPM_TOKEN|op://Private/npm/credential
add|personal|GITEA_TOKEN|op://v/i/pat|acct.example.com
add|personal|NANOLEAF|op://v/i/n
add|guild|NPM_TOKEN|op://Private/npm/rotated
add|personal|GITEA_TOKEN|op://v/i/pat2
use|guild
add|brandnew|X1|op://v/i/x
add|personal|LATER|op://v/i/later
rm|personal|NANOLEAF
add|guild|BAD|op://broken
add|Guild|UP|op://v/i/f
add|guild|OKNAME|op://v/i/f|bad acct!
add|guild|bad name|op://v/i/f
use|nosuch
use|guild|nosuch
rm|personal|NOSUCH
rm|nosuch|X
add|guild|OTHER|op://v/i/o|main.1password.com
use|guild|brandnew
SEQ
  # bash side
  ( export PREFLIGHT_CONFIG_DIR="$par/bash" OP_ACCOUNT=main.1password.com
    while IFS= read -r line; do
      IFS='|' read -r -a args <<< "$line"
      op-env "${args[@]}" </dev/null >/dev/null 2>&1 || true
    done < "$par/seq.txt"
    op-env list > "$par/bash.list" 2>&1 )
  # PowerShell side
  cat > "$par/run.ps1" <<'PS1'
param([string]$Repo, [string]$Seq, [string]$Out)
$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $Repo 'pwsh/Preflight.psd1') -Force 3>$null
foreach ($line in Get-Content -LiteralPath $Seq) {
    $a = $line.Split('|')
    Invoke-OpEnv @a *>$null
}
Invoke-OpEnv list 6>&1 | Out-String -Stream | Where-Object { $_ -ne '' } | Set-Content -LiteralPath $Out
PS1
  env -u XDG_CONFIG_HOME -u XDG_STATE_HOME PREFLIGHT_CONFIG_DIR="$par/ps" PREFLIGHT_STATE_DIR="$par/ps-state" OP_ACCOUNT=main.1password.com \
    pwsh -NoProfile -File "$par/run.ps1" -Repo "$R" -Seq "$par/seq.txt" -Out "$par/ps.list" >/dev/null 2>&1
  files_of() { ( cd "$1/envsets" 2>/dev/null && find . -mindepth 0 | sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(stat -c '%a' "$f")"; done ); }
  chk "parity: the same files and modes" '[[ -n "$(files_of "$par/bash")" && "$(files_of "$par/bash")" == "$(files_of "$par/ps")" ]]'
  same=1; for f in "$par"/bash/envsets/*.tsv "$par"/bash/envsets/.active; do
    [[ -e "$f" ]] || continue
    cmp -s "$f" "$par/ps/envsets/$(basename "$f")" || { same=0; echo "DIFFERS: $(basename "$f")"; diff "$f" "$par/ps/envsets/$(basename "$f")" | head -5; }
  done
  chk "parity: every set file and .active is byte-identical" '[[ $same -eq 1 ]]'
  grep -v '^$' "$par/bash.list" > "$par/bash.list2"
  chk "parity: op-env list prints the same text" 'cmp -s "$par/bash.list2" "$par/ps.list" || { diff "$par/bash.list2" "$par/ps.list" | head -6; false; }'
  chk "parity: no temp files left on either side" '[[ -z "$(find "$par/bash/envsets" "$par/ps/envsets" -name ".tmp.*" 2>/dev/null)" ]]'
else
  echo "skipped: bash/PowerShell op-env parity (needs pwsh and GNU stat, bash pass only)"
fi

echo "$passes passed, $fails failed"
[[ $fails -eq 0 ]]
