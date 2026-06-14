#!/usr/bin/env bash
# test.sh — Smoke tests Headway gateway lanes.
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
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

  HTTP_CODE=$(curl -s -o "$outfile" -w "%{http_code}" --max-time 15 \
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
  # Resolves a bedrock-* alias from litellm_config.yaml to native model id.
  # Returns "MODEL_ID REGION".
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
  local request_id="$5"

  # Bedrock Converse API format: content items need "type"+"text" keys (not just "text").
  HTTP_CODE=$(curl -s -o "$outfile" -w "%{http_code}" --max-time 25 \
    "$base_url/model/$model/converse" \
    -H "Content-Type: application/json" \
    -H "x-request-id: $request_id" \
    -d "{\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"$prompt\"}]}],\"inferenceConfig\":{\"maxTokens\":32}}" \
    2>/dev/null || echo "000")
}

run_bedrock_converse_compression_probe() {
  local base_url="$1"
  local model="$2"
  local outfile="$3"
  local request_id="$4"
  local payload_file

  payload_file=$(make_tmp)
  python3 - "$payload_file" <<'PY'
import json
import sys
import time

out = sys.argv[1]
# Unique per run so the CompressionCache never returns a cached result —
# each test run must exercise the full compression pipeline.
probe_run_id = int(time.time() * 1000)
# Large repetitive payload — cycles through 25 unique items.
arr = [
    {
        "id": i % 25,
        "name": f"item{i % 25}",
        "status": "ok",
        "count": i,
        "payload": "x" * 80,
        "run": probe_run_id,
    }
    for i in range(2000)
]
# Build a realistic multi-turn conversation. SmartCrusher (max_items_after_crush=8)
# only activates when non-protected messages > 8. With protect_recent=2 and 14 total
# messages, non-protected = 12 > 8, so SmartCrusher drops the oldest 4 messages
# (including the big toolResult at index 2) → measurable token savings.
msgs = [
    # Turn 0 — old, will be crushed
    {"role": "user", "content": [{"type": "text", "text": "Start the analysis."}]},
    {
        "role": "assistant",
        "content": [{"toolUse": {"toolUseId": "toolu_probe_42", "name": "custom_fetch", "input": {"q": "all"}}}],
    },
    # Big tool result in earliest history (index 2 of 14 — far outside protect window)
    {
        "role": "user",
        "content": [{"toolResult": {"toolUseId": "toolu_probe_42", "content": [{"json": arr}]}}],
    },
    {"role": "assistant", "content": [{"type": "text", "text": "Data fetched. Reviewing."}]},
    # Turn 2
    {"role": "user", "content": [{"type": "text", "text": "Any errors?"}]},
    {"role": "assistant", "content": [{"type": "text", "text": "No errors found."}]},
    # Turn 3
    {"role": "user", "content": [{"type": "text", "text": "Check the totals."}]},
    {"role": "assistant", "content": [{"type": "text", "text": "Totals look correct."}]},
    # Turn 4
    {"role": "user", "content": [{"type": "text", "text": "What about the averages?"}]},
    {"role": "assistant", "content": [{"type": "text", "text": "Averages are within range."}]},
    # Turn 5
    {"role": "user", "content": [{"type": "text", "text": "Anything else to check?"}]},
    {"role": "assistant", "content": [{"type": "text", "text": "All checks passed."}]},
    # Recent protected (last 2 messages with protect_recent=2)
    {"role": "user", "content": [{"type": "text", "text": "Summarize in one short line."}]},
    {"role": "assistant", "content": [{"type": "text", "text": "Ready."}]},
]
payload = {"messages": msgs, "inferenceConfig": {"maxTokens": 32}}
with open(out, "w", encoding="utf-8") as f:
    f.write(json.dumps(payload, separators=(",", ":")))
PY

  HTTP_CODE=$(curl -s -o "$outfile" -w "%{http_code}" --max-time 90 \
    "$base_url/model/$model/converse" \
    -H "Content-Type: application/json" \
    -H "x-request-id: $request_id" \
    --data-binary @"$payload_file" \
    2>/dev/null || echo "000")
}

get_bedrock_native_saved_tokens() {
  local base_url="$1"
  curl -s --max-time 8 "$base_url/bedrock-native/stats" 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    print(int((d.get("tokens") or {}).get("saved",0)))
except Exception:
    print(0)
'
}

