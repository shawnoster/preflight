#!/usr/bin/env bash
# install.sh — Preflight installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/shawnoster/preflight/main/install.sh | bash
#
# Env var overrides:
#   PREFLIGHT_DIR      Install location (default: ~/.preflight)
#   PREFLIGHT_REPO     Git repo URL (default: https://github.com/shawnoster/preflight.git)
#   PREFLIGHT_BRANCH   Branch to clone (default: main)
#   PREFLIGHT_PROFILE  RC file to modify (default: auto-detected)
#   NO_MODIFY_PROFILE  Set to 1 to skip dotfile modification

{ # guard against partial downloads — nothing runs until closing }

set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────

_pf_bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
_pf_info()  { printf '  %s\n' "$*"; }
_pf_ok()    { printf '  \033[32m✔\033[0m  %s\n' "$*"; }
_pf_warn()  { printf '  \033[33m⚠\033[0m  %s\n' "$*"; }
_pf_err()   { printf '  \033[31m✖\033[0m  %s\n' "$*" >&2; }
_pf_die()   { _pf_err "$*"; exit 1; }

_pf_has() { command -v "$1" &>/dev/null; }

# ── Config ────────────────────────────────────────────────────────────────────

PREFLIGHT_DIR="${PREFLIGHT_DIR:-$HOME/.preflight}"
PREFLIGHT_REPO="${PREFLIGHT_REPO:-https://github.com/shawnoster/preflight.git}"
PREFLIGHT_BRANCH="${PREFLIGHT_BRANCH:-main}"

# Build source line from $PREFLIGHT_DIR so custom install locations work correctly.
# Uses single-quotes around the condition but double-quotes to expand PREFLIGHT_DIR
# at install time, so the baked path is always correct.
_pf_make_source_line() {
  local dir="$1"
  local shell_name="$2"
  case "$shell_name" in
    fish)
      # fish syntax: test -f ... && source ...
      printf 'test -f "%s/init.sh" && source "%s/init.sh"\n' "$dir" "$dir"
      ;;
    *)
      # bash/zsh: [[ -f ... ]] && source ...
      printf '[[ -f "%s/init.sh" ]] && source "%s/init.sh"\n' "$dir" "$dir"
      ;;
  esac
}

# ── Detect profile file ───────────────────────────────────────────────────────

_pf_detect_profile() {
  if [[ -n "${PREFLIGHT_PROFILE:-}" ]]; then
    echo "$PREFLIGHT_PROFILE"
    return
  fi

  local shell_name
  shell_name=$(basename "${SHELL:-bash}")

  case "$shell_name" in
    bash)
      # Prefer .bashrc; fall back to .bash_profile; create .bashrc if neither exists
      if [[ -f "$HOME/.bashrc" ]]; then
        echo "$HOME/.bashrc"
      elif [[ -f "$HOME/.bash_profile" ]]; then
        echo "$HOME/.bash_profile"
      else
        echo "$HOME/.bashrc"
      fi
      ;;
    zsh)
      echo "${ZDOTDIR:-$HOME}/.zshrc"
      ;;
    fish)
      echo "$HOME/.config/fish/config.fish"
      ;;
    *)
      echo "$HOME/.profile"
      ;;
  esac
}

# ── Check if source line is already present ───────────────────────────────────

_pf_profile_has_line() {
  local profile="$1"
  [[ -f "$profile" ]] && grep -qF 'preflight/init.sh' "$profile"
}

# ── Add source line to profile ────────────────────────────────────────────────

_pf_add_to_profile() {
  local profile="$1"
  local shell_name="$2"

  if _pf_profile_has_line "$profile"; then
    _pf_ok "Already present in $profile — skipping"
    return
  fi

  # Ensure parent directory exists (e.g. ~/.config/fish/ on a fresh fish install)
  mkdir -p "$(dirname "$profile")"

  local source_line
  source_line=$(_pf_make_source_line "$PREFLIGHT_DIR" "$shell_name")
  printf '\n# Preflight — developer environment\n%s\n' "$source_line" >> "$profile"
  _pf_ok "Added to $profile"
}

