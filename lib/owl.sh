#!/usr/bin/env bash
# ~/.preflight/lib/owl.sh — OOO (Obtusely Optimistic Owl)
#
# Provides:
#   owl-theme [name]        — switch Oh My Posh palette + prompt icon (persists)
#   owl-theme               — list available themes
#   owl-theme --current     — print active theme name
#   _owl_splash             — MOTD called once per interactive top-level shell
#
# Configuration (set in config/owl.sh, auto-created from config/owl.sh.template):
#   OWL_THEME_DIR     — directory where theme state is stored  (default: $PREFLIGHT_DIR/state/owl)
#   OWL_OMP_CONFIG    — path to your Oh My Posh JSON config    (default: $HOME/theme-catppuccin.omp.json)
#
# Oh My Posh is OPTIONAL. If OWL_OMP_CONFIG is unset or the file doesn't exist,
# owl-theme still switches splash colors — it just skips the OMP palette patch
# and prompt reload.

PREFLIGHT_DIR="${PREFLIGHT_DIR:-$HOME/.preflight}"
OWL_THEME_DIR="${OWL_THEME_DIR:-$PREFLIGHT_DIR/state/owl}"
OWL_OMP_CONFIG="${OWL_OMP_CONFIG:-}"   # set in config/owl.sh; empty = OMP disabled

# ── Theme definitions ─────────────────────────────────────────────────────────
# Each theme sets:
#   owl_body / owl_eyes / owl_text / owl_sub  (R;G;B for ANSI 24-bit color)
#   omp_*  (hex for Oh My Posh palette keys)
#   icon   (prompt icon emoji — patched into the first text segment of the OMP config)
#   label  (human-readable name shown in the theme list)

_owl_theme_def() {
  case "$1" in

    catppuccin)
      label="Catppuccin Warm"
      icon=$'\U0001f431'  # 🐱
      owl_body="196;112;63"    owl_eyes="250;179;135"
      owl_text="205;214;244"   owl_sub="108;112;134"
      omp_cat="#CDD6F4" omp_path="#89DCEB" omp_git="#A6E3A1"
      omp_node="#89B4FA" omp_python="#F9E2AF" omp_yarn="#F5C2E7"
      omp_ok="#A6E3A1"  omp_err="#F38BA8"
      ;;

    honeypot)
      label="Honeypot Gold"
      icon=$'\U0001f36f'  # 🍯
      owl_body="180;130;50"    owl_eyes="245;210;110"
      owl_text="222;198;158"   owl_sub="160;145;115"
      omp_cat="#DEC69E" omp_path="#E8C872" omp_git="#C8B86A"
      omp_node="#D4A44C" omp_python="#F0C878" omp_yarn="#E0B868"
      omp_ok="#C8B86A"  omp_err="#D08040"
      ;;

    twilight)
      label="Twilight Feathers"
      icon=$'\U0001f989'  # 🦉
      owl_body="120;95;145"    owl_eyes="240;195;120"
      owl_text="180;170;205"   owl_sub="130;120;155"
      omp_cat="#B4A0D0" omp_path="#9E8EC0" omp_git="#A8C090"
      omp_node="#8EA0D0" omp_python="#F0C378" omp_yarn="#C8A0C8"
      omp_ok="#A8C090"  omp_err="#D07878"
      ;;

    moonlit)
      label="Moonlit Branch"
      icon=$'\U0001f319'  # 🌙
      owl_body="108;112;164"   owl_eyes="180;190;254"
      owl_text="170;175;220"   owl_sub="120;125;160"
      omp_cat="#B4BEFE" omp_path="#94A0E8" omp_git="#8CC0A8"
      omp_node="#7EA0E0" omp_python="#C8B8E0" omp_yarn="#A8A0D8"
      omp_ok="#8CC0A8"  omp_err="#C87888"
      ;;

    autumn)
      label="Autumn Roost"
      icon=$'\U0001f342'  # 🍂
      owl_body="160;90;70"     owl_eyes="230;160;90"
      owl_text="210;175;140"   owl_sub="150;120;95"
      omp_cat="#D2AF8C" omp_path="#C89868" omp_git="#A8B070"
      omp_node="#C0885A" omp_python="#E0B870" omp_yarn="#D09870"
      omp_ok="#A8B070"  omp_err="#C86050"
      ;;

    rose)
      label="Dusty Rose"
      icon=$'\U0001f338'  # 🌸
      owl_body="160;110;130"   owl_eyes="235;175;185"
      owl_text="215;185;195"   owl_sub="150;125;138"
      omp_cat="#EBAFB9" omp_path="#D8A0B0" omp_git="#B0C0A0"
      omp_node="#C098B8" omp_python="#E0C0A8" omp_yarn="#D0A0C0"
      omp_ok="#B0C0A0"  omp_err="#D07080"
      ;;

    moss)
      label="Lichen & Moss"
      icon=$'\U0001f33f'  # 🌿
      owl_body="90;130;95"     owl_eyes="170;220;150"
      owl_text="160;195;155"   owl_sub="110;140;108"
      omp_cat="#AADC96" omp_path="#88C890" omp_git="#90C880"
      omp_node="#78B890" omp_python="#C8D890" omp_yarn="#A0C8A0"
      omp_ok="#90C880"  omp_err="#C88868"
      ;;

    parchment)
      label="Parchment & Ink"
      icon=$'\U0001f4dc'  # 📜
      owl_body="139;119;101"   owl_eyes="222;198;158"
      owl_text="190;180;165"   owl_sub="140;132;120"
      omp_cat="#BEB4A5" omp_path="#C8B898" omp_git="#A8B098"
      omp_node="#B0A898" omp_python="#D0C0A0" omp_yarn="#C0B0A0"
      omp_ok="#A8B098"  omp_err="#C89070"
      ;;

    *)
      return 1
      ;;
  esac
}

