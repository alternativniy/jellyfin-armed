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
  local shown="$current" val=""
  if [[ -z "$shown" && -n "$def" ]]; then shown="$def"; fi
  # Try to read from /dev/tty if stdin is not a TTY (e.g., curl | bash)
  if [[ -e /dev/tty && -r /dev/tty ]]; then
    if [[ -n "$shown" ]]; then
      printf "%s [%s]: " "$label" "$shown" > /dev/tty
      IFS= read -r val < /dev/tty || true
      val="${val:-$shown}"
    else
      printf "%s: " "$label" > /dev/tty
      IFS= read -r val < /dev/tty || true
    fi
  else
    # Fallback: no TTY available, use shown/default and inform user
    if [[ -n "$shown" ]]; then
      val="$shown"
    else
      err "No TTY to prompt for $name and no default provided. Set $name in env or run interactively."; exit 1
    fi
  fi
  export "$name"="$val"
}

# Persistent prompts storage in JARM_DIR
JARM_SETTINGS_FILE="${JARM_DIR:-$HOME/.jarm}/settings.env"
# Only persist these variables
ALLOWED_PROMPT_VARS=(
  CONFIG_PATH
  MEDIA_PATH
  DOWNLOAD_PATH
  TZ
  PUID
  PGID
  QB_USERNAME
  QB_PASSWORD
)

load_saved_prompts() {
  local f="$JARM_SETTINGS_FILE"
  [[ -f "$f" ]] || return 0
  # Build regex group for allowed keys
  local keys regex
  keys=$(printf "|%s" "${ALLOWED_PROMPT_VARS[@]}")
  regex="^(${keys:1})="
  local tmp
  tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp' 2>/dev/null || true" RETURN
  # Filter only allowed assignments and normalize line endings
  grep -E "$regex" "$f" | sed 's/\r$//' > "$tmp" || true
  # Source into environment
  set -a
  # shellcheck disable=SC1090
  . "$tmp" || true
  set +a
}

save_prompts() {
  local f="$JARM_SETTINGS_FILE"
  mkdir -p "$(dirname "$f")"
  : > "$f"
  local k v
  for k in "${ALLOWED_PROMPT_VARS[@]}"; do
    v="${!k-}"
    # Use %q to shell-escape values safely
    if [[ -n "$v" ]]; then printf '%s=%q\n' "$k" "$v" >> "$f"; fi
  done
  chmod 600 "$f" 2>/dev/null || true
}

# Ask only if not already set (useful with saved prompts)
ask_once() { # name label [default]
  local name="$1"; local label="$2"; local def="${3-}"
  if [[ -n "${!name-}" ]]; then return 0; fi
  prompt_var "$name" "$label" "$def"
}

collect_stack_vars() {
  # Load previously saved values first
  load_saved_prompts || true
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
  local def_uid
  local def_gid
  def_uid="$(id -u 2>/dev/null || echo 1000)"
  def_gid="$(id -g 2>/dev/null || echo 1000)"

  ask_once CONFIG_PATH "Absolute path for CONFIG_PATH (base path for configs)" "$def_cfg"
  ask_once MEDIA_PATH "Absolute path for MEDIA_PATH (media library)" "$def_media"
  ask_once DOWNLOAD_PATH "Absolute path for DOWNLOAD_PATH (downloads)" "$def_dl"
  ask_once TZ "Timezone (e.g., Asia/Almaty)" "Asia/Almaty"
  ask_once PUID "PUID (container user id)" "$def_uid"
  ask_once PGID "PGID (container group id)" "$def_gid"

  export WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"
  export WAIT_INTERVAL="${WAIT_INTERVAL:-2}"
  export AUTO_CONFIG="${AUTO_CONFIG:-0}"

  # Persist collected values for next runs
  save_prompts || true
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
    # Try to align ownership with requested PUID/PGID (non-fatal if not permitted)
    if [[ -n "${PUID:-}" && -n "${PGID:-}" ]]; then
      chown -R "$PUID:$PGID" "$d" >/dev/null 2>&1 || true
    fi
  done
}

# HTTP helpers used by service modules
http_get_json() { local url="$1"; shift; curl -sS -H 'Accept: application/json' "$@" "$url"; }
http_post_json() { local url="$1"; local data="$2"; shift 2; curl -sS -H 'Content-Type: application/json' -H 'Accept: application/json' "$@" -d "$data" -X POST "$url"; }
