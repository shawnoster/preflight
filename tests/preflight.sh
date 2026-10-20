#!/usr/bin/env bash
# tests/preflight.sh - the preflight status strip: _pf_cell and _pf_render_summary.
#
#   tests/preflight.sh       run under bash, and under zsh if it is installed
#
# Colors are left unset, so the helpers render plain text.

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

R_="$PF_REPO"
fails=0 passes=0
chk() { if eval "$2"; then passes=$((passes + 1)); else fails=$((fails + 1)); echo "FAIL: $1"; fi; }

source "$R_/lib/preflight.sh"
unset B T S R _pf_bad _pf_upd

# _render <aws> — run the summary with the current globals
_render() { out=$(_pf_render_summary "$1"); }
_reset() {
  issues=0; updates_available=0; issue_msgs=(); update_msgs=()
  _pf_cells="■■■"; verbose=false
}

# ── _pf_cell ──────────────────────────────────────────────────────────────────
chk "cell: unchanged counts pass"     '[ "$(_pf_cell 2 2 1 1)" = "■" ]'
chk "cell: new issue fails"           '[ "$(_pf_cell 2 3 1 1)" = "□" ]'
chk "cell: new update only is ■"      '[ "$(_pf_cell 0 0 0 1)" = "■" ]'
chk "cell: issue wins over update"    '[ "$(_pf_cell 0 1 0 1)" = "□" ]'

# ── all clear ─────────────────────────────────────────────────────────────────
_reset; _render dev
chk "clear: cells, verdict, cat last" '[ "$out" = "  ■■■  all systems go · aws:dev  ᓚᘏᗢ" ]'
_reset; _render ""
chk "clear: no aws label when empty"  '[ "$out" = "  ■■■  all systems go  ᓚᘏᗢ" ]'

# ── issues ────────────────────────────────────────────────────────────────────
_reset; issues=1; issue_msgs=("AWS SSO refresh failed"); _pf_cells="■□■"; _render dev
chk "one issue: inline, shrug, no aws" '[ "$out" = "  ■□■  1 issue · AWS SSO refresh failed  ¯\_(ツ)_/¯" ]'

_reset; issues=2; issue_msgs=("first" "second"); _render ""
chk "two issues: plural header"       '[ "$(printf "%s\n" "$out" | head -1)" = "  ■■■  2 issues  ¯\_(ツ)_/¯" ]'
chk "two issues: both listed"         '[ "$(printf "%s\n" "$out" | sed -n 2p)" = "    • first" ] && [ "$(printf "%s\n" "$out" | sed -n 3p)" = "    • second" ]'

_reset; issues=1; issue_msgs=("only"); updates_available=1; update_msgs=("jq: 1 → 2"); _render ""
chk "issue + update: not inlined"     '[ "$(printf "%s\n" "$out" | head -1)" = "  ■■■  1 issue · 1 update  ¯\_(ツ)_/¯" ]'
chk "issue + update: both lists"      'printf "%s\n" "$out" | grep -qxF "    • only" && printf "%s\n" "$out" | grep -qxF "    ↑ jq: 1 → 2"'

_reset; issues=1; _render ""
chk "counted issue without message"   '[ "$out" = "  ■■■  1 issue  ¯\_(ツ)_/¯" ]'

_reset; issues=1; issue_msgs=('100% \n literal'); _render ""
chk "message printed as typed"        '[ "$out" = "  ■■■  1 issue · 100% \n literal  ¯\_(ツ)_/¯" ]'

# ── updates ───────────────────────────────────────────────────────────────────
_reset; updates_available=2; update_msgs=("a" "b"); _render dev
chk "updates only: flower face"       '[ "$(printf "%s\n" "$out" | head -1)" = "  ■■■  2 updates  (❁´◡\`❁)" ]'
chk "updates only: listed"            '[ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" = 3 ]'

_reset; verbose=true; updates_available=1; update_msgs=("a"); _render ""
chk "verbose: blank line first"       '[ -z "$(printf "%s\n" "$out" | head -1)" ]'
chk "verbose: no repeated update list" '! printf "%s\n" "$out" | grep -q "↑"'

