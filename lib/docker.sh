#!/usr/bin/env bash
# ~/.dev/lib/docker.sh - Docker utilities
#
# Requires: docker, fzf

# Display help for all Docker commands
docker-help() {
  cat <<'EOF'
Docker Utilities
================

Available Commands:
-------------------

docker-help
  Display this help message showing all available Docker commands.

dex [shell]
  Fuzzy select and exec into a running container.
  Arguments:
    shell - Optional. Shell to use (default: /bin/sh)
  Example: dex /bin/bash

dlogs
  Fuzzy select a container and tail its logs.
  Use Ctrl+C to stop tailing.

dstop
  Fuzzy select and stop one or more running containers.
  Supports multi-select (Tab to select multiple).

drm
  Fuzzy select and remove one or more containers.
  Supports multi-select (Tab to select multiple).

drmi
  Fuzzy select and remove one or more images.
  Supports multi-select (Tab to select multiple).

dprune
  Clean up Docker resources (stopped containers, dangling images, etc).
  Non-interactive, safe cleanup.

dprune-all
  Aggressive cleanup including volumes.
  Prompts for confirmation before proceeding.

Common Aliases:
---------------
dps      - docker ps
dpsa     - docker ps -a
di       - docker images
dcp      - docker compose
dcup     - docker compose up -d
dcdown   - docker compose down
dclogs   - docker compose logs -f

Requirements:
-------------
- Docker
- fzf (for interactive selection)

EOF
}

# dex: fuzzy exec into running container
dex() {
  local container
  container=$(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | fzf --prompt="Select container > " | cut -f1)
  if [[ -n "$container" ]]; then
    local shell="${1:-/bin/sh}"
    docker exec -it "$container" "$shell"
  fi
}

# dlogs: fuzzy select container and tail logs
dlogs() {
  local container
  container=$(docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | fzf --prompt="Select container > " | cut -f1)
  if [[ -n "$container" ]]; then
    docker logs -f "$container"
  fi
}

# dstop: fuzzy select and stop containers
dstop() {
  local containers
  containers=$(docker ps --format '{{.Names}}\t{{.Image}}' | fzf -m --prompt="Select containers to stop > " | cut -f1)
  if [[ -n "$containers" ]]; then
    echo "$containers" | xargs docker stop
  fi
}

# drm: fuzzy select and remove containers
drm() {
  local containers
  containers=$(docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | fzf -m --prompt="Select containers to remove > " | cut -f1)
  if [[ -n "$containers" ]]; then
    echo "$containers" | xargs docker rm
  fi
}

# drmi: fuzzy select and remove images
drmi() {
  local images
  images=$(docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}' | fzf -m --prompt="Select images to remove > " | cut -f1)
  if [[ -n "$images" ]]; then
    echo "$images" | xargs docker rmi
  fi
}

# dprune: clean up docker resources
dprune() {
  echo "🧹 Pruning Docker resources..."
  docker system prune -f
  echo "✅ Done"
}

# dprune-all: aggressive cleanup (includes volumes)
dprune-all() {
  echo "⚠️ This will remove all unused containers, networks, images, and volumes"
  read -p "Continue? [y/N] " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    docker system prune -af --volumes
    echo "✅ Done"
  fi
}

# Aliases
alias dps='docker ps'
alias dpsa='docker ps -a'
alias di='docker images'
alias dcp='docker compose'
alias dcup='docker compose up -d'
alias dcdown='docker compose down'
alias dclogs='docker compose logs -f'
