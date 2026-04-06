# Sizzle — Developer Environment Scripts

A modular collection of shell utilities for development workflows. Drop it in `~/.dev`, source it from `.bashrc`, and get fuzzy-powered shortcuts for AWS, Docker, Git, 1Password, and project navigation.

## Getting Started

```bash
# 1. Clone to home directory
git clone git@github.com:shawnoster/sizzle.git ~/.dev

# 2. Add to your .bashrc (near the end)
echo '[[ -f "$HOME/.dev/init.sh" ]] && source "$HOME/.dev/init.sh"' >> ~/.bashrc

# 3. Reload your shell
source ~/.bashrc

# 4. Configure your accounts
cp ~/.dev/config/accounts.sh.template ~/.dev/config/accounts.sh
cp ~/.dev/lib/1password.sh.template ~/.dev/lib/1password.sh
# Edit both files with your settings

# 5. Run preflight to start your session
preflight    # Signs in to 1Password, loads secrets, refreshes AWS, checks environment
```

Use `dev-commands` to see everything available, or `dev-help` for the full menu.

## Manual Installation

```bash
cp -r .dev ~/
echo '[[ -f "$HOME/.dev/init.sh" ]] && source "$HOME/.dev/init.sh"' >> ~/.bashrc
source ~/.bashrc
```

## Structure

```
~/.dev/
├── init.sh              # Main loader
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

### Git (`lib/git.sh`)

| Command | Description |
|---------|-------------|
| `gco [branch]` | Fuzzy checkout branch |
| `glog` | Interactive git log with preview |
| `gstash [ref]` | Fuzzy apply stash |
| `gpr` | Create PR via GitHub CLI |
| `gwip [msg]` | Quick WIP commit |
| `gunwip` | Undo last WIP commit |
| `gclean [main]` | Remove merged branches |
| `gsync [main]` | Sync fork with upstream |

**Aliases:** `gs`, `ga`, `gc`, `gp`, `gpl`, `gd`, `gds`

### Docker (`lib/docker.sh`)

| Command | Description |
|---------|-------------|
| `dex [container] [shell]` | Exec into container (default shell: /bin/sh) |
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

Edit `~/.dev/config/accounts.sh` to customize:

- `OP_ACCOUNT` - 1Password account shorthand
- `PROJ_DIRS` - Directories for `proj` command
- `AWS_PROFILE` - Default AWS profile

## Adding Custom Scripts

Files in `~/.dev/lib/` are automatically sourced. Create `~/.dev/lib/custom.sh` for local additions.

## Dependencies

- **fzf** - Fuzzy finder (required for interactive selection)
- **jq** - JSON processor (for npm/package.json parsing and AWS output)
- **op** - 1Password CLI
- **aws** - AWS CLI v2
- **gh** - GitHub CLI (optional, for `gpr` and `preflight -u`)
