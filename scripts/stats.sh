#!/usr/bin/env bash
# stats.sh — Print a concise savings and usage report from Headroom stats.
#
# Usage:
#   ./scripts/stats.sh

set -euo pipefail

GATEWAY="http://127.0.0.1:4000"

RAW_STATS=$(curl -sS --max-time 8 "$GATEWAY/stats" 2>/dev/null || true)
RAW_HISTORY=$(curl -sS --max-time 8 "$GATEWAY/stats-history" 2>/dev/null || true)

if [[ -z "$RAW_STATS" ]]; then
  echo "ERROR: Could not fetch stats from $GATEWAY/stats"
  echo "Check gateway health with: ./scripts/status.sh"
  exit 1
fi

python3 - "$RAW_STATS" "$RAW_HISTORY" <<'PY'
import json
import sys

stats = json.loads(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1] else {}
hist = json.loads(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else {}

summary = stats.get("summary", {})
compression = summary.get("compression", {})
cost = summary.get("cost", {})
breakdown = cost.get("breakdown", {})
uncompressed = summary.get("uncompressed_requests", {})
requests = stats.get("requests", {})
tokens = stats.get("tokens", {})
latency = stats.get("latency", {})
overhead = stats.get("overhead", {})

display = hist.get("display_session", {}) if isinstance(hist, dict) else {}

print("=== Headroom Savings Report ===")
print()
print("[ Totals ]")
print(f"  API requests: {summary.get('api_requests', 0)}")
print(f"  Input tokens: {tokens.get('input', 0)}")
print(f"  Output tokens: {tokens.get('output', 0)}")
print(f"  Total saved tokens (all layers): {tokens.get('saved', 0)}")
print(f"  Proxy compression saved tokens: {tokens.get('proxy_compression_saved', 0)}")
print(f"  CLI filtering saved tokens: {tokens.get('cli_filtering_saved', 0)}")
print(f"  RTK saved tokens: {tokens.get('rtk_saved', 0)}")
print(f"  Savings percent (active): {tokens.get('savings_percent', 0.0)}%")
print()
print("[ Compression ]")
print(f"  Requests compressed: {compression.get('requests_compressed', 0)}")
print(f"  Tokens removed: {compression.get('total_tokens_removed', 0)}")
print(f"  Avg compression: {compression.get('avg_compression_pct', 0.0)}%")
print(f"  Best compression: {compression.get('best_compression_pct', 0.0)}%")
print(f"  Prefix frozen (not compressed): {uncompressed.get('prefix_frozen', 0)}")
print(f"  No compressible content: {uncompressed.get('no_compressible_content', 0)}")
print()
print("[ Cost ]")
print(f"  Cost without headroom: ${cost.get('without_headroom_usd', 0.0):.6f}")
print(f"  Cost with headroom: ${cost.get('with_headroom_usd', 0.0):.6f}")
print(f"  Total USD saved: ${cost.get('total_saved_usd', 0.0):.6f}")
print(f"  Savings percent: {cost.get('savings_pct', 0.0)}%")
print(f"  Cache savings USD: ${breakdown.get('cache_savings_usd', 0.0):.6f}")
print(f"  Compression savings USD: ${breakdown.get('compression_savings_usd', 0.0):.6f}")
print()
print("[ Cache / Request Mix ]")
print(f"  Requests total: {requests.get('total', 0)}")
print(f"  Requests cached: {requests.get('cached', 0)}")
print(f"  Requests failed: {requests.get('failed', 0)}")
print(f"  Requests rate-limited: {requests.get('rate_limited', 0)}")
print()
print("[ Performance ]")
print(f"  Latency avg/min/max (ms): {latency.get('average_ms', 0.0)} / {latency.get('min_ms', 0.0)} / {latency.get('max_ms', 0.0)}")
print(f"  Headroom overhead avg/min/max (ms): {overhead.get('average_ms', 0.0)} / {overhead.get('min_ms', 0.0)} / {overhead.get('max_ms', 0.0)}")
print()
print("[ Session ]")
print(f"  Session requests: {display.get('requests', 0)}")
print(f"  Session tokens saved: {display.get('tokens_saved', 0)}")
print(f"  Session input tokens: {display.get('total_input_tokens', 0)}")
print(f"  Session savings percent: {display.get('savings_percent', 0.0)}%")
print(f"  Last activity: {display.get('last_activity_at', 'n/a')}")
PY
