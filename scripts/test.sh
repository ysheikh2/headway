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
  local model="$1"
  local prompt="$2"
  local max_tokens="$3"
  local outfile="$4"

  HTTP_CODE=$(curl -s -o "$outfile" -w "%{http_code}" --max-time 50 \
    "$GATEWAY/v1/chat/completions" \
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

cleanup() {
  local f
  for f in "${cleanup_files[@]:-}"; do
    [[ -n "$f" ]] && rm -f "$f" 2>/dev/null || true
  done
}
trap cleanup EXIT

echo "=== LiteLLM+Headroom Gateway — Smoke Tests ==="
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

    run_chat_completion "$COPILOT_TEST_MODEL" "Reply with single word: COPILOTOK" 10 "$TMPFILE"

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
  run_chat_completion "$BEDROCK_TEST_MODEL" "Reply with the single word: BEDROCKOK" 8 "$TMPFILE"

  if [[ "$HTTP_CODE" == "200" ]] && response_has_choices "$TMPFILE"; then
    CONTENT=$(response_first_content "$TMPFILE")
    ok "Bedrock response: \"$CONTENT\" (HTTP $HTTP_CODE)"
  else
    ERR=$(python3 -c "import json; d=json.load(open('$TMPFILE')); print(str(d)[:200])" 2>/dev/null || head -c 200 "$TMPFILE")
    fail "Bedrock request failed (HTTP $HTTP_CODE): $ERR"
    info "AWS credentials issue? Run: aws sso login --profile d2i_stg"
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
expected = "http://127.0.0.1:4000/v1"
for key in ("github-copilot", "openai-compatible"):
    block = provider.get(key, {})
    opts = block.get("options", {}) if isinstance(block, dict) else {}
    if opts.get("baseURL") != expected:
        raise SystemExit(1)
' "$KILO_CONF" 2>/dev/null; then
    ok "kilo.jsonc points to gateway (port 4000)"
  else
    fail "kilo.jsonc provider baseURLs are not fully set to this gateway"
    info "Expected both providers to use: \"http://127.0.0.1:4000/v1\""
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
  echo "    AWS expired:  aws sso login --profile d2i_stg"
  exit 1
fi

echo "  All tests passed. Gateway is working correctly."