# ── Main install ──────────────────────────────────────────────────────────────

main() {
  echo ""
  _pf_bold "Preflight Installer"
  echo ""

  # Prerequisites
  _pf_has git || _pf_die "git is required but not found — please install git and retry"

  # Already installed?
  if [[ -d "$PREFLIGHT_DIR/.git" ]]; then
    _pf_warn "Preflight already installed at $PREFLIGHT_DIR"
    _pf_info "To update, run: preflight update"
    _pf_info "To reinstall, remove $PREFLIGHT_DIR and re-run this script"
    echo ""
    exit 0
  fi

  if [[ -d "$PREFLIGHT_DIR" ]]; then
    _pf_die "$PREFLIGHT_DIR exists but is not a git repo — remove it and retry"
  fi

  # Clone
  _pf_info "Cloning to $PREFLIGHT_DIR ..."
  if git clone --depth=1 --branch "$PREFLIGHT_BRANCH" "$PREFLIGHT_REPO" "$PREFLIGHT_DIR" 2>&1 \
      | sed 's/^/    /'; then
    _pf_ok "Cloned $PREFLIGHT_REPO"
  else
    _pf_die "git clone failed"
  fi

  # Dotfile modification
  local shell_name
  shell_name=$(basename "${SHELL:-bash}")

  if [[ "${NO_MODIFY_PROFILE:-0}" == "1" ]]; then
    _pf_warn "NO_MODIFY_PROFILE set — skipping shell profile modification"
    _pf_info "Add manually to your shell rc file:"
    _pf_info "  $(_pf_make_source_line "$PREFLIGHT_DIR" "$shell_name")"
  else
    local profile
    profile=$(_pf_detect_profile)
    _pf_info "Updating $profile ..."
    _pf_add_to_profile "$profile" "$shell_name"
  fi

  # First-time config setup (init.sh handles this too, but do it now so the
  # user sees the files immediately)
  if [[ ! -f "$PREFLIGHT_DIR/config/accounts.sh" ]] \
      && [[ -f "$PREFLIGHT_DIR/config/accounts.sh.template" ]]; then
    cp "$PREFLIGHT_DIR/config/accounts.sh.template" "$PREFLIGHT_DIR/config/accounts.sh"
    _pf_ok "Created config/accounts.sh from template"
  fi

  if [[ ! -f "$PREFLIGHT_DIR/lib/1password.sh" ]] \
      && [[ -f "$PREFLIGHT_DIR/lib/1password.sh.template" ]]; then
    cp "$PREFLIGHT_DIR/lib/1password.sh.template" "$PREFLIGHT_DIR/lib/1password.sh"
    _pf_ok "Created lib/1password.sh from template"
  fi

  # Done
  local reload_cmd="source ~/.bashrc"
  [[ "$shell_name" == "zsh" ]]  && reload_cmd="source ${ZDOTDIR:-~}/.zshrc"
  [[ "$shell_name" == "fish" ]] && reload_cmd="source ~/.config/fish/config.fish"

  echo ""
  _pf_bold "Installation complete!"
  echo ""
  _pf_info "Next steps:"
  _pf_info "  1. Edit $PREFLIGHT_DIR/config/accounts.sh  — set OP_ACCOUNT, PROJ_DIRS, etc."
  _pf_info "  2. Edit $PREFLIGHT_DIR/lib/1password.sh    — configure your 1Password secrets"
  _pf_info "  3. Reload your shell:  $reload_cmd  (or open a new terminal)"
  _pf_info "  4. Run: preflight"
  echo ""
  _pf_info "To add custom shell functions, create $PREFLIGHT_DIR/lib/local.sh"
  _pf_info "To check for updates later, run: preflight update"
  echo ""
}

main "$@"

} # end of download guard
