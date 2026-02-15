#!/usr/bin/env bash
# ~/.dev/lib/help.sh - Central help system
#
# Provides unified help interface for all dev environment utilities

# Display central help menu with links to all module help commands
dev-help() {
  cat <<'EOF'
Developer Environment Utilities
================================

Welcome to your developer environment! This collection provides utilities
for AWS, Docker, Git, 1Password, and project management.

Module Help Commands:
---------------------

aws-help
  AWS CLI utilities including profile switching, SSO login, and identity.
  Commands: awsp, aws-whoami, aws-login

docker-help
  Docker utilities for container management and cleanup.
  Commands: dex, dlogs, dstop, drm, drmi, dprune, dprune-all

git-help
  Git shortcuts and utilities for branch management and workflows.
  Commands: gco, glog, gstash, gpr, gwip, gunwip, gclean, gsync

op-help
  1Password CLI utilities for secrets management.
  Commands: op-status, op-signin, op-load-env, op-clear-env

project-help
  Project navigation and build tool runners.
  Commands: bake, yak, poet, proj, serve

Quick Reference:
----------------

Load secrets:
  op-load-env              # Load secrets from 1Password

Switch AWS profile:
  awsp                     # Interactive profile switcher

Docker shortcuts:
  dex                      # Exec into container
  dlogs                    # Tail container logs

Git shortcuts:
  gco                      # Checkout branch
  gwip                     # Quick WIP commit

Build tools:
  bake                     # Run Makefile targets
  yak                      # Run npm scripts
  poet                     # Run poetry scripts

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

2. Sign in to 1Password:
   op-signin

3. Load secrets:
   op-load-env

4. Explore individual modules:
   aws-help
   docker-help
   git-help
   op-help
   project-help

For more details on any module, run its help command (e.g., 'aws-help').

EOF
}

# Alias for convenience
alias devhelp='dev-help'
