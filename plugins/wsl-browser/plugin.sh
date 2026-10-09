#!/usr/bin/env bash
# ~/.preflight/plugins/wsl-browser/plugin.sh - open links in the Windows host browser from WSL
#
# An opt-in plugin: init.sh sources it only when "wsl-browser" is in the config.json `plugins` list.
#
# Without it, WSL tends to fall back to a Linux Chrome installed inside the distro. That opens a WSLg
# (WSL's Linux GUI support) window (which can land off-screen) and relays Chrome's stderr onto the launching terminal. This plugin
# points $BROWSER at bin/winbrowser, which hands the URL to the Windows default browser through
# rundll32.exe, and `wsl-browser-doctor` checks (and with --fix, repairs) the xdg side for tools that
# call xdg-open (the XDG desktop-standard opener) instead of reading $BROWSER. With --fix it also adds a marked block to ~/.profile so login
# shells and non-interactive callers (hooks, cron, scripts), which never source the file that loads this
# plugin, get the same $BROWSER.
#
# Provides:
#   wsl-browser-doctor          — check the setup
#   wsl-browser-doctor --fix    — repair it (desktop entry, xdg defaults, ~/.profile block)
#
# Inert outside WSL, so the same plugins list can be shared with non-WSL machines. Silent at load.

_wslb_is_wsl() { [ -n "${WSL_DISTRO_NAME:-}" ] || { [ -r /proc/version ] && grep -qi microsoft /proc/version; }; }

_wslb_dir="${PREFLIGHT_DIR:-$HOME/.preflight}/plugins/wsl-browser"
_wslb_rundll32="${WSL_BROWSER_RUNDLL32:-/mnt/c/Windows/System32/rundll32.exe}"

# $BROWSER is what Python's webbrowser module (e.g. Snowflake externalbrowser SSO) and `sensible-browser`
# read. Only set it when the wrapper can work, so a WSL without interop keeps whatever it had.
if _wslb_is_wsl && [ -x "$_wslb_rundll32" ] && [ -x "$_wslb_dir/bin/winbrowser" ]; then
  export BROWSER="$_wslb_dir/bin/winbrowser"
fi

# ── doctor ───────────────────────────────────────────────────────────────────

