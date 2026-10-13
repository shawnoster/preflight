#!/usr/bin/env bash
# tests/wsl-browser.sh - the wsl-browser plugin: $BROWSER wiring and `wsl-browser-doctor [--fix]`.
#
#   tests/wsl-browser.sh       run under bash, and under zsh if it is installed
#
# HOME is redirected to a scratch dir and rundll32.exe is a fake, so nothing real is read or written.

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

R="$PF_REPO"
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
fails=0 passes=0
chk() { if eval "$2"; then passes=$((passes + 1)); else fails=$((fails + 1)); echo "FAIL: $1"; fi; }

export HOME="$T/home" PREFLIGHT_DIR="$R" WSL_DISTRO_NAME=Test
unset XDG_DATA_HOME XDG_CONFIG_HOME BROWSER
mkdir -p "$HOME"
FAKE="$T/rundll32.exe"
printf '#!/bin/sh\nprintf "%%s\\n" "$2" >> "%s/opened"\n' "$T" > "$FAKE"
chmod +x "$FAKE"
WRAP="$R/plugins/wsl-browser/bin/winbrowser"
MIME="$HOME/.config/mimeapps.list"

# ── inert off WSL ─────────────────────────────────────────────────────────────
(
  unset WSL_DISTRO_NAME
  export WSL_BROWSER_RUNDLL32="$FAKE"
  # /proc/version of the machine running the tests decides; only assert when it is not WSL.
  grep -qi microsoft /proc/version 2>/dev/null && exit 0
  source "$R/plugins/wsl-browser/plugin.sh"
  [ -z "${BROWSER:-}" ]
) && chk "not WSL: BROWSER untouched" true || chk "not WSL: BROWSER untouched" false

# ── on WSL without interop: BROWSER untouched, doctor reports it ──────────────
(
  export WSL_BROWSER_RUNDLL32="$T/nope.exe"
  source "$R/plugins/wsl-browser/plugin.sh"
  [ -z "${BROWSER:-}" ] && ! wsl-browser-doctor >/dev/null
) && chk "no interop: BROWSER untouched, doctor fails" true || chk "no interop: BROWSER untouched, doctor fails" false

# ── on WSL with interop ───────────────────────────────────────────────────────
export WSL_BROWSER_RUNDLL32="$FAKE"
source "$R/plugins/wsl-browser/plugin.sh"
chk "BROWSER points at the wrapper" '[ "$BROWSER" = "$WRAP" ]'

"$BROWSER" "https://example.com/a?b=1&c=2" ; sleep 0
chk "wrapper passes URL (with &) through untouched" 'grep -qxF "https://example.com/a?b=1&c=2" "$T/opened"'

# A user file with other content must survive --fix.
mkdir -p "$HOME/.config"
printf '[Default Applications]\ntext/html=com.google.Chrome.desktop\nx-scheme-handler/http=com.google.Chrome.desktop\napplication/pdf=evince.desktop\n\n[Added Associations]\ntext/html=foo.desktop;\n' > "$MIME"

chk "doctor without --fix reports problems" '! wsl-browser-doctor >/dev/null'
chk "doctor without --fix writes nothing" '[ ! -e "$HOME/.local/share/applications/winbrowser.desktop" ] && grep -q "^text/html=com.google.Chrome.desktop" "$MIME"'

wsl-browser-doctor --fix >/dev/null
chk "--fix writes the desktop entry" 'grep -qF "Exec=$WRAP %u" "$HOME/.local/share/applications/winbrowser.desktop"'
for m in text/html x-scheme-handler/http x-scheme-handler/https; do
  chk "--fix sets $m" 'grep -qx "$m=winbrowser.desktop" "$MIME"'
done
chk "--fix replaces rather than duplicates" '[ "$(grep -c "^text/html=" "$MIME")" = 2 ]'   # one per section
chk "--fix keeps unrelated defaults" 'grep -qx "application/pdf=evince.desktop" "$MIME"'
chk "--fix keeps other sections" 'grep -qx "text/html=foo.desktop;" "$MIME"'
chk "doctor passes after --fix" 'wsl-browser-doctor >/dev/null'
chk "--fix is idempotent" 'before=$(cat "$MIME"); wsl-browser-doctor --fix >/dev/null; [ "$before" = "$(cat "$MIME")" ]'
chk "bad flag exits 2" 'wsl-browser-doctor --nope 2>/dev/null; [ $? -eq 2 ]'

