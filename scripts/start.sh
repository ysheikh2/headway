#!/usr/bin/env bash
# start.sh — Build and start the LiteLLM+headroom gateway with fresh credentials.
# Run this after a Mac reboot or any time the gateway is not running.
#
# Usage: ./scripts/start.sh [--aws-profile <profile>]
#   --aws-profile <name>   AWS SSO profile for Bedrock (default: d2i_stg)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="$DIR/docker-compose.yml"
ENV_FILE="$DIR/.env"
GATEWAY="http://127.0.0.1:4000"
LITELLM_ADMIN="http://127.0.0.1:4001"
AWS_PROFILE_NAME="d2i_stg"
GENERATOR="$DIR/scripts/generate-litellm-config.sh"
AWS_REGION_NAME="eu-central-1"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --aws-profile)      AWS_PROFILE_NAME="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

echo "=== Starting LiteLLM+Headroom Gateway ==="
echo

# --- Check Docker ---
if ! docker info &>/dev/null; then
    echo "ERROR: Docker is not running."
    echo "Start Docker Desktop from Applications or the menu bar, then re-run."
    exit 1
fi

# ── AWS Auth (for Bedrock) ─────────────────────────────────────────────────────
echo "[ AWS Authentication — profile: $AWS_PROFILE_NAME ]"
if ! AWS_REGION="$AWS_REGION_NAME" AWS_DEFAULT_REGION="$AWS_REGION_NAME" aws sts get-caller-identity --profile "$AWS_PROFILE_NAME" &>/dev/null; then
    echo "  SSO session expired. Logging in..."
    aws sso login --profile "$AWS_PROFILE_NAME"
fi
AWS_IDENTITY=$(AWS_REGION="$AWS_REGION_NAME" AWS_DEFAULT_REGION="$AWS_REGION_NAME" aws sts get-caller-identity --profile "$AWS_PROFILE_NAME" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Account: {d[\"Account\"]}  ARN: {d[\"Arn\"]}')" \
    2>/dev/null || echo "(could not retrieve identity)")
echo "  $AWS_IDENTITY"
echo

# ── Write .env ─────────────────────────────────────────────────────────────────
cat > "$ENV_FILE" <<EOF
AWS_PROFILE=$AWS_PROFILE_NAME
EOF
echo "[ .env written: $ENV_FILE ]"
echo

# ── Generate LiteLLM config from Bedrock model discovery ─────────────────────
echo "[ Generating litellm_config.yaml from AWS Bedrock ]"
if ! bash "$GENERATOR" --aws-profile "$AWS_PROFILE_NAME" --output "$DIR/litellm_config.yaml"; then
    echo "  WARNING: generation failed; continuing with existing litellm_config.yaml"
fi
echo

# ── Pull images ───────────────────────────────────────────────────────────────
echo "[ Pulling latest images ]"
cd "$DIR"
docker compose -f "$COMPOSE" pull
echo

# ── Stop old containers ────────────────────────────────────────────────────────
echo "[ Stopping existing containers ]"
docker compose -f "$COMPOSE" down 2>/dev/null || true
docker rm -f headroom-kilo 2>/dev/null || true
docker rm -f litellm-gateway 2>/dev/null || true
echo

# ── Start ──────────────────────────────────────────────────────────────────────
echo "[ Starting gateway ]"
docker compose -f "$COMPOSE" up -d
echo

# ── Wait for healthy ───────────────────────────────────────────────────────────
echo "[ Waiting for gateway to become healthy... ]"
LIVE=""
for i in $(seq 1 30); do
    LIVE=$(curl -sf --max-time 3 "$GATEWAY/livez" 2>/dev/null || true)
    if [[ -n "$LIVE" ]]; then
        echo "  Gateway is healthy."
        break
    fi
    printf "  Attempt %d/30...\r" "$i"
    sleep 2
done

if [[ -z "${LIVE:-}" ]]; then
    echo "  WARNING: Gateway did not respond within 60s. Check logs:"
    echo "  docker logs headroom-kilo"
    echo "  docker logs litellm-gateway"
    CODE_LINE=$(docker logs litellm-gateway 2>/dev/null | grep -E 'Please visit https://github.com/login/device and enter code' | tail -1 || true)
    if [[ -n "$CODE_LINE" ]]; then
        echo
        echo "  Copilot device auth pending:"
        echo "  $CODE_LINE"
        echo "  Open: https://github.com/login/device"
    fi
    exit 1
fi

echo
echo "=== Done ==="
echo "  Gateway: $GATEWAY"
echo "  Models (via Headroom): $GATEWAY/v1/models"
echo "  Models (LiteLLM):      $LITELLM_ADMIN/v1/models"
echo "  Logs:    docker compose logs -f"
echo
echo "Kilo: github-copilot provider → baseURL: $GATEWAY/v1"
echo "Run ./scripts/test.sh to verify end-to-end."
