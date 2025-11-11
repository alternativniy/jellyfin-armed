#!/usr/bin/env bash
set -euo pipefail

radarr_ensure_dirs() {
  mkdir -p "$CONFIG_PATH/configs/radarr"
  mkdir -p "$MEDIA_PATH/movies"
}

radarr_wait_ready() {
  wait_for_http "radarr" "http://127.0.0.1:7878" || wait_for_tcp "radarr" 127.0.0.1 7878 || true
}

radarr_find_api_key() {
  local cfg="$CONFIG_PATH/configs/radarr/config.xml"
  [[ -f "$cfg" ]] || return 0
  grep -oP '(?<=<ApiKey>)[^<]+' "$cfg" | head -n1 || true
}

radarr_configure() {
  local k="${1-}"; [[ -z "$k" ]] && log "[radarr] missing API key" && return 0
  local base="http://127.0.0.1:7878/api/v3"; local header=( -H "X-Api-Key: $k" )
  local existing=$(http_get_json "$base/rootfolder" "${header[@]}" | grep -oE '"path":"[^"]+"' || true)
  if ! grep -q '/movies' <<<"$existing" && ! grep -q '/media/movies' <<<"$existing"; then
    log "[radarr] adding root folder /movies"; http_post_json "$base/rootfolder" '{"path":"/movies","accessible":true}' "${header[@]}" >/dev/null 2>&1 || true
  fi

  # Ensure qBittorrent credentials (use stored file or prompt if interactive)
  if [[ -z "${QB_USERNAME:-}" ]]; then QB_USERNAME="admin"; export QB_USERNAME; fi
  if [[ -z "${QB_PASSWORD:-}" ]]; then
    if [[ -f "${JARM_DIR:-$HOME/.jarm}/qbittorrent_password.txt" ]]; then
      QB_PASSWORD="$(cat "${JARM_DIR:-$HOME/.jarm}/qbittorrent_password.txt" 2>/dev/null)"; export QB_PASSWORD
    elif [[ "${RUN_NONINTERACTIVE:-0}" != "1" ]]; then
      prompt_var QB_USERNAME "qBittorrent WebUI username" "admin"
      prompt_var QB_PASSWORD "qBittorrent WebUI password"
    fi
  fi
  if [[ -n "${QB_USERNAME:-}" && -n "${QB_PASSWORD:-}" ]]; then
    local clients
    clients=$(curl -sS -H "X-Api-Key: $k" "$base/downloadclient" || true)
    if ! echo "$clients" | grep -qi qbittorrent; then
      local client_json
      client_json=$(cat <<EOF
{
  "name": "qBittorrent",
  "protocol": "torrent",
  "implementation": "QBittorrent",
  "configContract": "QBittorrentSettings",
  "fields": [
    {"name":"host","value":"qbittorrent"},
    {"name":"port","value":8080},
    {"name":"useSsl","value":false},
    {"name":"urlBase","value":""},
    {"name":"username","value":"${QB_USERNAME}"},
    {"name":"password","value":"${QB_PASSWORD}"},
    {"name":"movieCategory","value":"movies"},
    {"name":"recentPriority","value":0},
    {"name":"olderPriority","value":0},
    {"name":"removeCompleted","value":false},
    {"name":"addPaused","value":false},
    {"name":"useCategory","value":true},
    {"name":"enable","value":true}
  ],
  "enable": true,
  "removeCompleted": false,
  "id": 0
}
EOF
)
      curl -sS -H "X-Api-Key: $k" -H "Content-Type: application/json" -d "$client_json" "$base/downloadclient" >/dev/null 2>&1 || true
      log "[radarr] added qBittorrent download client"
    else
      log "[radarr] qBittorrent client already present"
    fi
  else
    log "[radarr] qBittorrent credentials missing; skip download client add"
  fi
}
