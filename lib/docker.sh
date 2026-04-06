#!/usr/bin/env bash
# ~/.dev/lib/docker.sh - Docker utilities
#
# Requires: docker, fzf

docker-help() {
  cat <<'EOF'
Docker Utilities
================

Available Commands:
-------------------

docker-help
  Display this help message.

dex [container] [shell]
  Exec into a running container. Pass container name to skip fzf.
  shell defaults to /bin/sh.

dlogs [container]
  Tail container logs. Pass container name to skip fzf.

dstop [container...]
  Stop one or more containers. Pass names to skip fzf (supports multi-select).

drm [container...]
  Remove one or more containers. Pass names to skip fzf (supports multi-select).

drmi [image...]
  Remove one or more images. Pass names to skip fzf (supports multi-select).

dprune
  Clean up Docker resources (stopped containers, dangling images, etc).

dprune-all
  Aggressive cleanup including volumes. Prompts for confirmation.

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

# dex: exec into running container
dex() {
  local container="${1:-}"
  local shell="${2:-/bin/sh}"

  if [[ -z "$container" ]]; then
    if [[ ! -t 0 ]]; then
      echo "Usage: dex <container> [shell]" >&2
      return 1
    fi
    container=$(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | fzf --prompt="Select container > " | cut -f1)
  fi

  if [[ -n "$container" ]]; then
    if [[ -t 0 && -t 1 ]]; then
      docker exec -it "$container" "$shell"
    else
      docker exec -i "$container" "$shell"
    fi
  fi
}

# dlogs: tail container logs
dlogs() {
  local container="${1:-}"

  if [[ -z "$container" ]]; then
    if [[ ! -t 0 ]]; then
      echo "Usage: dlogs <container>" >&2
      return 1
    fi
    container=$(docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | fzf --prompt="Select container > " | cut -f1)
  fi

  [[ -n "$container" ]] && docker logs -f "$container"
}

# dstop: stop containers
dstop() {
  if [[ $# -gt 0 ]]; then
    docker stop "$@"
    return
  fi

  if [[ ! -t 0 ]]; then
    echo "Usage: dstop <container...>" >&2
    return 1
  fi

  local containers
  containers=$(docker ps --format '{{.Names}}\t{{.Image}}' | fzf -m --prompt="Select containers to stop > " | cut -f1)
  [[ -n "$containers" ]] && echo "$containers" | xargs docker stop
}

# drm: remove containers
drm() {
  if [[ $# -gt 0 ]]; then
    docker rm "$@"
    return
  fi

  if [[ ! -t 0 ]]; then
    echo "Usage: drm <container...>" >&2
    return 1
  fi

  local containers
  containers=$(docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | fzf -m --prompt="Select containers to remove > " | cut -f1)
  [[ -n "$containers" ]] && echo "$containers" | xargs docker rm
}

# drmi: remove images
drmi() {
  if [[ $# -gt 0 ]]; then
    docker rmi "$@"
    return
  fi

  if [[ ! -t 0 ]]; then
    echo "Usage: drmi <image...>" >&2
    return 1
  fi

  local images
  images=$(docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}' | fzf -m --prompt="Select images to remove > " | cut -f1)
  [[ -n "$images" ]] && echo "$images" | xargs docker rmi
}

# dprune: clean up docker resources
dprune() {
  echo "🧹 Pruning Docker resources..."
  docker system prune -f
  echo "✅ Done"
}

# dprune-all: aggressive cleanup (includes volumes)
dprune-all() {
  echo "⚠️  This will remove all unused containers, networks, images, and volumes"
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
