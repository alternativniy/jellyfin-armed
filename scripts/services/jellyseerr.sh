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
    # No API key provided; we'll attempt auth-based initialization instead
    log "[jellyseerr] no API key provided; will attempt Jellyfin auth to bootstrap"
  fi
  local base="http://127.0.0.1:5055/api/v1"; local header=()
  # Helper wrappers
  js_get() { local p="$1"; shift; curl -sS "${header[@]}" "$@" "$base$p"; }
  js_post() { local p="$1"; local data="$2"; shift 2; curl -sS -H 'Content-Type: application/json' "${header[@]}" -d "$data" -X POST "$base$p"; }

  # Decide whether we must authenticate: probe API with an API key if available.
  local candidate_key="${k-}"
  if [[ -z "$candidate_key" ]]; then candidate_key="$(jellyseerr_find_api_key || true)"; fi
  local api_status=""
  if [[ -n "$candidate_key" ]]; then
    api_status=$(curl -sS -o /dev/null -w '%{http_code}' -H "X-Api-Key: $candidate_key" "$base/settings/jellyfin" || true)
  fi

  if [[ "$api_status" =~ ^2 ]]; then
    # API key works; no need to authenticate via Jellyfin
    header=( -H "X-Api-Key: $candidate_key" )
    log "[jellyseerr] API key validated; skipping Jellyfin auth"
  else
    # Need to authenticate via Jellyfin to create initial user / obtain token
    if [[ -z "${JELLYFIN_ADMIN_USER-}" ]]; then prompt_var JELLYFIN_ADMIN_USER "Jellyfin admin username" "admin"; fi
    if [[ -z "${JELLYFIN_ADMIN_PASS-}" ]]; then prompt_var JELLYFIN_ADMIN_PASS "Jellyfin admin password"; fi
    if [[ -z "${JELLYSEERR_ADMIN_EMAIL-}" ]]; then prompt_var JELLYSEERR_ADMIN_EMAIL "Jellyseerr admin email"; fi

    # Derive host/port/ssl/urlBase from JELLYFIN_URL if available
    local auth_url auth_scheme auth_host auth_port auth_path auth_use_ssl auth_url_base
    auth_url="${JELLYFIN_URL:-http://jellyfin:8096}"
    auth_scheme="http"; auth_host="jellyfin"; auth_port="8096"; auth_path=""; auth_use_ssl=false; auth_url_base=""
    if [[ "$auth_url" =~ ^(https?)://([^/:]+)(:([0-9]+))?(/.*)?$ ]]; then
      auth_scheme="${BASH_REMATCH[1]}"; auth_host="${BASH_REMATCH[2]}"; auth_port="${BASH_REMATCH[4]:-}"; auth_path="${BASH_REMATCH[5]:-}"
    fi
    if [[ -z "$auth_port" ]]; then
      if [[ "$auth_scheme" == "https" ]]; then auth_port="443"; else auth_port="80"; fi
    fi
    if [[ "$auth_scheme" == "https" ]]; then auth_use_ssl=true; else auth_use_ssl=false; fi
    if [[ -n "$auth_path" && "$auth_path" != "/" ]]; then
      auth_url_base="${auth_path%/}"
    else
      auth_url_base=""
    fi

    local login_payload login_resp token
    login_payload=$(cat <<EOF
{
  "username": "${JELLYFIN_ADMIN_USER}",
  "password": "${JELLYFIN_ADMIN_PASS}",
  "hostname": "${auth_host}",
  "port": ${auth_port},
  "useSsl": ${auth_use_ssl},
  "urlBase": "${auth_url_base}",
  "email": "${JELLYSEERR_ADMIN_EMAIL}",
  "serverType": 2
}
EOF
)
    login_resp=$(curl -sS -H 'Content-Type: application/json' -d "$login_payload" -X POST "$base/auth/jellyfin" || true)
    token=$(echo "$login_resp" | grep -oE '"(token|accessToken)"\s*:\s*"[^"]+"' | sed -E 's/.*:\s*"([^"]+)"/\1/' | head -n1 || true)
    if [[ -n "$token" ]]; then
      header=( -H "Authorization: Bearer $token" )
      log "[jellyseerr] authenticated via Jellyfin; token acquired"
    else
      log "[jellyseerr] ERROR: Jellyfin auth failed and API key is not valid; cannot configure Jellyseerr"
      return 0
    fi
  fi

  # Track completion flags
  local sonarr_ok=0 radarr_ok=0 jellyfin_ok=0

  # 1) Sync and enable all Jellyfin libraries (requires auth)
  local libs_json ids_csv=""
  libs_json=$(js_get "/settings/jellyfin/library?sync=true" || true)
  if [[ -n "$libs_json" ]]; then
    if command -v jq >/dev/null 2>&1; then
      ids_csv=$(echo "$libs_json" | jq -r '.[].id' | paste -sd, - | sed 's/ //g' || true)
    else
      ids_csv=$(echo "$libs_json" | grep -oE '"id"\s*:\s*"[^"]+"' | sed -E 's/.*:\s*"([^"]+)"/\1/' | paste -sd, - | sed 's/ //g' || true)
    fi
  fi
  if [[ -n "$ids_csv" ]]; then
    js_get "/settings/jellyfin/library?enable=$ids_csv" || true
    jellyfin_ok=1
    log "[jellyseerr] enabled Jellyfin libraries: $(echo "$ids_csv" | sed 's/,/, /g')"
  else
    # If there are no libraries, still consider Jellyfin reachable
    jellyfin_ok=1
    log "[jellyseerr] no Jellyfin libraries found to enable (or parse failed)"
  fi

  # 2) Add Sonarr and Radarr as applications in Jellyseerr
  local sonarr_key="" radarr_key="" keys_file
  keys_file="${OUTPUT_KEYS_FILE}"
  if [[ -f "$keys_file" ]]; then
    sonarr_key=$(grep -oE '"sonarr":\s*\{"apiKey":\s*"[^"]+"' "$keys_file" | sed -E 's/.*"apiKey":\s*"([^"]+)"/\1/' || true)
    radarr_key=$(grep -oE '"radarr":\s*\{"apiKey":\s*"[^"]+"' "$keys_file" | sed -E 's/.*"apiKey":\s*"([^"]+)"/\1/' || true)
  fi

  # Only proceed with Radarr/Sonarr after Jellyfin is configured
  if [[ $jellyfin_ok -eq 1 ]]; then
    # Sonarr config
    local sonarr_list; sonarr_list=$(js_get "/settings/sonarr" || true)
    if [[ "$sonarr_list" != *"hostname"* && -n "$sonarr_key" ]]; then
      # Probe Sonarr to get profiles, language profiles and root folders
      local s_host s_port s_ssl s_base st_payload st_resp s_profile_id s_profile_name s_lang_profile_id s_anime_profile_id s_anime_lang_profile_id s_anime_profile_name s_active_dir s_anime_dir
      s_host="${SONARR_HOST:-sonarr}"
      s_port=${SONARR_PORT:-8989}
      s_ssl=${SONARR_USE_SSL:-false}
      s_base="${SONARR_BASE_URL:-}"
      st_payload=$(cat <<EOF
{
  "hostname": "${s_host}",
  "port": ${s_port},
  "apiKey": "${sonarr_key}",
  "useSsl": ${s_ssl},
  "baseUrl": "${s_base}"
}
EOF
)
      st_resp=$(js_post "/settings/sonarr/test" "$st_payload" || true)
      if command -v jq >/dev/null 2>&1; then
        s_profile_id=$(echo "$st_resp" | jq -r '.profiles[0].id // empty')
        s_profile_name=$(echo "$st_resp" | jq -r '.profiles[0].name // empty')
        s_lang_profile_id=$(echo "$st_resp" | jq -r '.languageProfiles[0].id // empty')
        s_anime_profile_id=$(echo "$st_resp" | jq -r '.animeProfiles[0].id // empty')
        s_anime_lang_profile_id=$(echo "$st_resp" | jq -r '.animeLanguageProfiles[0].id // empty')
        s_anime_profile_name=$(echo "$st_resp" | jq -r '.animeProfiles[0].name // empty')
        s_active_dir=$(echo "$st_resp" | jq -r '.rootFolders[0].path // empty')
        s_anime_dir=$(echo "$st_resp" | jq -r '.animeRootFolders[0].path // empty')
      else
        s_profile_id=$(echo "$st_resp" | grep -oE '"id"\s*:\s*[0-9]+' | head -n1 | sed -E 's/[^0-9]//g' || true)
        s_profile_name=$(echo "$st_resp" | grep -oE '"name"\s*:\s*"[^"]+"' | head -n1 | sed -E 's/.*:\s*"([^"]+)"/\1/' || true)
        s_lang_profile_id="1"
        s_anime_profile_id="0"
        s_anime_lang_profile_id="0"
        s_anime_profile_name="$s_profile_name"
        s_active_dir=$(echo "$st_resp" | grep -oE '"path"\s*:\s*"[^"]+"' | head -n1 | sed -E 's/.*:\s*"([^"]+)"/\1/' || true)
        s_anime_dir=""
      fi
      # Fallbacks if probe didn't return expected fields
      s_profile_id=${s_profile_id:-1}
      s_profile_name=${s_profile_name:-Default}
      s_lang_profile_id=${s_lang_profile_id:-1}
      s_anime_profile_id=${s_anime_profile_id:-0}
      s_anime_lang_profile_id=${s_anime_lang_profile_id:-0}
      s_anime_profile_name=${s_anime_profile_name:-$s_profile_name}
      if [[ -z "$s_active_dir" ]]; then
        if [[ -n "${MEDIA_PATH:-}" ]]; then s_active_dir="${MEDIA_PATH%/}/tv"; else s_active_dir="/tv"; fi
      fi
      if [[ -z "$s_anime_dir" ]]; then
        if [[ -n "${MEDIA_PATH:-}" ]]; then s_anime_dir="${MEDIA_PATH%/}/tv/anime"; else s_anime_dir="/tv/anime"; fi
      fi

      local s_payload
      s_payload=$(cat <<EOF
{
  "name": "Sonarr",
  "hostname": "${s_host}",
  "port": ${s_port},
  "apiKey": "${sonarr_key}",
  "useSsl": ${s_ssl},
  "baseUrl": "${s_base}",
  "activeProfileId": ${s_profile_id},
  "activeProfileName": "${s_profile_name}",
  "activeDirectory": "${s_active_dir}",
  "activeLanguageProfileId": ${s_lang_profile_id},
  "activeAnimeProfileId": ${s_anime_profile_id},
  "activeAnimeLanguageProfileId": ${s_anime_lang_profile_id},
  "activeAnimeProfileName": "${s_anime_profile_name}",
  "activeAnimeDirectory": "${s_anime_dir}",
  "is4k": false,
  "enableSeasonFolders": false,
  "isDefault": true,
  "externalUrl": "${SONARR_EXTERNAL_URL:-}",
  "syncEnabled": false,
  "preventSearch": false
}
EOF
)
      js_post "/settings/sonarr" "$s_payload" >/dev/null 2>&1 || true
      # verify
      sonarr_list=$(js_get "/settings/sonarr" || true)
      if [[ "$sonarr_list" == *"hostname"* ]]; then
        sonarr_ok=1; log "[jellyseerr] added Sonarr connection (profile ${s_profile_id}: ${s_profile_name})"
      else
        log "[jellyseerr] failed to add Sonarr connection"
      fi
    else
      if [[ "$sonarr_list" == *"hostname"* ]]; then
        sonarr_ok=1; log "[jellyseerr] Sonarr connection already present"
      else
        [[ -z "$sonarr_key" ]] && log "[jellyseerr] sonarr api key missing; skip sonarr setup"
      fi
    fi

    # Radarr config
    local radarr_list; radarr_list=$(js_get "/settings/radarr" || true)
    if [[ "$radarr_list" != *"hostname"* && -n "$radarr_key" ]]; then
      # Probe Radarr to get profiles and root folders
      local r_host r_port r_ssl r_base test_payload test_resp profile_id profile_name active_dir
      r_host="${RADARR_HOST:-radarr}"
      r_port=${RADARR_PORT:-7878}
      r_ssl=${RADARR_USE_SSL:-false}
      r_base="${RADARR_BASE_URL:-}"
      test_payload=$(cat <<EOF
{
  "hostname": "${r_host}",
  "port": ${r_port},
  "apiKey": "${radarr_key}",
  "useSsl": ${r_ssl},
  "baseUrl": "${r_base}"
}
EOF
)
      test_resp=$(js_post "/settings/radarr/test" "$test_payload" || true)
      if command -v jq >/dev/null 2>&1; then
        profile_id=$(echo "$test_resp" | jq -r '.profiles[0].id // empty')
        profile_name=$(echo "$test_resp" | jq -r '.profiles[0].name // empty')
        active_dir=$(echo "$test_resp" | jq -r '.rootFolders[0].path // empty')
      else
        profile_id=$(echo "$test_resp" | grep -oE '"id"\s*:\s*[0-9]+' | head -n1 | sed -E 's/[^0-9]//g' || true)
        profile_name=$(echo "$test_resp" | grep -oE '"name"\s*:\s*"[^"]+"' | head -n1 | sed -E 's/.*:\s*"([^"]+)"/\1/' || true)
        active_dir=$(echo "$test_resp" | grep -oE '"path"\s*:\s*"[^"]+"' | head -n1 | sed -E 's/.*:\s*"([^"]+)"/\1/' || true)
      fi
      # Fallbacks if probe didn't return expected fields
      profile_id=${profile_id:-1}
      profile_name=${profile_name:-Default}
      if [[ -z "$active_dir" ]]; then
        if [[ -n "${MEDIA_PATH:-}" ]]; then active_dir="${MEDIA_PATH%/}/movies"; else active_dir="/movies"; fi
      fi

      local r_payload
      r_payload=$(cat <<EOF
{
  "name": "Radarr",
  "hostname": "${r_host}",
  "port": ${r_port},
  "apiKey": "${radarr_key}",
  "useSsl": ${r_ssl},
  "baseUrl": "${r_base}",
  "activeProfileId": ${profile_id},
  "activeProfileName": "${profile_name}",
  "activeDirectory": "${active_dir}",
  "is4k": false,
  "minimumAvailability": "Released",
  "isDefault": true,
  "externalUrl": "${RADARR_EXTERNAL_URL:-}",
  "syncEnabled": false,
  "preventSearch": false
}
EOF
)
      js_post "/settings/radarr" "$r_payload" >/dev/null 2>&1 || true
      # verify
      radarr_list=$(js_get "/settings/radarr" || true)
      if [[ "$radarr_list" == *"hostname"* ]]; then
        radarr_ok=1; log "[jellyseerr] added Radarr connection (profile ${profile_id}: ${profile_name})"
      else
        log "[jellyseerr] failed to add Radarr connection"
      fi
    else
      if [[ "$radarr_list" == *"hostname"* ]]; then
        radarr_ok=1; log "[jellyseerr] Radarr connection already present"
      else
        [[ -z "$radarr_key" ]] && log "[jellyseerr] radarr api key missing; skip radarr setup"
      fi
    fi
  else
    log "[jellyseerr] Skipping Sonarr/Radarr setup until Jellyfin is configured"
  fi

  # 3) If all connections are present, mark initialization complete
  if [[ $sonarr_ok -eq 1 && $radarr_ok -eq 1 && $jellyfin_ok -eq 1 ]]; then
    js_post "/settings/initialize" '{}' >/dev/null 2>&1 || true
    log "[jellyseerr] initialization marked complete"
  fi
}
