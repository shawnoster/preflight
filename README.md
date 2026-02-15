# Developer Environment Scripts

A modular collection of shell utilities for development workflows.

## Installation

```bash
# Copy to home directory
cp -r .dev ~/

# Add to your .bashrc (near the end)
echo '[[ -f "$HOME/.dev/init.sh" ]] && source "$HOME/.dev/init.sh"' >> ~/.bashrc

# Reload
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
│   └── project.sh       # Build tool wrappers
└── config/
    └── accounts.sh      # Non-secret configuration
```

## Available Commands

### 1Password (`lib/1password.sh`)

| Command | Description |
|---------|-------------|
| `op-status` | Check if signed in to 1Password |
| `op-signin [account]` | Sign in to 1Password (prompts for password) |
| `set-secure-env` | Load secrets into environment variables |
| `clear-secure-env` | Clear sensitive environment variables |

**Initial setup:**
```bash
op account add --shorthand guild_education
```

### AWS (`lib/aws.sh`)

| Command | Description |
|---------|-------------|
| `awsp` | Fuzzy-select and switch AWS profile |
| `aws-whoami` | Show current profile, region, and identity |
| `aws-login [profile]` | SSO login (fuzzy-selects if no profile given) |

### Project Tools (`lib/project.sh`)

| Command | Description |
|---------|-------------|
| `bake` | Fuzzy-select Makefile target |
| `yak` | Fuzzy-select npm script from package.json |
| `poet` | Fuzzy-select poetry script |
| `proj` | Jump to project directory |
| `serve [port]` | Quick Python HTTP server (default: 8000) |

### Git (`lib/git.sh`)

| Command | Description |
|---------|-------------|
| `gco` | Fuzzy checkout branch |
| `glog` | Interactive git log with preview |
| `gstash` | Fuzzy apply stash |
| `gpr` | Create PR via GitHub CLI |
| `gwip [msg]` | Quick WIP commit |
| `gunwip` | Undo last WIP commit |
| `gclean [main]` | Remove merged branches |
| `gsync [main]` | Sync fork with upstream |

**Aliases:** `gs`, `ga`, `gc`, `gp`, `gpl`, `gd`, `gds`

### Docker (`lib/docker.sh`)

| Command | Description |
|---------|-------------|
| `dex [shell]` | Exec into container (default: /bin/sh) |
| `dlogs` | Tail container logs |
| `dstop` | Fuzzy-stop containers |
| `drm` | Fuzzy-remove containers |
| `drmi` | Fuzzy-remove images |
| `dprune` | Clean unused resources |
| `dprune-all` | Aggressive cleanup (with volumes) |

**Aliases:** `dps`, `dpsa`, `di`, `dcp`, `dcup`, `dcdown`, `dclogs`

## Configuration

Edit `~/.dev/config/accounts.sh` to customize:

- `OP_ACCOUNT` - 1Password account shorthand
- `PROJ_DIRS` - Directories for `proj` command
- `GIT_MAIN_BRANCH` - Default main branch name

## Adding Custom Scripts

Create new files in `~/.dev/lib/` - they're automatically sourced.

Example `~/.dev/lib/custom.sh`:
```bash
#!/usr/bin/env bash
# My custom utilities

my-function() {
  echo "Hello from custom script!"
}
```

## Dependencies

- **fzf** - Fuzzy finder (required for most commands)
- **jq** - JSON processor (for npm/package.json parsing)
- **op** - 1Password CLI
- **aws** - AWS CLI
- **gh** - GitHub CLI (optional, for `gpr`)