get_copilot_saved_tokens() {
  local base_url="$1"
  curl -s --max-time 8 "$base_url/stats" 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    print(int((d.get("tokens") or {}).get("saved",0)))
except Exception:
    print(0)
'
}

get_copilot_cache_read_tokens() {
  local base_url="$1"
  curl -s --max-time 8 "$base_url/stats" 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    print(int(((d.get("prefix_cache") or {}).get("totals") or {}).get("cache_read_tokens",0)))
except Exception:
    print(0)
'
}

get_copilot_cache_savings_usd() {
  local base_url="$1"
  curl -s --max-time 8 "$base_url/stats" 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    print(float((d.get("cost") or {}).get("cache_savings_usd",0.0)))
except Exception:
    print(0.0)
'
}

run_copilot_cache_probe() {
  # Send the SAME large stable prompt twice so the provider (GitHub Copilot for
  # Claude models) serves the second from its automatic prompt cache and reports
  # cached_tokens. Unlike the compression probe, the payload is stable (no run id)
  # so the provider cache can hit.
  local base_url="$1"
  local model="$2"
  local payload_file
  payload_file=$(make_tmp)
  python3 - "$payload_file" "$model" <<'PY'
import json, sys
out, model = sys.argv[1], sys.argv[2]
arr = [{"id": i % 25, "name": f"item{i % 25}", "status": "ok", "count": i,
        "payload": "x" * 60} for i in range(500)]
big = json.dumps(arr)
msgs = [
    {"role": "user", "content": "Analyze this dataset and remember it."},
    {"role": "assistant", "content": None,
     "tool_calls": [{"id": "call_cache", "type": "function",
                     "function": {"name": "fetch", "arguments": "{}"}}]},
    {"role": "tool", "tool_call_id": "call_cache", "content": big},
    {"role": "assistant", "content": "Loaded."},
    {"role": "user", "content": "Ready?"},
    {"role": "assistant", "content": "Yes."},
]
with open(out, "w", encoding="utf-8") as f:
    f.write(json.dumps({"model": model, "messages": msgs, "max_tokens": 8, "stream": False},
                       separators=(",", ":")))
PY
  local n
  for n in 1 2; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 60 \
      "$base_url/v1/chat/completions" -H "Content-Type: application/json" \
      --data-binary @"$payload_file" 2>/dev/null || echo "000")
    sleep 1
  done
}

run_copilot_compression_probe() {
  # Build a compressible OpenAI-format conversation and POST it to the Copilot
  # lane (:4000). A large, stale tool result sits early in history (outside the
  # protect_recent window) so headroom's compression pipeline removes tokens.
  # Compression is recorded before upstream forwarding, so the savings delta is
  # measurable regardless of the upstream completion status.
  local base_url="$1"
  local model="$2"
  local outfile="$3"
  local payload_file
  payload_file=$(make_tmp)
  python3 - "$payload_file" "$model" <<'PY'
import json, sys, time

out, model = sys.argv[1], sys.argv[2]
# Unique per run so the CompressionCache never short-circuits the pipeline.
run_id = int(time.time() * 1000)
arr = [
    {"id": i % 25, "name": f"item{i % 25}", "status": "ok", "count": i,
     "payload": "x" * 80, "run": run_id}
    for i in range(1200)
]
big = json.dumps(arr)
msgs = [
    {"role": "user", "content": "Start the analysis."},
    {"role": "assistant", "content": None,
     "tool_calls": [{"id": "call_probe_42", "type": "function",
                     "function": {"name": "custom_fetch", "arguments": "{\"q\":\"all\"}"}}]},
    # Big stale tool result (index 2 of 14 — outside protect_recent=2).
    {"role": "tool", "tool_call_id": "call_probe_42", "content": big},
    {"role": "assistant", "content": "Data fetched. Reviewing."},
    {"role": "user", "content": "Any errors?"},
    {"role": "assistant", "content": "No errors found."},
    {"role": "user", "content": "Check the totals."},
    {"role": "assistant", "content": "Totals look correct."},
    {"role": "user", "content": "What about the averages?"},
    {"role": "assistant", "content": "Averages are within range."},
    {"role": "user", "content": "Anything else to check?"},
    {"role": "assistant", "content": "All checks passed."},
    # Recent protected (last 2).
    {"role": "user", "content": "Summarize in one short line."},
    {"role": "assistant", "content": "Ready."},
]
payload = {"model": model, "messages": msgs, "max_tokens": 16, "stream": False}
with open(out, "w", encoding="utf-8") as f:
    f.write(json.dumps(payload, separators=(",", ":")))
PY

  HTTP_CODE=$(curl -s -o "$outfile" -w "%{http_code}" --max-time 60 \
    "$base_url/v1/chat/completions" \
    -H "Content-Type: application/json" \
    --data-binary @"$payload_file" \
    2>/dev/null || echo "000")
}

