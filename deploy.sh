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
JARM_DIR="${JARM_DIR:-/opt/jarm}"
# Predefine COMPOSE_FILE so sourced compose.sh doesn't fail; will be overwritten by compose_build_compose
export COMPOSE_FILE="${JARM_DIR}/docker-compose.yaml"
cleanup() { rm -rf "$MODULE_ROOT" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

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
