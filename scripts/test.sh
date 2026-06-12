#!/usr/bin/env bash
# test.sh — Smoke tests LiteLLM+Headroom gateway.
# Run anytime to verify end-to-end gateway health.
#
# Tests:
# 1. Docker containers running
# 2. Gateway liveness endpoint responds
# 3. Gateway/LiteLLM model list reachable
# 4. GitHub Copilot request goes through (lowest-cost preferred)
# 5. Bedrock request goes through (lowest-cost preferred)
# 6. Kilo config correct baseURL

set -euo pipefail

GATEWAY="http://127.0.0.1:4000"
LITELLM_ADMIN="http://127.0.0.1:4001"
BEDROCK_NATIVE_GATEWAY="http://127.0.0.1:4002"
PASS=0
FAIL=0

curl_with_retries() {
  local url="$1"
  local attempts="${2:-8}"
  local delay="${3:-1}"
  local out=""
  local i

  for ((i = 1; i <= attempts; i++)); do
    out=$(curl -sf --max-time 8 "$url" 2>/dev/null || true)
    if [[ -n "$out" ]]; then
      echo "$out"
      return 0
    fi
    sleep "$delay"
  done

  return 1
}

ok() {
  echo "  [PASS] $*"
  PASS=$((PASS + 1))
}
fail() {
  echo "  [FAIL] $*"
  FAIL=$((FAIL + 1))
}
info() { echo "         $*"; }

cleanup_files=()
make_tmp() {
  local tmp
  tmp=$(mktemp /tmp/gateway-test-XXXXXX)
  cleanup_files+=("$tmp")
  echo "$tmp"
}

run_chat_completion() {
  local base_url="$1"
  local model="$2"
  local prompt="$3"
  local max_tokens="$4"
  local outfile="$5"

  HTTP_CODE=$(curl -s -o "$outfile" -w "%{http_code}" --max-time 50 \
    "$base_url/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"$prompt\"}],\"max_tokens\":$max_tokens,\"stream\":false}" \
    2>/dev/null || echo "000")
}

response_has_choices() {
  local file="$1"
  python3 -c "import json,sys; d=json.load(open('$file')); sys.exit(0 if d.get('choices') else 1)" 2>/dev/null
}

response_first_content() {
  local file="$1"
  python3 -c "import json; d=json.load(open('$file')); c=d.get('choices',[]); print((c[0]['message'].get('content','') if c else '').strip())" 2>/dev/null || echo ""
}

resolve_bedrock_native_model() {
  # Finds the first bedrock-* alias in litellm_config.yaml that maps to eu-central-1
  # and returns "MODEL_ID REGION". Falls back to the provided alias's model+region.
  local preferred_alias="$1"
  python3 - "$preferred_alias" <<'PY' 2>/dev/null || true
import sys, re

preferred = sys.argv[1]

try:
    content = open('litellm_config.yaml', 'r', encoding='utf-8').read()
except Exception:
    print('')
    raise SystemExit(0)

# Parse all model blocks: model_name -> {model_id, region}
entries = []
blocks = re.split(r'\n  - model_name:', '\n' + content)
for block in blocks[1:]:
    lines = block.splitlines()
    name = lines[0].strip()
    model_id = ''
    region = ''
    for l in lines[1:]:
        s = l.strip()
        if s.startswith('- model_name:'):
            break
        if s.startswith('model: bedrock/') and not model_id:
            model_id = s.split('model: bedrock/', 1)[1].strip()
        if s.startswith('aws_region_name:') and not region:
            region = s.split('aws_region_name:', 1)[1].strip()
    if model_id:
        entries.append((name, model_id, region or 'eu-central-1'))

# First try: preferred alias
for name, model_id, region in entries:
    if name == preferred:
        print(f'{model_id} {region}')
        raise SystemExit(0)

print('')
PY
}

run_bedrock_converse() {
  local base_url="$1"
  local model="$2"
  local prompt="$3"
  local outfile="$4"

  # Bedrock Converse API format: content items need "type"+"text" keys (not just "text").
  HTTP_CODE=$(curl -s -o "$outfile" -w "%{http_code}" --max-time 60 \
    "$base_url/model/$model/converse" \
    -H "Content-Type: application/json" \
    -d "{\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"$prompt\"}]}],\"inferenceConfig\":{\"maxTokens\":32}}" \
    2>/dev/null || echo "000")
}

