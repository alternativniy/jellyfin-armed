#!/usr/bin/env bash
set -euo pipefail

prowlarr_ensure_dirs() { mkdir -p "$CONFIG_PATH/configs/prowlarr"; }

prowlarr_wait_ready() {
  wait_for_http "prowlarr" "http://127.0.0.1:9696" || wait_for_tcp "prowlarr" 127.0.0.1 9696 || true
}

prowlarr_find_api_key() {
  local cfg="$CONFIG_PATH/configs/prowlarr/config.xml"
  [[ -f "$cfg" ]] || return 0
  grep -oP '(?<=<ApiKey>)[^<]+' "$cfg" | head -n1 || true
}

prowlarr_configure() {
  local k="${1-}"; [[ -z "$k" ]] && log "[prowlarr] missing API key" && return 0
  local base="http://127.0.0.1:9696/api/v1"; local header=( -H "X-Api-Key: $k" )
  if http_get_json "$base/system/status" "${header[@]}" >/dev/null 2>&1; then
    log "[prowlarr] API OK"
  else
    log "[prowlarr] system/status unreachable"; return 0
  fi

  # Resolve applications endpoint (Prowlarr supports /applications; fallback /app)
  local list_url="$base/applications"
  local existing
  existing=$(http_get_json "$list_url" "${header[@]}" || true)
  if [[ -z "$existing" || "$existing" == "null" ]]; then
    list_url="$base/app"
    existing=$(http_get_json "$list_url" "${header[@]}" || true)
  fi

  # Read Sonarr/Radarr API keys from keys JSON (if available)
  local sonarr_key="" radarr_key="" keys_file
  keys_file="${OUTPUT_KEYS_FILE}"
  if [[ -f "$keys_file" ]]; then
    sonarr_key=$(grep -oE '"sonarr":\s*\{"apiKey":\s*"[^"]+"' "$keys_file" | sed -E 's/.*"apiKey":\s*"([^"]+)"/\1/' || true)
    radarr_key=$(grep -oE '"radarr":\s*\{"apiKey":\s*"[^"]+"' "$keys_file" | sed -E 's/.*"apiKey":\s*"([^"]+)"/\1/' || true)
  fi

  # Helper: add application if missing
  local add_app
  add_app() {
    local app_name="$1" impl="$2" contract="$3" host="$4" port="$5" api_key="$6"
    local tag_match
    tag_match=$(echo "$existing" | grep -qi "$impl" && echo yes || echo no)
    if [[ "$tag_match" == yes ]]; then
      log "[prowlarr] $app_name application already present"
      return 0
    fi
    if [[ -z "$api_key" ]]; then
      log "[prowlarr] missing $app_name API key — skip"
      return 0
    fi
    local payload
    payload=$(cat <<EOF
{
  "name": "$app_name",
  "implementation": "$impl",
  "configContract": "$contract",
  "syncLevel": "addRemove",
  "enable": true,
  "fields": [
    {"name":"host","value":"$host"},
    {"name":"port","value":$port},
    {"name":"useSsl","value":false},
    {"name":"urlBase","value":""},
    {"name":"apiKey","value":"$api_key"}
  ]
}
EOF
)
    curl -sS -H "Content-Type: application/json" "${header[@]}" -d "$payload" -X POST "$list_url" >/dev/null 2>&1 || true
    log "[prowlarr] added $app_name application"
  }

  add_app "Sonarr" "Sonarr" "SonarrSettings" "sonarr" 8989 "$sonarr_key"
  add_app "Radarr" "Radarr" "RadarrSettings" "radarr" 7878 "$radarr_key"
}
