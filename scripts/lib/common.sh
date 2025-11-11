#!/usr/bin/env bash
# Common helpers and interactive variable collection
set -euo pipefail

log() { printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
err() { printf "[ERROR] %s\n" "$*" >&2; }

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Required command not found: $1"; exit 1;
  fi
}

pick_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    err "Neither 'docker compose' nor 'docker-compose' is available."; exit 1
  fi
}

prompt_var() { # name label [default]
  local name="$1"; local label="$2"; local def="${3-}"
  local current="${!name-}"
  local shown="$current"
  if [[ -z "$shown" && -n "$def" ]]; then shown="$def"; fi
  # In non-interactive mode, auto-apply default if provided
  if [[ "${RUN_NONINTERACTIVE:-0}" == "1" ]]; then
    if [[ -z "${!name-}" ]]; then
      if [[ -n "$def" ]]; then export "$name"="$def"; else err "Missing required variable: $name"; exit 1; fi
    fi
    return 0
  fi
  if [[ -n "$shown" ]]; then
    read -r -p "$label [$shown]: " val || true
    val="${val:-$shown}"
  else
    read -r -p "$label: " val || true
  fi
  export "$name"="$val"
}

collect_stack_vars() {
  # Offer defaults from current env; if .env exists, use values as suggestions
  local env_file="${ENV_FILE:-.env}"
  if [[ -z "${CONFIG_PATH-}" && -f "$env_file" ]]; then CONFIG_PATH=$(grep -E '^CONFIG_PATH=' "$env_file" | sed -E 's/^CONFIG_PATH=//'); fi
  if [[ -z "${MEDIA_PATH-}" && -f "$env_file" ]]; then MEDIA_PATH=$(grep -E '^MEDIA_PATH=' "$env_file" | sed -E 's/^MEDIA_PATH=//'); fi
  if [[ -z "${DOWNLOAD_PATH-}" && -f "$env_file" ]]; then DOWNLOAD_PATH=$(grep -E '^DOWNLOAD_PATH=' "$env_file" | sed -E 's/^DOWNLOAD_PATH=//'); fi
  if [[ -z "${TZ-}" && -f "$env_file" ]]; then TZ=$(grep -E '^TZ=' "$env_file" | sed -E 's/^TZ=//'); fi

  # Default user-writable paths under JARM_DIR
  local def_root="${JARM_DIR:-$HOME/.jarm}"
  local def_cfg="$def_root"
  local def_media="$def_root/media"
  local def_dl="$def_root/downloads"

  prompt_var CONFIG_PATH "Absolute path for CONFIG_PATH (base path for configs)" "$def_cfg"
  prompt_var MEDIA_PATH "Absolute path for MEDIA_PATH (media library)" "$def_media"
  prompt_var DOWNLOAD_PATH "Absolute path for DOWNLOAD_PATH (downloads)" "$def_dl"
  prompt_var TZ "Timezone (e.g., Asia/Almaty)" "Asia/Almaty"
  # qBittorrent credentials (used for WebUI/API)
  prompt_var QB_USERNAME "qBittorrent WebUI username" "admin"
  prompt_var QB_PASSWORD "qBittorrent WebUI password" "adminadmin"

  export WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"
  export WAIT_INTERVAL="${WAIT_INTERVAL:-2}"
  export AUTO_CONFIG="${AUTO_CONFIG:-0}"
}

ensure_dirs() {
  local dirs=(
    "${JARM_DIR:-$HOME/.jarm}"
    "$CONFIG_PATH/configs/qbittorrent"
    "$MEDIA_PATH"
    "$DOWNLOAD_PATH"
    "$DOWNLOAD_PATH/tv"
    "$DOWNLOAD_PATH/movies"
    "$CONFIG_PATH/configs/sonarr"
    "$MEDIA_PATH/tv"
    "$CONFIG_PATH/configs/radarr"
    "$MEDIA_PATH/movies"
    "$CONFIG_PATH/configs/jellyfin"
    "$CONFIG_PATH/jellyfin/cache"
    "$CONFIG_PATH/configs/jellyseerr"
    "$CONFIG_PATH/configs/prowlarr"
  )
  for d in "${dirs[@]}"; do
    if [[ -z "$d" ]]; then
      err "Empty directory path encountered while ensuring dirs"; exit 1
    fi
    if [[ ! -d "$d" ]]; then
      log "Creating directory: $d"
      mkdir -p "$d"
    fi
  done
}

# HTTP helpers used by service modules
http_get_json() { local url="$1"; shift; curl -sS -H 'Accept: application/json' "$@" "$url"; }
http_post_json() { local url="$1"; local data="$2"; shift 2; curl -sS -H 'Content-Type: application/json' -H 'Accept: application/json' "$@" -d "$data" -X POST "$url"; }
