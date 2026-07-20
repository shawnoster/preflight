# Preflight — Developer Environment Scripts

A modular collection of shell utilities for development workflows. Drop it in `~/.preflight`, source it from `.bashrc`, and get fuzzy-powered shortcuts for AWS, Docker, Git, 1Password, and project navigation — plus an owl-themed MOTD and Oh My Posh color switcher.

> **PowerShell users**: a Windows-native sibling lives in [`pwsh/`](pwsh/README.md) and is installed separately via `pwsh/install.ps1`. Phase 1 ships the 1Password layer (`Get-OpStatus`, `Connect-Op`, `Import-OpEnv`, `Clear-OpEnv`, `New-OpItem`, `Import-OpCsv`); more layers follow.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/shawnoster/preflight/main/install.sh | bash
```

The installer:
- Clones the repo to `~/.preflight` (override with `PREFLIGHT_DIR=/your/path`)
- Adds a source line to your shell rc file (`.bashrc` or `.zshrc`), with the correct syntax for your shell
- Creates `config/accounts.sh` and `lib/1password.sh` from their templates

After installing:

```bash
# 1. Configure your accounts
vim ~/.preflight/config/accounts.sh   # set OP_ACCOUNT, PROJ_DIRS, etc.
vim ~/.preflight/lib/1password.sh     # configure your 1Password secrets

# 2. Reload your shell
source ~/.bashrc   # or open a new terminal

# 3. Run preflight to start your session
preflight
```

**Options:**
```bash
# Install to a custom location
PREFLIGHT_DIR=~/.config/preflight curl -fsSL https://raw.githubusercontent.com/shawnoster/preflight/main/install.sh | bash

# Skip shell profile modification (add the source line yourself)
NO_MODIFY_PROFILE=1 curl -fsSL https://raw.githubusercontent.com/shawnoster/preflight/main/install.sh | bash
```

## Updating

```bash
preflight update
```

Pulls the latest changes from the upstream repo, shows incoming commits, and warns if any tracked files have local modifications. Gitignored files (`config/accounts.sh`, `config/owl.sh`, `lib/1password.sh`) are never touched.

After updating, reload your shell:

```bash
source ~/.bashrc   # or open a new terminal
```

## Uninstalling

```bash
preflight uninstall
```

Removes `~/.preflight` and the source line from your shell profile(s). Prompts for confirmation first.

## Manual Installation

If you prefer not to pipe to bash:

```bash
git clone https://github.com/shawnoster/preflight.git ~/.preflight
echo '[[ -f "$HOME/.preflight/init.sh" ]] && source "$HOME/.preflight/init.sh"' >> ~/.bashrc
source ~/.bashrc
```

## Structure

```
~/.preflight/
├── init.sh              # Main loader (also adds bin/ to PATH)
├── bin/                 # Distributed scripts (auto on PATH)
│   ├── light-remind     # Visual reminder (snapshot/flash/restore)
│   ├── nanoleaf-streak  # Per-panel streak via Nanoleaf direct API
│   └── nanoleaf-kitt    # KITT-style scanner with comet trail
├── lib/
│   ├── 1password.sh     # 1Password CLI utilities
│   ├── aws.sh           # AWS profile management
│   ├── docker.sh        # Docker utilities
│   ├── git.sh           # Git shortcuts
│   ├── help.sh          # Unified help system (dev-help / devhelp)
│   ├── owl.sh           # OOO theme engine + MOTD splash
│   ├── preflight.sh     # Session startup + environment health check
│   └── project.sh       # Build tool wrappers
├── config/
│   ├── accounts.sh      # Non-secret configuration (gitignored, from template)
│   └── owl.sh           # Owl/OMP config — OWL_OMP_CONFIG path (gitignored, from template)
├── pwsh/                # PowerShell sibling — see pwsh/README.md
│   ├── Preflight.psd1   # Module manifest
│   ├── Preflight.psm1   # Entry — dot-sources lib/*.ps1
│   ├── install.ps1      # Windows installer (mirrors install.sh)
│   ├── lib/             # PowerShell helpers (1password.ps1, …)
│   └── config/          # accounts.ps1 (gitignored, from template)
└── docs/
    └── wsl-ssh-setup.md # WSL + 1Password SSH setup guide
