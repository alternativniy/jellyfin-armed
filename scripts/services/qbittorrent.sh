#!/usr/bin/env bash
set -euo pipefail

qbittorrent_ensure_dirs() { mkdir -p "$CONFIG_PATH/configs/qbittorrent"; }

qbittorrent_wait_ready() { wait_for_http "qbittorrent" "http://127.0.0.1:8080" || wait_for_tcp "qbittorrent" 127.0.0.1 8080 || true; }

qbittorrent_find_api_key() { :; }

qbittorrent_login() { # login <user> <pass>
	local user="${1:-${QB_USERNAME:-admin}}" pass="${2:-${QB_PASSWORD:-adminadmin}}"
	QB_COOKIE_JAR="$MODULE_ROOT/qbittorrent_cookies.txt"
	rm -f "$QB_COOKIE_JAR" 2>/dev/null || true
	local resp
	resp=$(curl -sS -c "$QB_COOKIE_JAR" -X POST -d "username=$user&password=$pass" http://127.0.0.1:8080/api/v2/auth/login || true)
	if [[ "$resp" != *"Ok."* ]] || ! grep -q SID "$QB_COOKIE_JAR" 2>/dev/null; then
		log "[qbittorrent] login failed for user '$user'"
		return 1
	fi
	export QB_COOKIE_JAR
	log "[qbittorrent] authenticated as $user"
}

qbittorrent_extract_initial_password() {
	# Attempt to parse initial/temporary password from container logs
	local raw
	raw=$(docker logs qbittorrent 2>&1 | tail -n 200 || true)
	# Common patterns: 'Web UI: username: admin password: xxxxxx' or 'Generated password: xxxxxx'
	local pw=""
	pw=$(echo "$raw" | grep -Eo 'password:?\s+[A-Za-z0-9!@#%^&_+=-]+' | tail -n1 | sed -E 's/.*password:?\s+//' || true)
	if [[ -n "$pw" ]]; then
		log "[qbittorrent] extracted initial password from logs"
		printf '%s\n' "$pw" > "${JARM_DIR:-/opt/jarm}/qbittorrent_initial_password.txt" 2>/dev/null || true
		chmod 600 "${JARM_DIR:-/opt/jarm}/qbittorrent_initial_password.txt" 2>/dev/null || true
		QB_INITIAL_PASSWORD="$pw"; export QB_INITIAL_PASSWORD
		return 0
	fi
	log "[qbittorrent] could not extract initial password"
	return 1
}

qbittorrent_change_password() { # change to QB_PASSWORD if differs
	local new_pw="${QB_PASSWORD:-adminadmin}" user="${QB_USERNAME:-admin}"
	[[ -z "${QB_COOKIE_JAR:-}" ]] && { log "[qbittorrent] cannot change password: not authenticated"; return 1; }
	# Set new password via preferences API (web_ui_password key)
	local json
	json="{\"web_ui_password\":\"$new_pw\",\"web_ui_username\":\"$user\"}"
	curl -sS -b "$QB_COOKIE_JAR" -X POST -d "json=$json" http://127.0.0.1:8080/api/v2/app/setPreferences >/dev/null 2>&1 || true
	printf '%s\n' "$new_pw" > "${JARM_DIR:-/opt/jarm}/qbittorrent_password.txt" 2>/dev/null || true
	chmod 600 "${JARM_DIR:-/opt/jarm}/qbittorrent_password.txt" 2>/dev/null || true
	log "[qbittorrent] password updated and stored at ${JARM_DIR:-/opt/jarm}/qbittorrent_password.txt"
}

qbittorrent_set_preferences() {
	[[ -z "${QB_COOKIE_JAR:-}" ]] && qbittorrent_login || true
	[[ -z "${QB_COOKIE_JAR:-}" ]] && { log "[qbittorrent] cannot set preferences without auth"; return 1; }
	local base_download="${DOWNLOAD_PATH:-/downloads}"
	mkdir -p "$base_download/tv" "$base_download/movies"
	# Preferences: save path + enable automatic torrent management
	local prefs_json="{\"save_path\":\"$base_download\",\"auto_tmm_enabled\":true,\"temp_path_enabled\":false}"
	curl -sS -b "$QB_COOKIE_JAR" -X POST -d "json=$prefs_json" http://127.0.0.1:8080/api/v2/app/setPreferences >/dev/null 2>&1 || true
	# Create categories with per-category save paths
	for cat in tv movies; do
		curl -sS -b "$QB_COOKIE_JAR" -X POST -d "category=$cat&savePath=$base_download/$cat" http://127.0.0.1:8080/api/v2/torrents/createCategory >/dev/null 2>&1 || true
	done
	log "[qbittorrent] preferences applied (auto management + categories)"
}

qbittorrent_configure() {
	# Try normal login first
	if ! qbittorrent_login "${QB_USERNAME:-admin}" "${QB_PASSWORD:-adminadmin}"; then
		log "[qbittorrent] primary login failed; attempting to extract initial password from logs"
		qbittorrent_extract_initial_password || true
		if [[ -n "${QB_INITIAL_PASSWORD:-}" ]]; then
			qbittorrent_login "${QB_USERNAME:-admin}" "$QB_INITIAL_PASSWORD" || true
			if [[ -n "${QB_COOKIE_JAR:-}" ]]; then
				qbittorrent_change_password || true
			fi
		else
			log "[qbittorrent] no initial password found; skipping password change"
		fi
	fi
	# Apply preferences (requires authenticated session)
	qbittorrent_set_preferences || true
}
