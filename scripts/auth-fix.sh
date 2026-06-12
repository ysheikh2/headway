#!/usr/bin/env bash
# auth-fix.sh — Fix 403 auth errors for GitHub Copilot or AWS Bedrock.
#
# Run this when your client shows:
#   "Please reauthenticate with the copilot provider..."
#   statusCode: 403, "unauthorized: not authorized to use this Copilot feature"
#
# Also run this when Bedrock requests fail with credential errors.
#
# What it does:
#   1. Refreshes AWS SSO session (if expired)
#   2. Regenerates LiteLLM config
#   3. Restarts gateway containers
#   4. Runs a smoke check

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="$DIR/docker-compose.yml"
ENV_FILE="$DIR/.env"
GATEWAY="http://127.0.0.1:4000"
GENERATOR="$DIR/scripts/generate-litellm-config.sh"
AWS_REGION_NAME="eu-central-1"

# Source .env first so its values take precedence over the shell environment.
# Shell env is only the fallback when .env doesn't exist or a key is absent.
if [[ -f "$ENV_FILE" ]]; then
  set -o allexport
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +o allexport
fi
AWS_PROFILE_NAME="${AWS_PROFILE:-default}"

echo "=== Auth Fix ==="
echo

# --- Check Docker ---
if ! docker info &>/dev/null; then
  echo "ERROR: Docker is not running. Start Docker Desktop first."
  exit 1
fi

# ── AWS SSO ────────────────────────────────────────────────────────────────────
echo "[ AWS SSO — profile: $AWS_PROFILE_NAME ]"
if ! AWS_REGION="$AWS_REGION_NAME" AWS_DEFAULT_REGION="$AWS_REGION_NAME" aws sts get-caller-identity --profile "$AWS_PROFILE_NAME" &>/dev/null; then
  echo "  SSO session expired. Logging in..."
  aws sso login --profile "$AWS_PROFILE_NAME"
  echo "  SSO login complete."
else
  echo "  AWS session valid."
fi
echo

# ── Upsert .env — only add keys that are missing; never overwrite existing ─────
append_if_missing() {
  local key="$1" value="$2"
  if [[ ! -f "$ENV_FILE" ]] || ! grep -q "^${key}=" "$ENV_FILE"; then
    echo "${key}=${value}" >>"$ENV_FILE"
    echo "  added: ${key}=${value}"
  fi
}
[[ -f "$ENV_FILE" ]] || touch "$ENV_FILE"
append_if_missing "AWS_PROFILE" "$AWS_PROFILE_NAME"
append_if_missing "BEDROCK_AWS_PROFILE" "$AWS_PROFILE_NAME"
append_if_missing "BEDROCK_DISCOVERY_PROFILE" "$AWS_PROFILE_NAME"
echo "[ .env checked (existing values untouched): $ENV_FILE ]"
echo

# ── Generate LiteLLM config from Bedrock model discovery ─────────────────────
echo "[ Generating litellm_config.yaml from AWS Bedrock ]"
if ! bash "$GENERATOR" --aws-profile "$AWS_PROFILE_NAME" --output "$DIR/litellm_config.yaml"; then
  echo "  WARNING: generation failed"
  if [[ ! -s "$DIR/litellm_config.yaml" ]]; then
    echo "  ERROR: missing or empty litellm_config.yaml and generation failed"
    exit 1
  fi
  echo "  Continuing with existing litellm_config.yaml"
fi
echo

# ── Restart gateways ───────────────────────────────────────────────────────────
echo "[ Restarting gateways with fresh credentials ]"
cd "$DIR"

# Restart Copilot lane first. This must succeed for Copilot auth recovery.
docker rm -f litellm-gateway 2>/dev/null || true
docker rm -f headroom-gateway 2>/dev/null || true
docker compose -f "$COMPOSE" up -d litellm headroom

# Bedrock lane is best-effort here: a missing image must not block Copilot auth fix.
docker rm -f headroom-bedrock-gateway 2>/dev/null || true
if ! docker compose -f "$COMPOSE" up -d headroom-bedrock; then
  echo "  WARNING: headroom-bedrock failed to start (image/tag may be missing)."
  echo "  Copilot lane is still running; fix HEADROOM_BEDROCK_IMAGE and restart Bedrock lane later."