# ── _pf_op_may_prompt ─────────────────────────────────────────────────────────
# Stubs: entries name two accounts (one by default); whoami succeeds for those in $signed_in.
_op_env_entries() { printf 'A\top://v/a/f\nB\top://v/b/f\twork.1password.com\n'; }
_op_call() { case " $signed_in " in *" $3 "*) return 0 ;; *) return 1 ;; esac; }
OP_ACCOUNT=me.1password.com
OP_BIN=/usr/bin/op; signed_in="me.1password.com work.1password.com"
chk "native op, all signed in: no prompt"   '! _pf_op_may_prompt'
OP_BIN=/usr/bin/op; signed_in="me.1password.com"
chk "native op, one account out: may prompt" '_pf_op_may_prompt'
OP_BIN=/mnt/c/x/op.exe; signed_in=""
chk "op.exe: never a terminal prompt"        '! _pf_op_may_prompt'
_op_env_entries() { :; }
OP_BIN=/usr/bin/op; signed_in=""
chk "no secrets configured: no prompt"       '! _pf_op_may_prompt'

# ── the live strip: every box up front ────────────────────────────────────────
# _op_env_entries is still the empty stub from above.
unset GITEA_TOKEN _CHECK_AWS _CHECK_SSH _CHECK_GIT_CONFIG
chk "plan: every section on"          '[ "$(_pf_planned_sections)" = 9 ]'
_CHECK_AWS=0
chk "plan: aws off drops its box"     '[ "$(_pf_planned_sections)" = 8 ]'
_CHECK_SSH=0; _CHECK_GIT_CONFIG=0
chk "plan: ssh and git off"           '[ "$(_pf_planned_sections)" = 6 ]'
unset _CHECK_AWS _CHECK_SSH _CHECK_GIT_CONFIG
GITEA_TOKEN=x
chk "plan: gitea token set adds one"  '[ "$(_pf_planned_sections)" = 10 ]'
unset GITEA_TOKEN
_op_env_entries() { printf 'GITEA_TOKEN\top://v/g/t\n'; }
chk "plan: gitea token from a set"    '[ "$(_pf_planned_sections)" = 10 ]'
_op_env_entries() { printf 'GITEA_SERVER_TOKEN\top://v/g/t\n'; }
chk "plan: other gitea var: no box"   '[ "$(_pf_planned_sections)" = 9 ]'
_op_env_entries() { :; }

chk "pending cell: empty box"         '[ "$(_pf_cell_pending)" = "□" ]'
_strip() { _pf_strip "$1" | sed $'s/^\r\033\\[2K//'; }
_pf_planned=5; _pf_closed=0; _pf_cells=""
chk "strip: all empty at the start"   '[ "$(_strip "Settings: checking...")" = "  □□□□□  Settings: checking..." ]'
_pf_closed=2; _pf_cells="■■"
chk "strip: finished cells fill in"   '[ "$(_strip "SSH: checking...")" = "  ■■□□□  SSH: checking..." ]'
_pf_closed=5; _pf_cells="■■■■■"
chk "strip: all filled, no extras"    '[ "$(_strip x)" = "  ■■■■■  x" ]'
_pf_closed=6; _pf_cells="■■■■■■"
chk "strip: more sections than planned" '[ "$(_strip x)" = "  ■■■■■■  x" ]'

# ── every issue message is counted ────────────────────────────────────────────
# A message without ((issues++)) leaves its cell green and, alone, reads as all clear.
uncounted=$(awk '
  /^preflight\(\) \{/ { inside = 1 }
  inside && /^\}/     { inside = 0 }
  inside && /issue_msgs\+=/ { pending[NR] = 1 }
  inside && /\(\(issues\+\+\)\)/ { for (n in pending) if (NR - n <= 6) delete pending[n] }
  END { for (n in pending) print n }
' "$R_/lib/preflight.sh")
chk "every issue_msgs+= is followed by ((issues++))" '[ -z "$uncounted" ] || { echo "  uncounted at lines: $uncounted"; false; }'

echo "$passes passed, $fails failed"
[ "$fails" -eq 0 ]
