#!/usr/bin/env bash
set -euo pipefail

jellyfin_ensure_dirs() {
  mkdir -p "$CONFIG_PATH/configs/jellyfin"
  mkdir -p "$CONFIG_PATH/jellyfin/cache"
}

jellyfin_wait_ready() { wait_for_http "jellyfin" "http://127.0.0.1:8096" || wait_for_tcp "jellyfin" 127.0.0.1 8096 || true; }

jellyfin_find_api_key() { :; }

# Internal: perform authenticated request (requires JELLYFIN_TOKEN)
jf_get() { local path="$1"; curl -sS -H "X-Emby-Token: $JELLYFIN_TOKEN" "http://127.0.0.1:8096$path"; }
jf_post_json() { local path="$1"; local data="$2"; curl -sS -H "Content-Type: application/json" -H "X-Emby-Token: $JELLYFIN_TOKEN" -d "$data" -X POST "http://127.0.0.1:8096$path"; }

jellyfin_configure() {
  # Goal: ensure an admin user exists and libraries (Movies, TV Shows) are created.
  # 1. Determine if system already initialized.
  local cfg_dir="$CONFIG_PATH/configs/jellyfin"; local users_file="$cfg_dir/data/users/users.json"
  if [[ -f "$users_file" ]] && grep -q '"Id"' "$users_file"; then
    log "[jellyfin] users file present — assuming initialized"
  else
    log "[jellyfin] no users.json found — attempting initial admin creation"
    # Collect admin credentials (prompt if interactive, fallback defaults)
    if [[ -z "${JELLYFIN_ADMIN_USER:-}" ]]; then JELLYFIN_ADMIN_USER="admin"; fi
    if [[ -z "${JELLYFIN_ADMIN_PASS:-}" ]]; then JELLYFIN_ADMIN_PASS="adminadmin"; fi
    if [[ "${RUN_NONINTERACTIVE:-0}" != "1" ]]; then
      prompt_var JELLYFIN_ADMIN_USER "Jellyfin admin username" "admin"
      prompt_var JELLYFIN_ADMIN_PASS "Jellyfin admin password" "adminadmin"
    fi
    # Jellyfin doesn't offer a simple unauthenticated user creation API once wizard done; attempt wizard endpoints.
    # Try QuickConnect style: fetch system info to decide stage.
    local public
    public=$(curl -sS "http://127.0.0.1:8096/emby/System/Info/Public" || true)
    if [[ -n "$public" ]]; then
      # Attempt to create user via /emby/Users/New
      local new_payload
      new_payload=$(cat <<EOF
{
  "Name": "$JELLYFIN_ADMIN_USER",
  "Password": "$JELLYFIN_ADMIN_PASS"
}
EOF
)
      curl -sS -H 'Content-Type: application/json' -d "$new_payload" -X POST "http://127.0.0.1:8096/emby/Users/New" >/dev/null 2>&1 || true
      log "[jellyfin] attempted admin user creation"
    fi
  fi

  # 2. Obtain authentication token (login)
  if [[ -z "${JELLYFIN_ADMIN_USER:-}" ]]; then JELLYFIN_ADMIN_USER="admin"; fi
  if [[ -z "${JELLYFIN_ADMIN_PASS:-}" ]]; then JELLYFIN_ADMIN_PASS="adminadmin"; fi
  local auth
  auth=$(curl -sS -X POST -H 'Content-Type: application/json' -d "{\"Username\":\"$JELLYFIN_ADMIN_USER\",\"Pw\":\"$JELLYFIN_ADMIN_PASS\"}" "http://127.0.0.1:8096/emby/Users/authenticatebyname" || true)
  JELLYFIN_TOKEN=$(echo "$auth" | grep -oE '"AccessToken":"[^"]+"' | sed -E 's/.*:"([^"]+)"/\1/' || true)
  if [[ -z "$JELLYFIN_TOKEN" ]]; then
    log "[jellyfin] authentication failed; cannot configure"
    return 0
  fi
  export JELLYFIN_TOKEN
  printf '%s\n' "$JELLYFIN_TOKEN" > "${JARM_DIR:-/opt/jarm}/jellyfin_token.txt" 2>/dev/null || true
  chmod 600 "${JARM_DIR:-/opt/jarm}/jellyfin_token.txt" 2>/dev/null || true
  log "[jellyfin] obtained token and stored"

  # 2b. Configure locale and metadata language
  if [[ -z "${JELLYFIN_LANG:-}" ]]; then JELLYFIN_LANG="en-US"; fi
  if [[ "${RUN_NONINTERACTIVE:-0}" != "1" ]]; then
    prompt_var JELLYFIN_LANG "Jellyfin language/locale (e.g., en-US, ru-RU)" "en-US"
  fi
  local lang_ui="$JELLYFIN_LANG"
  local meta_lang country
  meta_lang="${JELLYFIN_LANG%%-*}"; country="${JELLYFIN_LANG#*-}"; [[ "$meta_lang" == "$country" ]] && country="US"
  # System configuration: PreferredMetadataLanguage, MetadataCountryCode
  local syscfg
  syscfg=$(jf_get "/emby/System/Configuration" || true)
  if [[ -n "$syscfg" ]]; then
    local sys_modified
    sys_modified=$(printf "%s" "$syscfg" \
      | sed -E "s/\"PreferredMetadataLanguage\":\"[^\"]*\"/\"PreferredMetadataLanguage\":\"$meta_lang\"/" \
      | sed -E "s/\"MetadataCountryCode\":\"[^\"]*\"/\"MetadataCountryCode\":\"$country\"/")
    jf_post_json "/emby/System/Configuration" "$sys_modified" >/dev/null 2>&1 || true
    log "[jellyfin] set metadata language=$meta_lang, country=$country"
  else
    log "[jellyfin] could not fetch system configuration for locale"
  fi
  # User display language
  local users_json user_id
  users_json=$(jf_get "/emby/Users" || true)
  user_id=$(echo "$users_json" | grep -oE "\{[^}]*\"Name\":\"$JELLYFIN_ADMIN_USER\"[^}]*\"Id\":\"[^\"]+\"" | sed -E 's/.*"Id":"([^"]+)"/\1/' | head -n1 || true)
  if [[ -n "$user_id" ]]; then
    local ucfg ucfg_mod
    ucfg=$(jf_get "/emby/Users/$user_id/Configuration" || true)
    if [[ -n "$ucfg" ]]; then
      ucfg_mod=$(printf "%s" "$ucfg" | sed -E "s/\"DisplayLanguage\":\"[^\"]*\"/\"DisplayLanguage\":\"$lang_ui\"/")
      jf_post_json "/emby/Users/$user_id/Configuration" "$ucfg_mod" >/dev/null 2>&1 || true
      log "[jellyfin] set user display language to $lang_ui"
    else
      log "[jellyfin] could not fetch user configuration for $JELLYFIN_ADMIN_USER"
    fi
  else
    log "[jellyfin] admin user id not found; skip user locale"
  fi
  printf '%s\n' "$JELLYFIN_LANG" > "${JARM_DIR:-/opt/jarm}/jellyfin_language.txt" 2>/dev/null || true

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