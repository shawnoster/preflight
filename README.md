# Preflight — Developer Environment Scripts

A modular collection of shell utilities for development workflows. Drop it in `~/.preflight`, source it from `.bashrc`, and get fuzzy-powered shortcuts for AWS, Docker, Git, 1Password, and project navigation.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/shawnoster/preflight/main/install.sh | bash
```

The installer:
- Clones the repo to `~/.preflight` (override with `PREFLIGHT_DIR=/your/path`)
- Adds a source line to your shell rc file (`.bashrc`, `.zshrc`, or `config.fish`)
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
PREFLIGHT_DIR=~/.config/preflight curl -fsSL .../install.sh | bash

# Skip shell profile modification (add the source line yourself)
NO_MODIFY_PROFILE=1 curl -fsSL .../install.sh | bash
```

## Updating

```bash
preflight update
```

Pulls the latest changes from the upstream repo, shows incoming commits, and warns if any tracked files have local modifications. Gitignored files (`config/accounts.sh`, `lib/1password.sh`) are never touched.

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
│   ├── preflight.sh     # Session startup + environment health check
│   └── project.sh       # Build tool wrappers
└── config/
    └── accounts.sh      # Non-secret configuration
```

## Available Commands

### Preflight (`lib/preflight.sh`)

| Command | Description |
|---------|-------------|
| `preflight` | Session startup: sign in to 1Password, load secrets, refresh AWS, run health checks |
| `preflight -u` | Same + compare installed tools against latest stable versions |
| `preflight update` | Pull latest changes from upstream repo |
| `preflight uninstall` | Remove preflight and undo shell profile changes |

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

**Initial setup:**
```bash
op account add --shorthand guild_education
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
awsp guild-dev    # switch profile directly
bake test         # run make target directly
```

Commands that require interactive selection will exit with a usage message when called without a TTY and no arguments.

## Configuration

Edit `~/.preflight/config/accounts.sh` to customize:

- `OP_ACCOUNT` - 1Password account shorthand
- `PROJ_DIRS` - Directories for `proj` command
- `AWS_PROFILE` - Default AWS profile

## Adding Custom Scripts

Files in `~/.preflight/lib/` are automatically sourced. Create `~/.preflight/lib/custom.sh` for local additions.

## Dependencies

- **fzf** - Fuzzy finder (required for interactive selection)
- **jq** - JSON processor (for npm/package.json parsing and AWS output)
- **op** - 1Password CLI
- **aws** - AWS CLI v2
- **gh** - GitHub CLI (optional, for `gpr` and `preflight -u`)
