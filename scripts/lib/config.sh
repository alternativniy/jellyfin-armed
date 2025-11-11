#!/usr/bin/env bash
set -euo pipefail

WORK_DIR="${WORK_DIR:-${JARM_DIR:-$PWD}}"
OUTPUT_KEYS_JSON="${OUTPUT_KEYS_JSON:-$WORK_DIR/found_api_keys.json}"

http_get_json() { local url="$1"; shift; curl -sS -H 'Accept: application/json' "$@" "$url"; }
http_post_json() { local url="$1"; local data="$2"; shift 2; curl -sS -H 'Content-Type: application/json' -H 'Accept: application/json' "$@" -d "$data" -X POST "$url"; }

scan_api_keys() {
  log "Scanning for API keys"
  local -A keys
  local base_cfg="$CONFIG_PATH/configs"
  local sonarr_cfg="$base_cfg/sonarr/config.xml"
  local radarr_cfg="$base_cfg/radarr/config.xml"
  local prowlarr_cfg="$base_cfg/prowlarr/config.xml"
  local jellyseerr_json1="$base_cfg/jellyseerr/settings.json"
  local jellyseerr_json2="$base_cfg/jellyseerr/config/settings.json"
  local k
  if [[ -f "$sonarr_cfg" ]]; then k=$(grep -oP '(?<=<ApiKey>)[^<]+' "$sonarr_cfg" | head -n1 || true); [[ -n "${k:-}" ]] && keys[sonarr]="$k"; fi
  if [[ -f "$radarr_cfg" ]]; then k=$(grep -oP '(?<=<ApiKey>)[^<]+' "$radarr_cfg" | head -n1 || true); [[ -n "${k:-}" ]] && keys[radarr]="$k"; fi
  if [[ -f "$prowlarr_cfg" ]]; then k=$(grep -oP '(?<=<ApiKey>)[^<]+' "$prowlarr_cfg" | head -n1 || true); [[ -n "${k:-}" ]] && keys[prowlarr]="$k"; fi
  if [[ -f "$jellyseerr_json1" ]]; then k=$(grep -oE '"apiKey"\s*:\s*"[^"]+"' "$jellyseerr_json1" | sed -E 's/.*:\s*"([^"]+)"/\1/' | head -n1 || true); [[ -n "${k:-}" ]] && keys[jellyseerr]="$k"; fi
  if [[ -z "${keys[jellyseerr]:-}" && -f "$jellyseerr_json2" ]]; then k=$(grep -oE '"apiKey"\s*:\s*"[^"]+"' "$jellyseerr_json2" | sed -E 's/.*:\s*"([^"]+)"/\1/' | head -n1 || true); [[ -n "${k:-}" ]] && keys[jellyseerr]="$k"; fi
  for svc in sonarr radarr prowlarr; do
    if [[ -z "${keys[$svc]:-}" && -d "$base_cfg/$svc" ]]; then
      k=$(grep -R -I -oP "(?i)(?<=api[_-]?key[\"'>:\\s]*[\"':\\s]*)([A-Za-z0-9]{16,})" "$base_cfg/$svc" 2>/dev/null | head -n1 || true)
      [[ -n "${k:-}" ]] && keys[$svc]="$k"
    fi
  done
  { printf '{\n'; local first=1; for svc in qbittorrent flaresolverr sonarr radarr jellyfin jellyseerr prowlarr; do local val="${keys[$svc]:-}"; (( first )) && first=0 || printf ',\n'; if [[ -n "$val" ]]; then printf '  "%s": {"apiKey": "%s"}' "$svc" "$val"; else printf '  "%s": {"apiKey": null}' "$svc"; fi; done; printf '\n}\n'; } >"$OUTPUT_KEYS_JSON"
  log "API keys saved to $OUTPUT_KEYS_JSON"
}

configure_all_services() {
  if [[ ! -f "$OUTPUT_KEYS_JSON" ]]; then log "Missing $OUTPUT_KEYS_JSON — skipping configure"; return 0; fi
  # Delegate to per-service configurators via services.sh orchestrator
  services_configure_from_keys
  log "Basic configuration complete"
}