# ── ~/.profile block ─────────────────────────────────────────────────────────
# A pre-existing profile with an older BROWSER export and no trailing newline must keep its content.
printf '# mine\nexport BROWSER="$HOME/.local/bin/old"' > "$HOME/.profile"
chk "doctor flags the missing profile block" '! wsl-browser-doctor >/dev/null'
wsl-browser-doctor --fix >/dev/null
chk "--fix keeps existing profile lines" 'grep -qx "# mine" "$HOME/.profile" && grep -qF "local/bin/old" "$HOME/.profile"'
chk "--fix appends one block" '[ "$(grep -c ">>> preflight wsl-browser >>>" "$HOME/.profile")" = 1 ]'
chk "block is on its own line after a no-newline profile" 'grep -qx "# >>> preflight wsl-browser >>>" "$HOME/.profile"'
chk "block is POSIX (dash parses it)" '! command -v dash >/dev/null || dash -n "$HOME/.profile"'
chk "login shell gets BROWSER from the profile alone" '[ "$(env -i HOME="$HOME" PATH="$PATH" bash -lc "printf %s \"\$BROWSER\"")" = "$WRAP" ]'
chk "non-login non-interactive shell does not (documents the gap)" '[ -z "$(env -i HOME="$HOME" PATH="$PATH" bash -c "printf %s \"\${BROWSER:-}\"")" ]'
before=$(cat "$HOME/.profile"); wsl-browser-doctor --fix >/dev/null
chk "profile --fix is idempotent" '[ "$before" = "$(cat "$HOME/.profile")" ]'
# A stale block (preflight moved) is replaced in place, not duplicated.
sed -i 's|^  export BROWSER=.*|  export BROWSER="/old/place/winbrowser"|' "$HOME/.profile"
chk "stale block is detected" '! wsl-browser-doctor >/dev/null'
wsl-browser-doctor --fix >/dev/null
chk "stale block is rewritten once" '[ "$(grep -c ">>> preflight wsl-browser >>>" "$HOME/.profile")" = 1 ] && ! grep -q "/old/place" "$HOME/.profile"'
chk "text after the block is preserved" 'printf "\n# tail\n" >> "$HOME/.profile"; wsl-browser-doctor --fix >/dev/null; grep -qx "# tail" "$HOME/.profile"'
# A hand-edited block (start marker, no end marker) must never lose the lines after it.
printf '# top\n# >>> preflight wsl-browser >>>\nexport KEEP_ME=1\nalias important=true\n' > "$HOME/.profile"
before=$(cat "$HOME/.profile")
chk "unbalanced markers: --fix refuses" '! wsl-browser-doctor --fix >/dev/null'
chk "unbalanced markers: profile untouched" '[ "$before" = "$(cat "$HOME/.profile")" ]'
# Output from the user's startup files must not be mistaken for the value.
printf 'echo "welcome banner"\n' > "$HOME/.profile"
wsl-browser-doctor --fix >/dev/null
chk "noisy profile: probe still sees the wrapper" 'wsl-browser-doctor >/dev/null'
# No profile at all.
rm -f "$HOME/.profile"
wsl-browser-doctor --fix >/dev/null
chk "--fix creates a missing profile" 'grep -qx "# <<< preflight wsl-browser <<<" "$HOME/.profile"'

# ── Claude Code settings pin ─────────────────────────────────────────────────
if command -v jq >/dev/null 2>&1; then
  mkdir -p "$HOME/.claude"
  printf '{"env":{"BROWSER":"%s/gone"}}' "$T" > "$HOME/.claude/settings.json"
  chk "dangling env.BROWSER pin is a problem" '! wsl-browser-doctor >/dev/null'
  printf '#!/bin/sh\n' > "$T/older"; chmod +x "$T/older"
  printf '{"env":{"BROWSER":"%s/older"}}' "$T" > "$HOME/.claude/settings.json"
  chk "working env.BROWSER pin is only informational" 'wsl-browser-doctor >/dev/null'
  chk "doctor never edits the settings file" '[ "$(jq -r .env.BROWSER "$HOME/.claude/settings.json")" = "$T/older" ]'
  rm -f "$HOME/.claude/settings.json"
fi

# No mimeapps.list at all.
rm -f "$MIME"
wsl-browser-doctor --fix >/dev/null
chk "--fix creates a missing mimeapps.list" 'grep -qx "x-scheme-handler/https=winbrowser.desktop" "$MIME" && head -1 "$MIME" | grep -qx "\[Default Applications\]"'

echo "$passes passed, $fails failed"
[ "$fails" = 0 ]