run_bedrock_converse_stream() {
  local base_url="$1"
  local model="$2"
  local prompt="$3"
  local outfile="$4"

  # Use EventStream Accept to get raw passthrough bytes — the SSE translator only
  # handles InvokeModel "chunk" events, not Converse stream event types.
  # EventStream passthrough confirms the route + SigV4 + upstream are all working.
  HTTP_CODE=$(curl -s -o "$outfile" -w "%{http_code}" --max-time 60 \
    "$base_url/model/$model/converse-stream" \
    -H "Content-Type: application/json" \
    -H "Accept: application/vnd.amazon.eventstream" \
    -d "{\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"$prompt\"}]}],\"inferenceConfig\":{\"maxTokens\":32}}" \
    2>/dev/null || echo "000")
}

bedrock_native_routes_available() {
  local base_url="$1"
  # Probe the /model/{id}/converse route directly — the Rust headroom-proxy
  # does not expose openapi.json (it proxies all unknown paths to upstream).
  # A 404 means the route is not mounted; any other response (200, 400, 500)
  # means the route exists and is being handled.
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${base_url}/model/probe-route-check/converse" \
    -H "Content-Type: application/json" \
    -d '{}' --max-time 8 2>/dev/null || echo "000")
  [[ "$code" != "404" && "$code" != "000" ]]
}

cleanup() {
  local f
  for f in "${cleanup_files[@]:-}"; do
    [[ -n "$f" ]] && rm -f "$f" 2>/dev/null || true
  done
}
trap cleanup EXIT

echo "=== LiteLLM+Headroom Gateway — Smoke Tests ==="
echo

# --- Test 2b: Bedrock headroom liveness (:4002) ---
echo "[ Test 2b: Bedrock headroom gateway liveness ]"
BEDROCK_LIVE=$(curl_with_retries "$BEDROCK_NATIVE_GATEWAY/healthz" 6 1 || true)
if [[ -n "$BEDROCK_LIVE" ]]; then
  ok "Bedrock headroom liveness responded: $BEDROCK_LIVE"
else
  fail "Bedrock headroom liveness unreachable at $BEDROCK_NATIVE_GATEWAY/healthz"
  info "Fix: ./scripts/start.sh"
fi
echo

echo "[ Preflight: wait gateway readiness ]"
if curl_with_retries "$GATEWAY/livez" 20 1 >/dev/null; then
  ok "Gateway responded on /livez"
else
  fail "Gateway did not become ready on /livez"
  info "Fix: docker compose up -d"
fi
echo

# --- Test 1: Containers running ---
echo "[ Test 1: Docker containers running ]"
for container in litellm-gateway headroom-gateway; do
  if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
    status=$(docker ps --format '{{.Status}}' --filter "name=${container}" | head -1)
    ok "${container} is running: $status"
  else
    fail "Container '${container}' is not running"
    info "Fix: ./scripts/start.sh"
  fi
done
echo

# --- Test 2: Liveness ---
echo "[ Test 2: Gateway liveness ]"
LIVE=$(curl_with_retries "$GATEWAY/livez" 6 1 || true)
if [[ -n "$LIVE" ]]; then
  ok "Liveness responded: $LIVE"
else
  fail "Liveness unreachable at $GATEWAY/livez"
  info "Fix: ./scripts/start.sh"
fi
echo

# --- Test 3: Model list ---
echo "[ Test 3: Gateway/LiteLLM model list endpoint ]"
MODELS=$(curl_with_retries "$GATEWAY/v1/models" 6 1 || true)
if [[ -z "$MODELS" ]]; then
  MODELS=$(curl_with_retries "$LITELLM_ADMIN/v1/models" 6 1 || true)
fi
if [[ -n "$MODELS" ]]; then
  COUNT=$(echo "$MODELS" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null || echo "?")
  ok "LiteLLM /v1/models reachable ($COUNT models listed)"
else
  fail "Model list unreachable at both $GATEWAY/v1/models and $LITELLM_ADMIN/v1/models"
fi
echo

# --- Test 4: GitHub Copilot end-to-end ---
echo "[ Test 4: GitHub Copilot end-to-end (lowest-cost model preferred) ]"
TMPFILE=$(make_tmp)
HTTP_CODE="000"
COPILOT_CANDIDATES=()

