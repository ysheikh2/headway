#!/usr/bin/env bash
# generate-litellm-config.sh — auto-generate the Copilot-only LiteLLM config.
#
# Bedrock is served natively by the Rust `headroom-proxy` (SigV4 in-process), so
# LiteLLM only fronts the GitHub Copilot / OpenAI lane. This script discovers the
# enabled Copilot chat models and writes named `copilot-*` aliases plus the `*`
# wildcard fallback. No AWS / Bedrock discovery is involved.
#
# Usage:
#   ./scripts/cli/generate-litellm-config.sh [--output <path>]

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT_FILE="$DIR/litellm_config.yaml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "ERROR: --output requires a non-empty path"
        exit 1
      fi
      OUTPUT_FILE="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1"
      exit 1
      ;;
  esac
done

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/copilot-config-XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

# Copy the Copilot token from the LiteLLM container to a temp file so the Python
# generator can reach it even when running on the host.
COPILOT_TOKEN_FILE=""
CONTAINER_TOKEN="/root/.config/litellm/github_copilot/api-key.json"
if docker inspect litellm-gateway >/dev/null 2>&1; then
  TMP_TOKEN="$TMP_DIR/copilot-api-key.json"
  if docker cp "litellm-gateway:$CONTAINER_TOKEN" "$TMP_TOKEN" 2>/dev/null; then
    COPILOT_TOKEN_FILE="$TMP_TOKEN"
  fi
fi
# Fall back to host path if set (e.g., when running inside container or after manual export)
if [[ -z "$COPILOT_TOKEN_FILE" && -f "${GITHUB_COPILOT_TOKEN_DIR:-$HOME/.config/litellm/github_copilot}/api-key.json" ]]; then
  COPILOT_TOKEN_FILE="${GITHUB_COPILOT_TOKEN_DIR:-$HOME/.config/litellm/github_copilot}/api-key.json"
fi

# Repo-local fallback (this workspace mounts ./.data/litellm into the container).
if [[ -z "$COPILOT_TOKEN_FILE" && -f "$DIR/.data/litellm/github_copilot/api-key.json" ]]; then
  COPILOT_TOKEN_FILE="$DIR/.data/litellm/github_copilot/api-key.json"
fi

TMP_OUTPUT_FILE="$TMP_DIR/litellm_config.yaml"
python3 "$DIR/scripts/cli/headroom_python.py" generate-config "$TMP_OUTPUT_FILE" "${COPILOT_TOKEN_FILE:-}"

cp "$TMP_OUTPUT_FILE" "$OUTPUT_FILE"

echo "[generator] Done"
