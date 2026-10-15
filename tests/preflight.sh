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
chk "clear: one line, cells then cat" '[ "$out" = "  ■■■ ᓚᘏᗢ  all systems go · aws:dev" ]'
_reset; _render ""
chk "clear: no aws label when empty"  '[ "$out" = "  ■■■ ᓚᘏᗢ  all systems go" ]'

# ── issues ────────────────────────────────────────────────────────────────────
_reset; issues=1; issue_msgs=("AWS SSO refresh failed"); _pf_cells="■□■"; _render dev
chk "one issue: inline, shrug, no aws" '[ "$out" = "  ■□■ ¯\_(ツ)_/¯  1 issue · AWS SSO refresh failed" ]'

_reset; issues=2; issue_msgs=("first" "second"); _render ""
chk "two issues: plural header"       '[ "$(printf "%s\n" "$out" | head -1)" = "  ■■■ ¯\_(ツ)_/¯  2 issues" ]'
chk "two issues: both listed"         '[ "$(printf "%s\n" "$out" | sed -n 2p)" = "    • first" ] && [ "$(printf "%s\n" "$out" | sed -n 3p)" = "    • second" ]'

_reset; issues=1; issue_msgs=("only"); updates_available=1; update_msgs=("jq: 1 → 2"); _render ""
chk "issue + update: not inlined"     '[ "$(printf "%s\n" "$out" | head -1)" = "  ■■■ ¯\_(ツ)_/¯  1 issue · 1 update" ]'
chk "issue + update: both lists"      'printf "%s\n" "$out" | grep -qxF "    • only" && printf "%s\n" "$out" | grep -qxF "    ↑ jq: 1 → 2"'

_reset; issues=1; _render ""
chk "counted issue without message"   '[ "$out" = "  ■■■ ¯\_(ツ)_/¯  1 issue" ]'

_reset; issues=1; issue_msgs=('100% \n literal'); _render ""
chk "message printed as typed"        '[ "$out" = "  ■■■ ¯\_(ツ)_/¯  1 issue · 100% \n literal" ]'

# ── updates ───────────────────────────────────────────────────────────────────
_reset; updates_available=2; update_msgs=("a" "b"); _render dev
chk "updates only: flower face"       '[ "$(printf "%s\n" "$out" | head -1)" = "  ■■■ (❁´◡\`❁)  2 updates" ]'
chk "updates only: listed"            '[ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" = 3 ]'

_reset; verbose=true; updates_available=1; update_msgs=("a"); _render ""
chk "verbose: blank line first"       '[ -z "$(printf "%s\n" "$out" | head -1)" ]'
chk "verbose: no repeated update list" '! printf "%s\n" "$out" | grep -q "↑"'

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