run_bedrock_converse_stream() {
  local base_url="$1"
  local model="$2"
  local prompt="$3"
  local outfile="$4"
  local request_id="$5"

  # Use EventStream Accept to get raw passthrough bytes — the SSE translator only
  # handles InvokeModel "chunk" events, not Converse stream event types.
  # EventStream passthrough confirms the route + SigV4 + upstream are all working.
  HTTP_CODE=$(curl -s -o "$outfile" -w "%{http_code}" --max-time 25 \
    "$base_url/model/$model/converse-stream" \
    -H "Content-Type: application/json" \
    -H "Accept: application/vnd.amazon.eventstream" \
    -H "x-request-id: $request_id" \
    -d "{\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"$prompt\"}]}],\"inferenceConfig\":{\"maxTokens\":32}}" \
    2>/dev/null || echo "000")
}

bedrock_log_has_for_request() {
  local request_id="$1"
  local marker="$2"
  local tail_lines="${BEDROCK_LOG_TAIL_LINES:-4000}"
  docker logs --tail "$tail_lines" headroom-bedrock-gateway 2>/dev/null | grep -F "$request_id" | grep -F "$marker" >/dev/null 2>&1
}

bedrock_native_routes_available() {
  local base_url="$1"
  # Probe the /model/{id}/converse route directly — the Rust Bedrock lane
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

echo "=== Headway Gateway — Smoke Tests ==="
echo

# --- Preflight: Copilot auth check ---
# Detect a pending GitHub device-code auth early so tests fail fast instead of
# waiting through 25 s × 3 retries × N model candidates.
COPILOT_DEVICE_CODE=$(docker logs litellm-gateway 2>/dev/null |
  grep -E 'Please visit https://github.com/login/device and enter code' |
  tail -1 || true)
if [[ -n "$COPILOT_DEVICE_CODE" ]]; then
  echo "[WARN] Copilot device auth is pending — complete it before testing:"
  echo "       $COPILOT_DEVICE_CODE"
  echo "       Open: https://github.com/login/device"
  echo "       Then run: ./headway auth"
  echo
fi

# --- Preflight: allow headroom-gateway prewarm on fresh start ---
# The Kompress ONNX model cold-load takes ~30 s. If the gateway has been up
# for less than 90 s, pause briefly so the prewarm thread finishes before the
# compression probe runs (avoids spurious timeouts immediately after a restart).
HEADROOM_UPTIME=$(docker inspect headroom-bedrock-gateway --format '{{.State.StartedAt}}' 2>/dev/null |
  python3 -c "
import sys, datetime
try:
    ts = sys.stdin.read().strip()
    started = datetime.datetime.fromisoformat(ts.replace('Z','+00:00'))
    now = datetime.datetime.now(datetime.timezone.utc)
    print(int((now - started).total_seconds()))
except Exception:
    print(9999)
" 2>/dev/null || echo 9999)
if [[ "${HEADROOM_UPTIME:-9999}" -lt 90 ]]; then
  WAIT_SECS=$((90 - HEADROOM_UPTIME))
  echo "[ Preflight: headroom-bedrock-gateway started ${HEADROOM_UPTIME}s ago; waiting ${WAIT_SECS}s for prewarm ]"
  sleep "$WAIT_SECS"
  echo
fi

# --- Test 2b: Bedrock headroom liveness (:4002) ---
echo "[ Test 2b: Bedrock headroom gateway liveness ]"
BEDROCK_LIVE=$(curl_with_retries "$BEDROCK_NATIVE_GATEWAY/livez" 3 1 || true)
if [[ -n "$BEDROCK_LIVE" ]]; then
  ok "Bedrock headroom liveness responded: $BEDROCK_LIVE"
else
  fail "Bedrock headroom liveness unreachable at $BEDROCK_NATIVE_GATEWAY/livez"
  info "Fix: ./headway up"
fi
echo

echo "[ Preflight: wait gateway readiness ]"
if curl_with_retries "$GATEWAY/livez" 5 1 >/dev/null; then
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
    info "Fix: ./headway up"
  fi
done
echo

# --- Test 2: Liveness ---
echo "[ Test 2: Gateway liveness ]"
LIVE=$(curl_with_retries "$GATEWAY/livez" 3 1 || true)
if [[ -n "$LIVE" ]]; then
  ok "Liveness responded: $LIVE"
else
  fail "Liveness unreachable at $GATEWAY/livez"
  info "Fix: ./headway up"
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
COPILOT_CANDIDATES=""

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
  COPILOT_CANDIDATES="$COPILOT_FROM_MODELS"
fi

# De-duplicate while preserving order.
if [[ -n "$COPILOT_CANDIDATES" ]]; then
  COPILOT_CANDIDATES=$(printf '%s\n' "$COPILOT_CANDIDATES" | python3 -c '
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
fi

COPILOT_TEST_MODEL=""

while IFS= read -r CANDIDATE; do
  [[ -z "$CANDIDATE" ]] && continue
  COPILOT_TEST_MODEL="$CANDIDATE"

  for ATTEMPT in 1 2 3; do
    [[ $ATTEMPT -gt 1 ]] && {
      echo "  Retrying Copilot request in 2s (attempt $ATTEMPT/3, model $COPILOT_TEST_MODEL)..."
      sleep 2
    }

    run_chat_completion "$GATEWAY" "$COPILOT_TEST_MODEL" "Reply with single word: COPILOTOK" 10 "$TMPFILE"

    # Only retry on transient gateway errors; auth failures and timeouts should not be retried.
    [[ "$HTTP_CODE" == "502" || "$HTTP_CODE" == "429" ]] || break
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
done <<<"$COPILOT_CANDIDATES"

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
  info "Fix: ./headway auth"
  CODE_LINE=$(docker logs litellm-gateway 2>/dev/null | grep -E 'Please visit https://github.com/login/device and enter code' | tail -1 || true)
  if [[ -n "$CODE_LINE" ]]; then
    info "Copilot device auth pending: $CODE_LINE"
    info "Open: https://github.com/login/device"
  fi
fi
echo

# --- Test 4b: Copilot lane compression (:4000) ---
# Guards against silent compression regressions on the Copilot lane (the bedrock
# lane already has an equivalent probe). Only runs if the Copilot e2e above
# resolved a working model.
echo "[ Test 4b: Copilot lane compression (:4000) ]"
if [[ "$HTTP_CODE" == "200" && -n "$COPILOT_TEST_MODEL" ]]; then
  PROBE_OUT=$(make_tmp)
  COP_SAVED_BEFORE=$(get_copilot_saved_tokens "$GATEWAY")
  run_copilot_compression_probe "$GATEWAY" "$COPILOT_TEST_MODEL" "$PROBE_OUT"
  COP_PROBE_HTTP="$HTTP_CODE"
  COP_SAVED_AFTER=$(get_copilot_saved_tokens "$GATEWAY")
  COP_DELTA=$((COP_SAVED_AFTER - COP_SAVED_BEFORE))
  if [[ "$COP_DELTA" -gt 0 ]]; then
    ok "Copilot compression recorded measurable token savings (+${COP_DELTA} tokens, model: $COPILOT_TEST_MODEL, probe HTTP $COP_PROBE_HTTP)"
  else
    fail "Copilot compression probe removed 0 tokens (saved before=$COP_SAVED_BEFORE after=$COP_SAVED_AFTER, model: $COPILOT_TEST_MODEL, probe HTTP $COP_PROBE_HTTP)"
    info "A compressible payload (large stale tool result) should yield savings; check headroom compression pipeline on :4000."
  fi
else
  info "Skipped: Copilot e2e did not resolve a working model above."
fi
echo

# --- Test 4c: Copilot prefix-cache savings pricing (:4000) ---
# Provider auto-caching (Copilot for Claude) reports cached_tokens; headroom
# records them but cannot price them, so the unified patch values them via
# models.dev. Guard: when cache reads are observed, the priced savings must be > 0.
echo "[ Test 4c: Copilot prefix-cache savings pricing (:4000) ]"
if [[ "$HTTP_CODE" == "200" && -n "$COPILOT_TEST_MODEL" ]]; then
  run_copilot_cache_probe "$GATEWAY" "$COPILOT_TEST_MODEL"
  CACHE_READ_TOKENS=$(get_copilot_cache_read_tokens "$GATEWAY")
  CACHE_SAVINGS=$(get_copilot_cache_savings_usd "$GATEWAY")
  if [[ "$CACHE_READ_TOKENS" -gt 0 ]]; then
    NONZERO=$(python3 -c "print(1 if float('$CACHE_SAVINGS') > 0 else 0)" 2>/dev/null || echo 0)
    if [[ "$NONZERO" == "1" ]]; then
      ok "Copilot prefix-cache savings priced (${CACHE_READ_TOKENS} cache-read tokens -> \$${CACHE_SAVINGS}, model: $COPILOT_TEST_MODEL)"
    else
      fail "Copilot reported ${CACHE_READ_TOKENS} cache-read tokens but priced savings is \$${CACHE_SAVINGS} (models.dev pricing or attribution regressed)"
    fi
  else
    info "Provider did not report cached tokens this run (caching not observed) — pricing path not exercised."
  fi
else
  info "Skipped: Copilot e2e did not resolve a working model above."
fi
echo

# --- Test 5: Bedrock end-to-end ---
BEDROCK_CANDIDATES=$(echo "$MODELS" | python3 -c "
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
selected=[p for p in preferred if p in ids]
if selected:
    print('\\n'.join(selected))
    raise SystemExit(0)

# Fallback: any bedrock alias in the model list.
fallback=[x for x in ids if x.startswith('bedrock-')]
print('\\n'.join(fallback))
" 2>/dev/null || echo "")

BEDROCK_ANTHROPIC_TEST_MODEL=$(echo "$MODELS" | python3 -c "
import json,sys
try:
    data=json.load(sys.stdin).get('data',[])
except Exception:
    print('')
    raise SystemExit(0)
ids=[m.get('id','') for m in data]
preferred=[
  'bedrock-eu-anthropic-claude-haiku-4-5-20251001-v1-0',
  'bedrock-global-anthropic-claude-haiku-4-5-20251001-v1-0',
  'bedrock-eu-anthropic-claude-sonnet-4-5-20250929-v1-0',
  'bedrock-global-anthropic-claude-sonnet-4-5-20250929-v1-0',
]
for p in preferred:
    if p in ids:
        print(p)
        raise SystemExit(0)
for x in ids:
    if x.startswith('bedrock-') and 'anthropic' in x:
        print(x)
        raise SystemExit(0)
print('')
" 2>/dev/null || echo "")

BEDROCK_TEST_MODEL=""
if [[ -z "$BEDROCK_CANDIDATES" ]]; then
  fail "No bedrock-* model aliases found in /v1/models"
  info "Fix: ./headway up --regen-config"
  echo
else
  echo "[ Test 5: AWS Bedrock end-to-end (lowest-cost model preferred) ]"
  TMPFILE=$(make_tmp)
  LAST_BEDROCK_ERR=""

  while IFS= read -r CANDIDATE; do
    [[ -z "$CANDIDATE" ]] && continue
    BEDROCK_TEST_MODEL="$CANDIDATE"

    for ATTEMPT in 1 2 3; do
      [[ $ATTEMPT -gt 1 ]] && {
        echo "  Retrying Bedrock request in 2s (attempt $ATTEMPT/3, model $BEDROCK_TEST_MODEL)..."
        sleep 2
      }
      run_chat_completion "$GATEWAY" "$BEDROCK_TEST_MODEL" "Reply with the single word: BEDROCKOK" 8 "$TMPFILE"
      [[ "$HTTP_CODE" == "502" || "$HTTP_CODE" == "429" ]] || break
    done

    if [[ "$HTTP_CODE" == "200" ]] && response_has_choices "$TMPFILE"; then
      CONTENT=$(response_first_content "$TMPFILE")
      ok "Bedrock response using $BEDROCK_TEST_MODEL: \"$CONTENT\" (HTTP $HTTP_CODE)"
      break
    fi

    LAST_BEDROCK_ERR=$(python3 -c "import json; d=json.load(open('$TMPFILE')); print(str(d).lower()[:500])" 2>/dev/null || tr '[:upper:]' '[:lower:]' <"$TMPFILE" | head -c 500)
    if [[ "$HTTP_CODE" == "000" ]]; then
      echo "  No response from gateway (HTTP 000) — AWS credentials likely expired or request timed out"
      echo "  Fix: ./headway auth"
      BEDROCK_TEST_MODEL=""
      break
    fi
    if [[ "$HTTP_CODE" == "429" || "$HTTP_CODE" == "502" || "$HTTP_CODE" == "503" || "$HTTP_CODE" == "504" ]]; then
      echo "  Bedrock transient failure for $BEDROCK_TEST_MODEL (HTTP $HTTP_CODE); trying next candidate"
      BEDROCK_TEST_MODEL=""
      continue
    fi
    if echo "$LAST_BEDROCK_ERR" | grep -Eq "model|not found|unsupported|does not exist|accessdenied|not authorized|validationexception|unrecognized"; then
      echo "  Bedrock model not usable via LiteLLM route: $BEDROCK_TEST_MODEL (trying next candidate)"
      BEDROCK_TEST_MODEL=""
      continue
    fi

    BEDROCK_TEST_MODEL=""
    break
  done <<<"$BEDROCK_CANDIDATES"

  if [[ -n "$BEDROCK_TEST_MODEL" ]]; then
    :
  else
    fail "Bedrock request failed across candidates (last HTTP ${HTTP_CODE:-000}): ${LAST_BEDROCK_ERR:-unknown error}"
    info "AWS credentials issue? Run: aws sso login --profile ${BEDROCK_AWS_PROFILE:-default}"
  fi
fi
echo

# --- Test 5b: Bedrock native Converse + ConverseStream via :4002 ---
echo "[ Test 5b: Bedrock native Converse + ConverseStream via :4002 ]"
BEDROCK_NATIVE_ALIAS="$BEDROCK_TEST_MODEL"
if [[ -z "$BEDROCK_NATIVE_ALIAS" ]]; then
  while IFS= read -r CANDIDATE; do
    [[ -n "$CANDIDATE" ]] || continue
    BEDROCK_NATIVE_ALIAS="$CANDIDATE"
    break
  done <<<"$BEDROCK_CANDIDATES"
fi

if [[ -z "$BEDROCK_NATIVE_ALIAS" ]]; then
  fail "No bedrock-* model found in :4001 model list — cannot run Test 5b"
  info "Fix: ./headway up"
elif ! bedrock_native_routes_available "$BEDROCK_NATIVE_GATEWAY"; then
  fail "Bedrock :4002 does not expose native /model/{id}/converse routes"
  info "Image lacks native Bedrock route surface; set HEADROOM_BEDROCK_IMAGE to a native bedrock image and restart"
else
  RESOLVED=$(resolve_bedrock_native_model "$BEDROCK_NATIVE_ALIAS")
  BEDROCK_NATIVE_MODEL=$(echo "$RESOLVED" | awk '{print $1}')
  if [[ -z "$BEDROCK_NATIVE_MODEL" ]]; then
    fail "Could not resolve native model id from alias: $BEDROCK_NATIVE_ALIAS"
    info "Fix: regenerate litellm_config.yaml via ./headway config regen"
  else
    CONVERSE_EXPECT_ANTHROPIC_COMPRESS=0
    if [[ "$BEDROCK_NATIVE_MODEL" == anthropic.* || "$BEDROCK_NATIVE_MODEL" == *.anthropic.* ]]; then
      CONVERSE_EXPECT_ANTHROPIC_COMPRESS=1
    fi

    STREAM_CHECK_ALIAS="$BEDROCK_NATIVE_ALIAS"
    if [[ -n "$BEDROCK_ANTHROPIC_TEST_MODEL" ]]; then
      STREAM_CHECK_ALIAS="$BEDROCK_ANTHROPIC_TEST_MODEL"
    fi
    STREAM_RESOLVED=$(resolve_bedrock_native_model "$STREAM_CHECK_ALIAS")
    STREAM_CHECK_MODEL=$(echo "$STREAM_RESOLVED" | awk '{print $1}')
    STREAM_EXPECT_ANTHROPIC_COMPRESS=0
    if [[ "$STREAM_CHECK_MODEL" == anthropic.* || "$STREAM_CHECK_MODEL" == *.anthropic.* ]]; then
      STREAM_EXPECT_ANTHROPIC_COMPRESS=1
    fi

    TMPFILE=$(make_tmp)
    CONVERSE_REQ_ID="test-bedrock-converse-$(date +%s)-$$"
    run_bedrock_converse "$BEDROCK_NATIVE_GATEWAY" "$BEDROCK_NATIVE_MODEL" "Reply with the single word: BEDROCKNATIVEOK" "$TMPFILE" "$CONVERSE_REQ_ID"
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
      ok "Bedrock :4002 converse passed (HTTP $HTTP_CODE, model: $BEDROCK_NATIVE_MODEL, region: ${AWS_REGION:-eu-central-1}, text: \"${CONTENT:-<empty>}\")"

      if bedrock_log_has_for_request "$CONVERSE_REQ_ID" '"event":"bedrock_envelope_parse_error"'; then
        fail "Bedrock :4002 converse had envelope parse error for request $CONVERSE_REQ_ID"
      elif [[ $CONVERSE_EXPECT_ANTHROPIC_COMPRESS -eq 1 ]] && bedrock_log_has_for_request "$CONVERSE_REQ_ID" '"event":"bedrock_compression_skipped"'; then
        fail "Bedrock :4002 converse skipped compression for anthropic request $CONVERSE_REQ_ID"
        info "Check vendor detection path in Bedrock native image"
      else
        ok "Bedrock :4002 converse did not report compression skip/parse errors"
      fi

      # Compression probe: always run with an Anthropic model (compression only applies
      # to Anthropic models). Use the converse model if it is Anthropic, otherwise fall
      # back to the stream model (STREAM_CHECK_MODEL, which is always Haiku when available).
      # This ensures the probe is not silently skipped when the cheapest converse model
      # is non-Anthropic (e.g. Mistral).
      PROBE_MODEL=""
      if [[ $CONVERSE_EXPECT_ANTHROPIC_COMPRESS -eq 1 ]]; then
        PROBE_MODEL="$BEDROCK_NATIVE_MODEL"
      elif [[ -n "$STREAM_CHECK_MODEL" ]] && [[ "$STREAM_CHECK_MODEL" == anthropic.* || "$STREAM_CHECK_MODEL" == *.anthropic.* ]]; then
        PROBE_MODEL="$STREAM_CHECK_MODEL"
      fi
      if [[ -n "$PROBE_MODEL" ]]; then
        TMPFILE=$(make_tmp)
        PROBE_SAVED_BEFORE=$(get_bedrock_native_saved_tokens "$BEDROCK_NATIVE_GATEWAY")
        PROBE_REQ_ID="test-bedrock-converse-compress-$(date +%s)-$$"
        run_bedrock_converse_compression_probe "$BEDROCK_NATIVE_GATEWAY" "$PROBE_MODEL" "$TMPFILE" "$PROBE_REQ_ID"
        if [[ "$HTTP_CODE" == "200" ]]; then
          PROBE_SAVED_AFTER=$(get_bedrock_native_saved_tokens "$BEDROCK_NATIVE_GATEWAY")
          PROBE_DELTA=$((PROBE_SAVED_AFTER - PROBE_SAVED_BEFORE))
          if [[ "${PROBE_SAVED_AFTER:-0}" -gt "${PROBE_SAVED_BEFORE:-0}" ]]; then
            ok "Bedrock :4002 compression probe recorded measurable token savings (+${PROBE_DELTA} tokens, total_saved=$PROBE_SAVED_AFTER, model: $PROBE_MODEL)"
          else
            fail "Bedrock :4002 compression probe did not increase measured token savings (cumulative before=$PROBE_SAVED_BEFORE after=$PROBE_SAVED_AFTER, model: $PROBE_MODEL)"
            info "Check /bedrock-native/stats and headroom-gateway logs for patch/compression path"
          fi
        else
          ERR=$(python3 -c "import json; d=json.load(open('$TMPFILE')); print(str(d)[:220])" 2>/dev/null || head -c 220 "$TMPFILE")
          fail "Bedrock :4002 compression probe failed (HTTP $HTTP_CODE, model: $PROBE_MODEL): $ERR"
          info "Check /bedrock-native/stats and headroom-gateway logs for patch/compression path"
        fi
      fi
    else
      ERR=$(python3 -c "import json; d=json.load(open('$TMPFILE')); print(str(d)[:220])" 2>/dev/null || head -c 220 "$TMPFILE")
      fail "Bedrock :4002 converse failed (HTTP $HTTP_CODE): $ERR"
      info "Check logs: docker logs headroom-bedrock-gateway"
      echo "         --- recent headroom-bedrock logs ---"
      docker logs --tail 12 headroom-bedrock-gateway 2>/dev/null | sed 's/^/         /' || true
      echo "         ---"
    fi

    if [[ -n "$STREAM_CHECK_MODEL" ]]; then
      BEDROCK_NATIVE_MODEL="$STREAM_CHECK_MODEL"
    fi

    TMPFILE=$(make_tmp)
    STREAM_REQ_ID="test-bedrock-converse-stream-$(date +%s)-$$"
    run_bedrock_converse_stream "$BEDROCK_NATIVE_GATEWAY" "$BEDROCK_NATIVE_MODEL" "Reply with the single word: BEDROCKSTREAMOK" "$TMPFILE" "$STREAM_REQ_ID"
    # converse-stream uses EventStream passthrough — check for raw binary response bytes
    STREAM_BYTES=$(wc -c <"$TMPFILE" 2>/dev/null | tr -d ' ')
    if [[ "$HTTP_CODE" == "200" ]] && [[ "${STREAM_BYTES:-0}" -gt 0 ]]; then
      ok "Bedrock :4002 converse-stream passed (HTTP $HTTP_CODE, EventStream bytes: $STREAM_BYTES, model: $BEDROCK_NATIVE_MODEL, region: ${AWS_REGION:-eu-central-1})"

      if bedrock_log_has_for_request "$STREAM_REQ_ID" '"event":"bedrock_envelope_parse_error"'; then
        fail "Bedrock :4002 converse-stream had envelope parse error for request $STREAM_REQ_ID"
      elif [[ $STREAM_EXPECT_ANTHROPIC_COMPRESS -eq 1 ]] && bedrock_log_has_for_request "$STREAM_REQ_ID" '"event":"bedrock_compression_skipped"'; then
        fail "Bedrock :4002 converse-stream skipped compression for anthropic request $STREAM_REQ_ID"
        info "Image regression: stream path is treating Anthropic model as non-anthropic vendor"
      else
        ok "Bedrock :4002 converse-stream did not report compression skip/parse errors"
      fi
    else
      ERR=$(python3 -c "import json; d=json.load(open('$TMPFILE')); print(str(d)[:220])" 2>/dev/null || head -c 220 "$TMPFILE")
      fail "Bedrock :4002 converse-stream failed (HTTP $HTTP_CODE, bytes: ${STREAM_BYTES:-0}): $ERR"
      info "Check logs: docker logs headroom-bedrock-gateway"
      echo "         --- recent headroom-bedrock logs ---"
      docker logs --tail 12 headroom-bedrock-gateway 2>/dev/null | sed 's/^/         /' || true
      echo "         ---"
    fi
  fi
fi

echo

# --- Test 5c: Unified stats aggregation script ---
echo "[ Test 5c: Unified stats aggregation (:4000 + :4002) ]"
COMBINED_JSON=$(python3 "$DIR/scripts/cli/headroom_python.py" combined-stats 2>/dev/null || true)
if [[ -z "$COMBINED_JSON" ]]; then
  fail "Unified stats script returned no output"
  info "Fix: ensure scripts/cli/headroom_python.py is present and Python can run it"
else
  if echo "$COMBINED_JSON" | python3 -c '
import json,sys
d=json.load(sys.stdin)
sys.exit(0 if d.get("ok") else 1)
' 2>/dev/null; then
    U_REQ=$(echo "$COMBINED_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("unified",{}).get("api_requests",0))' 2>/dev/null || echo "?")
    ok "Unified stats available (api_requests: $U_REQ)"
  else
    ERR=$(echo "$COMBINED_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(f"{d.get("error","unknown")}: {d.get("details","")}")' 2>/dev/null || echo "unknown error")
    fail "Unified stats unavailable: $ERR"
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
    info "Fix: ./headway config kilo"
  fi
else
  fail "kilo.jsonc not found at $KILO_CONF"
  info "Fix: ./headway config kilo"
fi
echo

# --- Summary ---
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo

if [[ $FAIL -gt 0 ]]; then
  echo "  Some tests failed. Quick fixes:"
  echo "    Not running:  ./headway up"
  echo "    Auth (403):   ./headway auth"
  echo "    AWS expired:  aws sso login --profile ${BEDROCK_AWS_PROFILE:-default}"
  exit 1
fi

echo "  All tests passed. Gateway is working correctly."
