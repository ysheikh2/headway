#!/usr/bin/env bash
# test.sh — Smoke tests for the LiteLLM+headroom gateway.
# Run this any time you want to verify the gateway is working end-to-end.
#
# Tests:
#   1. Docker container is running
#   2. Gateway liveness endpoint responds
#   3. Gateway model list is reachable
#   4. LiteLLM model list is reachable
#   4. GitHub Copilot request goes through (cheap model preferred)
#   5. Bedrock request goes through (auto-discovered bedrock-* alias)
#   6. Kilo config has the correct baseURL

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
    for ((i=1; i<=attempts; i++)); do
        out=$(curl -sf --max-time 8 "$url" 2>/dev/null || true)
        if [[ -n "$out" ]]; then
            echo "$out"
            return 0
        fi
        sleep "$delay"
    done
    return 1
}

ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
info() { echo "         $*"; }

echo "=== LiteLLM+Headroom Gateway — Smoke Tests ==="
echo

echo "[ Preflight: wait for gateway readiness ]"
if curl_with_retries "$GATEWAY/livez" 20 1 >/dev/null; then
    ok "Gateway responded on /livez"
else
    fail "Gateway did not become ready on /livez"
    info "Fix: docker compose up -d"
fi
echo

# --- Test 1: Container running ---
echo "[ Test 1: Docker container running ]"
if docker ps --format '{{.Names}}' | grep -q "^litellm-gateway$"; then
    STATUS=$(docker ps --format '{{.Status}}' --filter name=litellm-gateway | head -1)
    ok "litellm-gateway is running: $STATUS"
else
    fail "Container 'litellm-gateway' is not running"
    info "Fix: ./scripts/start.sh"
fi
echo

# --- Test 2: Liveness ---
echo "[ Test 2: Gateway liveness endpoint ]"
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
echo "[ Test 4: GitHub Copilot end-to-end (cheap model preferred) ]"
TMPFILE=$(mktemp /tmp/gateway-test-XXXXXX)
TS=$(date +%s)
HTTP_CODE="000"
COPILOT_CANDIDATES=("claude-haiku-4.5" "gemini-3-flash" "gpt-5-mini" "claude-sonnet-4.6")
COPILOT_TEST_MODEL=""
for CANDIDATE in "${COPILOT_CANDIDATES[@]}"; do
    COPILOT_TEST_MODEL="$CANDIDATE"
    for ATTEMPT in 1 2 3; do
        [[ $ATTEMPT -gt 1 ]] && { echo "  Retrying Copilot request in 5s (attempt $ATTEMPT/3, model $COPILOT_TEST_MODEL)..."; sleep 5; }
        HTTP_CODE=$(curl -s -o "$TMPFILE" -w "%{http_code}" --max-time 45 \
            "$GATEWAY/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{\"model\":\"$COPILOT_TEST_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ts=$TS — Reply with the single word: COPILOTOK\"}],\"max_tokens\":10,\"stream\":false}" \
            2>/dev/null || echo "000")
        [[ "$HTTP_CODE" != "502" && "$HTTP_CODE" != "429" ]] && break
    done

    if [[ "$HTTP_CODE" == "200" ]]; then
        break
    fi

    # Move to the next model for known model-availability / routing failures.
    if [[ "$HTTP_CODE" == "400" || "$HTTP_CODE" == "404" ]]; then
        ERR_SNIPPET=$(python3 -c "import json; d=json.load(open('$TMPFILE')); print(str(d).lower()[:400])" 2>/dev/null || cat "$TMPFILE" | tr '[:upper:]' '[:lower:]' | head -c 400)
        if echo "$ERR_SNIPPET" | grep -Eq "model|not found|unsupported|does not exist"; then
            echo "  Model not available via Copilot route: $COPILOT_TEST_MODEL (trying next candidate)"
            continue
        fi
    fi

    # Non-model error; stop fallback chain and report.
    break
done

if [[ "$HTTP_CODE" == "200" ]] && ! python3 -c "import json,sys; d=json.load(open('$TMPFILE')); sys.exit(0 if d.get('error') else 1)" 2>/dev/null; then
    CONTENT=$(python3 -c "import json; d=json.load(open('$TMPFILE')); c=d.get('choices',[]); print((c[0]['message'].get('content','') if c else '').strip())" 2>/dev/null || echo "")
    if [[ -n "$CONTENT" ]]; then
        ok "Copilot response using $COPILOT_TEST_MODEL: \"$CONTENT\" (HTTP $HTTP_CODE)"
    else
        ok "Copilot request using $COPILOT_TEST_MODEL succeeded (HTTP $HTTP_CODE, empty non-stream choices is acceptable)"
    fi
