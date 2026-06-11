#!/usr/bin/env bash
# status.sh — Show the current state of the LiteLLM+headroom gateway
# Usage: ./scripts/status.sh

set -euo pipefail
GATEWAY="http://127.0.0.1:4000"
LITELLM_ADMIN="http://127.0.0.1:4001"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_REGION_NAME="eu-central-1"

curl_with_retries() {
    local url="$1"
    local attempts="${2:-5}"
    local delay="${3:-1}"
    local out=""
    local i
    for ((i=1; i<=attempts; i++)); do
        out=$(curl -sf --max-time 5 "$url" 2>/dev/null || true)
        if [[ -n "$out" ]]; then
            echo "$out"
            return 0
        fi
        sleep "$delay"
    done
    return 1
}

echo "=== LiteLLM+Headroom Gateway Status ==="
echo

# --- Docker containers ---
echo "[ Docker Containers ]"
if docker ps --format '{{.Names}}' | grep -q "^litellm-gateway$"; then
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}' | grep litellm-gateway
else
    echo "  litellm-gateway: NOT RUNNING"
fi
if docker ps --format '{{.Names}}' | grep -q "^headroom-gateway$"; then
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}' | grep headroom-gateway
else
    echo "  headroom-gateway: NOT RUNNING"
fi
if ! docker ps --format '{{.Names}}' | grep -q "^litellm-gateway$"; then
    echo "  To start: cd $DIR && ./scripts/start.sh"
fi
echo

# --- Gateway health ---
echo "[ Gateway Health ]"
LIVE=$(curl_with_retries "$GATEWAY/livez" 6 1 || true)
if [[ -n "$LIVE" ]]; then
    echo "  Status: healthy"
    echo "  Response: $LIVE"
else
    echo "  Status: UNREACHABLE"
    echo "  Endpoint: $GATEWAY/livez"
fi
echo

# --- Headroom health / stats (Copilot path) ---
echo "[ Headroom Proxy ]"
H_LIVE=$(curl_with_retries "$GATEWAY/livez" 6 1 || true)
if [[ -n "$H_LIVE" ]]; then
    echo "  Status: healthy"
    H_STATS=$(curl_with_retries "$GATEWAY/stats" 4 1 || true)
    if [[ -n "$H_STATS" ]]; then
        echo "$H_STATS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
s = d.get('summary', {})
c = s.get('compression', {})
print(f\"  API requests: {s.get('api_requests', '?')}\")
print(f\"  Tokens removed: {c.get('total_tokens_removed', '?')}\")
" 2>/dev/null || echo "  Could not parse /stats"
    fi
else
    echo "  Status: UNREACHABLE"
    echo "  Endpoint: $GATEWAY/livez"
fi
echo

# --- Available models ---
echo "[ Available Models ]"
MODELS=$(curl_with_retries "$GATEWAY/v1/models" 4 1 || true)
if [[ -z "$MODELS" ]]; then
    MODELS=$(curl_with_retries "$LITELLM_ADMIN/v1/models" 4 1 || true)
fi
if [[ -n "$MODELS" ]]; then
    echo "$MODELS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
models = [m['id'] for m in d.get('data', [])]
copilot = [m for m in models if not m.startswith('bedrock')]
bedrock = [m for m in models if m.startswith('bedrock')]
print(f'  Total models: {len(models)}')
print(f'  GitHub Copilot models: {len(copilot)}')
print(f'  Bedrock models: {len(bedrock)}')
print('  Copilot sample:')
for m in sorted(copilot)[:8]: print(f'    {m}')
print('  Bedrock sample:')
for m in sorted(bedrock)[:12]: print(f'    {m}')
" 2>/dev/null || echo "  Could not parse model list"
    if [[ "$(grep -Fc 'model_name: "*"' "$DIR/litellm_config.yaml" 2>/dev/null || true)" -gt 0 ]]; then
        echo "  Copilot wildcard route: configured in litellm_config.yaml (model_name: *)"
    fi
else
    echo "  Could not fetch model list from LiteLLM backend"
fi
echo

# --- Kilo config check ---
echo "[ Kilo Config ]"
KILO_CONF="$HOME/.config/kilo/kilo.jsonc"
if [[ -f "$KILO_CONF" ]]; then
    if grep -q '"github-copilot"' "$KILO_CONF" 2>/dev/null \
        && grep -q '"openai-compatible"' "$KILO_CONF" 2>/dev/null \
        && grep -q '"baseURL": "http://127.0.0.1:4000/v1"' "$KILO_CONF" 2>/dev/null; then
        echo "  kilo.jsonc: baseURL points to gateway ✓"
        grep '"baseURL"' "$KILO_CONF" | sed 's/^/  /'
    else
        echo "  kilo.jsonc: WARNING — provider baseURL entries are not fully aligned"
        echo "  Expected: \"baseURL\": \"http://127.0.0.1:4000/v1\""
        echo "  Run: ./scripts/setup-kilo.sh"
    fi
else
    echo "  kilo.jsonc not found at $KILO_CONF"
    echo "  Run: ./scripts/setup-kilo.sh"
fi
echo

# --- AWS SSO status ---
echo "[ AWS Credentials ]"
AWS_PROFILE_NAME="${AWS_PROFILE:-d2i_stg}"
if AWS_REGION="$AWS_REGION_NAME" AWS_DEFAULT_REGION="$AWS_REGION_NAME" aws sts get-caller-identity --profile "$AWS_PROFILE_NAME" &>/dev/null; then
    IDENTITY=$(AWS_REGION="$AWS_REGION_NAME" AWS_DEFAULT_REGION="$AWS_REGION_NAME" aws sts get-caller-identity --profile "$AWS_PROFILE_NAME" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Arn'])" 2>/dev/null || echo "ok")
    echo "  Profile $AWS_PROFILE_NAME: valid ($IDENTITY)"
else
    echo "  Profile $AWS_PROFILE_NAME: EXPIRED — run: aws sso login --profile $AWS_PROFILE_NAME"
fi
echo
