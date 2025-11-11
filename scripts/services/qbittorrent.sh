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
	# Supports multiple message formats from linuxserver/qbittorrent
	local cname="${QBIT_CONTAINER_NAME:-qbittorrent}"
	local raw pw=""
	raw=$(docker logs "$cname" 2>&1 | tail -n 400 || true)

	# Pattern 1 (new): "A temporary password is provided for this session: <PASS>"
	pw=$(printf '%s\n' "$raw" | sed -nE 's/.*provided for this session:[[:space:]]*([^[:space:]]+).*/\1/p' | tail -n1)

	# Pattern 2: "WebUI ... password ...: <PASS>" (various wordings)
	if [[ -z "$pw" ]]; then
		pw=$(printf '%s\n' "$raw" | sed -nE 's/.*[Pp]assword[^:]*:[[:space:]]*([^[:space:]]+).*/\1/p' | tail -n1)
	fi

	# Pattern 3: "Generated password: <PASS>" or "admin password is: <PASS>"
	if [[ -z "$pw" ]]; then
		pw=$(printf '%s\n' "$raw" | sed -nE 's/.*(Generated password|admin password is):[[:space:]]*([^[:space:]]+).*/\2/p' | tail -n1)
	fi

	# Basic sanity: restrict to printable non-space, 4-128 chars
	if [[ -n "$pw" && ${#pw} -ge 4 && ${#pw} -le 128 ]]; then
		log "[qbittorrent] extracted initial password from logs"
		local out="${JARM_DIR:-$HOME/.jarm}/qbittorrent_initial_password.txt"
		mkdir -p "$(dirname "$out")" 2>/dev/null || true
		printf '%s\n' "$pw" > "$out" 2>/dev/null || true
		chmod 600 "$out" 2>/dev/null || true
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
	printf '%s\n' "$new_pw" > "${JARM_DIR:-$HOME/.jarm}/qbittorrent_password.txt" 2>/dev/null || true
	chmod 600 "${JARM_DIR:-$HOME/.jarm}/qbittorrent_password.txt" 2>/dev/null || true
	log "[qbittorrent] password updated and stored at ${JARM_DIR:-$HOME/.jarm}/qbittorrent_password.txt"
}

qbittorrent_set_preferences() {
	[[ -z "${QB_COOKIE_JAR:-}" ]] && qbittorrent_login || true
	[[ -z "${QB_COOKIE_JAR:-}" ]] && { log "[qbittorrent] cannot set preferences without auth"; return 1; }
	local base_download="/downloads"
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

qbittorrent_prompt_credentials() {
  # Only prompt if we still failed automatic methods and have a TTY
  if [[ -e /dev/tty && -r /dev/tty ]]; then
    printf "qBittorrent WebUI available at: http://127.0.0.1:8080\n" > /dev/tty
    printf "Automatic authentication failed. Please enter credentials to proceed.\n" > /dev/tty
    printf "Username [admin]: " > /dev/tty; IFS= read -r QB_USERNAME < /dev/tty || true; QB_USERNAME="${QB_USERNAME:-admin}"; export QB_USERNAME
    printf "Password [adminadmin]: " > /dev/tty; IFS= read -r QB_PASSWORD < /dev/tty || true; QB_PASSWORD="${QB_PASSWORD:-adminadmin}"; export QB_PASSWORD
  else
    log "[qbittorrent] Automatic auth failed and no TTY to prompt; set QB_USERNAME/QB_PASSWORD env and re-run config"
  fi
}

qbittorrent_configure() {
	# Attempt automatic authentication strategies in order:
	# 1. Existing saved password file
	local pw_file="${JARM_DIR:-$HOME/.jarm}/qbittorrent_password.txt"
	if [[ -f "$pw_file" ]]; then
		QB_PASSWORD="$(cat "$pw_file" 2>/dev/null)"; export QB_PASSWORD
		qbittorrent_login "${QB_USERNAME:-admin}" "$QB_PASSWORD" || true
	fi

	# 2. Default credentials (admin/adminadmin)
	if [[ -z "${QB_COOKIE_JAR:-}" ]]; then
		qbittorrent_login "${QB_USERNAME:-admin}" "${QB_PASSWORD:-adminadmin}" || true
	fi

	# 3. Extract initial password from logs and try login
	if [[ -z "${QB_COOKIE_JAR:-}" ]]; then
		log "[qbittorrent] trying to extract temporary initial password from logs"
		qbittorrent_extract_initial_password || true
		if [[ -n "${QB_INITIAL_PASSWORD:-}" ]]; then
			qbittorrent_login "${QB_USERNAME:-admin}" "$QB_INITIAL_PASSWORD" || true
			# If we authenticated using initial password, change to stored or default
			if [[ -n "${QB_COOKIE_JAR:-}" ]]; then
				qbittorrent_change_password || true
			fi
		fi
	fi

	# 4. If still not authenticated, interactively prompt user once
	if [[ -z "${QB_COOKIE_JAR:-}" ]]; then
		qbittorrent_prompt_credentials
		if [[ -n "${QB_USERNAME:-}" && -n "${QB_PASSWORD:-}" ]]; then
			qbittorrent_login "$QB_USERNAME" "$QB_PASSWORD" || true
			if [[ -n "${QB_COOKIE_JAR:-}" ]]; then
				qbittorrent_change_password || true
			fi
		fi
	fi

	if [[ -z "${QB_COOKIE_JAR:-}" ]]; then
		log "[qbittorrent] all authentication attempts failed; skipping preference configuration"
		return 0
	fi

	# Apply preferences (requires authenticated session)
	qbittorrent_set_preferences || true
}
