#!/usr/bin/env bash
# generate-litellm-config.sh — auto-generate LiteLLM config from AWS Bedrock (EU regions)
#
# Usage:
#   ./scripts/generate-litellm-config.sh [--aws-profile <profile>] [--output <path>]

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_PROFILE_NAME="${AWS_PROFILE:-d2i_stg}"
OUTPUT_FILE="$DIR/litellm_config.yaml"
AWS_REGION_NAME="${AWS_REGION_NAME:-eu-central-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --aws-profile)
      AWS_PROFILE_NAME="$2"
      shift 2
      ;;
    --output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1"
      exit 1
      ;;
  esac
done

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI is required but not installed"
  exit 1
fi

if ! AWS_REGION="$AWS_REGION_NAME" AWS_DEFAULT_REGION="$AWS_REGION_NAME" aws sts get-caller-identity --profile "$AWS_PROFILE_NAME" >/dev/null 2>&1; then
  echo "ERROR: AWS profile '$AWS_PROFILE_NAME' is not authenticated."
  echo "Run: aws sso login --profile $AWS_PROFILE_NAME"
  exit 1
fi

# Prefer dynamic EU region discovery; fall back to a static list if unavailable.
EU_REGIONS=$(aws ec2 describe-regions \
  --region "$AWS_REGION_NAME" \
  --all-regions \
  --profile "$AWS_PROFILE_NAME" \
  --query "Regions[?starts_with(RegionName, 'eu-') && (OptInStatus=='opt-in-not-required' || OptInStatus=='opted-in')].RegionName" \
  --output text 2>/dev/null || true)

if [[ -z "${EU_REGIONS:-}" ]]; then
  EU_REGIONS="eu-central-1 eu-west-1 eu-west-2 eu-west-3 eu-north-1 eu-south-1 eu-south-2"
fi

TMP_DIR="$(mktemp -d /tmp/bedrock-models-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "[generator] Discovering Bedrock models for profile: $AWS_PROFILE_NAME"
echo "[generator] EU regions: $EU_REGIONS"

for region in $EU_REGIONS; do
  AWS_REGION="$region" AWS_DEFAULT_REGION="$region" aws bedrock list-inference-profiles \
    --profile "$AWS_PROFILE_NAME" \
    --region "$region" \
    --output json >"$TMP_DIR/inference-$region.json" 2>/dev/null || true

  AWS_REGION="$region" AWS_DEFAULT_REGION="$region" aws bedrock list-foundation-models \
    --profile "$AWS_PROFILE_NAME" \
    --region "$region" \
    --output json >"$TMP_DIR/foundation-$region.json" 2>/dev/null || true
done

# Copy Copilot token from the LiteLLM container to a temp file so the
# Python generator can reach it even when running on the host.
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

python3 "$DIR/scripts/_generate_config.py" "$TMP_DIR" "$OUTPUT_FILE" "${COPILOT_TOKEN_FILE:-}"

echo "[generator] Done"
