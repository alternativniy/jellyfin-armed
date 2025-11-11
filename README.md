# Jellyfin Armored (JArm)

## DO NOT USE THIS

It is currently in active development and exists as a proof-of-concept.

Automated Docker stack for Jellyfin and companion services: qBittorrent, Sonarr, Radarr, Jellyseerr, Prowlarr, and FlareSolverr. The `deploy.sh` orchestrator handles interactive setup, Docker Compose assembly, readiness checks, API key discovery, and post-deploy configuration through each service’s API.

## Features

- Interactive setup (no mandatory `.env`) with safe defaults
- Preflight checks (Docker, Compose/`docker compose`, curl)
- Dynamic Compose assembly from per-service fragments into `/opt/jarm/docker-compose.yaml`
- One-command lifecycle: pull, up -d, readiness checks, and optional auto-config
- API key discovery (Sonarr/Radarr/Prowlarr/Jellyseerr) -> saved to `found_api_keys.json`
- Post-config automation:
  - qBittorrent: login (including initial password extraction from logs), password set, save paths, categories (tv/movies)
  - Sonarr/Radarr: root folders and qBittorrent as Download Client
  - Prowlarr: registers Sonarr/Radarr as Applications
  - Jellyfin: admin bootstrap, token retrieval, libraries (Movies/TV), locale & metadata language, library refresh
  - Jellyseerr: links Sonarr/Radarr and Jellyfin

## Requirements

- Linux with Docker
- Docker Compose (CLI plugin `docker compose` or legacy `docker-compose`)
- curl

## Quick start

You can fetch and run the deploy script directly from GitHub raw without cloning:

```bash
curl -fsSL https://raw.githubusercontent.com/alternativniy/jellyfin-armed/main/deploy.sh | bash -s -- up
```

The script will automatically download the remaining modules using REMOTE_BASE (default:
`https://raw.githubusercontent.com/alternativniy/jellyfin-armed/main`).

Common operations:

- Stop: `bash ./deploy.sh down`
- Restart: `bash ./deploy.sh restart`
- Rescan API keys only: `bash ./deploy.sh keys`
- Post-config only: `bash ./deploy.sh config` or `AUTO_CONFIG=1 bash ./deploy.sh up`

## Environment variables (interactive prompts available)

Required (prompted if missing):

- `CONFIG_PATH` — root folder for service configs (mounted into containers)
- `MEDIA_PATH` — media library root (will contain `tv` and `movies`)
- `DOWNLOAD_PATH` — downloads root (script ensures `/downloads/tv` and `/downloads/movies`)
- `TZ` — timezone (e.g., `Asia/Almaty`)

Optional:

- `AUTO_CONFIG=1` — run post-config automatically after `up`
- `RUN_NONINTERACTIVE=1` — no prompts (all required vars must be set)
- `WAIT_TIMEOUT` — readiness timeout in seconds (default 180)
- `WAIT_INTERVAL` — readiness poll interval in seconds (default 2)
- `JARM_DIR` — persistent work dir (default `/opt/jarm`), stores final compose and artifacts (`found_api_keys.json`, tokens, passwords)
- `COMPOSE_INCLUDE` — comma-separated service names to include (default: qbittorrent,flaresolverr,sonarr,radarr,jellyfin,jellyseerr,prowlarr)

Service-specific (prompted when needed):

- `QB_USERNAME` / `QB_PASSWORD` — qBittorrent WebUI credentials (auto-extracted initial password supported)
- `JELLYFIN_ADMIN_USER` / `JELLYFIN_ADMIN_PASS` — Jellyfin admin credentials (for bootstrap)
- `JELLYFIN_LANG` — locale (default `en-US`, e.g., `ru-RU`)

## How it works

1. `deploy.sh` copies/loads modules from the repo (or REMOTE_BASE), assembles per-service Compose fragments into `/opt/jarm/docker-compose.yaml`, then starts the stack.
2. Readiness checks wait for ports/HTTP to be available.
3. API key discovery scans mounted config paths and writes `found_api_keys.json` into `JARM_DIR`.
4. Post-config (optional or via `./deploy.sh config`) calls into service modules under `scripts/services/*.sh` to finish setup.

Artifacts saved in `JARM_DIR`:

- `docker-compose.yaml` — generated final Compose
- `found_api_keys.json` — discovered keys
- `qbittorrent_initial_password.txt` / `qbittorrent_password.txt`
- `jellyfin_token.txt` / `jellyfin_language.txt`

## Services

- qBittorrent: 8080 (WebUI), categories `tv`/`movies`, default save path `/downloads`
- Sonarr: 8989, root folder `/tv`, qBittorrent as Download Client
- Radarr: 7878, root folder `/movies`, qBittorrent as Download Client
- Prowlarr: 9696, adds Sonarr/Radarr as applications
- Jellyfin: 8096, admin bootstrap, token saved, Movies/TV libraries, locale and metadata language
- Jellyseerr: 5055, connects to Sonarr/Radarr and Jellyfin
- FlareSolverr: 8191 (if included)

## Development

Project structure:

- `deploy.sh` — bootstrap/orchestrator (interactive flow, compose assembly, lifecycle commands)
- `compose/*.yaml` — per-service compose fragments (merged at runtime)
- `scripts/lib/*.sh` — shared utilities:
  - `common.sh` — prompts, HTTP helpers, directory prep
  - `compose.sh` — readiness checks and compose lifecycle
  - `services.sh` — service registry and orchestrator
  - `config.sh` — API key scanner and configure-all delegator
- `scripts/services/*.sh` — per-service hooks (ensure_dirs, wait_ready, find_api_key, configure)

### Add a new service

1) Create a compose fragment: `compose/<service>.yaml`

2) Add a service module: `scripts/services/<service>.sh` with functions:
    - `<service>_ensure_dirs` — create host directories used in volume mounts
    - `<service>_wait_ready` — wait until service is reachable (HTTP/TCP)
    - `<service>_find_api_key` — return API key or empty (optional)
    - `<service>_configure` — idempotent API configuration steps

3) Wire into the default service order (if needed): edit `scripts/lib/services.sh` `SERVICES_DEFAULT=(...)`.

4) Test locally:

```fish
bash -n scripts/services/<service>.sh
AUTO_CONFIG=1 COMPOSE_INCLUDE=<service> ./deploy.sh up
```

Guidelines:

- Keep service-specific logic in `scripts/services/*`, not in shared libs
- Make steps idempotent (check first, then apply)
- Prefer container-visible paths (as mounted in compose) when configuring via API
- Store credentials/tokens under `${JARM_DIR}` with restrictive permissions

## Troubleshooting

- qBittorrent initial password: `docker logs qbittorrent | grep -i password` (script also saves it to `${JARM_DIR}`)
- Keys missing in `found_api_keys.json`: run `./deploy.sh keys` after containers create configs
- Compose file location: `/opt/jarm/docker-compose.yaml` (or `${JARM_DIR}/docker-compose.yaml`)
- Limit services: `COMPOSE_INCLUDE=sonarr,radarr,jellyfin ./deploy.sh up`

## Security notes

- Tokens and passwords are stored under `${JARM_DIR}` with `chmod 600` where applicable
- Consider setting non-root PUID/PGID in compose fragments for production
- Review exposed ports and restrict as needed via firewall

## License

MIT
