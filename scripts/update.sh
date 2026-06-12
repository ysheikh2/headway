#!/usr/bin/env bash
# update.sh — Pull latest images and restart the gateway stack.
# Safe to run at any time; zero downtime is not guaranteed but the full stack
# is back up before the script exits.
#
# Usage: ./scripts/update.sh [--aws-profile <profile>]

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="$DIR/docker-compose.yml"
AWS_PROFILE_NAME="${AWS_PROFILE:-d2i_stg}"
GATEWAY="http://127.0.0.1:4000"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --aws-profile)
      AWS_PROFILE_NAME="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1"
      exit 1
      ;;
  esac
done

if ! docker info &>/dev/null; then
  echo "ERROR: Docker is not running."
  exit 1
fi

cd "$DIR"

echo "=== Headroom Gateway — Self-Update ==="
echo

# Show what we have now
echo "[ Current image digests ]"
for svc in headroom litellm headroom-bedrock; do
  img=$(docker compose -f "$COMPOSE" config --format json 2>/dev/null |
    python3 -c "import json,sys; s=json.load(sys.stdin)['services']; print(s.get('$svc',{}).get('image','?'))" 2>/dev/null || echo "?")
  if [[ "$img" != "?" ]]; then
    id=$(docker images --no-trunc --quiet "$img" 2>/dev/null | head -1 || true)
    echo "  $svc: $img ${id:+(${id:7:12})}"
  fi
done
echo

# Pull latest
echo "[ Pulling latest images ]"
docker compose -f "$COMPOSE" pull litellm headroom

# Bedrock lane may use a local image tag.
BEDROCK_IMAGE=$(docker compose -f "$COMPOSE" config --format json 2>/dev/null |
  python3 -c "import json,sys; print(json.load(sys.stdin)['services'].get('headroom-bedrock',{}).get('image',''))" 2>/dev/null || echo "")
if [[ -n "$BEDROCK_IMAGE" && "$BEDROCK_IMAGE" == *"/"* ]]; then
  docker compose -f "$COMPOSE" pull headroom-bedrock
else
  echo "  Skipping pull for headroom-bedrock image: ${BEDROCK_IMAGE:-<unset>}"
fi
echo

# Restart only services whose image changed (compose recreates automatically)
echo "[ Restarting stack with updated images ]"
docker compose -f "$COMPOSE" up -d --remove-orphans
echo

# Wait for headroom to be healthy
echo "[ Waiting for gateway to become healthy... ]"
for i in $(seq 1 20); do
  LIVE=$(curl -sf --max-time 3 "$GATEWAY/livez" 2>/dev/null || true)
  if [[ -n "$LIVE" ]]; then
    VER=$(echo "$LIVE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
    echo "  Gateway healthy — headroom v$VER"
    break
  fi
  printf "  Attempt %d/20...\r" "$i"
  sleep 2
done

if [[ -z "${LIVE:-}" ]]; then
  echo "  WARNING: Gateway did not respond. Check: docker compose logs -f"
  exit 1
fi

# Also show bedrock gateway version
BEDROCK_LIVE=$(curl -sf --max-time 3 "http://127.0.0.1:4002/healthz" 2>/dev/null || true)
if [[ -n "$BEDROCK_LIVE" ]]; then
  BVER=$(echo "$BEDROCK_LIVE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
  echo "  Bedrock gateway healthy — headroom v$BVER"
fi

echo
echo "=== Update complete ==="
echo "  Run ./scripts/test.sh to verify end-to-end."
