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
  # Build Authorization header with quoted values; include Token if available
  local client="JArm" device="JArm" version="1.0.0"
  if [[ -n "${JELLYFIN_TOKEN:-}" ]]; then
    printf 'Authorization: MediaBrowser Client="%s", Device="%s", DeviceId="%s", Version="%s", Token="%s"' "$client" "$device" "${JF_DEVICE_ID}" "$version" "${JELLYFIN_TOKEN}"
  else
    printf 'Authorization: MediaBrowser Client="%s", Device="%s", DeviceId="%s", Version="%s"' "$client" "$device" "${JF_DEVICE_ID}" "$version"
  fi
}

jf_get() {
  local path="$1"; shift || true
  local auth_header; auth_header="$(jf_build_auth_header)"
  curl -sS -H "$auth_header" "$@" "http://127.0.0.1:8096$path"
}

jf_post_json() {
  local path="$1"; local data="$2"; shift 2 || true
  local auth_header; auth_header="$(jf_build_auth_header)"
  curl -sS -H "$auth_header" -H 'Content-Type: application/json' -d "$data" -X POST "$@" "http://127.0.0.1:8096$path"
}

jellyfin_configure() {
  # Strategy:
  # 1. If uninitialized, show URL and wait until user completes wizard and creates an account.
  # 2. Prompt for admin credentials regardless of RUN_NONINTERACTIVE.
  # 3. Attempt login and obtain token; if success, continue with locale and libraries.

  local cfg_dir="$CONFIG_PATH/configs/jellyfin"
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

  # Detect completion of initial setup via StartupWizardCompleted flag.
  local initialized=0 start_ts=$SECONDS last_log=$SECONDS public
  public=$(curl -sS "$base_url/System/Info/Public" 2>/dev/null || true)
  if printf '%s' "$public" | grep -q '"StartupWizardCompleted":true'; then
    initialized=1
    log "[jellyfin] Initial setup already completed"
  else
    log "[jellyfin] Initial setup not finished yet. Complete the wizard at $base_url (timeout: ${WAIT_TIMEOUT:-180}s)"
    while (( initialized == 0 )); do
      public=$(curl -sS "$base_url/System/Info/Public" 2>/dev/null || true)
      if printf '%s' "$public" | grep -q '"StartupWizardCompleted":true'; then
        initialized=1; break
      fi
      if (( SECONDS - start_ts >= ${WAIT_TIMEOUT:-180} )); then
        log "[jellyfin] timeout waiting for wizard completion; proceeding anyway"
        break
      fi
      if (( SECONDS - last_log >= 30 )); then
        log "[jellyfin] still waiting for StartupWizardCompleted=true"
        last_log=$SECONDS
      fi
      sleep "${WAIT_INTERVAL:-2}"
    done
    (( initialized )) && log "[jellyfin] Initial setup completed" || true
  fi

  # Always prompt for credentials and obtain a fresh token (token is session-scoped; do not persist)
  prompt_var JELLYFIN_ADMIN_USER "Jellyfin admin username" ""
  prompt_var JELLYFIN_ADMIN_PASS "Jellyfin admin password" ""

  jf_ensure_device_id
  # Ensure AuthenticateByName is called without Token in header
  unset JELLYFIN_TOKEN || true
  local auth_header; auth_header="$(jf_build_auth_header)"
  local auth
  auth=$(curl -sS -H "$auth_header" -H 'Content-Type: application/json' -d "{\"Username\":\"$JELLYFIN_ADMIN_USER\",\"Pw\":\"$JELLYFIN_ADMIN_PASS\"}" "$base_url/Users/AuthenticateByName" || true)
  JELLYFIN_TOKEN=$(echo "$auth" | grep -oE '"AccessToken":"[^\"]+"' | sed -E 's/.*:"([^\"]+)"/\1/' | tr -d '\r\n' || true)
  if [[ -z "${JELLYFIN_TOKEN:-}" ]]; then
    log "[jellyfin] authentication failed (no AccessToken in response); aborting configuration"
    return 0
  fi
  export JELLYFIN_TOKEN
  log "[jellyfin] authenticated (token acquired)"

  # 2b. Skip locale/language configuration; user completes initial wizard themselves

  # 3. Ensure libraries Movies + TV Shows
  local libs
  libs=$(jf_get "/Library/VirtualFolders") || true
  local need_movies=1 need_tv=1
  if echo "$libs" | grep -Eqi '"Name":"Movies"|"name":"Movies"'; then need_movies=0; fi
  if echo "$libs" | grep -Eqi '"Name":"TV Shows"|"name":"TV Shows"'; then need_tv=0; fi

  local movies_path="$MEDIA_PATH/movies" tv_path="$MEDIA_PATH/tv"
  if (( need_movies )) && [[ -d "$movies_path" ]]; then
    jf_post_json "/Library/VirtualFolders?name=Movies&collectionType=movies&paths=/media/movies&refreshLibrary=true" '{}' >/dev/null 2>&1 || true
    log "[jellyfin] created Movies library"
  else
    (( need_movies == 0 )) && log "[jellyfin] Movies library exists" || log "[jellyfin] movies path missing: $movies_path"
  fi
  if (( need_tv )) && [[ -d "$tv_path" ]]; then
    jf_post_json "/Library/VirtualFolders?name=TV%20Shows&collectionType=tvshows&paths=/media/tv&refreshLibrary=true" '{}' >/dev/null 2>&1 || true
    log "[jellyfin] created TV Shows library"
  else
    (( need_tv == 0 )) && log "[jellyfin] TV Shows library exists" || log "[jellyfin] tv path missing: $tv_path"
  fi

  # 4. Trigger library scan
  jf_post_json "/Library/Refresh" '{}' >/dev/null 2>&1 || true
  log "[jellyfin] triggered library refresh"

  log "[jellyfin] configuration complete"
}