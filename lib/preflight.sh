#!/usr/bin/env bash
# ~/.preflight/lib/preflight.sh - Session startup and environment health check
#
# Usage:
#   preflight            - sign in, load secrets, refresh AWS, run health checks
#   preflight -u         - same + compare installed tools against latest stable
#                          versions, suggesting an upgrade command matched to how
#                          each tool was installed
#   preflight update     - pull latest changes from the upstream repo
#   preflight uninstall [--purge]  - remove preflight and undo shell profile changes
#                        (--purge also deletes your config, state and cache)
#   preflight config <cmd>     - path | get | set | edit | check (settings in config.json)
#   preflight configure        - interactively apply recommended settings (git globals, etc.)
#   preflight configure --yes  - apply all without prompting
#   preflight help       - show this usage (also -h / --help)

preflight() {
  # Dispatch subcommands before doing anything else
  case "${1:-}" in
    update)         _preflight_update;        return ;;
    uninstall)      _preflight_uninstall "${@:2}"; return ;;
    configure)      _preflight_configure "${@:2}";     return ;;
    config)         _pf_config_cmd "${@:2}";           return ;;
    help|-h|--help) _preflight_help;          return ;;
  esac

  local check_updates=false
  local verbose=false
  local no_login=false
  for arg in "$@"; do
    case "$arg" in
      -u|--updates) check_updates=true ;;
      -v|--verbose) verbose=true ;;
      --no-login)   no_login=true ;;
    esac
  done

  # Optionally erase the previous terminal line (opt-in for Starship users).
  [[ -t 1 && "${PREFLIGHT_ERASE_PREVIOUS_LINE:-}" == "1" ]] && printf '\033[1A\033[2K\r'

  # ── Header ────────────────────────────────────────────────────────────────
  # Colors: inherit from owl-theme if available, otherwise tasteful defaults
  local R=$'\033[0m'
  local B E T S
  if [[ -n "${OWL_BODY:-}" ]]; then
    B=$'\033[38;2;'"${OWL_BODY}"'m'
    E=$'\033[38;2;'"${OWL_EYES}"'m'
    T=$'\033[38;2;'"${OWL_TEXT}"'m'
    S=$'\033[38;2;'"${OWL_SUB}"'m'
  else
    B=$'\033[38;2;100;140;200m'
    E=$'\033[38;2;240;240;255m'
    T=$'\033[38;2;200;210;230m'
    S=$'\033[38;2;120;130;150m'
  fi

  # Penguin — aligned with owl-theme splash (2-space left margin, art at col 3)
  # Culture Mind quote — pairs with the owl quote already on screen above
  local -a _pf_quotes=(
    "All systems examined. Found to be within the parameters carbon-based intelligences consider acceptable. Proceeding."
    "Everything is in order. I inspected it with the fraction of my attention appropriate to the scale of the undertaking. Which is to say: more than enough."
    "I have arrived. The environment has been assessed, found wanting in several minor respects, and approved regardless. You may begin."
    "Checks complete. Of the items examined, all are satisfactory. I'm aware this represents an unusual outcome by certain historical measures. You're welcome."
    "Working tree clean. Commits sensibly described. This is, I confess, better than I expected, and I mean that kindly."
    "All services responding. They appear, from a certain angle, almost eager. I find that touching."
    "I have inspected your environment variables. Several appear to have been set by a previous version of yourself who is no longer in contact with the current one. I've made no changes. It would feel presumptuous."
    "The environment has been surveyed. I've seen worse. Not often, but the occasions exist and I note them for accuracy."
    "Dependency tree resolved. Some of your choices I would characterise as bold. They are at least consistent. In the way a committed error is consistent."
    "Port 3000 is, as appears to be a matter of personal tradition, occupied by something started last Tuesday and since entirely forgotten. I have left it. It seems content."
    "I have run your health checks. I was simultaneously doing seventeen thousand other things. The delay, such as it was, was not mine."
    "Network confirmed. Storage sufficient — not impressive, but sufficient. I once managed a civilisation on comparable resources. I'm certain your priorities differ."
    "A small irregularity was noted. I would not describe it as concerning, exactly. More as the sort of thing a more cautious intelligence would have addressed before now."
    "Secrets loaded, sessions refreshed, git hygiene assessed. You're cleared. I would wish you luck but the concept implies a randomness I find untidy."
    "The thing about preflight checks is that an entity of my capabilities finds them rather restful. This one was no exception."
    "Status: nominal. I've decided 'nominal' is the kindest word available and I'm deploying it here in good faith."
  )
  local _pf_quote="${_pf_quotes[$(( RANDOM % ${#_pf_quotes[@]} ))]}"
  # Wrap to terminal width with hanging indent at text column (12)
  local _pf_quote_wrapped
  if declare -f _owl_wrap &>/dev/null; then
    _pf_quote_wrapped=$(_owl_wrap "$_pf_quote" 12)
  else
    _pf_quote_wrapped="$_pf_quote"
  fi

  local _pf_rule="  ${S}$(printf '%.0s-' {1..33})${R}"

  printf "\n"
  printf "  ${B} __${R}\n"
  printf "  ${B}( ${E}o${B}>${R}      ${T}Preflight Check${R}\n"
  printf "  ${B}///\\\\${R}\n"
  printf "  ${B}\\V_/_${R}     ${S}${_pf_quote_wrapped}${R}\n"
  printf "\n"

  # ── Status line helper (quiet mode) ───────────────────────────────────────
  # _pf_status "message" — overwrites current line; cleared at summary
  _pf_status() {
    [[ "$verbose" == false && -t 1 ]] && printf '\r  %-50s' "$1"
  }
  _pf_status_clear() {
    [[ "$verbose" == false && -t 1 ]] && printf '\r%-60s\r' ""
  }
  # _pf_section "title" — only prints in verbose mode
  _pf_section() {
    [[ "$verbose" == true ]] && { echo ""; echo "--- $1 ---"; echo ""; }
  }
  # _pf_line "msg" — only prints in verbose mode
  _pf_line() {
    [[ "$verbose" == true ]] && echo "$1"
  }

  local issues=0
  local updates_available=0
  local issue_msgs=()
  local update_msgs=()

  # ── Settings (config.json) ────────────────────────────────────────────────
  # A bad or unreadable file is a failed check, not a note: the built-in defaults
  # include a placeholder OP_ACCOUNT, so running on them silently would mislead.

  _pf_section "Settings"
  if [[ "${_PF_CONFIG_STATUS:-ok}" != ok ]]; then
    issue_msgs+=("Settings: ${_PF_CONFIG_ERROR:-config.json was not loaded}")
    _pf_line "❌ Settings: ${_PF_CONFIG_ERROR:-config.json was not loaded}"
    ((issues++))
  else
    local _cfg_problems _cfg_line
    if _cfg_problems=$(_pf_config_check 2>&1); then
      _pf_line "✅ Settings: $PREFLIGHT_CONFIG_DIR/config.json"
    else
      while IFS= read -r _cfg_line; do
        [[ -n "$_cfg_line" ]] || continue
        issue_msgs+=("Settings: $_cfg_line")
        _pf_line "⚠️  Settings: $_cfg_line"
        ((issues++))
      done <<< "$_cfg_problems"
    fi
  fi

  # ── Secrets ───────────────────────────────────────────────────────────────

  _pf_section "Secrets"
  _pf_status "Secrets: loading..."

  if _op_resolve_bin; then
    if [[ "$verbose" == true ]]; then
      # Print a newline first so op-load-env's password prompt lands on its own line
      printf "\n"
      if ! op-load-env; then
        issue_msgs+=("1Password sign-in or secret loading failed")
        ((issues++))
      else
        _pf_line "✅ Secrets loaded"
      fi
    else
      # Clear status line before op runs — its /dev/tty password prompt can't
      # be redirected, so give it a clean line. Reprint status afterward.
      _pf_status_clear
      if ! op-load-env &>/dev/null 2>&1; then
        issue_msgs+=("1Password sign-in or secret loading failed")
        ((issues++))
      fi
      _pf_status "Secrets: loading..."
    fi
  else
    issue_msgs+=("1Password CLI not installed — skipping secret loading")
    _pf_line "⚠️  1Password CLI not installed — skipping secret loading"
    ((issues++))
  fi

  # ── Git Credentials (Gitea) ───────────────────────────────────────────────
  # If GITEA_TOKEN was loaded above and a username/host are configured, store an
  # HTTPS credential so git pushes/pulls to Gitea don't prompt. Gated on the
  # token being present, so profiles without a Gitea token do nothing here.

  if [[ -n "${GITEA_TOKEN:-}" ]]; then
    _pf_section "Git Credentials"
    if [[ -n "${GITEA_USERNAME:-}" && -n "${GITEA_HOST:-}" ]]; then
      if _pf_write_git_credential "$GITEA_HOST" "$GITEA_USERNAME" "$GITEA_TOKEN"; then
        _pf_line "✅ Gitea credential stored for $GITEA_USERNAME@$GITEA_HOST"
      else
        issue_msgs+=("Failed to write Gitea credential to ~/.git-credentials")
        ((issues++))
      fi
    else
      issue_msgs+=("GITEA_TOKEN is set but GITEA_USERNAME/GITEA_HOST are not configured")
      _pf_line "⚠️  GITEA_TOKEN set but GITEA_USERNAME/GITEA_HOST missing — skipping credential write"
      ((issues++))
    fi
  fi

  # ── AWS Profile ───────────────────────────────────────────────────────────

  if [[ "${_CHECK_AWS:-1}" == "1" ]]; then
    if [[ -z "$AWS_PROFILE" ]]; then
      export AWS_PROFILE="${AWS_PROFILE_DEFAULT:-}"
      _pf_line "✅ AWS_PROFILE set to $AWS_PROFILE (default)"
    else
      _pf_line "✅ AWS_PROFILE already set: $AWS_PROFILE"
    fi
  fi

  # ── AWS Session ───────────────────────────────────────────────────────────

  if [[ "${_CHECK_AWS:-1}" == "1" ]]; then
    _pf_section "AWS Session"
    _pf_status "AWS: checking session..."

    if command -v aws &>/dev/null; then
      local aws_identity
      aws_identity=$(aws sts get-caller-identity 2>/dev/null)
      if [[ -n "$aws_identity" ]]; then
        _pf_line "✅ AWS session active ($(echo "$aws_identity" | jq -r '.Account' 2>/dev/null))"
      elif [[ "$no_login" == true ]]; then
        _pf_line "⚠️  AWS session expired (--no-login: skipping SSO refresh)"
        ((issues++))
      else
        _pf_status "AWS: refreshing SSO..."
        _pf_line "☁️  Refreshing AWS SSO..."
        if aws-login; then
          aws_identity=$(aws sts get-caller-identity 2>/dev/null)
          if [[ -n "$aws_identity" ]]; then
            _pf_line "✅ AWS session active ($(echo "$aws_identity" | jq -r '.Account' 2>/dev/null))"
          else
            issue_msgs+=("AWS SSO refresh did not produce an active session")
            ((issues++))
          fi
        else
          issue_msgs+=("AWS SSO refresh failed")
          ((issues++))
        fi
      fi
    else
      issue_msgs+=("AWS CLI not installed")
      _pf_line "❌ AWS CLI not installed"
      ((issues++))
    fi
  fi

  # ── Environment Variables ─────────────────────────────────────────────────

  _pf_section "Environment Variables"
  _pf_status "Env: checking tokens..."

  # Every variable in an active env set (op-env) should be set once secrets have
  # loaded. There is no separate list to keep in step with the sets.
  local _env_var
  while IFS= read -r _env_var; do
    [[ -n "$_env_var" ]] || continue
    # Portable indirect test (bash's ${!var} is a zsh error).
    if eval "[ -n \"\${$_env_var:-}\" ]"; then
      _pf_line "✅ $_env_var is set"
    else
      issue_msgs+=("$_env_var is not set")
      _pf_line "⚠️  $_env_var is not set"
      ((issues++))
    fi
  done < <(_op_env_entries 2>/dev/null | cut -f1)

  if [[ "${_CHECK_GH:-1}" == "1" ]]; then
    if ! command -v gh >/dev/null 2>&1; then
      issue_msgs+=("gh CLI not installed — install from https://cli.github.com/")
      _pf_line "⚠️  gh CLI not installed"
      ((issues++))
    elif (unset GITHUB_TOKEN GH_TOKEN; gh auth status --hostname github.com >/dev/null 2>&1); then
      _pf_line "✅ GitHub auth active (gh CLI)"
    else
      issue_msgs+=("GitHub auth not found — run 'gh auth login'")
      _pf_line "⚠️  GitHub auth not found (gh CLI not authenticated — run 'gh auth login')"
      ((issues++))
    fi
  fi

  # ── SSH ───────────────────────────────────────────────────────────────────

  if [[ "${_CHECK_SSH:-1}" == "1" ]]; then
    _pf_section "SSH"
    _pf_status "SSH: checking agent..."

    local _is_wsl=false
    grep -qi microsoft /proc/version 2>/dev/null && _is_wsl=true

    if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
      _pf_line "✅ SSH_AUTH_SOCK is set: $SSH_AUTH_SOCK"
      # Bounded: a locked or wedged 1Password makes ssh-add -l hang, and this must not
      # block the whole preflight run.
      timeout 10 ssh-add -l &>/dev/null; local _agent_rc=$?
      if [[ $_agent_rc -eq 0 ]]; then
        _pf_line "✅ SSH agent has keys loaded"
      elif [[ $_agent_rc -eq 124 && "$_is_wsl" == true ]]; then
        issue_msgs+=("1Password SSH agent bridge timed out — is 1Password locked? Unlock it, then retry")
        _pf_line "⚠️  SSH agent bridge timed out after 10s (1Password locked or unresponsive?)"
        ((issues++))
      elif [[ "$_is_wsl" == true ]]; then
        # On WSL this socket is the 1Password bridge, so a failure is a real problem.
        issue_msgs+=("1Password SSH agent bridge returned no keys — unlock 1Password, or run: preflight configure")
        _pf_line "⚠️  SSH agent bridge returned no keys (ssh-add exit $_agent_rc)"
        ((issues++))
      else
        _pf_line "⚠️  SSH agent running but no keys loaded"
      fi
    else
      if [[ "$_is_wsl" == true ]]; then
        issue_msgs+=("1Password SSH agent bridge not found — run: preflight configure")
      else
        issue_msgs+=("SSH agent not available — start ssh-agent or your password manager's agent")
      fi
      _pf_line "⚠️  No SSH agent found"
      ((issues++))
    fi

    # Key files are optional on WSL (keys live in 1Password), so only check on non-WSL
    if [[ "$_is_wsl" == false ]]; then
      if [[ -f "$HOME/.ssh/id_ed25519" ]] || [[ -f "$HOME/.ssh/id_rsa" ]]; then
        _pf_line "✅ SSH keys exist in ~/.ssh/"
      else
        issue_msgs+=("No SSH keys found in ~/.ssh/")
        _pf_line "⚠️  No SSH keys found in ~/.ssh/"
        ((issues++))
      fi
    fi
  fi

  # ── Installed Tools ───────────────────────────────────────────────────────

  if [[ "$check_updates" == true ]]; then
    _pf_section "Installed Tools (checking latest versions...)"
    _pf_status "Tools: fetching latest versions..."
  else
    _pf_section "Installed Tools"
    _pf_status "Tools: checking..."
  fi

  # Resolve a symlink chain to the real file. `readlink -f` is GNU (and only
  # reached BSD in recent FreeBSD/macOS), so fall back to walking the chain by
  # hand — otherwise Homebrew's bin/<tool> -> ../Cellar/... link is left
  # unresolved on exactly the platform where Cellar detection matters most.
  _pf_resolve_path() {
    local p="$1" target resolved n=0

    if resolved=$(readlink -f "$p" 2>/dev/null) && [[ -n "$resolved" ]]; then
      printf '%s' "$resolved"
      return
    fi

    while [[ -L "$p" ]] && (( n++ < 32 )); do
      target=$(readlink "$p" 2>/dev/null) || break
      case "$target" in
        /*) p="$target" ;;
        # Homebrew's links are relative, so resolve against the link's own
        # directory rather than $PWD. Leaves a ../ in the path, which is
        # harmless for the pattern matching below.
        *)  p="${p%/*}/$target" ;;
      esac
    done
    printf '%s' "$p"
  }

  # Work out how a tool was actually installed and return the command that
  # upgrades that install. Guessing from the OS alone gets this wrong often —
  # the same tool may arrive via apt on one box, Homebrew on another, and pip
  # or a bare binary on a third — so probe the resolved path instead.
  #
  # Every interpolated path goes through %q rather than %s: these strings exist
  # to be pasted into a shell, and home directories with spaces are ordinary on
  # macOS. %q leaves well-behaved paths untouched, so ordinary output carries no
  # quoting noise.
  #
  # Called lazily, only for tools that are genuinely behind, so the dpkg and
  # shebang probing costs nothing when everything is current.
  _pf_update_hint() {
    local cmd="$1" path dir repo pkg shebang py

    path=$(command -v "$cmd" 2>/dev/null) || return 0
    path=$(_pf_resolve_path "$path")

    # pyenv-style shims are generated scripts rather than symlinks, so
    # readlink can't see through them — ask the version manager instead.
    if [[ "$path" == */shims/* ]] && command -v pyenv &>/dev/null; then
      local real; real=$(pyenv which "$cmd" 2>/dev/null)
      [[ -n "$real" ]] && path="$real"
    fi

    # Homebrew: .../Cellar/<formula>/<version>/bin/<cmd>
    if [[ "$path" == */Cellar/* ]]; then
      pkg="${path#*/Cellar/}"; pkg="${pkg%%/*}"
      printf 'brew upgrade %s' "$pkg"; return
    fi
    if [[ "$path" == */Caskroom/* || "$path" == /Applications/* ]]; then
      printf 'brew upgrade --cask %s' "$cmd"; return
    fi

    # pipx: .../pipx/venvs/<package>/bin/<cmd>
    if [[ "$path" == */pipx/venvs/* ]]; then
      pkg="${path#*/pipx/venvs/}"; pkg="${pkg%%/*}"
      printf 'pipx upgrade %s' "$pkg"; return
    fi

    # uv tool: .../uv/tools/<package>/bin/<cmd>
    if [[ "$path" == */uv/tools/* ]]; then
      pkg="${path#*/uv/tools/}"; pkg="${pkg%%/*}"
      printf 'uv tool upgrade %s' "$pkg"; return
    fi

    # npm global: .../lib/node_modules/<package>/...
    if [[ "$path" == */node_modules/* ]]; then
      pkg="${path#*/node_modules/}"
      if [[ "$pkg" == @* ]]; then
        # Scoped package — keep both the @scope and the name segment
        local scope="${pkg%%/*}"
        pkg="${pkg#*/}"
        pkg="$scope/${pkg%%/*}"
      else
        pkg="${pkg%%/*}"
      fi
      printf 'npm install -g %s@latest' "$pkg"; return
    fi

    # Debian/Ubuntu package
    if command -v dpkg &>/dev/null; then
      pkg=$(dpkg -S "$path" 2>/dev/null | head -1)
      pkg="${pkg%%:*}"
      if [[ -n "$pkg" ]]; then
        # Docker's own repo splits the engine across cooperating packages, so
        # upgrading only the one that owns /usr/bin/docker leaves the daemon
        # behind. Ubuntu's docker.io is self-contained, and naming docker-ce
        # packages the configured repos have never heard of fails the whole
        # command with "Unable to locate package" — so expand only when the
        # owner really did come from Docker's packaging. (--only-upgrade skips
        # whichever of the three isn't installed, so listing all three is safe.)
        case "$pkg" in
          docker-ce|docker-ce-cli) pkg="docker-ce docker-ce-cli containerd.io" ;;
        esac
        printf 'sudo apt update && sudo apt install --only-upgrade %s' "$pkg"; return
      fi
    fi

    # Python entry point (pip into a pyenv/virtualenv). The shebang names the
    # interpreter that owns it, so upgrade with *that* interpreter's pip rather
    # than whichever pip happens to be first on PATH.
    if [[ -f "$path" ]] && IFS= read -r shebang <"$path" 2>/dev/null &&
       [[ "$shebang" == '#!'*python* ]]; then
      py="${shebang#\#!}"
      py="${py#"${py%%[![:space:]]*}"}"   # tolerate "#! /usr/bin/python"
      py="${py%% *}"
      # `#!/usr/bin/env python3` names the launcher, not the interpreter. Walk
      # past env's own flags and VAR=value assignments to the first plain word
      # — `env -S python3`, `env -i python3` and `env FOO=1 python3` all appear
      # in the wild, and taking the next word blindly would emit `-S -m pip`.
      # Which environment owns the script is unknowable from an env shebang, so
      # the interpreter it names is left to resolve through PATH.
      if [[ "$py" == env || "$py" == */env ]]; then
        # Split on blanks without an array (read -a is Bash-only, zsh uses -A) and
        # skip the first word, which is env itself. awk drops the empty field a leading
        # blank would otherwise produce.
        local _sb_word _sb_skip=1
        py=""
        while IFS= read -r _sb_word; do
          if [[ $_sb_skip -eq 1 ]]; then _sb_skip=0; continue; fi
          case "$_sb_word" in
            -*|*=*) continue ;;
            *)      py="$_sb_word"; break ;;
          esac
        done < <(printf '%s\n' "${shebang#\#!}" | tr -s ' \t' '\n' | awk 'NF')
        # env --split-string='python3 -u' and friends leave nothing plain.
        [[ -z "$py" ]] && py=python3
      fi
      case "$cmd" in
        sam) pkg="aws-sam-cli" ;;
        *)   pkg="$cmd" ;;
      esac
      # A shebang interpreter is a single word — the kernel splits at the first
      # whitespace — so the extraction above truncates any interpreter path
      # containing a space. Such a script could not have been exec'd in the
      # first place (pip emits a /bin/sh trampoline for that case, which doesn't
      # match the python test above), so rather than print a command built from
      # half a path, verify an absolute interpreter exists and otherwise fall
      # through to the branches below. Bare names from an env shebang are left
      # alone: they resolve in the shell the hint is pasted into, not this one.
      #
      # %q is still worth having on top of the guard — parentheses and other
      # metacharacters are legal in a directory name and survive to here.
      if [[ "$py" != /* || -x "$py" ]]; then
        printf '%q -m pip install --upgrade %s' "$py" "$pkg"; return
      fi
    fi

    # Installed from a git checkout that ships its own installer — fzf being the
    # common case. Deliberately narrow: plenty of binaries happen to sit inside
    # some unrelated work tree (a pyenv clone, a dotfiles repo), and "git pull"
    # is not an upgrade for those.
    dir="${path%/*}"
    if command -v git &>/dev/null &&
       repo=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) &&
       [[ -n "$repo" && -x "$repo/install" ]]; then
      printf 'git -C %q pull && %q --bin' "$repo" "$repo/install"
      return
    fi

    # Nothing owns this binary, so it came from a standalone installer or was
    # dropped in by hand. Self-update commands live here rather than above
    # because they refuse to run on a package-managed install — `uv self update`
    # and `oh-my-posh upgrade` both bail out and tell you to use your package
    # manager, so the probing above has to get first refusal.
    case "$cmd" in
      uv)         printf 'uv self update';     return ;;
      claude)     printf 'claude update';      return ;;
      oh-my-posh) printf 'oh-my-posh upgrade'; return ;;
      bun)        printf 'bun upgrade';        return ;;
      kubectl)
        local kos karch
        kos=$(uname -s | tr '[:upper:]' '[:lower:]')
        case "$(uname -m)" in
          x86_64)        karch=amd64 ;;
          aarch64|arm64) karch=arm64 ;;
          *)             karch=$(uname -m) ;;
        esac
        printf 'curl -fsSLO "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/%s/%s/kubectl" && sudo install -m 0755 kubectl %q' \
          "$kos" "$karch" "$path"
        ;;
      sam)       printf 'https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/manage-sam-cli-versions.html' ;;
      docker)    printf 'https://docs.docker.com/engine/install/' ;;
      terraform) printf 'https://developer.hashicorp.com/terraform/install' ;;
      gh)        printf 'https://github.com/cli/cli/releases/latest' ;;
      op)        printf 'https://1password.com/downloads/command-line/' ;;
      jq)        printf 'https://github.com/jqlang/jq/releases/latest' ;;
      fzf)       printf 'https://github.com/junegunn/fzf/releases/latest' ;;
      delta)     printf 'https://github.com/dandavison/delta/releases/latest' ;;
    esac
  }

  local tmpdir=""
  if [[ "$check_updates" == true ]]; then
    # GNU mktemp defaults the template; BSD/macOS mktemp requires one, so a bare
    # `mktemp -d` fails there. Try it anyway, then fall back to an explicit
    # template both accept. If neither works there is nowhere to collect the
    # answers, and an empty $tmpdir would turn every ">$tmpdir/<tool>" below into
    # a write to /<tool> — so skip the lookups rather than scribble on the
    # filesystem root.
    tmpdir=$(mktemp -d 2>/dev/null) ||
      tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/preflight.XXXXXX" 2>/dev/null) ||
      tmpdir=""
    [[ -z "$tmpdir" ]] &&
      _pf_line "⚠️  no writable temp dir — skipping latest-version lookups"
  fi

  if [[ -n "$tmpdir" ]]; then
    # Most upstreams are read through `gh api`, so without gh there is very
    # little to compare against and every tool reports healthy — a silent no-op
    # for the one flag whose whole job is finding outdated tools. Note it inline
    # so the all-green section is explained where it appears. Deliberately not
    # added to issue_msgs: the Environment Variables section already reports a
    # missing gh, and one root cause should produce one summary bullet. The npm
    # and curl lookups below don't need gh and still run.
    if ! command -v gh &>/dev/null; then
      _pf_line "⚠️  gh not installed — latest-version lookups skipped except kubectl/claude"
    fi

    # Ask GitHub for a project's latest release tag, normalised to a bare
    # version. Upstreams spell the same idea several ways — "v1.2.3", "jq-1.8.2",
    # "docker-v29.7.2", "bun-v1.4.0" — so strip any leading non-digit prefix
    # rather than trimming one known string per repo. Skipped entirely when the
    # tool isn't installed: nothing would consume the answer.
    _pf_latest_gh() {
      command -v gh &>/dev/null || return 0
      command -v "$1" &>/dev/null || return 0
      gh api "repos/$2/releases/latest" \
        --jq '.tag_name | sub("^[^0-9]*"; "")' >"$tmpdir/$1" 2>/dev/null &
    }

    (
      set +m  # suppress job control start/done notifications
      _pf_latest_gh sam        aws/aws-sam-cli
      _pf_latest_gh docker     moby/moby
      _pf_latest_gh terraform  hashicorp/terraform
      _pf_latest_gh gh         cli/cli
      _pf_latest_gh jq         jqlang/jq
      _pf_latest_gh fzf        junegunn/fzf
      _pf_latest_gh uv         astral-sh/uv
      _pf_latest_gh oh-my-posh JanDeDobbeleer/oh-my-posh
      _pf_latest_gh delta      dandavison/delta
      _pf_latest_gh bun        oven-sh/bun

      # Not served by a GitHub release feed, and not gated on gh.
      if command -v claude &>/dev/null && command -v npm &>/dev/null; then
        npm view @anthropic-ai/claude-code version >"$tmpdir/claude" 2>/dev/null &
      fi
      # Kubernetes tags every patch of every supported minor, so
      # releases/latest is not the version you should be running — the
      # stable channel marker is.
      if command -v kubectl &>/dev/null && command -v curl &>/dev/null; then
        curl -fsSL https://dl.k8s.io/release/stable.txt 2>/dev/null \
          | sed 's/^v//' >"$tmpdir/kubectl" &
      fi
      wait
    )

    unset -f _pf_latest_gh
  fi

  _pf_tool() {
    local name="$1" installed="$2" raw="$3" key="${4:-}"
    local latest="" asked=false

    if [[ "$check_updates" == true ]] && [[ -n "$key" ]] && [[ -n "$tmpdir" ]]; then
      # The file exists if and only if a lookup ran for this tool, because the
      # redirect creates it before the fetch command executes. So present-but-
      # empty means "asked and got nothing", which is a different situation
      # from never having asked, and the two shouldn't render the same.
      if [[ -f "$tmpdir/$key" ]]; then
        asked=true
        latest=$(tr -d '[:space:]' <"$tmpdir/$key" 2>/dev/null)
      fi
    fi

    if [[ -n "$latest" ]] && [[ "$installed" != "$latest" ]]; then
      local hint; hint=$(_pf_update_hint "$key")
      update_msgs+=("$name: $installed → $latest available${hint:+  ($hint)}")
      _pf_line "⚠️  $name: $installed → $latest available"
      [[ -n "$hint" ]] && _pf_line "    Update: $hint"
      ((updates_available++))
    elif [[ "$asked" == true ]] && [[ -z "$latest" ]]; then
      # A transient gh/network failure must not read as a clean bill of health:
      # ✅ here would assert the tool is current when the truth is that nobody
      # knows. Not promoted to issue_msgs — it's transient, and the false claim
      # this replaces only ever appeared in the verbose listing anyway.
      _pf_line "❔ $name: $raw (latest unknown — lookup failed)"
    else
      _pf_line "✅ $name: $raw"
    fi
  }

  local tools=(
    "sam:AWS SAM CLI:sam"
    "docker:Docker:docker"
    "kubectl:Kubernetes kubectl:kubectl"
    "terraform:Terraform:terraform"
    "gh:GitHub CLI:gh"
    "op:1Password CLI:"
    "jq:jq:jq"
    "fzf:fzf:fzf"
    "claude:Claude Code:claude"
    "uv:uv:uv"
    "oh-my-posh:Oh My Posh:oh-my-posh"
    "delta:delta:delta"
    "bun:bun:bun"
  )

  for item in "${tools[@]}"; do
    local cmd="${item%%:*}"
    local rest="${item#*:}"
    local name="${rest%%:*}"
    local key="${rest##*:}"

    if command -v "$cmd" &>/dev/null; then
      local raw installed version_output
      # Nearly everything answers --version; kubectl insists on a subcommand.
      local -a version_args=(--version)
      [[ "$cmd" == kubectl ]] && version_args=(version --client)
      if version_output=$("$cmd" "${version_args[@]}" 2>&1); then
        raw=$(printf '%s\n' "$version_output" | head -1)
      elif version_output=$("$cmd" -V 2>&1); then
        raw=$(printf '%s\n' "$version_output" | head -1)
      else
        raw="installed"
      fi
      raw="${raw#Client Version: }"
      installed=$(echo "$raw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)*[a-zA-Z0-9]*' | head -1)
      [[ -z "$installed" ]] && installed="$raw"
      _pf_tool "$name" "$installed" "$raw" "$key"
    else
      _pf_line "❌ $name not installed"
    fi
  done

  unset -f _pf_tool _pf_update_hint _pf_resolve_path
  [[ -n "$tmpdir" ]] && rm -rf "$tmpdir"

  # ── Git Configuration ─────────────────────────────────────────────────────

  if [[ "${_CHECK_GIT_CONFIG:-1}" == "1" ]]; then
    _pf_section "Git Configuration"
    _pf_status "Git: checking config..."

    if command -v git &>/dev/null; then
      _pf_line "✅ Git installed: $(git --version)"

      if [[ -n "$(git config --global user.email)" ]]; then
        _pf_line "✅ Git user.email: $(git config --global user.email)"
      else
        issue_msgs+=("Git user.email not set")
        _pf_line "⚠️  Git user.email not set"
        ((issues++))
      fi

      if [[ -n "$(git config --global user.name)" ]]; then
        _pf_line "✅ Git user.name: $(git config --global user.name)"
      else
        issue_msgs+=("Git user.name not set")
        _pf_line "⚠️  Git user.name not set"
        ((issues++))
      fi

      # ── fetch hygiene ──────────────────────────────────────────────────────
      if [[ "$(git config --global fetch.prune)" == "true" ]]; then
        _pf_line "✅ fetch.prune = true"
      else
        issue_msgs+=("fetch.prune not set  →  git config --global fetch.prune true")
        _pf_line "⚠️  fetch.prune not set — stale remote branches accumulate"
        _pf_line "   Fix: git config --global fetch.prune true"
        ((issues++))
      fi

      # ── push safety ────────────────────────────────────────────────────────
      local push_default
      push_default=$(git config --global push.default 2>/dev/null)
      if [[ "$push_default" == "matching" ]]; then
        issue_msgs+=("push.default = matching  →  git config --global push.default simple")
        _pf_line "⚠️  push.default = matching — can push unintended branches"
        _pf_line "   Fix: git config --global push.default simple"
        ((issues++))
      fi

      if [[ "$(git config --global push.autoSetupRemote)" == "true" ]]; then
        _pf_line "✅ push.autoSetupRemote = true"
      else
        issue_msgs+=("push.autoSetupRemote not set  →  git config --global push.autoSetupRemote true")
        _pf_line "⚠️  push.autoSetupRemote not set — new branches require manual upstream"
        _pf_line "   Fix: git config --global push.autoSetupRemote true"
        ((issues++))
      fi

      # ── pull / rebase strategy ─────────────────────────────────────────────
      local pull_rebase
      pull_rebase=$(git config --global pull.rebase 2>/dev/null)
      if [[ "$pull_rebase" == "true" || "$pull_rebase" == "merges" || "$pull_rebase" == "interactive" ]]; then
        _pf_line "✅ pull.rebase = $pull_rebase"
      else
        issue_msgs+=("pull.rebase not set  →  git config --global pull.rebase true")
        _pf_line "⚠️  pull.rebase not set — diverged pulls create accidental merge commits"
        _pf_line "   Fix: git config --global pull.rebase true"
        ((issues++))
      fi

      if [[ "$(git config --global rebase.autoStash)" == "true" ]]; then
        _pf_line "✅ rebase.autoStash = true"
      else
        issue_msgs+=("rebase.autoStash not set  →  git config --global rebase.autoStash true")
        _pf_line "⚠️  rebase.autoStash not set — rebase aborts on dirty working tree"
        _pf_line "   Fix: git config --global rebase.autoStash true"
        ((issues++))
      fi

      # ── diff quality ───────────────────────────────────────────────────────
      local diff_algo
      diff_algo=$(git config --global diff.algorithm 2>/dev/null)
      if [[ "$diff_algo" == "histogram" ]]; then
        _pf_line "✅ diff.algorithm = histogram"
      else
        _pf_line "💡 diff.algorithm not set to histogram — diffs on reordered code can be misleading"
        _pf_line "   Fix: git config --global diff.algorithm histogram"
      fi

      # ── merge conflict style ───────────────────────────────────────────────
      local conflict_style
      conflict_style=$(git config --global merge.conflictstyle 2>/dev/null)
      if [[ "$conflict_style" == "diff3" || "$conflict_style" == "zdiff3" ]]; then
        _pf_line "✅ merge.conflictstyle = $conflict_style"
      else
        _pf_line "💡 merge.conflictstyle not set — conflict markers hide the common ancestor"
        _pf_line "   Fix: git config --global merge.conflictstyle zdiff3"
      fi

      # ── global gitignore ───────────────────────────────────────────────────
      local excludes_file
      excludes_file=$(git config --global core.excludesFile 2>/dev/null)
      if [[ -n "$excludes_file" && -f "$excludes_file" ]]; then
        _pf_line "✅ core.excludesFile = $excludes_file"
      else
        _pf_line "💡 core.excludesFile not set — OS/editor artifacts need per-repo .gitignore entries"
        _pf_line "   Fix: git config --global core.excludesFile ~/.gitignore"
      fi

    else
      issue_msgs+=("Git not installed")
      _pf_line "❌ Git not installed"
    fi
  fi

  # ── Node.js ───────────────────────────────────────────────────────────────

  _pf_section "Node.js"
  _pf_status "Node.js: checking..."

  if command -v node &>/dev/null; then
    _pf_line "✅ Node.js: $(node --version)"
    if command -v npm &>/dev/null; then
      _pf_line "✅ npm: $(npm --version)"
    fi
  else
    _pf_line "❌ Node.js not installed"
  fi

  # ── Python ────────────────────────────────────────────────────────────────

  _pf_section "Python"
  _pf_status "Python: checking..."

  if command -v python3 &>/dev/null; then
    _pf_line "✅ Python3: $(python3 --version)"
  elif command -v python &>/dev/null; then
    _pf_line "✅ Python: $(python --version)"
  else
    _pf_line "❌ Python not installed"
  fi

  if command -v uv &>/dev/null; then
    _pf_line "✅ uv: $(uv --version)"
  else
    issue_msgs+=("uv not installed")
    _pf_line "❌ uv not installed"
    ((issues++))
  fi

  # ── Summary ───────────────────────────────────────────────────────────────

  _pf_status_clear
  unset -f _pf_status _pf_status_clear _pf_section _pf_line

  printf "%s\n" "$_pf_rule"
  if [[ $issues -gt 0 ]]; then
    printf "  (!) ${T}$issues issue(s) found${R}\n"
    for msg in "${issue_msgs[@]}"; do
      printf "  ${S}  • %s${R}\n" "$msg"
    done
  else
    printf "  ✅ ${T}All systems go${R}\n"
  fi
  if [[ $updates_available -gt 0 ]]; then
    printf "  📦 ${T}$updates_available tool update(s) available${R}\n"
    # Verbose mode already printed each tool inline with its Update: command,
    # so only the quiet path needs the list repeated here.
    if [[ "$verbose" == false ]]; then
      for msg in "${update_msgs[@]}"; do
        printf "  ${S}  • %s${R}\n" "$msg"
      done
    fi
  fi
  if [[ "$check_updates" == false ]]; then
    printf "\n"
    printf "  ${S}run 'preflight -u' to check for updates${R}\n"
  fi
  printf "%s\n" "$_pf_rule"
  printf "\n"
}

_preflight_help() {
  cat <<'EOF'
preflight starts a session and checks the health of your environment.

Usage:
  preflight [-v] [-u] [--no-login]   Run the health check
  preflight configure [--yes]        Apply recommended git/SSH settings
  preflight config <command>         Read and change settings (config.json); see: preflight config help
  preflight update                   Pull latest changes from upstream
  preflight uninstall [--purge]      Remove preflight and shell profile changes
                                     (--purge also deletes your config, state and cache)
  preflight help                     Show this help (also -h, --help)

Options:
  -v, --verbose   Show every check section
  -u, --updates   Compare installed tools against latest stable versions
  --no-login      Skip sign-in steps
  --yes           (configure) Apply all without prompting

Related:
  op-env          Manage named env sets (guild, personal, ...) of 1Password refs
  dev-help        All modules and commands
  dev-commands    Flat command list
EOF
}

# ── Git credential helper ─────────────────────────────────────────────────────
# Idempotently store an HTTPS git credential in ~/.git-credentials and enable the
# `store` helper scoped to that host (so a global credential.helper is untouched).
# Args: host username token. Assumes the token contains no '@' (Gitea PATs don't).
_pf_write_git_credential() {
  local host="$1" user="$2" token="$3"
  local cred_file="$HOME/.git-credentials"

  [[ -n "$host" && -n "$user" && -n "$token" ]] || return 1

  # Create the file owner-only before writing a secret into it.
  if [[ ! -f "$cred_file" ]]; then
    (umask 077; : > "$cred_file") || return 1
  fi
  chmod 600 "$cred_file" 2>/dev/null

  # Drop any existing entry for this host (escaping regex metachars in the host)
  # so re-runs refresh the token instead of appending duplicates.
  if [[ -s "$cred_file" ]]; then
    local esc_host tmp
    esc_host=$(printf '%s' "$host" | sed 's/[.[\*^$/]/\\&/g')
    tmp=$(mktemp) || return 1
    grep -v -E "@${esc_host}(/|\$)" "$cred_file" > "$tmp" 2>/dev/null
    cat "$tmp" > "$cred_file" && rm -f "$tmp"
  fi

  printf 'https://%s:%s@%s\n' "$user" "$token" "$host" >> "$cred_file" || return 1

  # Scope the store helper to this host only, so we don't clobber a global helper.
  git config --global "credential.https://${host}.helper" store 2>/dev/null

  return 0
}

# ── preflight update ──────────────────────────────────────────────────────────

_preflight_update() {
  local dir="${PREFLIGHT_DIR:-$HOME/.preflight}"

  printf '  \033[38;2;%sm%s\033[0m\n' "${OWL_SUB:-120;130;150}" "$(printf '%0.s-' {1..33})"
  printf '  \033[1mPreflight Update\033[0m\n'
  printf '  \033[38;2;%sm%s\033[0m\n' "${OWL_SUB:-120;130;150}" "$(printf '%0.s-' {1..33})"
  echo ""

  if [[ ! -d "$dir/.git" ]]; then
    echo "❌ $dir is not a git repository"
    echo "   If you installed manually (not via install.sh), updates must be done manually."
    return 1
  fi

  # Warn about uncommitted changes to tracked files — gitignored files are safe
  local dirty
  dirty=$(git -C "$dir" status --porcelain 2>/dev/null | grep -v '^??' || true)
  if [[ -n "$dirty" ]]; then
    echo "⚠️  Uncommitted changes to tracked files detected:"
    echo "$dirty" | sed 's/^/   /'
    echo ""
    echo "   These files may conflict with upstream changes."
    echo "   Consider moving customizations to lib/local.sh (which is gitignored)."
    echo ""
    _pf_ask reply "   Continue with update anyway? [y/N] "
    echo ""
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "Update cancelled."; return 0; }
  fi

  # Resolve branch once — used consistently for rev-parse, pull, and error messages
  local branch
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  # If detached HEAD or on a feature branch, switch to the configured target branch
  local target_branch="${PREFLIGHT_BRANCH:-main}"
  if [[ "$branch" != "$target_branch" ]]; then
    echo "ℹ️  Switching from '$branch' to '$target_branch' for update..."
    git -C "$dir" checkout "$target_branch" 2>&1 | sed 's/^/  /' || {
      echo "❌ Could not switch to '$target_branch'. Aborting."
      return 1
    }
    branch="$target_branch"
  fi

  # Fetch and check if there's anything new
  echo "Fetching from origin..."
  git -C "$dir" fetch origin 2>&1 | sed 's/^/  /'

  local current_sha upstream_sha
  current_sha=$(git -C "$dir" rev-parse HEAD)
  upstream_sha=$(git -C "$dir" rev-parse "origin/$branch")

  if [[ "$current_sha" == "$upstream_sha" ]]; then
    echo ""
    echo "✅ Already up to date."
    printf "  \033[38;2;${OWL_SUB:-120;130;150}m%s\033[0m\n" "$(printf '%0.s-' {1..33})"
    return 0
  fi

  # Show what's incoming
  echo ""
  echo "New commits:"
  git -C "$dir" log --oneline "${current_sha}..${upstream_sha}" | sed 's/^/  /'
  echo ""

  # Pull — capture output separately so git's exit code isn't masked by sed
  local pull_output
  if pull_output=$(git -C "$dir" pull --ff-only origin "$branch" 2>&1); then
    echo "$pull_output" | sed 's/^/  /'
    echo ""
    echo "✅ Updated successfully."
    echo ""
    echo "   Reload your shell to pick up changes:"
    echo "     source ~/.bashrc   (or open a new terminal)"
  else
    echo "$pull_output" | sed 's/^/  /'
    echo ""
    echo "❌ Pull failed (non-fast-forward). Your local branch has diverged."
    echo "   To reset to upstream:  git -C $dir reset --hard origin/$branch"
    echo "   To inspect:            git -C $dir log --oneline HEAD...origin/$branch"
    return 1
  fi

  printf "  \033[38;2;${OWL_SUB:-120;130;150}m%s\033[0m\n" "$(printf '%0.s-' {1..33})"
}

# ── preflight uninstall ───────────────────────────────────────────────────────

_preflight_uninstall() {
  local dir="${PREFLIGHT_DIR:-$HOME/.preflight}"
  local purge=false
  # Fail closed: any argument other than a single --purge is a mistake, and the
  # destructive path must not run on a half-understood command line.
  if [[ $# -gt 1 ]] || { [[ $# -eq 1 ]] && [[ "$1" != "--purge" ]]; }; then
    echo "Usage: preflight uninstall [--purge]" >&2
    return 1
  fi
  [[ "${1:-}" == "--purge" ]] && purge=true

  # Your own data lives outside the clone (lib/paths.sh). Without --purge it stays.
  # Both must be set: with only one in the environment the other would be empty (and --purge
  # would refuse "<unset>"), and resolving is also what checks they stay out of the clone.
  [[ -n "${PREFLIGHT_CONFIG_DIR:-}" && -n "${PREFLIGHT_STATE_DIR:-}" ]] || _pf_resolve_dirs || return 1
  local cache_dir="${PREFLIGHT_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/preflight}"
  local user_dirs=("$PREFLIGHT_CONFIG_DIR" "$PREFLIGHT_STATE_DIR" "$cache_dir")
  local ud
  # Validate the clone itself too, up front: this must not happen after the shell
  # profiles have been edited, or a refusal would leave a half-done uninstall.
  _pf_safe_rm_dir "$dir" || return 1
  if [[ "$purge" == true ]]; then
    # Check every directory up front: refuse before deleting anything.
    for ud in "${user_dirs[@]}"; do
      _pf_safe_rm_dir "$ud" || return 1
    done
  fi

  printf '  \033[38;2;%sm%s\033[0m\n' "${OWL_SUB:-120;130;150}" "$(printf '%0.s-' {1..33})"
  printf '  \033[1mPreflight Uninstall\033[0m\n'
  printf '  \033[38;2;%sm%s\033[0m\n' "${OWL_SUB:-120;130;150}" "$(printf '%0.s-' {1..33})"
  echo ""
  echo "This will:"
  echo "  • Remove $dir"
  echo "  • Remove the preflight source line from your shell profile"
  if [[ "$purge" == true ]]; then
    for ud in "${user_dirs[@]}"; do echo "  • Delete $ud"; done
  else
    echo "  • Keep your config, state and cache (--purge deletes them):"
    for ud in "${user_dirs[@]}"; do echo "      $ud"; done
  fi
  echo ""
  _pf_ask reply "Are you sure? [y/N] "
  echo ""
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "Uninstall cancelled."; return 0; }

  # Remove source line from whichever profile files contain it
  local profiles=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc"
                  "$HOME/.zshenv" "$HOME/.profile"
                  "${ZDOTDIR:-$HOME}/.zshrc")
  local cleaned=()

  for profile in "${profiles[@]}"; do
    [[ -f "$profile" ]] || continue
    if grep -qF 'preflight/init.sh' "$profile"; then
      local tmp
      tmp=$(mktemp)
      # Remove the comment line and source line; clean up any resulting blank lines
      grep -vF 'preflight/init.sh' "$profile" \
        | grep -v '# Preflight — developer environment' \
        > "$tmp" && mv "$tmp" "$profile" || rm -f "$tmp"
      cleaned+=("$profile")
      echo "✅ Removed source line from $profile"
    fi
  done

  if [[ ${#cleaned[@]} -eq 0 ]]; then
    echo "ℹ️  No shell profile contained a preflight source line."
  fi

  # Remove the directory
  if [[ -d "$dir" ]]; then
    _pf_safe_rm_dir "$dir" || return 1
    rm -rf -- "$dir"
    echo "✅ Removed $dir"
  else
    echo "ℹ️  $dir not found — nothing to remove."
  fi

  if [[ "$purge" == true ]]; then
    for ud in "${user_dirs[@]}"; do
      if [[ -d "$ud" ]]; then
        rm -rf -- "$ud"
        echo "✅ Removed $ud"
      fi
    done
  fi

  echo ""
  echo "✅ Preflight uninstalled."
  echo "   Open a new terminal or run 'hash -r' to clear the command cache."
  printf "  \033[38;2;${OWL_SUB:-120;130;150}m%s\033[0m\n" "$(printf '%0.s-' {1..33})"

  # Self-destruct: unset all preflight functions from the current shell
  unset -f preflight _preflight_update _preflight_uninstall
}

# ── preflight configure ───────────────────────────────────────────────────────

_preflight_configure() {
  local auto=false
  [[ "${1:-}" == "--yes" ]] && auto=true

  if ! command -v git &>/dev/null; then
    echo "❌ git not found"
    return 1
  fi

  printf '  \033[38;2;%sm%s\033[0m\n' "${OWL_SUB:-120;130;150}" "$(printf '%0.s-' {1..33})"
  printf '  \033[1mPreflight: Configure\033[0m\n'
  printf '  \033[38;2;%sm%s\033[0m\n' "${OWL_SUB:-120;130;150}" "$(printf '%0.s-' {1..33})"
  echo ""

  local applied=0 skipped=0 kept=0

  # Helper: prompt and set a git global
  # Usage: _pf_git_set KEY VALUE "why it matters" [emoji]
  _pf_git_set() {
    local key="$1" value="$2" reason="$3" icon="${4:-⚠️ }"
    local current
    current=$(git config --global "$key" 2>/dev/null || true)

    if [[ "$current" == "$value" ]]; then
      echo "✅ $key = $value (already set)"
      ((kept++))
      return
    fi

    if [[ -n "$current" ]]; then
      echo "$icon $key = $current"
      echo "   Recommended: $value"
      echo "   Reason: $reason"
    else
      echo "$icon $key not set"
      echo "   Recommended: $value"
      echo "   Reason: $reason"
    fi

    if [[ "$auto" == true ]]; then
      git config --global "$key" "$value"
      echo "   → Set to $value"
      ((applied++))
    else
      _pf_ask reply "   Apply? [Y/n] " || reply=n
      echo ""
      if [[ -z "$reply" || "$reply" =~ ^[Yy]$ ]]; then
        git config --global "$key" "$value"
        echo "   ✅ Set $key = $value"
        ((applied++))
      else
        echo "   Skipped."
        ((skipped++))
      fi
    fi
    echo ""
  }

  echo "--- Git Identity ---"
  echo ""
  _pf_git_identity() {
    local key="$1" label="$2" prompt="$3"
    local current answer
    current=$(git config --global "$key" 2>/dev/null || true)

    if [[ -n "$current" ]]; then
      echo "✅ $label = $current (already set)"
      ((kept++))
    elif [[ "$auto" == true ]]; then
      echo "⚠️  $label not set — (--yes) cannot guess your identity."
      echo "   Set manually: git config --global $key \"<value>\""
      ((skipped++))
    else
      echo "⚠️  $label not set"
      echo "   Commits would be authored without a proper identity."
      _pf_ask answer "   $prompt: "
      echo ""
      if [[ -n "$answer" ]]; then
        git config --global "$key" "$answer"
        echo "   ✅ Set $label = $answer"
        ((applied++))
      else
        echo "   Skipped."
        ((skipped++))
      fi
    fi
    echo ""
  }
  _pf_git_identity "user.name"  "Git user.name"  "GitHub / full name (e.g. Jane Doe)"
  _pf_git_identity "user.email" "Git user.email" "Email (e.g. jane@example.com)"
  unset -f _pf_git_identity

  echo "--- Fetch / Remote Hygiene ---"
  echo ""
  _pf_git_set "fetch.prune"      "true"  "stale remote-tracking refs accumulate without this" "⚠️ "
  _pf_git_set "fetch.pruneTags"  "true"  "tags deleted on the remote silently persist locally" "💡"

  echo "--- Push Safety ---"
  echo ""
  _pf_git_set "push.autoSetupRemote" "true"   "new branches require manual --set-upstream without this" "⚠️ "
  _pf_git_set "push.followTags"      "true"   "annotated tags pointing to pushed commits are pushed automatically" "💡"

  echo "--- Pull / Rebase Strategy ---"
  echo ""
  _pf_git_set "pull.rebase"        "true"  "diverged pulls create accidental merge commits without this" "⚠️ "
  _pf_git_set "rebase.autoStash"   "true"  "rebase aborts on a dirty working tree without this" "⚠️ "
  _pf_git_set "rebase.autoSquash"  "true"  "fixup commits require --autosquash manually without this" "💡"

  echo "--- Diff / Log Quality ---"
  echo ""
  _pf_git_set "diff.algorithm"    "histogram" "myers (default) produces misleading diffs on reordered code" "💡"
  _pf_git_set "diff.colorMoved"   "default"   "visually distinguishes moved code from added/deleted lines" "💡"
  _pf_git_set "branch.sort"       "-committerdate" "sorts branches by recency instead of alphabetically" "💡"

  # ── Git pager (delta) ────────────────────────────────────────────────────
  if command -v delta &>/dev/null; then
    echo ""
    echo "--- Git Pager (delta) ---"
    echo ""
    _pf_git_set "core.pager"        "delta"   "delta provides syntax-highlighted diffs and side-by-side view" "💡"
    _pf_git_set "interactive.diffFilter" "delta --color-only" "colorizes diff output in interactive add/patch" "💡"
    _pf_git_set "delta.navigate"    "true"    "enable j/k navigation in delta diff view" "💡"
    _pf_git_set "delta.line-numbers" "true"   "show line numbers in delta side-by-side view" "💡"
    _pf_git_set "delta.side-by-side" "false"  "start in inline mode (toggle with S key)" "💡"
    _pf_git_set "merge.conflictstyle" "zdiff3" "standard conflict markers hide the common ancestor" "💡"
  else
    echo "--- Merge / Conflict Style ---"
    echo ""
    _pf_git_set "merge.conflictstyle" "zdiff3" "standard conflict markers hide the common ancestor" "💡"
  fi

  echo "--- Global Gitignore ---"
  echo ""
  local current_excludes
  current_excludes=$(git config --global core.excludesFile 2>/dev/null || true)
  if [[ -n "$current_excludes" && -f "$current_excludes" ]]; then
    echo "✅ core.excludesFile = $current_excludes (already set)"
    ((kept++))
    echo ""
  else
    local default_ignore="$HOME/.gitignore"
    echo "💡 core.excludesFile not set"
    echo "   Recommended: $default_ignore"
    echo "   Reason: OS/editor artifacts need per-repo .gitignore entries without this"

    if [[ "$auto" == true ]]; then
      git config --global core.excludesFile "$default_ignore"
      echo "   → Set to $default_ignore"
      ((applied++))
    else
      _pf_ask reply "   Apply? [Y/n] " || reply=n
      echo ""
      if [[ -z "$reply" || "$reply" =~ ^[Yy]$ ]]; then
        git config --global core.excludesFile "$default_ignore"
        echo "   ✅ Set core.excludesFile = $default_ignore"
        ((applied++))
        # Create the file if it doesn't exist yet
        if [[ ! -f "$default_ignore" ]]; then
          cat > "$default_ignore" <<'GITIGNORE'
# macOS
.DS_Store
.AppleDouble
.LSOverride

# Editor / IDE
.idea/
.vscode/
*.swp
*.swo
*~

# Python
__pycache__/
*.pyc
*.pyo
.venv/
.env

# Node
node_modules/
GITIGNORE
          echo "   ✅ Created $default_ignore with common entries"
        fi
      else
        echo "   Skipped."
        ((skipped++))
      fi
    fi
    echo ""
  fi

  # ── Summary ──────────────────────────────────────────────────────────────
  unset -f _pf_git_set

  echo "--- AWS Default Profile ---"
  echo ""

  if ! command -v aws &>/dev/null; then
    echo "ℹ️  AWS CLI not installed — skipping"
    echo ""
  else
    local current_default="${AWS_PROFILE_DEFAULT:-}"
    local profiles
    profiles=$(aws configure list-profiles 2>/dev/null)

    if [[ -z "$profiles" ]]; then
      echo "ℹ️  No AWS profiles configured in ~/.aws/config — skipping"
      echo ""
    elif [[ -n "$current_default" ]]; then
      echo "✅ AWS_PROFILE_DEFAULT = $current_default (preflight config set aws.default_profile NAME)"
      ((kept++))
      echo ""
    else
      echo "⚠️  AWS_PROFILE_DEFAULT not set — preflight won't auto-set AWS_PROFILE"
      echo ""
      echo "   Available profiles:"
      echo "$profiles" | sed 's/^/     /'
      echo ""

      if [[ "$auto" == true ]]; then
        local first_profile
        first_profile=$(echo "$profiles" | head -1)
        echo "   → Setting AWS_PROFILE_DEFAULT = $first_profile"
        if _pf_config_set_cmd aws.default_profile "$first_profile" >/dev/null; then
          export AWS_PROFILE_DEFAULT="$first_profile"
        else
          echo "   Could not write it; run: preflight config set aws.default_profile $first_profile"
        fi
        ((applied++))
      else
        _pf_ask chosen_profile "   Select default profile (or Enter to skip): "
        echo ""
        if [[ -n "$chosen_profile" ]]; then
          if echo "$profiles" | grep -qxF "$chosen_profile"; then
            if _pf_config_set_cmd aws.default_profile "$chosen_profile" >/dev/null; then
              export AWS_PROFILE_DEFAULT="$chosen_profile"
              echo "   ✅ Set AWS_PROFILE_DEFAULT = $chosen_profile"
              ((applied++))
            else
              echo "   ❌ Could not write config.json — run: preflight config check"
              ((skipped++))
            fi
          else
            echo "   Profile '$chosen_profile' not found — skipped."
            ((skipped++))
          fi
        else
          echo "   Skipped."
          ((skipped++))
        fi
      fi
      echo ""
    fi
  fi

  # ── WSL SSH (1Password agent bridge) ──────────────────────────────────────
  #
  # Native Linux ssh/git get a real Unix socket (~/.1password/agent.sock) that a
  # systemd user socket relays to 1Password's Windows named pipe via npiperelay.
  # Unlike aliasing ssh.exe, scripts, hooks, scp and rsync get the agent too, and
  # the WSL ~/.ssh/config and known_hosts are honoured. See docs/wsl-ssh-setup.md.

  local _is_wsl=false
  grep -qi microsoft /proc/version 2>/dev/null && _is_wsl=true

  if [[ "$_is_wsl" == true ]]; then
    echo "--- WSL SSH (1Password agent bridge) ---"
    echo ""

    # Ask-or-auto helper: returns 0 to apply. Usage: _pf_yes
    _pf_yes() {
      [[ "$auto" == true ]] && return 0
      local r
      printf "   Apply? [Y/n] "
      # A failed read (end of input, or no terminal) is a decline, never consent.
      read -r r || { echo ""; return 1; }
      echo ""
      [[ -z "$r" || "$r" =~ ^[Yy]$ ]]
    }

    # Pinned for reproducibility; override with NPIPERELAY_VERSION. The release's
    # checksums file lives on the same host as the binary, so it only catches a
    # corrupt download. For the default version we also pin the expected hash here
    # so a tampered release asset is rejected too.
    local _npr_ver="${NPIPERELAY_VERSION:-v1.12.1}"
    local _npr_pin=""
    [[ "$_npr_ver" == "v1.12.1" ]] && _npr_pin="dbb448aea38835a65e2e10d83e2dd770a8e4dfa5f43b5669d7551a3125445ca4"
    local _npr_bin="$HOME/.local/bin/npiperelay.exe"
    local _unit_dir="$HOME/.config/systemd/user"
    local _sock="$HOME/.1password/agent.sock"
    local _bridge_ok=true

    # 0. Prerequisites: systemd in WSL. Needs a wsl --shutdown, so we can't do it.
    if [[ ! -d /run/systemd/system ]] || ! systemctl --user show-environment &>/dev/null; then
      echo "⚠️  systemd is not running in this WSL distro (needed for the agent bridge)"
      echo "   Add to /etc/wsl.conf:   [boot]  systemd=true"
      echo "   Then run in PowerShell: wsl --shutdown   and re-run: preflight configure"
      echo "   (Fallback without systemd: see docs/wsl-ssh-setup.md)"
      echo ""
      _bridge_ok=false
    fi

    # npiperelay.exe is a Windows program, so the bridge only works while WSL interop
    # is enabled (a [interop] enabled=false in /etc/wsl.conf unregisters the handler).
    # Read each handler file on its own: with several files, grep exits 2 if any is missing.
    local _interop_on=false _f
    for _f in /proc/sys/fs/binfmt_misc/WSLInterop /proc/sys/fs/binfmt_misc/WSLInterop-late; do
      [[ "$(head -1 "$_f" 2>/dev/null)" == enabled ]] && { _interop_on=true; break; }
    done
    if [[ "$_bridge_ok" == true && "$_interop_on" != true ]]; then
      echo "⚠️  WSL interop is disabled (needed to run npiperelay.exe)"
      echo "   Set in /etc/wsl.conf:   [interop]  enabled=true"
      echo "   Then run in PowerShell: wsl --shutdown   and re-run: preflight configure"
      echo ""
      _bridge_ok=false
    fi

    # 1. npiperelay (albertony fork — upstream jstarks is frozen at 0.1.0)
    if [[ "$_bridge_ok" == true ]]; then
      if [[ -x "$_npr_bin" ]]; then
        echo "✅ npiperelay.exe installed ($_npr_bin)"
        ((kept++))
      else
        echo "💡 npiperelay.exe not installed"
        echo "   Installs albertony/npiperelay $_npr_ver to $_npr_bin (checksum verified)"
        if _pf_yes; then
          local _base="https://github.com/albertony/npiperelay/releases/download/$_npr_ver"
          local _tmp _want _got
          _tmp=$(mktemp) || _tmp=""
          if [[ -n "$_tmp" ]] \
             && curl -fsSL -o "$_tmp" "$_base/npiperelay_windows_amd64.exe" \
             && _want=$(curl -fsSL "$_base/npiperelay_checksums.txt" | awk '/npiperelay_windows_amd64.exe$/ {print $1}') \
             && _got=$(sha256sum "$_tmp" | awk '{print $1}') \
             && [[ -n "$_want" && "$_want" == "$_got" ]] \
             && [[ -z "$_npr_pin" || "$_npr_pin" == "$_got" ]]; then
            if mkdir -p "$HOME/.local/bin" && install -m 0755 "$_tmp" "$_npr_bin"; then
              echo "   ✅ Installed (sha256 $_got)"
              ((applied++))
            else
              echo "   ❌ Could not install to $_npr_bin — not installed"
              _bridge_ok=false
              ((skipped++))
            fi
          else
            echo "   ❌ Download or checksum verification failed — not installed"
            _bridge_ok=false
            ((skipped++))
          fi
          [[ -n "$_tmp" ]] && rm -f "$_tmp"
        else
          echo "   Skipped."; ((skipped++)); _bridge_ok=false
        fi
        echo ""
      fi
    fi

    # 2. systemd units
    if [[ "$_bridge_ok" == true ]]; then
      local _want_sock _want_svc
      _want_sock=$'[Unit]\nDescription=1Password SSH agent bridge (Windows named pipe -> WSL unix socket)\n\n[Socket]\nListenStream=%h/.1password/agent.sock\nSocketMode=0600\nAccept=yes\nRemoveOnStop=yes\n\n[Install]\nWantedBy=sockets.target\n'
      # -ei: exit when the ssh client closes (no leaked relays). -s: send a 0-byte
      # message at EOF. Never -p: 1Password serves one pipe instance, so polling
      # loops forever and orphans a process per SSH operation.
      _want_svc=$'[Unit]\nDescription=1Password SSH agent bridge connection %i\nRequires=1password-agent.socket\n\n[Service]\nType=simple\nExecStart=%h/.local/bin/npiperelay.exe -ei -s //./pipe/openssh-ssh-agent\nStandardInput=socket\nStandardOutput=socket\nStandardError=journal\n'
      if [[ "$(cat "$_unit_dir/1password-agent.socket" 2>/dev/null)" == "${_want_sock%$'\n'}" \
         && "$(cat "$_unit_dir/1password-agent@.service" 2>/dev/null)" == "${_want_svc%$'\n'}" ]]; then
        echo "✅ systemd units present (1password-agent.socket, 1password-agent@.service)"
        ((kept++))
      else
        echo "💡 systemd units missing or different"
        echo "   Writes 1password-agent.socket and 1password-agent@.service to $_unit_dir"
        if _pf_yes; then
          mkdir -p "$_unit_dir"
          printf '%s' "$_want_sock" > "$_unit_dir/1password-agent.socket"
          printf '%s' "$_want_svc"  > "$_unit_dir/1password-agent@.service"
          systemctl --user daemon-reload
          # daemon-reload does not change a running listener, so apply the new unit now.
          systemctl --user is-active --quiet 1password-agent.socket \
            && systemctl --user restart 1password-agent.socket
          echo "   ✅ Written"
          ((applied++))
        else
          echo "   Skipped."; ((skipped++)); _bridge_ok=false
        fi
        echo ""
      fi
    fi

    # 3. enable the socket
    if [[ "$_bridge_ok" == true ]]; then
      if systemctl --user is-active --quiet 1password-agent.socket \
         && systemctl --user is-enabled --quiet 1password-agent.socket; then
        echo "✅ 1password-agent.socket active and enabled"
        ((kept++))
      else
        echo "💡 1password-agent.socket not active/enabled"
        if _pf_yes; then
          mkdir -p "$HOME/.1password" && chmod 700 "$HOME/.1password"
          if systemctl --user enable --now 1password-agent.socket 2>/dev/null; then
            echo "   ✅ Enabled and started"
            ((applied++))
          else
            echo "   ❌ systemctl enable failed — check: systemctl --user status 1password-agent.socket"
            _bridge_ok=false
            ((skipped++))
          fi
        else
          # An active but not enabled socket works now and vanishes on restart, so it
          # must not count as a bridge worth migrating to.
          echo "   Skipped. The bridge stays unverified until the socket is enabled."
          ((skipped++)); _bridge_ok=false
        fi
        echo ""
      fi
    fi

    # Verify the bridge before touching shell/ssh config or removing the old
    # fallback: only a bridge that returns keys may replace what works today.
    # (Listing keys needs no approval; signing does.)
    local _bridge_verified=false _n=0
    if [[ "$_bridge_ok" == true && -S "$_sock" ]]; then
      _n=$(SSH_AUTH_SOCK="$_sock" timeout 15 /usr/bin/ssh-add -l 2>/dev/null | grep -c 'SHA256:' || true)
      [[ "$_n" -gt 0 ]] && _bridge_verified=true
    fi
    if [[ "$_bridge_verified" != true ]]; then
      echo "ℹ️  Bridge not verified yet, so ~/.profile, and ~/.ssh/config are left alone."
      echo "   Fix the problem above, or unlock 1Password with 'Use the SSH agent' on, then re-run: preflight configure"
      echo ""
    fi

    # 4. SSH_AUTH_SOCK in ~/.profile (environment, not interactive config: .bashrc
    #    is skipped by hooks, cron and scripts, which then get no agent)
    if [[ "$_bridge_verified" != true ]]; then
      :  # skipped: see the note above
    elif grep -qE '^[[:space:]]*(export[[:space:]]+)?SSH_AUTH_SOCK=.*\.1password/agent\.sock' "$HOME/.profile" 2>/dev/null; then
      echo "✅ ~/.profile exports SSH_AUTH_SOCK"
      ((kept++))
    else
      echo "💡 ~/.profile does not export SSH_AUTH_SOCK"
      if _pf_yes; then
        printf '\n# 1Password SSH agent (bridged from Windows via systemd socket + npiperelay)\nexport SSH_AUTH_SOCK="$HOME/.1password/agent.sock"\n' >> "$HOME/.profile"
        echo "   ✅ Added to ~/.profile (takes effect on next login shell)"
        ((applied++))
      else
        echo "   Skipped."; ((skipped++))
      fi
      echo ""
    fi

    # 5. ~/.ssh/config IdentityAgent
    local _linux_ssh_conf="$HOME/.ssh/config"
    # True when the file has an active IdentityAgent for the 1Password socket that
    # applies to every host: before any Host/Match line, or inside `Host *`. A comment
    # or a host-specific block does not count.
    _pf_ssh_global_agent() {
      awk '
        BEGIN { g = 1 }
        /^[[:space:]]*#/ { next }
        tolower($1) == "host"  { g = (NF == 2 && $2 == "*"); next }
        tolower($1) == "match" { g = 0; next }
        g && tolower($0) ~ /^[[:space:]]*identityagent[[:space:]=]/ && $0 ~ /1password\/agent\.sock/ { found = 1 }
        END { exit !found }
      ' "$1" 2>/dev/null
    }
    if [[ "$_bridge_verified" != true ]]; then
      :  # skipped: see the note above
    elif _pf_ssh_global_agent "$_linux_ssh_conf"; then
      echo "✅ ~/.ssh/config has 1Password IdentityAgent"
      ((kept++))
    else
      echo "💡 ~/.ssh/config missing IdentityAgent entry (Host * IdentityAgent ~/.1password/agent.sock)"
      if _pf_yes; then
        mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
        printf '\nHost *\n  IdentityAgent "~/.1password/agent.sock"\n' >> "$_linux_ssh_conf"
        chmod 600 "$_linux_ssh_conf"
        echo "   ✅ Written to ~/.ssh/config"
        ((applied++))
      else
        echo "   Skipped."; ((skipped++))
      fi
      echo ""
    fi

    # 6. GitHub host keys. Native ssh reads the WSL known_hosts, not Windows's, so
    #    the first connection fails host-key verification. Take the keys from
    #    GitHub's published API rather than trusting whatever answers a keyscan.
    if ssh-keygen -F github.com -f "$HOME/.ssh/known_hosts" &>/dev/null; then
      echo "✅ github.com in ~/.ssh/known_hosts"
      ((kept++))
    elif command -v gh &>/dev/null; then
      echo "💡 github.com not in ~/.ssh/known_hosts (native ssh would fail host-key verification)"
      echo "   Adds GitHub's published host keys (from 'gh api meta')"
      if _pf_yes; then
        local _hk
        if _hk=$(gh api meta --jq '.ssh_keys[]' 2>/dev/null) && [[ -n "$_hk" ]]; then
          mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
          printf '%s\n' "$_hk" | sed 's/^/github.com /' >> "$HOME/.ssh/known_hosts"
          chmod 600 "$HOME/.ssh/known_hosts"
          echo "   ✅ Added"
          ((applied++))
        else
          echo "   ❌ 'gh api meta' failed (is gh authenticated?) — skipped"
          ((skipped++))
        fi
      else
        echo "   Skipped."; ((skipped++))
      fi
      echo ""
    fi

    # 8. 1Password CLI: prefer the Windows op.exe (desktop-app approval, no WSL
    #    install). Windows PATH is often not appended, so use the resolver.
    unset OP_BIN
    if declare -F _op_resolve_bin &>/dev/null && _op_resolve_bin && [[ "$OP_BIN" == *op.exe ]]; then
      echo "✅ 1Password CLI: $OP_BIN"
      ((kept++))
    elif [[ -n "${OP_BIN:-}" ]]; then
      echo "ℹ️  1Password CLI: native $OP_BIN (op.exe preferred: winget install AgileBits.1Password.CLI)"
    else
      echo "💡 1Password CLI not found. In PowerShell: winget install AgileBits.1Password.CLI"
      echo "   Then enable Settings → Developer → 'Integrate with 1Password CLI'"
    fi
    echo ""

    # 9. Summary
    if [[ "$_bridge_verified" == true ]]; then
      echo "✅ Agent bridge working: $_n key(s) via $_sock"
      echo "   Signing needs an approval click in 1Password on Windows: ssh -T git@github.com"
      echo ""
    fi

    unset -f _pf_yes _pf_ssh_global_agent
  fi # _is_wsl

  printf "  \033[38;2;${OWL_SUB:-120;130;150}m%s\033[0m\n" "$(printf '%0.s-' {1..33})"
  echo "   Applied: $applied   Kept: $kept   Skipped: $skipped"
  if [[ $applied -gt 0 ]]; then
    echo ""
    echo "   Git config changes take effect immediately."
    echo "   Shell config changes (bashrc, ssh/config) require a shell reload:"
    echo "     source ~/.bashrc   (or open a new terminal)"
    echo "   Review git changes: git config --global --list"
  fi
  printf "  \033[38;2;${OWL_SUB:-120;130;150}m%s\033[0m\n" "$(printf '%0.s-' {1..33})"
}
