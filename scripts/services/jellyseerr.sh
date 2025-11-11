#!/usr/bin/env bash
set -euo pipefail

jellyseerr_ensure_dirs() { mkdir -p "$CONFIG_PATH/configs/jellyseerr"; }

jellyseerr_wait_ready() { wait_for_http "jellyseerr" "http://127.0.0.1:5055" || wait_for_tcp "jellyseerr" 127.0.0.1 5055 || true; }

jellyseerr_find_api_key() {
  local f1="$CONFIG_PATH/configs/jellyseerr/settings.json"
  local f2="$CONFIG_PATH/configs/jellyseerr/config/settings.json"
  local file=""; [[ -f "$f1" ]] && file="$f1" || { [[ -f "$f2" ]] && file="$f2"; }
  [[ -n "$file" ]] || return 0
  grep -oE '"apiKey"\s*:\s*"[^"]+"' "$file" | sed -E 's/.*:\s*"([^"]+)"/\1/' | head -n1 || true
}

jellyseerr_configure() {
  local k="${1-}"
  if [[ -z "$k" ]]; then
    log "[jellyseerr] missing API key; cannot configure"
    return 0
  fi
  local base="http://127.0.0.1:5055/api/v1"; local header=( -H "X-Api-Key: $k" )
  # Helper wrappers
  js_get() { local p="$1"; shift; curl -sS "${header[@]}" "$@" "$base$p"; }
  js_post() { local p="$1"; local data="$2"; shift 2; curl -sS -H 'Content-Type: application/json' "${header[@]}" -d "$data" -X POST "$base$p"; }

  # 1) Add Sonarr and Radarr as applications in Jellyseerr
  local sonarr_key="" radarr_key=""
  if [[ -n "${OUTPUT_KEYS_JSON:-}" && -f "$OUTPUT_KEYS_JSON" ]]; then
    sonarr_key=$(grep -oE '"sonarr":\s*\{"apiKey":\s*"[^"]+"' "$OUTPUT_KEYS_JSON" | sed -E 's/.*"apiKey":\s*"([^"]+)"/\1/' || true)
    radarr_key=$(grep -oE '"radarr":\s*\{"apiKey":\s*"[^"]+"' "$OUTPUT_KEYS_JSON" | sed -E 's/.*"apiKey":\s*"([^"]+)"/\1/' || true)
  fi

  # Sonarr config
  local sonarr_list; sonarr_list=$(js_get "/settings/sonarr" || true)
  if [[ "$sonarr_list" != *"hostname"* && -n "$sonarr_key" ]]; then
    local s_payload
    s_payload=$(cat <<EOF
{
  "name": "Sonarr",
  "hostname": "sonarr",
  "port": 8989,
  "useSsl": false,
  "baseUrl": "",
  "apiKey": "$sonarr_key",
  "active": true,
  "isDefault": true
}
EOF
)
    js_post "/settings/sonarr" "$s_payload" >/dev/null 2>&1 || true
    log "[jellyseerr] added Sonarr connection"
  else
    [[ -z "$sonarr_key" ]] && log "[jellyseerr] sonarr api key missing; skip sonarr setup" || log "[jellyseerr] Sonarr connection already present"
  fi

  # Radarr config
  local radarr_list; radarr_list=$(js_get "/settings/radarr" || true)
  if [[ "$radarr_list" != *"hostname"* && -n "$radarr_key" ]]; then
    local r_payload
    r_payload=$(cat <<EOF
{
  "name": "Radarr",
  "hostname": "radarr",
  "port": 7878,
  "useSsl": false,
  "baseUrl": "",
  "apiKey": "$radarr_key",
  "active": true,
  "isDefault": true
}
EOF
)
    js_post "/settings/radarr" "$r_payload" >/dev/null 2>&1 || true
    log "[jellyseerr] added Radarr connection"
  else
    [[ -z "$radarr_key" ]] && log "[jellyseerr] radarr api key missing; skip radarr setup" || log "[jellyseerr] Radarr connection already present"
  fi

  # 2) Link Jellyfin as media server (if token is available)
  local jf_token=""; local jf_cfg
  if [[ -f "${JARM_DIR:-/opt/jarm}/jellyfin_token.txt" ]]; then
    jf_token=$(cat "${JARM_DIR:-/opt/jarm}/jellyfin_token.txt" 2>/dev/null)
  fi
  jf_cfg=$(js_get "/settings/jellyfin" || true)
  if [[ "$jf_cfg" != *"hostname"* && -n "$jf_token" ]]; then
    local jf_payload
    jf_payload=$(cat <<EOF
{
  "name": "Jellyfin",
  "hostname": "jellyfin",
  "port": 8096,
  "useSsl": false,
  "baseUrl": "",
  "apiKey": "$jf_token",
  "externalUrl": ""
}
EOF
)
    js_post "/settings/jellyfin" "$jf_payload" >/dev/null 2>&1 || true
    log "[jellyseerr] linked Jellyfin server"
  else
    [[ -z "$jf_token" ]] && log "[jellyseerr] jellyfin token missing; skip media server link" || log "[jellyseerr] Jellyfin already linked"
  fi
}
