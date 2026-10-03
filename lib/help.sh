#!/usr/bin/env bash
# ~/.preflight/lib/help.sh - Central help system

dev-help() {
  cat <<'EOF'
Developer Environment Utilities
================================

Module Help Commands:
---------------------

aws-help
  AWS CLI utilities: profile switching, SSO login, identity.
  Commands: awsp, aws-whoami, aws-login

docker-help
  Docker utilities: container management and cleanup.
  Commands: dex, dlogs, dstop, drm, drmi, dprune, dprune-all

git-help
  Git shortcuts: branch management and workflows.
  Commands: gco, glog, gstash, gpr, gwip, gunwip, gclean, gsync

op-help
  1Password CLI utilities: secrets management.
  Commands: op-status, op-signin, op-env (load, clear, add, list, rm, use)

pg-help
  PostgreSQL cluster control for manually-started clusters.
  Commands: pg-up, pg-down

project-help
  Project navigation and build tool runners.
  Commands: bake, yak, poet, proj, serve

Session Startup:
----------------

preflight                # Sign in, load secrets, verify environment
  preflight -v             # Same with verbose output
  preflight -u             # Same + check for tool updates
  preflight update         # Pull latest changes from upstream
  preflight uninstall      # Remove preflight and undo shell profile changes
  preflight help           # Usage for preflight and its subcommands
  preflight configure      # Apply recommended git/SSH settings
  preflight configure --yes # Apply all without prompting
  dev-commands             # List all available commands

Quick Reference:
----------------

Load secrets:
  op-env load [set...]     # Load secrets from 1Password (active sets, or just the named ones)
  op-env add               # Add a VAR -> op:// ref to a set (guild, personal, ...);
                           # sets are the only list of secrets op-env load uses;
                           # pass a 4th arg for a ref in another 1Password account
  op-env use               # Choose which sets load

Switch AWS profile:
  awsp [profile]           # Interactive profile switcher or direct

Docker shortcuts:
  dex [container] [shell]  # Exec into container
  dlogs [container]        # Tail container logs

Postgres:
  pg-up [version] [cluster]   # Start a cluster
  pg-down [version] [cluster] # Stop a cluster

Git shortcuts:
  gco [branch]             # Checkout branch
  gwip [msg]               # Quick WIP commit

Build tools:
  bake [target]            # Run Makefile targets
  yak [script]             # Run npm scripts
  poet [script]            # Run poetry scripts

Configuration:
--------------

Location: ~/.preflight/
Config:   $PREFLIGHT_CONFIG_DIR/config.json  (preflight config help)
Modules:  ~/.preflight/lib/*.sh

Environment Variables:
  OP_ACCOUNT          - 1Password account shorthand
  AWS_PROFILE_DEFAULT - Default AWS profile (preflight config set aws.default_profile NAME)
  AWS_PROFILE         - Active AWS profile (set at runtime by preflight/awsp)
  PROJ_DIRS           - Project directories for 'proj' command
  PREFLIGHT_DIR       - Install location (default: ~/.preflight)
  PREFLIGHT_BRANCH    - Branch used by 'preflight update' (default: main)
  PREFLIGHT_VERBOSE   - Set to "1" for verbose loading messages

Getting Started:
----------------

1. Configure your accounts:
   preflight config set op.account my-team.1password.com

2. Run preflight to start your session:
   preflight

3. Explore individual modules:
   aws-help / docker-help / git-help / op-help / pg-help / project-help

EOF
}

alias devhelp='dev-help'

# dev-commands: flat searchable list of all commands
dev-commands() {
  cat <<'EOF'
aws-help             Show AWS command help
aws-login [profile]  SSO login (fuzzy-selects if no profile given)
aws-whoami           Show current AWS profile, region, and identity
awsp [profile]       Switch AWS profile
bake [target]        Run Makefile target
dev-commands         This list
dev-help             Central help menu
dex [container] [shell] Exec into running container
dlogs [container]    Tail container logs
dprune               Safe Docker cleanup
dprune-all           Aggressive Docker cleanup (with volumes)
drm [container...]   Remove containers
drmi [image...]      Remove images
dstop [container...] Stop containers
gclean [main]        Remove merged branches locally
gco [branch]         Checkout branch
glog                 Interactive git log with preview
gpr                  Create pull request via GitHub CLI
gstash [ref]         Pop a stash (use --apply to keep in stash list)
gsync [main]         Sync fork with upstream
gunwip               Undo last WIP commit
gwip [msg]           Quick work-in-progress commit
op-env [cmd]         1Password env sets: load/clear secrets, add/list/rm/use
op-env clear [set...] Clear all loaded secrets (or only the named sets)
op-help              Show 1Password command help
op-env load [set...] Load secrets from 1Password into env vars
op-signin [account]  Sign in to 1Password
op-status            Check 1Password sign-in status
pg-down [version] [cluster] Stop a PostgreSQL cluster
pg-help              Show PostgreSQL command help
pg-up [version] [cluster]   Start a PostgreSQL cluster
poet [script]        Run poetry script
preflight            Session startup: sign in, load secrets, verify env
preflight -v         Same with verbose section output
preflight -u         Same + check for tool updates
preflight update     Pull latest changes from upstream repo
preflight uninstall  Remove preflight and undo shell profile changes
preflight help       Usage for preflight
preflight configure  Interactively apply recommended git/SSH settings
preflight configure --yes  Apply all recommended settings without prompting
proj [directory]     Jump to project directory
serve [port]         Quick Python HTTP server (default: 8000)
yak [script]         Run npm script
EOF
}
