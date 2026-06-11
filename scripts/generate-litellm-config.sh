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
        --aws-profile) AWS_PROFILE_NAME="$2"; shift 2 ;;
        --output)      OUTPUT_FILE="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
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

python3 - "$TMP_DIR" "$OUTPUT_FILE" <<'PY'
import json
import os
import re
import sys

tmp_dir = sys.argv[1]
output_file = sys.argv[2]


def slugify(value: str) -> str:
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", value.lower())).strip("-")


def region_from_filename(path: str) -> str:
    # inference-eu-central-1.json -> eu-central-1
    base = os.path.basename(path)
    return base.split("-")[1] + "-" + base.split("-")[2] + "-" + base.split("-")[3].split(".")[0]


def extract_model_id_from_arn(arn: str) -> str:
    # arn:...:foundation-model/<model-id>
    if "/" in arn:
        return arn.rsplit("/", 1)[-1]
    return ""


PREFERRED_REGION_ORDER = {
    "eu-central-1": 0,
    "eu-west-1": 1,
    "eu-west-2": 2,
    "eu-west-3": 3,
    "eu-north-1": 4,
    "eu-south-1": 5,
    "eu-south-2": 6,
}


def region_rank(region: str) -> int:
    return PREFERRED_REGION_ORDER.get(region, 99)


# key -> (alias, model, region)
selected = {}


def pick_better(existing, candidate):
    if existing is None:
        return candidate
    _, _, existing_region = existing
    _, _, candidate_region = candidate
    return candidate if region_rank(candidate_region) < region_rank(existing_region) else existing


def lifecycle_rank(status: str) -> int:
    s = (status or "").upper()
    if s == "ACTIVE":
        return 3
    if s == "LEGACY":
        return 2
    if s == "DEPRECATED":
        return 1
    return 0


foundation_status_by_model = {}
foundation_best_region = {}
foundation_on_demand = {}


# Pass 1: collect foundation metadata across regions.
for name in sorted(os.listdir(tmp_dir)):
    if not name.startswith("foundation-") or not name.endswith(".json"):
        continue
    path = os.path.join(tmp_dir, name)
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        continue

    region = region_from_filename(path)
    for model in data.get("modelSummaries", []):
        model_id = model.get("modelId")
        if not model_id:
            continue

        status = ((model.get("modelLifecycle") or {}).get("status") or "").upper()
        old_status = foundation_status_by_model.get(model_id, "")
        if lifecycle_rank(status) > lifecycle_rank(old_status):
            foundation_status_by_model[model_id] = status

        inf_types = {str(x).upper() for x in model.get("inferenceTypesSupported", [])}
        foundation_on_demand[model_id] = foundation_on_demand.get(model_id, False) or ("ON_DEMAND" in inf_types)

        prior_region = foundation_best_region.get(model_id)
        if prior_region is None or region_rank(region) < region_rank(prior_region):
            foundation_best_region[model_id] = region


covered_model_ids = set()


for name in sorted(os.listdir(tmp_dir)):
    if not name.startswith("inference-") or not name.endswith(".json"):
        continue
    path = os.path.join(tmp_dir, name)
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        continue

    region = region_from_filename(path)
    for summary in data.get("inferenceProfileSummaries", []):
        status = (summary.get("status") or "").upper()
        if status and status != "ACTIVE":
            continue
        profile_id = summary.get("inferenceProfileId")
        if not profile_id:
            continue
        # Prefer EU/global profile IDs. Regional IDs are still allowed if discovered in EU regions.
        if not (profile_id.startswith("eu.") or profile_id.startswith("global.") or region.startswith("eu-")):
            continue

        # Keep inference profiles only when at least one referenced model is ACTIVE
        # (or unknown in foundation list), and track active model coverage.
        referenced_ids = []
        for model_ref in summary.get("models", []):
            model_arn = model_ref.get("modelArn") if isinstance(model_ref, dict) else None
            model_id = extract_model_id_from_arn(model_arn or "")
            if model_id:
                referenced_ids.append(model_id)

        if referenced_ids:
            has_active_or_unknown = False
            for model_id in referenced_ids:
                foundation_status = foundation_status_by_model.get(model_id, "")
                if foundation_status in ("", "ACTIVE"):
                    has_active_or_unknown = True
                    break
            if not has_active_or_unknown:
                continue

            for model_id in referenced_ids:
                if foundation_status_by_model.get(model_id, "") == "ACTIVE":
                    covered_model_ids.add(model_id)

        key = f"profile::{profile_id}"
        candidate = (f"bedrock-{slugify(profile_id)}", f"bedrock/{profile_id}", region)
        selected[key] = pick_better(selected.get(key), candidate)


for model_id, status in foundation_status_by_model.items():
    if status != "ACTIVE":
        continue
    if not foundation_on_demand.get(model_id, False):
        continue
    if model_id in covered_model_ids:
        continue

    region = foundation_best_region.get(model_id, "eu-central-1")
    key = f"foundation::{model_id}"
    candidate = (f"bedrock-{slugify(model_id)}", f"bedrock/{model_id}", region)
    selected[key] = pick_better(selected.get(key), candidate)


entries = sorted(selected.values(), key=lambda x: x[0])

header = """# litellm_config.yaml
# AUTO-GENERATED by scripts/generate-litellm-config.sh
#
# Architecture:
#   bedrock-*  -> AWS Bedrock directly
#   *          -> github_copilot/*
#
# Do not edit this file manually; regenerate with:
#   ./scripts/generate-litellm-config.sh

model_list:
"""

lines = [header]

for alias, model, region in entries:
    lines.append(
        f"  - model_name: {alias}\n"
        f"    litellm_params:\n"
        f"      model: {model}\n"
        f"      aws_region_name: {region}\n"
    )

lines.append(
    "\n"
    "  - model_name: \"*\"\n"
    "    litellm_params:\n"
    "      model: \"github_copilot/*\"\n"
)

lines.append(
    "\n"
    "litellm_settings:\n"
    "  drop_params: true\n"
    "  set_verbose: false\n"
)

with open(output_file, "w", encoding="utf-8") as f:
    f.write("".join(lines))

print(f"[generator] wrote {output_file}")
print(f"[generator] total bedrock aliases: {len(entries)}")
print(f"[generator] covered by active inference profiles: {len(covered_model_ids)}")
PY

echo "[generator] Done"