COPILOT_FROM_MODELS=$(echo "$MODELS" | python3 -c '
import json,sys,re
try:
    data = json.load(sys.stdin).get("data", [])
except Exception:
    print("")
    raise SystemExit(0)

ids = [m.get("id", "") for m in data if m.get("id")]
pool = [x for x in ids if x.startswith("copilot-")]

# Strict, cheapest-first allowlist only (no heuristic fallback).
preferred = [
    "copilot-gpt-5-mini",
    "copilot-gemini-3-flash",
    "copilot-gemini-3-flash-preview",
    "copilot-claude-haiku-4-5",
]
selected = [p for p in preferred if p in pool]
print("\n".join(selected))
' 2>/dev/null || echo "")

if [[ -n "$COPILOT_FROM_MODELS" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && COPILOT_CANDIDATES+=("$line")
  done <<<"$COPILOT_FROM_MODELS"
fi

# De-duplicate while preserving order (portable with bash 3 + set -u).
if [[ ${#COPILOT_CANDIDATES[@]} -gt 0 ]]; then
  COPILOT_DEDUPED=$(printf '%s\n' "${COPILOT_CANDIDATES[@]}" | python3 -c '
import sys
seen=set()
out=[]
for line in sys.stdin:
    x=line.strip()
    if x and x not in seen:
        seen.add(x)
        out.append(x)
print("\n".join(out))
')
  COPILOT_CANDIDATES=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && COPILOT_CANDIDATES+=("$line")
  done <<<"$COPILOT_DEDUPED"
fi

COPILOT_TEST_MODEL=""

for CANDIDATE in "${COPILOT_CANDIDATES[@]}"; do
  COPILOT_TEST_MODEL="$CANDIDATE"

  for ATTEMPT in 1 2 3; do
    [[ $ATTEMPT -gt 1 ]] && {
      echo "  Retrying Copilot request in 5s (attempt $ATTEMPT/3, model $COPILOT_TEST_MODEL)..."
      sleep 5
    }

    run_chat_completion "$GATEWAY" "$COPILOT_TEST_MODEL" "Reply with single word: COPILOTOK" 10 "$TMPFILE"

    [[ "$HTTP_CODE" != "502" && "$HTTP_CODE" != "429" ]] && break
  done

  if [[ "$HTTP_CODE" == "200" ]]; then
    break
  fi

  if [[ "$HTTP_CODE" == "400" || "$HTTP_CODE" == "404" ]]; then
    ERR_SNIPPET=$(python3 -c "import json; d=json.load(open('$TMPFILE')); print(str(d).lower()[:400])" 2>/dev/null || tr '[:upper:]' '[:lower:]' <"$TMPFILE" | head -c 400)
    if echo "$ERR_SNIPPET" | grep -Eq "model|not found|unsupported|does not exist"; then
      echo "  Model not available via Copilot route: $COPILOT_TEST_MODEL (trying next candidate)"
      continue
    fi
  fi

  break
done

if [[ "$HTTP_CODE" == "200" ]] && response_has_choices "$TMPFILE"; then
  CONTENT=$(response_first_content "$TMPFILE")
  if [[ -n "$CONTENT" ]]; then
    ok "Copilot response using $COPILOT_TEST_MODEL: \"$CONTENT\" (HTTP $HTTP_CODE)"
  else
    ok "Copilot request using $COPILOT_TEST_MODEL succeeded (HTTP $HTTP_CODE, empty content)"
  fi
else
  ERR=$(python3 -c "import json; d=json.load(open('$TMPFILE')); print(str(d)[:200])" 2>/dev/null || head -c 200 "$TMPFILE")
  fail "Copilot request failed (HTTP $HTTP_CODE): $ERR"
  info "Fix: ./scripts/auth-fix.sh"
  CODE_LINE=$(docker logs litellm-gateway 2>/dev/null | grep -E 'Please visit https://github.com/login/device and enter code' | tail -1 || true)
  if [[ -n "$CODE_LINE" ]]; then
    info "Copilot device auth pending: $CODE_LINE"
    info "Open: https://github.com/login/device"
  fi
fi
echo

# --- Test 5: Bedrock end-to-end ---
BEDROCK_TEST_MODEL=$(echo "$MODELS" | python3 -c "
import json,sys
try:
    data=json.load(sys.stdin).get('data',[])
except Exception:
    print('')
    raise SystemExit(0)
ids=[m.get('id','') for m in data]

# Prefer explicitly cheapest aliases from current AWS Pricing + current alias inventory.
preferred=[
  'bedrock-mistral-voxtral-mini-3b-2507',
  'bedrock-google-gemma-3-4b-it',
  'bedrock-mistral-ministral-3-3b-instruct',
  'bedrock-eu-amazon-nova-micro-v1-0',
  'bedrock-eu-amazon-nova-2-lite-v1-0',
  'bedrock-global-amazon-nova-2-lite-v1-0',
  'bedrock-eu-amazon-nova-lite-v1-0',
  'bedrock-openai-gpt-oss-20b-1-0',
  'bedrock-eu-anthropic-claude-haiku-4-5-20251001-v1-0',
  'bedrock-global-anthropic-claude-haiku-4-5-20251001-v1-0',
]
for p in preferred:
    if p in ids:
        print(p)
        raise SystemExit(0)
print('')
" 2>/dev/null || echo "")

if [[ -z "$BEDROCK_TEST_MODEL" ]]; then
  fail "No bedrock-* model aliases found in /v1/models"
  info "Fix: ./scripts/start.sh (regenerates litellm_config.yaml from AWS Bedrock)"
  echo
else
  echo "[ Test 5: AWS Bedrock end-to-end (lowest-cost model preferred: $BEDROCK_TEST_MODEL) ]"
  TMPFILE=$(make_tmp)
  run_chat_completion "$GATEWAY" "$BEDROCK_TEST_MODEL" "Reply with the single word: BEDROCKOK" 8 "$TMPFILE"

  if [[ "$HTTP_CODE" == "200" ]] && response_has_choices "$TMPFILE"; then
    CONTENT=$(response_first_content "$TMPFILE")
    ok "Bedrock response: \"$CONTENT\" (HTTP $HTTP_CODE)"
  else
    ERR=$(python3 -c "import json; d=json.load(open('$TMPFILE')); print(str(d)[:200])" 2>/dev/null || head -c 200 "$TMPFILE")
    fail "Bedrock request failed (HTTP $HTTP_CODE): $ERR"
    info "AWS credentials issue? Run: aws sso login --profile ${BEDROCK_AWS_PROFILE:-default}"
  fi
fi
echo

# --- Test 5b: Bedrock native Converse + ConverseStream via :4002 ---
echo "[ Test 5b: Bedrock native Converse + ConverseStream via :4002 ]"
if [[ -z "$BEDROCK_TEST_MODEL" ]]; then
  fail "No bedrock-* model found in :4001 model list — cannot run Test 5b"
  info "Fix: ./scripts/start.sh"
elif ! bedrock_native_routes_available "$BEDROCK_NATIVE_GATEWAY"; then
  fail "Bedrock :4002 does not expose native /model/{id}/converse routes"
  info "Image lacks native Bedrock route surface; set HEADROOM_BEDROCK_IMAGE to a native bedrock image and restart"
else
  RESOLVED=$(resolve_bedrock_native_model "$BEDROCK_TEST_MODEL")
  BEDROCK_NATIVE_MODEL=$(echo "$RESOLVED" | awk '{print $1}')
  BEDROCK_NATIVE_REGION=$(echo "$RESOLVED" | awk '{print $2}')
  BEDROCK_NATIVE_REGION="${BEDROCK_NATIVE_REGION:-eu-central-1}"
  if [[ -z "$BEDROCK_NATIVE_MODEL" ]]; then
    fail "Could not resolve native model id from alias: $BEDROCK_TEST_MODEL"
    info "Fix: regenerate litellm_config.yaml via ./scripts/start.sh"
  else
    # If the model's region differs from the proxy's configured region, restart the proxy
    # with the correct region so SigV4 targets the right Bedrock endpoint.
    CURRENT_PROXY_REGION=$(docker inspect headroom-bedrock-gateway \
      --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
      grep 'HEADROOM_PROXY_BEDROCK_REGION=' | cut -d= -f2 || echo "eu-central-1")
    if [[ "$BEDROCK_NATIVE_REGION" != "$CURRENT_PROXY_REGION" ]]; then
      info "Model region ($BEDROCK_NATIVE_REGION) differs from proxy region ($CURRENT_PROXY_REGION); restarting proxy..."
      AWS_REGION="$BEDROCK_NATIVE_REGION" docker compose up -d headroom-bedrock >/dev/null 2>&1
      sleep 4
    fi

    TMPFILE=$(make_tmp)
    run_bedrock_converse "$BEDROCK_NATIVE_GATEWAY" "$BEDROCK_NATIVE_MODEL" "Reply with the single word: BEDROCKNATIVEOK" "$TMPFILE"
    if [[ "$HTTP_CODE" == "200" ]]; then
      # Proxy returns OpenAI-format response (choices[0].message.content)
      CONTENT=$(python3 -c "
import json
d=json.load(open('$TMPFILE'))
# OpenAI format (what the Rust proxy returns for /converse)
if 'choices' in d:
    print((d['choices'][0].get('message',{}).get('content','') or '').strip())
# Native Bedrock Converse format (fallback)
elif 'output' in d:
    for b in d.get('output',{}).get('message',{}).get('content',[]):
        if isinstance(b,dict) and 'text' in b:
            print(b['text'].strip()); break
" 2>/dev/null || echo "")
      ok "Bedrock :4002 converse passed (HTTP $HTTP_CODE, model: $BEDROCK_NATIVE_MODEL, region: $BEDROCK_NATIVE_REGION, text: \"${CONTENT:-<empty>}\")"
    else
      ERR=$(python3 -c "import json; d=json.load(open('$TMPFILE')); print(str(d)[:220])" 2>/dev/null || head -c 220 "$TMPFILE")
      fail "Bedrock :4002 converse failed (HTTP $HTTP_CODE): $ERR"
      info "Check native route wiring/image: docker logs headroom-bedrock-gateway"
    fi

    TMPFILE=$(make_tmp)
    run_bedrock_converse_stream "$BEDROCK_NATIVE_GATEWAY" "$BEDROCK_NATIVE_MODEL" "Reply with the single word: BEDROCKSTREAMOK" "$TMPFILE"
    # converse-stream uses EventStream passthrough — check for raw binary response bytes
    STREAM_BYTES=$(wc -c <"$TMPFILE" 2>/dev/null | tr -d ' ')
    if [[ "$HTTP_CODE" == "200" ]] && [[ "${STREAM_BYTES:-0}" -gt 0 ]]; then
      ok "Bedrock :4002 converse-stream passed (HTTP $HTTP_CODE, EventStream bytes: $STREAM_BYTES, model: $BEDROCK_NATIVE_MODEL, region: $BEDROCK_NATIVE_REGION)"
    else
      ERR=$(python3 -c "import json; d=json.load(open('$TMPFILE')); print(str(d)[:220])" 2>/dev/null || head -c 220 "$TMPFILE")
      fail "Bedrock :4002 converse-stream failed (HTTP $HTTP_CODE, bytes: ${STREAM_BYTES:-0}): $ERR"
      info "Check headroom-bedrock logs: docker logs headroom-bedrock-gateway"
    fi
  fi
fi
echo

# --- Test 6: Kilo config ---
echo "[ Test 6: Kilo config gateway baseURL ]"
KILO_CONF="$HOME/.config/kilo/kilo.jsonc"
if [[ -f "$KILO_CONF" ]]; then
  if python3 -c '
import json, pathlib, re, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
text = re.sub(r"(^|\s)//.*$", "", text, flags=re.M)
data = json.loads(text)
provider = data.get("provider", {})
errors = []

# Copilot + openai-compatible should point to :4000
for key in ("github-copilot", "openai-compatible"):
    block = provider.get(key, {})
    opts = block.get("options", {}) if isinstance(block, dict) else {}
    url = opts.get("baseURL", "")
    if url and url != "http://127.0.0.1:4000/v1":
        errors.append(f"{key}: {url} (expected http://127.0.0.1:4000/v1)")

# Bedrock should point to :4002 (no /v1 suffix — headroom is the endpoint)
bedrock = provider.get("amazon-bedrock", {})
bedrock_opts = bedrock.get("options", {}) if isinstance(bedrock, dict) else {}
bedrock_url = bedrock_opts.get("baseURL", "")
if bedrock_url and bedrock_url not in ("http://127.0.0.1:4002", "http://127.0.0.1:4002/v1"):
    errors.append(f"amazon-bedrock: {bedrock_url} (expected http://127.0.0.1:4002)")

if errors:
    for e in errors: print(f"  MISMATCH: {e}", file=__import__("sys").stderr)
    raise SystemExit(1)
' "$KILO_CONF" 2>/dev/null; then
    ok "kilo.jsonc provider baseURLs correct"
  else
    fail "kilo.jsonc provider baseURLs are not correctly set"
    info "Copilot/openai-compatible: http://127.0.0.1:4000/v1"
    info "amazon-bedrock:           http://127.0.0.1:4002"
    info "Fix: ./scripts/setup-kilo.sh"
  fi
else
  fail "kilo.jsonc not found at $KILO_CONF"
  info "Fix: ./scripts/setup-kilo.sh"
fi
echo

# --- Summary ---
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo

if [[ $FAIL -gt 0 ]]; then
  echo "  Some tests failed. Quick fixes:"
  echo "    Not running:  ./scripts/start.sh"
  echo "    Auth (403):   ./scripts/auth-fix.sh"
    echo "    AWS expired:  aws sso login --profile ${BEDROCK_AWS_PROFILE:-default}"
  exit 1
fi

echo "  All tests passed. Gateway is working correctly."