```

## Available Commands

### Preflight (`lib/preflight.sh`)

| Command | Description |
|---------|-------------|
| `preflight` | Session startup: sign in to 1Password, load secrets, refresh AWS, run health checks |
| `preflight -u` | Same + compare installed tools against latest stable versions |
| `preflight update` | Pull latest changes from upstream repo |
| `preflight uninstall` | Remove preflight and undo shell profile changes |
| `preflight configure` | Interactively apply recommended settings (git globals, WSL SSH via 1Password, etc.) |
| `preflight configure --yes` | Apply all recommended settings without prompting |

### Help (`lib/help.sh`)

| Command | Description |
|---------|-------------|
| `dev-help` / `devhelp` | Unified help menu for all modules |
| `dev-commands` | Flat searchable list of all commands |

### 1Password (`lib/1password.sh`)

| Command | Description |
|---------|-------------|
| `op-status` | Check if signed in to 1Password |
| `op-signin [account]` | Sign in to 1Password |
| `op-load-env` | Load all secrets from 1Password into env vars |
| `op-clear-env` | Clear all sensitive environment variables |

**Secrets loaded by `op-load-env`:** `ANTHROPIC_API_KEY`, `ATLASSIAN_API_TOKEN`, `GITHUB_TOKEN`, `NPM_TOKEN`, `DATADOG_API_KEY`, `SONAR_TOKEN`, and more.

**Auth model:** the helpers resolve an `op` binary and **prefer the Windows `op.exe` under WSL**, so secret reads are authorized by the Windows 1Password desktop app (Windows Hello / desktop unlock) — no password typed in WSL. On native Linux/macOS they fall back to the platform `op` and the manual session-token sign-in. See [docs/wsl-1password-cli.md](./docs/wsl-1password-cli.md) for the full WSL setup.

**GitHub auth:** owned by the `gh` CLI, which stores its own token in `~/.config/gh/hosts.yml`. That stored token is what `gh` (and tools that shell out to it) use — independent of whether `op-load-env` also exports a `GITHUB_TOKEN` for other tooling. Claude Code's `github` MCP server (`api.githubcopilot.com/mcp`) can't do OAuth, so it carries the `gh` token in an `Authorization` header baked into `~/.claude.json`. When the `gh` token rotates (`gh auth login`/`refresh`), re-stamp that header:

```bash
claude mcp remove github -s local
claude mcp add --transport http github \
  https://api.githubcopilot.com/mcp \
  --header "Authorization: Bearer $(gh auth token)"
```

**Initial setup:**
```bash
# WSL + Windows desktop app (recommended): enable the desktop app's
# Settings → Developer → "Integrate with 1Password CLI", install op.exe
# (winget install AgileBits.1Password.CLI), and set OP_ACCOUNT to your
# sign-in address (e.g. my-team.1password.com) in config/accounts.sh.

# Native Linux/macOS: add the account by shorthand instead.
op account add --shorthand my-team
```

### AWS (`lib/aws.sh`)

| Command | Description |
|---------|-------------|
| `awsp [profile]` | Switch AWS profile (fuzzy-select if no arg) |
| `aws-whoami` | Show current profile, region, and identity |
| `aws-login [profile]` | SSO login (fuzzy-selects if no profile given) |

### Project Tools (`lib/project.sh`)

| Command | Description |
|---------|-------------|
| `bake [target]` | Fuzzy-select Makefile target |
| `yak [script]` | Fuzzy-select npm script from package.json |
| `poet [script]` | Fuzzy-select poetry script |
| `proj [directory]` | Jump to project directory |
| `serve [port]` | Quick Python HTTP server (default: 8000) |

### Office Light Reminders (`bin/`)

Visual reminders driven through Home Assistant + Nanoleaf Light Panels.
`light-remind` shells out to a local `ha` CLI helper for HA REST API
calls (the helper reads its bearer token from `~/.claude.json`'s MCP
server config — populated when you run `claude mcp add ha …`). The
`nanoleaf-*` scripts read `NANOLEAF_TOKEN` from the environment first
(set by `op-load-env`), falling back to `~/.config/nanoleaf-direct/env`
(populated by `op-load-env` for cron) and finally
`~/.config/nanoleaf-direct/token.json` (offline backup).

| Command | Description |
|---------|-------------|
| `light-remind` | Snapshot panels → apply tone → restore. Default tone: `heads-up` (amber, 3s). Tones: `urgent`, `heads-up`, `note`, `done`, `streak`, `streak-pan`, `kitt-pan` |
| `nanoleaf-streak` | Direct Nanoleaf API: per-panel rolling color (`l2r`/`r2l`/`in`/`out`) for ~1.5s. Fire-and-forget |
| `nanoleaf-kitt` | Direct Nanoleaf API: KITT scanner — bouncing dot with comet trail. Loops until panel state is changed externally |

Examples:
```bash
light-remind                              # default heads-up amber
light-remind --tone urgent                # red flash
light-remind --tone kitt-pan              # 5s of KITT then restore
nanoleaf-kitt --color blue --period 1.4   # blue scanner, faster
nanoleaf-streak --direction in --color red  # red converging from ends
```

See the `nanoleaf-direct` project notebook for the auth/layout/effects
references.

### Owl Theme + MOTD (`lib/owl.sh`)

OOO (Obtusely Optimistic Owl) — a shell MOTD that appears once per interactive session, and a theme switcher that patches your Oh My Posh prompt palette.

| Command | Description |
|---------|-------------|
| `owl-theme` | List all available themes with a color preview |
| `owl-theme <name>` | Switch to a named theme — persists across sessions |
| `owl-theme --current` | Print the active theme name |

**Available themes:** `catppuccin`, `honeypot`, `twilight`, `moonlit`, `autumn`, `rose`, `moss`, `parchment`

**Oh My Posh integration is optional.** Set `OWL_OMP_CONFIG` in `~/.preflight/config/owl.sh` to the path of your OMP JSON config. If unset or the file doesn't exist, `owl-theme` still switches splash colors — it just won't touch your prompt.

```bash
# After installing, edit config/owl.sh to point at your OMP config:
vim ~/.preflight/config/owl.sh   # set OWL_OMP_CONFIG="$HOME/your-theme.omp.json"

