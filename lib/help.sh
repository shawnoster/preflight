#!/usr/bin/env bash
# ~/.dev/lib/help.sh - Central help system

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
  Commands: op-status, op-signin, op-load-env, op-clear-env

project-help
  Project navigation and build tool runners.
  Commands: bake, yak, poet, proj, serve

Session Startup:
----------------

preflight                # Sign in, load secrets, verify environment
preflight -u             # Same + check for tool updates
dev-commands             # List all available commands

Quick Reference:
----------------

Load secrets:
  op-load-env              # Load secrets from 1Password

Switch AWS profile:
  awsp [profile]           # Interactive profile switcher or direct

Docker shortcuts:
  dex [container] [shell]  # Exec into container
  dlogs [container]        # Tail container logs

Git shortcuts:
  gco [branch]             # Checkout branch
  gwip [msg]               # Quick WIP commit

Build tools:
  bake [target]            # Run Makefile targets
  yak [script]             # Run npm scripts
  poet [script]            # Run poetry scripts

Configuration:
--------------

Location: ~/.dev/
Config:   ~/.dev/config/accounts.sh
Modules:  ~/.dev/lib/*.sh

Environment Variables:
  OP_ACCOUNT    - 1Password account shorthand
  AWS_PROFILE   - Default AWS profile
  PROJ_DIRS     - Project directories for 'proj' command
  DEV_VERBOSE   - Set to "1" for verbose loading messages

Getting Started:
----------------

1. Configure your accounts:
   Edit ~/.dev/config/accounts.sh

2. Run preflight to start your session:
   preflight

3. Explore individual modules:
   aws-help / docker-help / git-help / op-help / project-help

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
gstash [ref]         Apply a stash
gsync [main]         Sync fork with upstream
gunwip               Undo last WIP commit
gwip [msg]           Quick work-in-progress commit
op-clear-env         Clear all sensitive environment variables
op-help              Show 1Password command help
op-load-env          Load secrets from 1Password into env vars
op-signin [account]  Sign in to 1Password
op-status            Check 1Password sign-in status
poet [script]        Run poetry script
preflight            Session startup: sign in, load secrets, verify env
preflight -u         Same + check for tool updates
proj [directory]     Jump to project directory
serve [port]         Quick Python HTTP server (default: 8000)
yak [script]         Run npm script
EOF
}
