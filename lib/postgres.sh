#!/usr/bin/env bash
# ~/.preflight/lib/postgres.sh - PostgreSQL cluster start/stop shortcuts
#
# Requires: postgresql-common (pg_lsclusters, pg_ctlcluster) — Debian/Ubuntu/WSL
# Optional: fzf (only consulted when more than one cluster exists)

pg-help() {
  cat <<'EOF'
PostgreSQL Utilities
====================

Available Commands:
-------------------

pg-help
  Display this help message.

pg-up [version] [cluster]
  Start a PostgreSQL cluster. Already running is not an error.

pg-down [version] [cluster]
  Stop a PostgreSQL cluster. Already stopped is not an error.

Cluster Selection:
------------------

With no arguments, the only cluster on the machine is used. When there is more
than one, fzf picks (or the list is printed if fzf isn't available). A cluster
can also be named directly, in any of these forms:

  pg-up 14           # version 14, cluster 'main'
  pg-up 14/main
  pg-up 14-main
  pg-up 14 main

Manual Startup:
---------------

These are most useful once a cluster no longer starts at boot, which is a
per-cluster setting in its start.conf:

  /etc/postgresql/<version>/<cluster>/start.conf

    auto      start at boot (the packaged default)
    manual    start only via pg-up / pg_ctlcluster / postgresql@.service
    disabled  refuse to start at all

Run 'sudo systemctl daemon-reload' after editing start.conf — a systemd
generator reads it to decide which clusters postgresql.service pulls in, and it
only re-runs on reload.

Status:
-------

pg_lsclusters              # version, cluster, port, status, data dir, log

Requirements:
-------------
- postgresql-common (Debian/Ubuntu/WSL)
- sudo rights to start/stop clusters
- fzf (optional, to choose between multiple clusters)

EOF
}

# Cluster start/stop is root's business. Skip sudo when we're already root so
# this stays usable from a root shell or a container without sudo installed.
_pg_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

# One line per cluster: "<version> <cluster> <port> <status>".
_pg_clusters() {
  pg_lsclusters --no-header 2>/dev/null | awk 'NF >= 4 { print $1, $2, $3, $4 }'
}

# Resolve the arguments to exactly one cluster and echo its line. Accepts
# "14", "14/main", "14-main" or "14 main"; with nothing at all, falls back to
# the only cluster present.
_pg_pick_cluster() {
  local want_ver="" want_name=""

  case $# in
    0) ;;
    1) want_ver="${1%%[-/]*}"
       [[ "$1" == *[-/]* ]] && want_name="${1#*[-/]}"
       ;;
    *) want_ver="$1"; want_name="$2" ;;
  esac

  local -a found=()
  local ver name port status
  while read -r ver name port status; do
    [[ -n "$want_ver" && "$ver" != "$want_ver" ]] && continue
    [[ -n "$want_name" && "$name" != "$want_name" ]] && continue
    found+=("$ver $name $port $status")
  done < <(_pg_clusters)

  case ${#found[@]} in
    1) printf '%s\n' "${found[0]}"; return 0 ;;
    0)
      if [[ -n "$want_ver" ]]; then
        printf 'No PostgreSQL cluster matching %s%s\n' \
          "$want_ver" "${want_name:+/$want_name}" >&2
      else
        printf 'No PostgreSQL clusters found\n' >&2
      fi
      local all
      all=$(_pg_clusters)
      if [[ -n "$all" ]]; then
        printf 'Available:\n' >&2
        printf '%s\n' "$all" | awk '{ printf "  %s/%s (%s)\n", $1, $2, $4 }' >&2
      fi
      return 1
      ;;
  esac

  # More than one match, so somebody has to choose. Interactivity is judged on
  # stderr, not stdout: this function's stdout is always a pipe because callers
  # capture the picked line, so -t 1 would report "not a terminal" every time
  # and the fzf prompt would never appear. fzf itself talks to /dev/tty rather
  # than stdout, so a captured stdout doesn't stop it from drawing.
  if command -v fzf &>/dev/null && [[ -t 2 ]]; then
    local choice
    choice=$(printf '%s\n' "${found[@]}" \
      | awk '{ printf "%s/%s\tport %s\t%s\n", $1, $2, $3, $4 }' \
      | fzf --prompt="Select cluster > " --with-nth=1,2,3 \
      | cut -f1)
    [[ -z "$choice" ]] && return 1
    printf '%s\n' "${found[@]}" \
      | awk -v want="$choice" '$1 "/" $2 == want { print; exit }'
    return 0
  fi

  printf 'Multiple PostgreSQL clusters — name one:\n' >&2
  printf '%s\n' "${found[@]}" | awk '{ printf "  %s/%s (%s)\n", $1, $2, $4 }' >&2
  return 1
}

_pg_action() {
  local action="$1"; shift

  # The systemd/Postgres verbs are start/stop; the commands people type are
  # up/down. Keep the mapping in one place so messages name a real command.
  local verb=up
  [[ "$action" == stop ]] && verb=down

  if ! command -v pg_lsclusters &>/dev/null; then
    printf 'pg-%s: needs postgresql-common (pg_lsclusters/pg_ctlcluster).\n' "$verb" >&2
    if command -v brew &>/dev/null; then
      printf '  Homebrew manages Postgres itself: brew services %s postgresql@<version>\n' \
        "$action" >&2
    fi
    return 1
  fi

  local picked ver name port status
  picked=$(_pg_pick_cluster "$@") || return 1
  read -r ver name port status <<<"$picked"

  # Report the no-op rather than failing it: pg-up on a running cluster is what
  # you type when you aren't sure, and it shouldn't punish you for asking.
  case "$action" in
    start)
      if [[ "$status" == online* ]]; then
        printf '✅ PostgreSQL %s/%s already up on port %s\n' "$ver" "$name" "$port"
        return 0
      fi
      ;;
    stop)
      if [[ "$status" != online* ]]; then
        printf '✅ PostgreSQL %s/%s already down\n' "$ver" "$name"
        return 0
      fi
      ;;
  esac

  # pg_ctlcluster hands start/stop/restart to systemd when systemd is running
  # and we are root, so this one call is correct on systemd and non-systemd
  # machines alike — no need to work out which init is in charge. It also still
  # starts clusters marked 'manual' in start.conf; only 'disabled' is refused.
  _pg_root pg_ctlcluster "$ver" "$name" "$action" || return $?

  # Success is silent, and silent-er once systemd has taken the request, so read
  # the state back instead of assuming the verb did what it said.
  local now
  now=$(_pg_clusters | awk -v v="$ver" -v c="$name" '$1 == v && $2 == c { print $4 }')
  if [[ "$now" == online* ]]; then
    printf '🐘 PostgreSQL %s/%s up on port %s\n' "$ver" "$name" "$port"
  else
    printf '🐘 PostgreSQL %s/%s down\n' "$ver" "$name"
  fi
}

pg-up()   { _pg_action start "$@"; }
pg-down() { _pg_action stop  "$@"; }