# Then switch themes live:
owl-theme moonlit
```

### Git (`lib/git.sh`)

| Command | Description |
|---------|-------------|
| `gco [branch]` | Fuzzy checkout branch |
| `glog` | Interactive git log with preview |
| `gstash [ref]` | Fuzzy pop stash (use --apply to keep in stash list) |
| `gpr` | Create PR via GitHub CLI |
| `gwip [msg]` | Quick WIP commit |
| `gunwip` | Undo last WIP commit |
| `gclean [main]` | Remove merged branches |
| `gsync [main]` | Sync fork with upstream |

**Aliases:** `gs`, `ga`, `gc`, `gp`, `gpl`, `gd`, `gds`

### Docker (`lib/docker.sh`)

| Command | Description |
|---------|-------------|
| `dex [container] [shell]` | Exec into container (tries bash, falls back to sh) |
| `dlogs [container]` | Tail container logs |
| `dstop [container...]` | Stop containers |
| `drm [container...]` | Remove containers |
| `drmi [image...]` | Remove images |
| `dprune` | Clean unused resources |
| `dprune-all` | Aggressive cleanup (with volumes) |

**Aliases:** `dps`, `dpsa`, `di`, `dcp`, `dcup`, `dcdown`, `dclogs`

## Non-Interactive Use

All fuzzy-finder commands accept direct arguments, making them safe to call from scripts or AI assistants without a TTY:

```bash
gco main          # checkout directly, no fzf
awsp my-dev-profile    # switch profile directly
bake test         # run make target directly
```

Commands that require interactive selection will exit with a usage message when called without a TTY and no arguments.

## Configuration

Edit `~/.preflight/config/accounts.sh` to customize:

- `OP_ACCOUNT` - 1Password account reference: sign-in address (e.g. `my-team.1password.com`) for WSL desktop integration, or the `op account add` shorthand for native `op`
- `PROJ_DIRS` - Directories for `proj` command
- `AWS_PROFILE_DEFAULT` - Default AWS profile (`preflight` sets `AWS_PROFILE` from this at startup)
- `PREFLIGHT_DIR` - Install location (default: `~/.preflight`)
- `PREFLIGHT_BRANCH` - Branch used by `preflight update` (default: `main`)

Edit `~/.preflight/config/owl.sh` to customize:

- `OWL_OMP_CONFIG` - Path to your Oh My Posh JSON config (leave empty to disable OMP integration)
- `OWL_THEME_DIR` - Where theme state is persisted (default: `$PREFLIGHT_DIR/state/owl`)

## Adding Custom Scripts

Files in `~/.preflight/lib/` are automatically sourced. Create `~/.preflight/lib/custom.sh` for local additions.

## Dependencies

- **fzf** - Fuzzy finder (required for interactive selection)
- **jq** - JSON processor (for npm/package.json parsing and AWS output)
- **op** - 1Password CLI (on WSL, the Windows `op.exe` is preferred — see [docs/wsl-1password-cli.md](./docs/wsl-1password-cli.md))
- **aws** - AWS CLI v2
- **gh** - GitHub CLI (optional, for `gpr` and `preflight -u`)
