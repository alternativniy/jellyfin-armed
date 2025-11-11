#!/usr/bin/env bash
set -euo pipefail

# COMPOSE_FILE must be provided by deploy.sh (path inside MODULE_ROOT)
: "${COMPOSE_FILE:?COMPOSE_FILE must be set by deploy.sh}"

wait_for_http() {
  local name="$1"; local url="$2"; local timeout="${3:-$WAIT_TIMEOUT}";
  local start=$(date +%s)
  while true; do
    if curl -sSf -m 3 "$url" >/dev/null 2>&1; then
  log "$name is reachable at $url"
      return 0
    fi
    local now=$(date +%s)
    if (( now - start >= timeout )); then
  err "Timeout waiting for $name at $url"
      return 1
    fi
    sleep "$WAIT_INTERVAL"
  done
}

wait_for_tcp() {
  local name="$1"; local host="$2"; local port="$3"; local timeout="${4:-$WAIT_TIMEOUT}";
  local start=$(date +%s)
  while true; do
    if (echo >/dev/tcp/$host/$port) >/dev/null 2>&1; then
  log "$name TCP $host:$port is open"
      return 0
    fi
    local now=$(date +%s)
    if (( now - start >= timeout )); then
  err "Timeout waiting for $name TCP $host:$port"
      return 1
    fi
    sleep "$WAIT_INTERVAL"
  done
}

compose_build_compose() {
  # Build a composed docker-compose.yaml into JARM_DIR (default: ~/.jarm)
  local target_dir="${JARM_DIR:-$HOME/.jarm}"
  mkdir -p "$target_dir"
  local out="$target_dir/docker-compose.yaml"
  : > "$out"

  # Write a single header and services root
  printf "version: '3.8'\n" >> "$out"
  printf "services:\n" >> "$out"

  # Merge selected service fragments under a single services: key
  for s in "${SERVICES[@]}"; do
    local frag="$MODULE_ROOT/compose/$s.yaml"
    if [[ -f "$frag" ]]; then
      # Strip the leading 'services:' line from fragment and append the rest
      printf "\n  # --- %s ---\n" "$s" >> "$out"
      awk 'NR==1 && $1=="services:" {next} {print}' "$frag" >> "$out"
    fi
  done

  log "Generated compose at $out"
  # Point COMPOSE_FILE to generated file
  COMPOSE_FILE="$out"
  export COMPOSE_FILE
}

compose_pull_up() {
  local CCMD
  CCMD=$(pick_compose_cmd)
  log "Compose command: $CCMD"
  $CCMD -f "$COMPOSE_FILE" pull
  $CCMD -f "$COMPOSE_FILE" up -d
}

compose_down() {
  local CCMD
  CCMD=$(pick_compose_cmd)
  $CCMD -f "$COMPOSE_FILE" down
}

compose_restart() {
  local CCMD
  CCMD=$(pick_compose_cmd)
  $CCMD -f "$COMPOSE_FILE" restart
}

service_readiness() { services_wait_readiness; }
