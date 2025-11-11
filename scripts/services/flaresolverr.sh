#!/usr/bin/env bash
set -euo pipefail

flaresolverr_ensure_dirs() { :; }

flaresolverr_wait_ready() { wait_for_http "flaresolverr" "http://127.0.0.1:8191" || true; }

flaresolverr_find_api_key() { :; }

flaresolverr_configure() { :; }
