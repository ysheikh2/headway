#!/usr/bin/env bash
# stop.sh — Stop the LiteLLM+Headroom gateway stack (containers are removed but
#            volumes and Copilot tokens are preserved).
#
# Usage: ./scripts/stop.sh

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="$DIR/docker-compose.yml"

if ! docker info &>/dev/null; then
    echo "ERROR: Docker is not running."
    exit 1
fi

# Check whether any stack containers actually exist before trying to stop.
running=$(docker compose -f "$COMPOSE" ps --quiet 2>/dev/null | wc -l | tr -d ' ')

if [[ "$running" -eq 0 ]]; then
    echo "Stack is not running — nothing to stop."
    exit 0
fi

echo "=== Stopping LiteLLM+Headroom Gateway ==="
docker compose -f "$COMPOSE" down
echo "Done. Run ./scripts/start.sh to bring it back up."
