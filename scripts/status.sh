#!/usr/bin/env bash
# status.sh — Show the current state of the LiteLLM+headroom gateway
# Usage: ./scripts/status.sh

set -euo pipefail
GATEWAY="http://127.0.0.1:4000"
LITELLM_ADMIN="http://127.0.0.1:4001"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_REGION_NAME="eu-central-1"
COMBINED_STATS_PY="$DIR/scripts/combined_stats.py"

curl_with_retries() {
  local url="$1"
  local attempts="${2:-5}"
  local delay="${3:-1}"
  local out=""
  local i
  for ((i = 1; i <= attempts; i++)); do
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
if docker ps --format '{{.Names}}' | grep -q "^headroom-bedrock-gateway$"; then
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}' | grep headroom-bedrock-gateway
else
  echo "  headroom-bedrock-gateway: NOT RUNNING"
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

# --- Bedrock headroom gateway health (:4002) ---
echo "[ Bedrock Headroom :4002 ]"
BEDROCK_GATEWAY="http://127.0.0.1:4002"
BEDROCK_LIVE=$(curl_with_retries "$BEDROCK_GATEWAY/healthz" 6 1 || true)
if [[ -n "$BEDROCK_LIVE" ]]; then
  echo "  Status: healthy"
  echo "  Endpoint: $BEDROCK_GATEWAY (native Bedrock routes, direct to AWS)"
  BEDROCK_IMG=$(docker ps --format '{{.Image}}' --filter 'name=^headroom-bedrock-gateway$' | head -1 || true)
  if [[ -n "$BEDROCK_IMG" ]]; then
    echo "  Image: $BEDROCK_IMG"
  fi
  B_STATS=$(curl_with_retries "$BEDROCK_GATEWAY/stats" 4 1 || true)
  if [[ -n "$B_STATS" ]]; then
    echo "$B_STATS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
s = d.get('summary', {})
c = s.get('compression', {})
print(f\"  API requests: {s.get('api_requests', '?')}\")
print(f\"  Tokens removed: {c.get('total_tokens_removed', '?')}\")
" 2>/dev/null || true
  fi
else
  echo "  Status: UNREACHABLE"
  echo "  Endpoint: $BEDROCK_GATEWAY/healthz"
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

# --- Unified stats across :4000 + :4002 ---
echo "[ Unified Stats ]"
if [[ -f "$COMBINED_STATS_PY" ]]; then
  COMBINED_JSON=$(python3 "$COMBINED_STATS_PY" 2>/dev/null || true)
  if [[ -n "$COMBINED_JSON" ]]; then
    echo "$COMBINED_JSON" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print('  Status: unavailable (parse error)')
    raise SystemExit(0)
if not d.get('ok'):
    print(f\"  Status: unavailable ({d.get('error','unknown')}: {d.get('details','')})\")
    raise SystemExit(0)
u=d.get('unified',{})
lanes=d.get('lanes',{})
b=lanes.get('bedrock_native',{})
print('  Status: available')
print(f\"  Unified API requests:    {u.get('api_requests', 0)}\")
print(f\"  Unified tokens saved:    {u.get('tokens_saved', 0)}\")
print(f\"  Unified cached requests: {u.get('requests_cached', 0)}\")
if not b.get('available', False):
    print(f\"  Bedrock native stats: unavailable ({b.get('error','unknown')})\")
else:
    raw_b = (d.get('raw') or {}).get('bedrock_native') or {}
    src = 'prometheus metrics' if isinstance(raw_b, dict) and raw_b.get('source') == 'prometheus' else 'runtime patch'
    print(f\"  Bedrock native requests: {b.get('api_requests', 0)} (source: {src})\")
" 2>/dev/null || echo "  Status: unavailable"
  else
    echo "  Status: unavailable"
  fi
else
  echo "  Status: unavailable (missing scripts/combined_stats.py)"
fi
echo

# --- Kilo config check ---
echo "[ Kilo Config ]"
KILO_CONF="$HOME/.config/kilo/kilo.jsonc"
if [[ -f "$KILO_CONF" ]]; then
  if python3 -c "
import json, pathlib, re, sys
p = pathlib.Path('$KILO_CONF')
text = p.read_text(encoding='utf-8')
text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
text = re.sub(r'(^\s*)//.*$', '', text, flags=re.M)
data = json.loads(text)
provider = data.get('provider', {})
for key in ('github-copilot', 'openai-compatible'):
    opts = provider.get(key, {}).get('options', {})
    url = opts.get('baseURL', '')
    if url and url != 'http://127.0.0.1:4000/v1':
        raise SystemExit(1)
bedrock_opts = provider.get('amazon-bedrock', {}).get('options', {})
bedrock_url = bedrock_opts.get('baseURL', '')
if bedrock_url and bedrock_url not in ('http://127.0.0.1:4002', 'http://127.0.0.1:4002/v1'):
    raise SystemExit(1)
" 2>/dev/null; then
    echo "  kilo.jsonc: baseURLs correct"
    python3 -c "
import json, pathlib, re
p = pathlib.Path('$KILO_CONF')
text = p.read_text()
text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
text = re.sub(r'(^\s*)//.*$', '', text, flags=re.M)
d = json.loads(text)
provider = d.get('provider', {})
for k, v in provider.items():
    opts = v.get('options', {}) if isinstance(v, dict) else {}
    url = opts.get('baseURL')
    if url: print(f'    {k}: {url}')
" 2>/dev/null || true
  else
    echo "  kilo.jsonc: WARNING — provider baseURLs not fully aligned"
    echo "  Expected: github-copilot + openai-compatible -> http://127.0.0.1:4000/v1"
    echo "  Expected: amazon-bedrock                    -> http://127.0.0.1:4002"
    echo "  Run: ./scripts/setup-kilo.sh"
  fi
else
  echo "  kilo.jsonc not found at $KILO_CONF"
  echo "  Run: ./scripts/setup-kilo.sh"
fi
echo

# --- AWS SSO status ---
echo "[ AWS Credentials ]"
AWS_PROFILE_NAME="${AWS_PROFILE:-default}"
if AWS_REGION="$AWS_REGION_NAME" AWS_DEFAULT_REGION="$AWS_REGION_NAME" aws sts get-caller-identity --profile "$AWS_PROFILE_NAME" &>/dev/null; then
  IDENTITY=$(AWS_REGION="$AWS_REGION_NAME" AWS_DEFAULT_REGION="$AWS_REGION_NAME" aws sts get-caller-identity --profile "$AWS_PROFILE_NAME" 2>/dev/null |
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Arn'])" 2>/dev/null || echo "ok")
  echo "  Profile $AWS_PROFILE_NAME: valid ($IDENTITY)"
else
  echo "  Profile $AWS_PROFILE_NAME: EXPIRED — run: aws sso login --profile $AWS_PROFILE_NAME"
fi
echo