_owl_theme_names() {
  echo "catppuccin honeypot twilight moonlit autumn rose moss parchment"
}

# ── Patch palette + icon in the OMP JSON ─────────────────────────────────────
# Only rewrites the palette object and the first text segment's template.
# Segment structure, styles, and all other fields are left untouched.
_owl_patch_omp() {
  [[ -z "$OWL_OMP_CONFIG" || ! -f "$OWL_OMP_CONFIG" ]] && return 0

  python3 - "$OWL_OMP_CONFIG" "$icon" \
    "$omp_cat" "$omp_err" "$omp_git" "$omp_node" \
    "$omp_ok" "$omp_path" "$omp_python" "$omp_yarn" << 'PYEOF'
import json, sys
path, icon = sys.argv[1], sys.argv[2]
cat, err, git, node, ok, pth, py, yarn = sys.argv[3:11]

with open(path) as f:
    cfg = json.load(f)

cfg["palette"] = {
    "cat": cat, "err": err, "git": git, "node": node,
    "ok": ok, "path": pth, "python": py, "yarn": yarn
}

# Update icon in the first text segment
for seg in cfg["blocks"][0]["segments"]:
    if seg["type"] == "text":
        seg["template"] = icon + " "
        break

with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYEOF
}

# ── Export owl colors for preflight.sh and _owl_splash ───────────────────────
_owl_export_colors() {
  export OWL_BODY="$owl_body" OWL_EYES="$owl_eyes"
  export OWL_TEXT="$owl_text" OWL_SUB="$owl_sub"
}

# ── Load current theme at shell start ────────────────────────────────────────
_owl_theme_load() {
  local theme
  theme=$(cat "$OWL_THEME_DIR/current" 2>/dev/null) || theme="catppuccin"
  if _owl_theme_def "$theme"; then
    _owl_export_colors
  fi
}

