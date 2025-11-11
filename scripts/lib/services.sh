#!/usr/bin/env bash
set -euo pipefail

# Registry of services (order matters for readiness and config dependencies)
SERVICES_DEFAULT=(qbittorrent flaresolverr sonarr radarr prowlarr jellyfin jellyseerr)
SERVICES=()

select_services() {
  # If COMPOSE_INCLUDE is set (comma-separated), filter services; else use defaults
  local include="${COMPOSE_INCLUDE:-}";
  if [[ -z "$include" ]]; then
    SERVICES=("${SERVICES_DEFAULT[@]}")
    return
  fi
  IFS=',' read -r -a requested <<<"$include"
  for r in "${requested[@]}"; do
    for d in "${SERVICES_DEFAULT[@]}"; do
      if [[ "$r" == "$d" ]]; then SERVICES+=("$r"); break; fi
    done
  done
}

# Dynamically source all service modules
MODULE_ROOT="${MODULE_ROOT:?MODULE_ROOT must be set by deploy.sh}" # Provided by deploy.sh bootstrap
for f in "$MODULE_ROOT/scripts/services"/*.sh; do
  # shellcheck disable=SC1090
  [[ -f "$f" ]] && source "$f"
done

# Compose helpers are expected to be present: wait_for_http, wait_for_tcp

# Aggregate: ensure directories
services_ensure_dirs() {
  for s in "${SERVICES[@]}"; do
    local fn="${s}_ensure_dirs"
    if type -t "$fn" >/dev/null 2>&1; then "$fn"; fi
  done
}

# Aggregate: wait readiness
services_wait_readiness() {
  for s in "${SERVICES[@]}"; do
    local fn="${s}_wait_ready"
    if type -t "$fn" >/dev/null 2>&1; then "$fn"; fi
  done
}

# Aggregate: scan API keys, writes JSON file to $OUTPUT_KEYS_JSON
services_scan_api_keys() {
  declare -A keys
  for s in "${SERVICES[@]}"; do
    local fn="${s}_find_api_key"; local key=""
    if type -t "$fn" >/dev/null 2>&1; then
      key=$($fn || true)
      [[ -n "$key" ]] && keys[$s]="$key"
    fi
  done
  {
    printf '{\n'
    local first=1
    for s in "${SERVICES[@]}"; do
      local v="${keys[$s]:-}"
      if (( first )); then first=0; else printf ',\n'; fi
      if [[ -n "$v" ]]; then printf '  "%s": {"apiKey": "%s"}' "$s" "$v"; else printf '  "%s": {"apiKey": null}' "$s"; fi
    done
    printf '\n}\n'
  } >"$OUTPUT_KEYS_JSON"
  log "API keys saved to $OUTPUT_KEYS_JSON"
}

# Aggregate: configure from keys JSON
services_configure_from_keys() {
  if [[ ! -f "$OUTPUT_KEYS_JSON" ]]; then err "Missing $OUTPUT_KEYS_JSON"; return 1; fi
  for s in "${SERVICES[@]}"; do
    local fn="${s}_configure"
    if type -t "$fn" >/dev/null 2>&1; then
      local key
      key=$(grep -oE '"'"$s"'":\s*\{"apiKey":\s*"[^"]+"' "$OUTPUT_KEYS_JSON" | sed -E 's/.*"apiKey":\s*"([^"]+)"/\1/' || true)
      "$fn" "$key"
    fi
  done
}