else
    ERR=$(python3 -c "import json; d=json.load(open('$TMPFILE')); print(str(d)[:200])" 2>/dev/null || cat "$TMPFILE" | head -c 200)
    fail "Copilot request failed (HTTP $HTTP_CODE): $ERR"
    info "Fix: ./scripts/auth-fix.sh"
    CODE_LINE=$(docker logs litellm-gateway 2>/dev/null | grep -E 'Please visit https://github.com/login/device and enter code' | tail -1 || true)
    if [[ -n "$CODE_LINE" ]]; then
        info "$CODE_LINE"
    fi
fi
rm -f "$TMPFILE"
echo

# --- Test 5: Bedrock end-to-end ---
BEDROCK_TEST_MODEL=$(echo "$MODELS" | python3 -c "
import json,sys
data=json.load(sys.stdin).get('data',[])
ids=[m.get('id','') for m in data]
preferred=[
    'bedrock-eu-anthropic-claude-haiku-4-5-20251001-v1-0',
    'bedrock-global-anthropic-claude-haiku-4-5-20251001-v1-0',
]
for p in preferred:
    if p in ids:
        print(p)
        raise SystemExit(0)
candidates=[m for m in ids if m.startswith('bedrock-') and ('haiku' in m or 'nova-lite' in m or 'nova-micro' in m)]
if not candidates:
    candidates=[m for m in ids if m.startswith('bedrock-')]
print(sorted(candidates)[0] if candidates else '')
" 2>/dev/null || echo "")

if [[ -z "$BEDROCK_TEST_MODEL" ]]; then
    fail "No bedrock-* model aliases found in /v1/models"
    info "Fix: ./scripts/start.sh (regenerates litellm_config.yaml from AWS Bedrock)"
    echo
else
echo "[ Test 5: AWS Bedrock end-to-end ($BEDROCK_TEST_MODEL) ]"
TMPFILE=$(mktemp /tmp/gateway-test-XXXXXX)
TS=$(date +%s)
HTTP_CODE=$(curl -s -o "$TMPFILE" -w "%{http_code}" --max-time 45 \
    "$GATEWAY/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$BEDROCK_TEST_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ts=$TS — Reply with the single word: BEDROCKOK\"}],\"max_tokens\":10,\"stream\":false}" \
    2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" ]] && python3 -c "import json; d=json.load(open('$TMPFILE')); exit(0 if d.get('choices') else 1)" 2>/dev/null; then
    CONTENT=$(python3 -c "import json; d=json.load(open('$TMPFILE')); print(d['choices'][0]['message']['content'].strip())" 2>/dev/null || echo "?")
    ok "Bedrock response: \"$CONTENT\" (HTTP $HTTP_CODE)"
else
    ERR=$(python3 -c "import json; d=json.load(open('$TMPFILE')); print(str(d)[:200])" 2>/dev/null || cat "$TMPFILE" | head -c 200)
    fail "Bedrock request failed (HTTP $HTTP_CODE): $ERR"
    info "AWS credentials issue? Run: aws sso login --profile d2i_stg"
fi
rm -f "$TMPFILE"
fi
echo

# --- Test 6: Kilo config ---
echo "[ Test 6: Kilo config has gateway baseURL ]"
KILO_CONF="$HOME/.config/kilo/kilo.jsonc"
if [[ -f "$KILO_CONF" ]]; then
    if grep -q '"github-copilot"' "$KILO_CONF" 2>/dev/null \
        && grep -q '"openai-compatible"' "$KILO_CONF" 2>/dev/null \
        && grep -q '"baseURL": "http://127.0.0.1:4000/v1"' "$KILO_CONF" 2>/dev/null; then
        ok "kilo.jsonc points to gateway (port 4000)"
    else
        fail "kilo.jsonc provider baseURLs are not fully set to this gateway"
        info "Expected: \"baseURL\": \"http://127.0.0.1:4000/v1\""
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
else
    echo "  All tests passed. Gateway is working correctly."
fi