# ── owl-theme command ─────────────────────────────────────────────────────────
owl-theme() {
  # No args — list themes
  if [[ $# -eq 0 ]]; then
    local current
    current=$(cat "$OWL_THEME_DIR/current" 2>/dev/null) || current="catppuccin"
    printf "\n  \033[1mOOO Themes\033[0m\n\n"
    for t in $(_owl_theme_names); do
      _owl_theme_def "$t"
      local B="\033[38;2;${owl_body}m" E="\033[38;2;${owl_eyes}m" R='\033[0m'
      local marker="  "
      [[ "$t" == "$current" ]] && marker="\033[1m▸ \033[0m"
      printf "  ${marker}${B}(${E}o${B},${E}o${B})${R}  %-12s %s  ${icon}\n" "$t" "$label"
    done
    printf "\n  Usage: \033[1mowl-theme <name>\033[0m\n\n"
    return
  fi

  # --current flag
  if [[ "$1" == "--current" ]]; then
    cat "$OWL_THEME_DIR/current" 2>/dev/null || echo "catppuccin"
    return
  fi

  # Switch to named theme
  local theme="$1"
  if ! _owl_theme_def "$theme"; then
    printf "  Unknown theme: %s\n" "$theme"
    printf "  Available: %s\n" "$(_owl_theme_names)"
    return 1
  fi

  # Persist selection
  mkdir -p "$OWL_THEME_DIR"
  echo "$theme" > "$OWL_THEME_DIR/current"

  # Patch OMP config (palette + icon only, structure untouched)
  _owl_patch_omp

  # Export colors for splash + preflight
  _owl_export_colors

  # Reload Oh My Posh into the current shell (no-op if OMP not configured)
  if [[ -n "$OWL_OMP_CONFIG" && -f "$OWL_OMP_CONFIG" ]] && command -v oh-my-posh &>/dev/null; then
    eval "$(oh-my-posh init bash --config "$OWL_OMP_CONFIG")"
  fi

  # Preview
  local R='\033[0m'
  local B="\033[38;2;${owl_body}m"
  local E="\033[38;2;${owl_eyes}m"
  local T="\033[38;2;${owl_text}m"
  local S="\033[38;2;${owl_sub}m"
  printf "\n"
  printf "  ${B} ___ ${R}\n"
  printf "  ${B}(${E}o${B},${E}o${B})${R}     ${S}Switched to ${label}.${R}\n"
  printf "  ${B}{\`\"'}${R}\n"
  printf "  ${B}-\"-\"-${R}     ${T}The owl approves.${R}\n"
  printf "\n"
}

# ── MOTD splash ───────────────────────────────────────────────────────────────
# Called once per interactive top-level shell (gated in init.sh).
# Colors come from OWL_BODY/EYES/TEXT/SUB exported by _owl_theme_load.
_owl_splash() {
  local R='\033[0m'
  local RUST="\033[38;2;${OWL_BODY:-196;112;63}m"
  local PEACH="\033[38;2;${OWL_EYES:-250;179;135}m"
  local TEXT="\033[38;2;${OWL_TEXT:-205;214;244}m"
  local SUB="\033[38;2;${OWL_SUB:-108;112;134}m"

  local date_str; date_str=$(date "+%A, %B %d")
  local uptime_str; uptime_str=$(uptime -p 2>/dev/null | sed 's/up //')

  # ── Mood pools ───────────────────────────────────────────────────────────────
  # Each mood has a face (eye pair) and a pool of quotes.
  # face format: two chars — each is one eye glyph rendered as (L,R)

  local -a moods faces

  # Alert — bright-eyed, ready, gently self-important
  moods+=(alert); faces+=(oo)
  local -a q_alert=(
    "The branch holds you because you forgot to fall."
    "The mouse is busy. The owl is ready."
    "You can see very far from a place of stillness."
    "I happen to know a thing or two about things or two."
    "The customary procedure is to begin. I believe I have mentioned this before."
    "It is precisely the sort of morning where something could be accomplished, and I intend to witness it."
    "One does not simply arrive at wisdom. One was already here."
    "I have consulted my references and they agree with me, as they usually do."
    "Start where you are. Use what you have. Fly when ready."
    "Athena chose the owl not for its wisdom but for its willingness to stay up and do the work."
  )

  # Sleepy — drowsy, philosophical about rest, Pooh-ish contentment
  moods+=(sleepy); faces+=(--)
  local -a q_sleepy=(
    "The hollow is warm enough. It was always warm enough."
    "People say nothing is impossible, but I do nothing every day."
    "I was not napping. I was considering the matter with my eyes closed."
    "The best time to plant a tree was twenty years ago. The second best time is after this cup of tea."
    "Resting is merely thinking in a more horizontal direction."
    "I have been awake for some time, I should think. The evidence is inconclusive."
    "A wise owl once said nothing at all and went back to sleep. It was me. Just now."
    "One cannot rush the dawn. I have tried, and it does not listen."
    "Feathers keep you warm whether you notice them or not."
    "The sun came back. It does that. I shall do the same presently."
  )

  # Happy — pleased, self-congratulatory, Owl explaining things to Piglet
  moods+=(happy); faces+=(^^)
  local -a q_happy=(
    "As I was saying — and I do say it rather well — things are looking up."
    "The Japanese call the owl fukurō — luck bird. It has been sitting here this whole time."
    "A little consideration, a little thought for others, makes all the difference."
    "Everything is going according to the plan I have just now devised."
    "I should think this is what they call a capital day. I have spelled it correctly."
    "One does occasionally get things right. I find it happens to me more than most."
    "The forest is in order. I have inspected it from this branch."
    "Trees grow slowly. Nobody complains about trees."
    "Owl hadn't exactly been given his spelling, but it had come to him."
    "I believe the word is 'splendid.' Or possibly 'speldnid.' In any case, this."
  )

  # Suspicious — one big eye, skeptical but well-meaning
  moods+=(suspicious); faces+=(oO)
  local -a q_suspicious=(
    "Something is afoot. Or possibly a-wing. I am investigating."
    "The owl does not boast of its night vision to the rooster. It simply sees."
    "According to the Talmud, the owl sees what others overlook. Mostly because everyone else is asleep."
    "I don't wish to alarm anyone but that is not where I left that branch."
    "One cannot be too careful. Unless one is me, in which case one is precisely careful enough."
    "I have noticed a thing. I shall continue to notice it until it explains itself."
    "If you wait until you're ready, you'll be waiting for the rest of your life. — Lemony Snicket, who was definitely an owl"
    "There is a draft. I suspect Piglet has left something open again."
    "My uncle Robert once saw something very like this. It turned out to be nothing, but impressively so."
    "One cannot fly into flying. — Lakota proverb, probably"
  )

  # Winking — conspiratorial, sharing a secret
  moods+=(winking); faces+=(o-)
  local -a q_winking=(
    "Between you and me — and I trust you to keep this between us — today is going to be fine."
    "I probably shouldn't tell you this, but the secret to wisdom is showing up."
    "This is strictly confidential, but I believe in you. Don't let it get around."
    "Shall I let you in on something? The mice never see me coming. Nor do the deadlines."
    "I have it on good authority — mine — that everything will sort itself out."
    "Not everyone can do what we do. Mostly because they are asleep. But still."
    "I have a system. I shan't describe it, but rest assured it is working."
    "Begin at the beginning, and go on till you come to the end: then stop."
    "I used to be indecisive. Now I'm not so sure."
    "Keep this between us, but the moon is just the sun being dramatic."
  )

  # Pick a random mood
  local idx=$(( RANDOM % ${#moods[@]} ))
  local mood="${moods[$idx]}"
  local face="${faces[$idx]}"
  local eye_l="${face:0:1}" eye_r="${face:1:1}"

  # Pick a random quote from that mood's pool
  local -n pool="q_${mood}"
  local quote="${pool[$(( RANDOM % ${#pool[@]} ))]}"

  printf "\n"
  printf "  ${RUST} ___ ${R}\n"
  printf "  ${RUST}(${PEACH}${eye_l}${RUST},${PEACH}${eye_r}${RUST})${R}     ${SUB}${quote}${R}\n"
  printf "  ${RUST}{\`\"'}${R}\n"
  printf "  ${RUST}-\"-\"-${R}     ${TEXT}${date_str}${R} ${SUB}· ↑ ${uptime_str}${R}\n"
  printf "\n"
}
