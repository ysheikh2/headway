#!/usr/bin/env bash
# uninstall.sh — Stop and remove the local gateway stack.
#
# Usage:
#   ./scripts/uninstall.sh [--yes] [--purge-data] [--prune-images] [--cleanup-kilo]
#
# Options:
#   --yes           Skip confirmation prompt.
#   --purge-data    Remove local runtime state in .data/.
#   --prune-images  Remove gateway images from local Docker cache.
#   --cleanup-kilo  Remove gateway baseURL entries from ~/.config/kilo/kilo.jsonc.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="$DIR/docker-compose.yml"
CONFIRM=true
PURGE_DATA=false
PRUNE_IMAGES=false
CLEANUP_KILO=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      CONFIRM=false
      shift
      ;;
    --purge-data)
      PURGE_DATA=true
      shift
      ;;
    --prune-images)
      PRUNE_IMAGES=true
      shift
      ;;
    --cleanup-kilo)
      CLEANUP_KILO=true
      shift
      ;;
    *)
      echo "Unknown arg: $1"
      exit 1
      ;;
  esac
done

if [[ "$CONFIRM" == true ]]; then
  echo "This will stop and remove the local gateway containers/network."
  echo "Flags selected:"
  echo "  purge-data:   $PURGE_DATA"
  echo "  prune-images: $PRUNE_IMAGES"
  echo "  cleanup-kilo: $CLEANUP_KILO"
  echo
  read -r -p "Proceed? (y/N): " ans
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo "=== Uninstall: Headroom + LiteLLM Gateway ==="

cd "$DIR"

echo "[1/5] Stopping stack"
docker compose -f "$COMPOSE" down --remove-orphans 2>/dev/null || true

echo "[2/5] Removing containers"
docker rm -f headroom-gateway 2>/dev/null || true
docker rm -f litellm-gateway 2>/dev/null || true
docker rm -f headroom-bedrock-gateway 2>/dev/null || true

echo "[3/5] Removing transient local files"
rm -f "$DIR/.env"

if [[ "$PURGE_DATA" == true ]]; then
  echo "[4/5] Removing local runtime data (.data/)"
  rm -rf "$DIR/.data"
else
  echo "[4/5] Keeping local runtime data (.data/)"
fi

if [[ "$PRUNE_IMAGES" == true ]]; then
  echo "[5/5] Removing local Docker images"
  docker image rm ghcr.io/chopratejas/headroom:code 2>/dev/null || true
  docker image rm ghcr.io/berriai/litellm:main-stable 2>/dev/null || true
  # Also attempt to remove the pinned Bedrock-native image if present
  docker image rm headroom-local:bedrock-c9e4822e 2>/dev/null || true
else
  echo "[5/5] Keeping local Docker images"
fi

if [[ "$CLEANUP_KILO" == true ]]; then
  KILO_CONF="$HOME/.config/kilo/kilo.jsonc"
  if [[ -f "$KILO_CONF" ]]; then
    echo "[extra] Removing gateway baseURL entries from Kilo config"
    python3 - <<'PY'
import json
import os
from pathlib import Path

p = Path(os.path.expanduser("~/.config/kilo/kilo.jsonc"))
if not p.exists():
    raise SystemExit(0)

text = p.read_text(encoding="utf-8").strip()
if not text:
    raise SystemExit(0)

data = json.loads(text)
providers = data.get("provider", {})

for key in ("github-copilot", "openai-compatible"):
    block = providers.get(key)
    if isinstance(block, dict):
        opts = block.get("options")
        if isinstance(opts, dict):
            if opts.get("baseURL") == "http://127.0.0.1:4000/v1":
                opts.pop("baseURL", None)

bedrock = providers.get("amazon-bedrock")
if isinstance(bedrock, dict):
    opts = bedrock.get("options")
    if isinstance(opts, dict):
        if opts.get("baseURL") in ("http://127.0.0.1:4002", "http://127.0.0.1:4002/v1"):
            opts.pop("baseURL", None)

p.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
print(f"updated {p}")
PY
  else
    echo "[extra] Kilo config not found; skipping cleanup"
  fi
fi

echo

echo "Uninstall complete."
if [[ "$PURGE_DATA" == false ]]; then
  echo "Note: .data/ was preserved. Re-run with --purge-data to remove it."
fi
