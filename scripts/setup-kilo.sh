#!/usr/bin/env bash
# setup-kilo.sh — Ensure Kilo providers point to the local gateway.
#
# Usage:
#   ./scripts/setup-kilo.sh

set -euo pipefail

KILO_DIR="$HOME/.config/kilo"
KILO_CONF="$KILO_DIR/kilo.jsonc"
BACKUP_SUFFIX="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$KILO_DIR"

if [[ -f "$KILO_CONF" ]]; then
    cp "$KILO_CONF" "$KILO_CONF.bak-$BACKUP_SUFFIX"
    echo "[backup] $KILO_CONF.bak-$BACKUP_SUFFIX"
fi

python3 - <<'PY'
import json
import os
from pathlib import Path

kilo_conf = Path(os.path.expanduser("~/.config/kilo/kilo.jsonc"))
data = {}

if kilo_conf.exists():
    text = kilo_conf.read_text(encoding="utf-8").strip()
    if text:
        data = json.loads(text)

provider = data.setdefault("provider", {})

gh = provider.setdefault("github-copilot", {})
gh_options = gh.setdefault("options", {})
gh_options["baseURL"] = "http://127.0.0.1:4000/v1"

oa = provider.setdefault("openai-compatible", {})
oa_options = oa.setdefault("options", {})
oa_options["baseURL"] = "http://127.0.0.1:4000/v1"
oa_options.setdefault("apiKey", "local")

kilo_conf.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
print(f"[write] {kilo_conf}")
PY

echo
echo "Kilo provider baseURLs are now set to: http://127.0.0.1:4000/v1"
