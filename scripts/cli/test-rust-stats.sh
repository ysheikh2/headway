#!/usr/bin/env bash
# End-to-end test for the single-Rust-proxy refactor.
#
# Validates that the native Rust `headroom-proxy` (from the headroom
# `feat/federated-stats` branch, built as $HEADROOM_IMAGE) is the one front door
# in headway's stack and natively serves:
#   - GET /healthz
#   - GET /stats     (unified savings JSON across all backends, no patches)
#   - GET /dashboard (embedded HTML)
#   - the recorder    (a Bedrock invoke is attributed in /stats by provider/model)
#
# Usage:
#   HEADROOM_IMAGE=headroom:feat-stats bash scripts/cli/test-rust-stats.sh
#
# Build the branch image first (from a checkout of the headroom branch):
#   docker build -f Dockerfile --target runtime \
#     --build-arg HEADROOM_EXTRAS=proxy,code -t headroom:feat-stats .
# (or the minimal Rust-only image documented in AGENTS.md).

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR" || exit 1

# Bounded curl: never let a stalled socket/DNS/AWS path hang `headway test`.
CURL=(curl --connect-timeout 5 --max-time 15)

PASS=0
FAIL=0
pass() {
  printf '  \033[1;32m[PASS]\033[0m %s\n' "$*"
  PASS=$((PASS + 1))
}
fail() {
  printf '  \033[1;31m[FAIL]\033[0m %s\n' "$*"
  FAIL=$((FAIL + 1))
}
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

OPENAI_URL="http://127.0.0.1:4000"
BEDROCK_URL="http://127.0.0.1:4002"

echo "=== Headway — single Rust proxy refactor smoke test ==="
info "HEADROOM_IMAGE=${HEADROOM_IMAGE:-<compose default>}"

# Bring up just the Rust proxy (LiteLLM/Copilot lane is optional and needs auth).
info "Bringing up the headroom (Rust proxy) service"
docker compose up -d headroom >/dev/null 2>&1

info "Waiting for the proxy to become healthy"
for _ in $(seq 1 20); do
  status="$(docker inspect -f '{{.State.Health.Status}}' headroom-gateway 2>/dev/null || echo none)"
  [ "$status" = "healthy" ] && break
  sleep 3
done

# 1. Liveness
if "${CURL[@]}" -sf "$OPENAI_URL/healthz" |
  python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('ok') is True else 1)" 2>/dev/null; then
  pass "/healthz responds from the Rust proxy"
else
  fail "/healthz did not respond"
fi

# 2. /stats native unified contract
STATS="$("${CURL[@]}" -sf "$OPENAI_URL/stats" || true)"
if echo "$STATS" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'requests' in d and 'tokens' in d and 'cost' in d and 'persistent_savings' in d" 2>/dev/null; then
  pass "/stats serves the unified savings contract natively (no Python proxy, no patches)"
else
  fail "/stats missing the expected contract: $(echo "$STATS" | head -c 160)"
fi

# 3. /dashboard embedded HTML
DASH_CODE="$("${CURL[@]}" -s -o /tmp/hw_dash.html -w '%{http_code}' "$BEDROCK_URL/dashboard")"
if [ "$DASH_CODE" = "200" ] && grep -q "/stats" /tmp/hw_dash.html; then
  pass "/dashboard serves the embedded UI that polls /stats"
else
  fail "/dashboard not served (HTTP $DASH_CODE)"
fi
rm -f /tmp/hw_dash.html

# 4. Recorder attributes a Bedrock request in the unified /stats.
#    The recorder fires before SigV4 signing, so this holds even without creds.
BR_MODEL="eu.anthropic.claude-haiku-4-5-20251001-v1:0"
BEFORE="$("${CURL[@]}" -sf "$OPENAI_URL/stats" | python3 -c "import json,sys;print(json.load(sys.stdin)['requests']['total'])" 2>/dev/null || echo 0)"
"${CURL[@]}" --max-time 30 -s -o /dev/null -X POST "$BEDROCK_URL/model/$BR_MODEL/invoke" \
  -H "content-type: application/json" \
  -d '{"anthropic_version":"bedrock-2023-05-31","messages":[{"role":"user","content":"hi"}],"max_tokens":10}'
AFTER_JSON="$("${CURL[@]}" -sf "$OPENAI_URL/stats")"
AFTER="$(echo "$AFTER_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['requests']['total'])" 2>/dev/null || echo 0)"
BR_COUNT="$(echo "$AFTER_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['requests']['by_provider'].get('bedrock',0))" 2>/dev/null || echo 0)"
if [ "$AFTER" -gt "$BEFORE" ] && [ "$BR_COUNT" -ge 1 ]; then
  pass "Bedrock invoke recorded and attributed: requests.total ${BEFORE} -> ${AFTER}, by_provider.bedrock=${BR_COUNT}"
else
  fail "Bedrock request not recorded in /stats (total ${BEFORE} -> ${AFTER}, bedrock=${BR_COUNT})"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
