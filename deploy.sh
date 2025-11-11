#!/usr/bin/env bash
set -euo pipefail

# Bootstrap launcher: loads modular scripts, collects variables (interactive),
# and performs stack operations.

# Resolve script root robustly (works for local file or stdin via pipe)
if [[ -n "${BASH_SOURCE:-}" && -n "${BASH_SOURCE[0]:-}" ]]; then
    ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null || pwd)"
elif [[ -n "${0:-}" && "${0}" != "-" ]]; then
    ROOT_DIR="$(cd "$(dirname "${0}")" 2>/dev/null || pwd)"
else
    ROOT_DIR="$PWD"
fi
REMOTE_BASE="${REMOTE_BASE:-https://raw.githubusercontent.com/alternativniy/jellyfin-armed/main}" # Optionally set to https://raw.githubusercontent.com/<org>/<repo>/<branch>
# Create a temporary module root that will always be cleaned up
MODULE_ROOT="$(mktemp -d -t jellyarmed.XXXXXX)"
WORK_DIR="$PWD"
# Optional persistent work dir for user artifacts (final compose, etc.)
# Default to a user-writable location to avoid requiring root
JARM_DIR="${JARM_DIR:-$HOME/.jarm}"
CONFIG_PATH="${CONFIG_PATH:-$JARM_DIR/configs}"
DOWNLOAD_PATH="${DOWNLOAD_PATH:-$JARM_DIR/downloads}"
MEDIA_PATH="${MEDIA_PATH:-$JARM_DIR/media}"
# Predefine COMPOSE_FILE so sourced compose.sh doesn't fail; will be overwritten by compose_build_compose
export COMPOSE_FILE="${JARM_DIR}/docker-compose.yaml"
cleanup() { rm -rf "$MODULE_ROOT" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

fetch_repo_bundle() {
    # Try to download the whole repo as a tarball once to speed up subsequent file fetches
    # Works automatically for REMOTE_BASE in the form:
    #   https://raw.githubusercontent.com/<owner>/<repo>/<branch>
    [[ -z "${REMOTE_BASE:-}" ]] && return 1
    command -v tar >/dev/null 2>&1 || return 1
    # Parse owner/repo/branch from REMOTE_BASE
    local base_no_proto="${REMOTE_BASE#*://}"
    IFS='/' read -r host owner repo branch rest <<<"$base_no_proto"
    if [[ "$host" != "raw.githubusercontent.com" || -z "$owner" || -z "$repo" || -z "$branch" ]]; then
        return 1
    fi
    local tar_url="https://codeload.github.com/$owner/$repo/tar.gz/refs/heads/$branch"
    local tar_path="$MODULE_ROOT/bundle.tar.gz"
    printf "[bootstrap] Downloading bundle %s\n" "$tar_url"
    if ! curl -fsSL "$tar_url" -o "$tar_path"; then
        printf "[bootstrap] Bundle download failed, will fallback to per-file fetch\n"
        return 1
    fi
    mkdir -p "$MODULE_ROOT/_bundle"
    # Determine top-level folder name from tar
    local top
    top=$(tar -tzf "$tar_path" 2>/dev/null | head -n1 | cut -d/ -f1)
    if [[ -z "$top" ]]; then
        printf "[bootstrap] Could not determine bundle top folder, fallback to per-file\n"
        return 1
    fi
    tar -xzf "$tar_path" -C "$MODULE_ROOT/_bundle" >/dev/null 2>&1 || true
    if [[ ! -d "$MODULE_ROOT/_bundle/$top" ]]; then
        printf "[bootstrap] Bundle extract missing expected folder, fallback to per-file\n"
        return 1
    fi
    export BUNDLE_ROOT="$MODULE_ROOT/_bundle/$top"
    printf "[bootstrap] Bundle extracted to %s\n" "$BUNDLE_ROOT"
    return 0
}

ensure_module() {
    # Ensure a module by relative path within the repo, e.g. scripts/lib/common.sh
    local rel="$1"
    local target="$MODULE_ROOT/$rel"
    local src_local="$ROOT_DIR/$rel"
    mkdir -p "$(dirname "$target")"
    if [[ -f "$src_local" ]]; then
        printf "[bootstrap] Copying %s\n" "$rel"
        cp "$src_local" "$target"
        chmod +x "$target" || true
        return 0
    fi
    # Try to serve from a pre-fetched bundle to avoid many network calls
    if [[ -n "${BUNDLE_ROOT:-}" && -f "$BUNDLE_ROOT/$rel" ]]; then
        printf "[bootstrap] From bundle %s\n" "$rel"
        cp "$BUNDLE_ROOT/$rel" "$target"
        chmod +x "$target" || true
        return 0
    fi
    if [[ -n "$REMOTE_BASE" ]]; then
        local url="$REMOTE_BASE/$rel"
        printf "[bootstrap] Downloading %s\n" "$url"
        curl -fsSL "$url" -o "$target"
        chmod +x "$target" || true
        return 0
    fi
    printf "[bootstrap][ERROR] Missing %s locally and REMOTE_BASE not set\n" "$rel" >&2
    exit 1
}

# Ensure curl is available before attempting remote module downloads
if ! command -v curl >/dev/null 2>&1; then
    printf "[bootstrap][ERROR] 'curl' is required but not found in PATH\n" >&2
    exit 1
fi

fetch_repo_bundle || true

ensure_module scripts/lib/common.sh
ensure_module scripts/lib/compose.sh
ensure_module scripts/lib/services.sh
ensure_module scripts/lib/config.sh
# compose fragments
ensure_module compose/base.yaml
ensure_module compose/qbittorrent.yaml
ensure_module compose/flaresolverr.yaml
ensure_module compose/sonarr.yaml
ensure_module compose/radarr.yaml
ensure_module compose/jellyfin.yaml
ensure_module compose/jellyseerr.yaml
ensure_module compose/prowlarr.yaml
# service modules
ensure_module scripts/services/qbittorrent.sh
ensure_module scripts/services/flaresolverr.sh
ensure_module scripts/services/sonarr.sh
ensure_module scripts/services/radarr.sh
ensure_module scripts/services/jellyfin.sh
ensure_module scripts/services/jellyseerr.sh
ensure_module scripts/services/prowlarr.sh

# shellcheck disable=SC1090
source "$MODULE_ROOT/scripts/lib/common.sh"
# shellcheck disable=SC1090
source "$MODULE_ROOT/scripts/lib/compose.sh"
# shellcheck disable=SC1090
source "$MODULE_ROOT/scripts/lib/services.sh"
# shellcheck disable=SC1090
source "$MODULE_ROOT/scripts/lib/config.sh"

# Compose will be generated at /opt/jarm; set env exports for modules
export MODULE_ROOT WORK_DIR JARM_DIR

usage() {
  cat <<'EOF'
Usage: ./deploy.sh <command>

Commands:
  up        Start stack (pull + up -d + readiness + API key scan)
  down      Stop stack
  restart   Restart containers
  keys      Only rescan API keys
  config    Run post-configuration (Sonarr/Radarr/Prowlarr)

Environment:
  RUN_NONINTERACTIVE=1  Disable prompts (all required vars must be set)
  AUTO_CONFIG=1         Run post-config right after up
  WAIT_TIMEOUT          Readiness timeout (seconds), default 180
  WAIT_INTERVAL         Poll interval (seconds), default 2
  REMOTE_BASE           Base URL for module downloads (raw GitHub)
  JARM_DIR              Directory to store final compose and artifacts (default: /opt/jarm)

Examples:
  ./deploy.sh up
  AUTO_CONFIG=1 ./deploy.sh up
  RUN_NONINTERACTIVE=1 CONFIG_PATH=/mnt/data ... ./deploy.sh up
EOF
}

main() {
    local cmd="${1:-up}"; shift || true
    require_cmd docker
    require_cmd curl
    
    case "$cmd" in
        up)
            collect_stack_vars
            ensure_dirs
            select_services
            services_ensure_dirs
            compose_build_compose
            compose_pull_up
            service_readiness
            scan_api_keys
            if [[ "${AUTO_CONFIG:-0}" == "1" ]]; then
                log "AUTO_CONFIG=1 — running base post-configuration"
                configure_all_services
            else
                log "AUTO_CONFIG not set — skipping post-configuration"
            fi
        ;;
        down)
            compose_down
        ;;
        restart)
            compose_restart
        ;;
        keys)
            collect_stack_vars
            ensure_dirs
            select_services
            services_ensure_dirs
            scan_api_keys
        ;;
        config)
            # Ensure we have any required variables and keys before configuring
            collect_stack_vars
            ensure_dirs
            select_services
            services_ensure_dirs
            if [[ ! -f "${WORK_DIR:-${JARM_DIR:-/opt/jarm}}/found_api_keys.json" ]]; then
                scan_api_keys
            fi
            configure_all_services
        ;;
        -h|--help|help)
            usage
        ;;
        *)
            err "Unknown command: $cmd"; usage; exit 1;
        ;;
    esac
}

main "$@"