fi
echo

# ── Wait for healthy ───────────────────────────────────────────────────────────
echo "[ Waiting for gateway to become healthy... ]"
LIVE=""
for i in $(seq 1 30); do
  LIVE=$(curl -sf --max-time 3 "$GATEWAY/livez" 2>/dev/null || true)
  if [[ -n "$LIVE" ]]; then
    echo "  Gateway healthy."
    break
  fi
  printf "  Waiting %d/30...\r" "$i"
  sleep 2
done

if [[ -z "$LIVE" ]]; then
  echo "ERROR: Gateway did not become healthy. Check logs:"
  echo "  docker logs headroom-gateway"
  echo "  docker logs litellm-gateway"
  CODE_LINE=$(docker logs litellm-gateway 2>/dev/null | grep -E 'Please visit https://github.com/login/device and enter code' | tail -1 || true)
  if [[ -n "$CODE_LINE" ]]; then
    echo
    echo "Copilot device auth pending:"
    echo "  $CODE_LINE"
    echo "  Open: https://github.com/login/device"
  fi
  exit 1
fi

# If Copilot aliases were not generated, surface a direct auth hint.
if ! grep -q '^  - model_name: copilot-' "$DIR/litellm_config.yaml" 2>/dev/null; then
  echo "WARNING: No named copilot-* aliases found in litellm_config.yaml."
  echo "         This usually means Copilot token refresh is required (401 from models API)."
  CODE_LINE=$(docker logs litellm-gateway 2>/dev/null | grep -E 'Please visit https://github.com/login/device and enter code' | tail -1 || true)
  if [[ -n "$CODE_LINE" ]]; then
    echo "  Device auth pending: $CODE_LINE"
    echo "  Open: https://github.com/login/device"
  else
    echo "  Check: docker logs litellm-gateway"
  fi
fi
echo

# ── Smoke test ─────────────────────────────────────────────────────────────────
echo "[ Smoke test: GitHub Copilot via gateway ]"
COPILOT_SMOKE_MODEL=""
RESPONSE=""
for CANDIDATE in "claude-haiku-4.5" "gemini-3-flash" "gpt-5-mini" "claude-sonnet-4.6"; do
  COPILOT_SMOKE_MODEL="$CANDIDATE"
  RESPONSE=$(curl -s --max-time 30 \
    "$GATEWAY/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$COPILOT_SMOKE_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: AUTHOK\"}],\"max_tokens\":10,\"stream\":false}" \
    2>/dev/null || true)

  if echo "$RESPONSE" | grep -qi "AUTHOK"; then
    break
  fi

  if echo "$RESPONSE" | tr '[:upper:]' '[:lower:]' | grep -Eq "model|not found|unsupported|does not exist"; then
    continue
  fi
done

if echo "$RESPONSE" | grep -qi "AUTHOK"; then
  echo "  Copilot smoke test: PASSED ($COPILOT_SMOKE_MODEL)"
elif [[ -n "$RESPONSE" ]]; then
  echo "  Copilot smoke test: got response (model $COPILOT_SMOKE_MODEL): $(echo "$RESPONSE" | head -c 200)"
  echo "  If this indicates GitHub Copilot auth is missing, check litellm logs for device code login prompt."
else
  echo "  Copilot smoke test: FAILED — no response"
  echo "  Check logs: docker logs litellm-gateway"
  echo "  If prompted, complete GitHub device flow shown in logs."
  CODE_LINE=$(docker logs litellm-gateway 2>/dev/null | grep -E 'Please visit https://github.com/login/device and enter code' | tail -1 || true)
  if [[ -n "$CODE_LINE" ]]; then
    echo "  Latest device code: $CODE_LINE"
  fi
fi
echo

echo "=== Auth fix complete ==="
echo "Restart your client to pick up the fresh connection."
echo
echo "  Gateway: $GATEWAY/health/liveliness"
echo "  Gateway: $GATEWAY/livez"
echo "  Models (LiteLLM):  http://127.0.0.1:4001/v1/models"