_wslb_apps_dir() { printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/applications"; }
_wslb_mimeapps() { printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"; }

_wslb_desktop_body() {
  cat <<EOF
[Desktop Entry]
Type=Application
Name=Windows Default Browser
GenericName=Web Browser
Comment=Open links in the Windows host browser instead of a browser inside WSL
Exec=$_wslb_dir/bin/winbrowser %u
Terminal=false
NoDisplay=true
MimeType=x-scheme-handler/http;x-scheme-handler/https;x-scheme-handler/about;x-scheme-handler/unknown;text/html;
Categories=Network;WebBrowser;
EOF
}

# Current default handler for a MIME type, from the user's mimeapps.list.
_wslb_get_default() {
  [ -f "$1" ] || return 0
  grep -m1 "^$2=" "$1" | cut -d= -f2-
}

# Set `mime=app` under [Default Applications], keeping every other line.
_wslb_set_default() {
  local f=$1 mime=$2 app=$3 tmp
  mkdir -p "$(dirname "$f")" || return 1
  [ -f "$f" ] || printf '[Default Applications]\n' > "$f" || return 1
  grep -q '^\[Default Applications\]' "$f" || printf '\n[Default Applications]\n' >> "$f"
  tmp=$(mktemp "$f.XXXXXX") || return 1
  if awk -v k="$mime" -v v="$app" '
       /^\[/ { if (insec && !done) { print k "=" v; done = 1 } insec = ($0 == "[Default Applications]") }
       insec && index($0, k "=") == 1 { if (!done) { print k "=" v; done = 1 } next }
       { print }
       END { if (insec && !done) print k "=" v }
     ' "$f" > "$tmp" && mv -f "$tmp" "$f"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# The ~/.profile block. POSIX sh only (dash reads .profile), guarded so a removed preflight can never leave
# $BROWSER pointing at nothing. Written with $HOME unexpanded when the wrapper lives under it.
_wslb_profile() { printf '%s' "$HOME/.profile"; }
_wslb_profile_block() {
  local w=$_wslb_dir/bin/winbrowser
  case $w in "$HOME"/*) w="\$HOME/${w#"$HOME"/}" ;; esac
  cat <<EOF
# >>> preflight wsl-browser >>>
# Managed by 'wsl-browser-doctor --fix'. Exported here as well as by the plugin so login and
# non-interactive shells (hooks, cron, scripts) open links in the Windows browser too.
if [ -x "$w" ]; then
  export BROWSER="$w"
fi
# <<< preflight wsl-browser <<<
EOF
}
_wslb_profile_current() {
  [ -f "$(_wslb_profile)" ] || return 1
  [ "$(awk '/^# >>> preflight wsl-browser >>>/{on=1} on{print} /^# <<< preflight wsl-browser <<</{on=0}' "$(_wslb_profile)")" = "$(_wslb_profile_block)" ]
}
# One start and one end marker, or neither. Anything else means the block was hand-edited, and rewriting
# would make awk's skip run to end of file and delete everything after a lone start marker.
_wslb_profile_balanced() {
  local f s e
  f=$(_wslb_profile)
  [ -f "$f" ] || return 0
  s=$(grep -c '^# >>> preflight wsl-browser >>>' "$f")
  e=$(grep -c '^# <<< preflight wsl-browser <<<' "$f")
  [ "$s" = "$e" ] && [ "$s" -le 1 ]
}
# Drop any existing managed block, then append the current one.
_wslb_profile_write() {
  local f tmp
  f=$(_wslb_profile)
  _wslb_profile_balanced || return 1
  [ -f "$f" ] || : > "$f" || return 1
  tmp=$(mktemp "$f.XXXXXX") || return 1
  if awk '/^# >>> preflight wsl-browser >>>/{skip=1} !skip{print} /^# <<< preflight wsl-browser <<</{skip=0}' "$f" > "$tmp" \
     && { [ ! -s "$tmp" ] || [ -z "$(tail -c1 "$tmp")" ] || echo >> "$tmp"; } \
     && _wslb_profile_block >> "$tmp" \
     && cat "$tmp" > "$f"; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# wsl-browser-doctor [--fix]
# Checks the Windows-browser hand-off and, with --fix, repairs what it can. Exit status is the number of
# problems still open, so it can gate a script.
wsl-browser-doctor() {
  local fix=0 open=0 cs wrapper="$_wslb_dir/bin/winbrowser" desktop mime cur rc line
  case "${1:-}" in
    "") ;;
    --fix) fix=1 ;;
    *) echo "usage: wsl-browser-doctor [--fix]" >&2; return 2 ;;
  esac

  if ! _wslb_is_wsl; then
    echo "not WSL: nothing to check"
    return 0
  fi

  if [ -x "$_wslb_rundll32" ]; then
    echo "✅ Windows interop: $_wslb_rundll32"
  else
    echo "❌ Windows interop: $_wslb_rundll32 not found"
    echo "   enable it in /etc/wsl.conf ([interop] enabled=true), then run 'wsl --shutdown' from Windows"
    open=$((open + 1))
  fi

  if [ -x "$wrapper" ]; then
    echo "✅ wrapper: $wrapper"
  elif [ -f "$wrapper" ] && [ "$fix" = 1 ] && chmod +x "$wrapper"; then
    echo "🔧 wrapper: made executable"
  else
    echo "❌ wrapper: $wrapper is missing or not executable (git checkout / preflight update)"
    open=$((open + 1))
  fi

  if [ "${BROWSER:-}" = "$wrapper" ]; then
    echo "✅ \$BROWSER: $BROWSER"
  else
    echo "❌ \$BROWSER is '${BROWSER:-<unset>}', expected $wrapper"
    echo "   open a new shell; if it persists something later in your rc files overrides it:"
    for rc in "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.zshenv" "$HOME/.zshrc"; do
      [ -f "$rc" ] || continue
      grep -n '^[[:space:]]*export BROWSER=' "$rc" | grep -v 'plugins/wsl-browser/bin/winbrowser' | while IFS= read -r line; do
        echo "   $rc:$line"
      done
    done
    open=$((open + 1))
  fi

  if _wslb_profile_current; then
    echo "✅ $(_wslb_profile): managed BROWSER block"
  elif ! _wslb_profile_balanced; then
    echo "❌ $(_wslb_profile): unbalanced '>>> preflight wsl-browser >>>' markers; fix by hand (left untouched)"
    open=$((open + 1))
  elif [ "$fix" = 1 ] && _wslb_profile_write; then
    echo "🔧 $(_wslb_profile): wrote managed BROWSER block"
  else
    echo "❌ $(_wslb_profile): no current BROWSER block, so login and non-interactive shells miss it (--fix adds it)"
    open=$((open + 1))
  fi
  # Login-shell view, the way a hook or cron job sees it: a clean env running the real startup files. The
  # value is the last line, so anything those files print does not leak into the comparison.
  cur=$(env -i HOME="$HOME" PATH="$PATH" bash -lc 'printf "\n%s\n" "${BROWSER:-}"' 2>/dev/null | tail -n 1)
  if [ "$cur" = "$wrapper" ]; then
    echo "✅ login shell resolves \$BROWSER to the wrapper"
  else
    echo "❌ login shell resolves \$BROWSER to '${cur:-<unset>}'"
    open=$((open + 1))
  fi

  # Claude Code reads env.BROWSER from its own settings before the shell's, so a pinned value there wins.
  # Only a dangling pin is a problem; a working one (an older wrapper, say) is left alone.
  cs="$HOME/.claude/settings.json"
  if [ -f "$cs" ] && command -v jq >/dev/null 2>&1; then
    cur=$(jq -r '.env.BROWSER // empty' "$cs" 2>/dev/null)
    if [ -z "$cur" ] || [ "$cur" = "$wrapper" ]; then
      echo "✅ Claude Code settings: no conflicting env.BROWSER"
    elif [ -x "$cur" ]; then
      echo "ℹ️  Claude Code settings pin env.BROWSER=$cur (works, but keep that file in place)"
      echo "   to follow the plugin: jq --arg b '$wrapper' '.env.BROWSER = \$b' $cs"
    else
      echo "❌ Claude Code settings pin env.BROWSER=$cur, which is not executable"
      echo "   fix: jq --arg b '$wrapper' '.env.BROWSER = \$b' $cs"
      open=$((open + 1))
    fi
  fi

  desktop="$(_wslb_apps_dir)/winbrowser.desktop"
  if [ -f "$desktop" ] && [ "$(_wslb_desktop_body)" = "$(cat "$desktop")" ]; then
    echo "✅ desktop entry: $desktop"
  elif [ "$fix" = 1 ] && mkdir -p "$(_wslb_apps_dir)" && _wslb_desktop_body > "$desktop"; then
    echo "🔧 desktop entry: wrote $desktop"
  else
    echo "❌ desktop entry: $desktop missing or out of date (--fix writes it)"
    open=$((open + 1))
  fi

  for mime in x-scheme-handler/http x-scheme-handler/https text/html; do
    cur=$(_wslb_get_default "$(_wslb_mimeapps)" "$mime")
    if [ "$cur" = "winbrowser.desktop" ]; then
      echo "✅ xdg default $mime"
    elif [ "$fix" = 1 ] && _wslb_set_default "$(_wslb_mimeapps)" "$mime" winbrowser.desktop; then
      echo "🔧 xdg default $mime: ${cur:-<unset>} -> winbrowser.desktop"
    else
      echo "❌ xdg default $mime is '${cur:-<unset>}' (--fix sets winbrowser.desktop)"
      open=$((open + 1))
    fi
  done

  if [ "$open" -gt 0 ] && [ "$fix" = 0 ]; then
    echo "run 'wsl-browser-doctor --fix' to repair what can be repaired"
  fi
  return "$open"
}
