#!/usr/bin/env bash
set -euo pipefail

jellyfin_ensure_dirs() {
  mkdir -p "$CONFIG_PATH/configs/jellyfin"
  mkdir -p "$CONFIG_PATH/jellyfin/cache"
}

jellyfin_wait_ready() { wait_for_http "jellyfin" "http://127.0.0.1:8096" || wait_for_tcp "jellyfin" 127.0.0.1 8096 || true; }

jellyfin_find_api_key() { :; }

# Device / headers / cookies helpers for Jellyfin
jf_ensure_device_id() {
  local f="${JARM_DIR:-$HOME/.jarm}/jellyfin_device_id.txt"
  if [[ -z "${JF_DEVICE_ID:-}" ]]; then
    if [[ -f "$f" ]]; then
      JF_DEVICE_ID="$(cat "$f" 2>/dev/null)"
    else
      if [[ -r /proc/sys/kernel/random/uuid ]]; then
        JF_DEVICE_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"
      else
        JF_DEVICE_ID="jarm-$(date +%s)-$RANDOM"
      fi
      mkdir -p "$(dirname "$f")" 2>/dev/null || true
      printf '%s\n' "$JF_DEVICE_ID" > "$f" 2>/dev/null || true
    fi
  fi
  export JF_DEVICE_ID
}

jf_build_auth_header() {
  printf 'Authorization: MediaBrowser Client=JARM, Device=JARM, DeviceId=%s, Version=1.0.0' "${JF_DEVICE_ID}"
}

jf_get() {
  local path="$1"; shift || true
  local auth_header; auth_header="$(jf_build_auth_header)"
  local args=(-sS -b "${JF_COOKIE_JAR:-}" -H "$auth_header")
  curl "${args[@]}" "$@" "http://127.0.0.1:8096$path"
}

jf_post_json() {
  local path="$1"; local data="$2"; shift 2 || true
  local auth_header; auth_header="$(jf_build_auth_header)"
  local args=(-sS -b "${JF_COOKIE_JAR:-}" -H "$auth_header" -H 'Content-Type: application/json')
  curl "${args[@]}" -d "$data" -X POST "$@" "http://127.0.0.1:8096$path"
}

jellyfin_configure() {
  # Strategy:
  # 1. If uninitialized, show URL and wait until user completes wizard and creates an account.
  # 2. Prompt for admin credentials regardless of RUN_NONINTERACTIVE.
  # 3. Attempt login and obtain token; if success, continue with locale and libraries.

  local cfg_dir="$CONFIG_PATH/configs/jellyfin"
  local users_file="$cfg_dir/data/users/users.json"
  local base_url="http://127.0.0.1:8096"

  # Helper: force prompt ignoring RUN_NONINTERACTIVE
  jellyfin_prompt_force() { # name label default
    local name="$1"; local label="$2"; local def="$3"; local val
    if [[ -n "$def" ]]; then
      read -r -p "$label [$def]: " val || true
      val="${val:-$def}"
    else
      read -r -p "$label: " val || true
    fi
    export "$name"="$val"
  }

  # Detect initialization; if not, guide and wait
  local initialized=0
  if [[ -f "$users_file" ]] && grep -q '"Id"' "$users_file" 2>/dev/null; then
    initialized=1
  else
    log "[jellyfin] Initial setup required. Open Jellyfin and create an admin user: $base_url"
    log "[jellyfin] Waiting for initial setup to complete (Ctrl+C to abort)..."
    while true; do
      # Check users.json presence or API flag
      if [[ -f "$users_file" ]] && grep -q '"Id"' "$users_file" 2>/dev/null; then
        initialized=1; break
      fi
      local public
      public=$(curl -sS "$base_url/emby/System/Info/Public" 2>/dev/null || true)
      if printf '%s' "$public" | grep -q '"StartupWizardCompleted":true'; then
        initialized=1; break
      fi
      sleep "${WAIT_INTERVAL:-2}"
    done
    log "[jellyfin] Detected completion of initial setup. Proceeding."
  fi

  # Prompt for admin credentials (do not persist between runs)
  prompt_var JELLYFIN_ADMIN_USER "Jellyfin admin username" ""
  prompt_var JELLYFIN_ADMIN_PASS "Jellyfin admin password" ""

  # Attempt login and obtain token
  local auth
  # Persist cookie jar so subsequent runs can reuse session if still valid
  JF_COOKIE_JAR="${JARM_DIR:-$HOME/.jarm}/jellyfin_cookies.txt"; rm -f "$JF_COOKIE_JAR" 2>/dev/null || true
  jf_ensure_device_id
  local auth_header; auth_header="$(jf_build_auth_header)"
  auth=$(curl -sS -c "$JF_COOKIE_JAR" -H "$auth_header" -H 'Content-Type: application/json' -d "{\"Username\":\"$JELLYFIN_ADMIN_USER\",\"Pw\":\"$JELLYFIN_ADMIN_PASS\"}" "$base_url/emby/Users/AuthenticateByName" || true)
  # Ensure SID/session cookie present; treat absence as failed auth
  if ! grep -q 'embyserver_' "$JF_COOKIE_JAR" 2>/dev/null && ! grep -q 'SID' "$JF_COOKIE_JAR" 2>/dev/null; then
    log "[jellyfin] authentication failed (no session cookie set); aborting configuration"
    return 0
  fi
  log "[jellyfin] authenticated and session cookie stored"

  # 2b. Skip locale/language configuration; user completes initial wizard themselves

  # 3. Ensure libraries Movies + TV Shows
  local libs
  libs=$(jf_get "/emby/Library/VirtualFolders") || true
  local need_movies=1 need_tv=1
  if echo "$libs" | grep -qi '"Name":"Movies"'; then need_movies=0; fi
  if echo "$libs" | grep -qi '"Name":"TV Shows"'; then need_tv=0; fi
  # Use container-visible paths (as mounted in compose):
  local movies_path="/media/movies" tv_path="/media/tv"
  if (( need_movies )) && [[ -d "$movies_path" ]]; then
    local movies_payload
    movies_payload=$(cat <<EOF
{
  "Name": "Movies",
  "CollectionType": "movies",
  "Paths": ["$movies_path"],
  "RefreshLibrary": true
}
EOF
)
    jf_post_json "/emby/Library/VirtualFolders" "$movies_payload" >/dev/null 2>&1 || true
    log "[jellyfin] created Movies library"
  else
    (( need_movies == 0 )) && log "[jellyfin] Movies library exists" || log "[jellyfin] movies path missing: $movies_path"
  fi
  if (( need_tv )) && [[ -d "$tv_path" ]]; then
    local tv_payload
    tv_payload=$(cat <<EOF
{
  "Name": "TV Shows",
  "CollectionType": "tvshows",
  "Paths": ["$tv_path"],
  "RefreshLibrary": true
}
EOF
)
    jf_post_json "/emby/Library/VirtualFolders" "$tv_payload" >/dev/null 2>&1 || true
    log "[jellyfin] created TV Shows library"
  else
    (( need_tv == 0 )) && log "[jellyfin] TV Shows library exists" || log "[jellyfin] tv path missing: $tv_path"
  fi

  # 4. Trigger library scan
  jf_post_json "/emby/Library/Refresh" '{}' >/dev/null 2>&1 || true
  log "[jellyfin] triggered library refresh"

  log "[jellyfin] configuration complete"
}