#!/usr/bin/env python3
"""
_generate_config.py — Build litellm_config.yaml from Bedrock model data + live Copilot models.

Called by generate-litellm-config.sh:
    python3 scripts/_generate_config.py <tmp_dir> <output_file> [copilot_token_file]
"""

import json
import os
import re
import sys
import urllib.error
import urllib.request

if len(sys.argv) < 3:
    print(
        "Usage: _generate_config.py <tmp_dir> <output_file> [copilot_token_file]",
        file=sys.stderr,
    )
    sys.exit(1)

tmp_dir = sys.argv[1]
output_file = sys.argv[2]
copilot_token_file = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else ""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def slugify(value: str) -> str:
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", value.lower())).strip("-")


def region_from_filename(path: str) -> str:
    # inference-eu-central-1.json -> eu-central-1
    base = os.path.basename(path)
    parts = base.split("-")
    return "-".join(parts[1:4]).split(".")[0]


def extract_model_id_from_arn(arn: str) -> str:
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


def lifecycle_rank(status: str) -> int:
    s = (status or "").upper()
    if s == "ACTIVE":
        return 3
    if s == "LEGACY":
        return 2
    if s == "DEPRECATED":
        return 1
    return 0


def pick_better(existing, candidate):
    if existing is None:
        return candidate
    return (
        candidate if region_rank(candidate[2]) < region_rank(existing[2]) else existing
    )


# ---------------------------------------------------------------------------
# Bedrock: collect foundation model metadata
# ---------------------------------------------------------------------------

foundation_status_by_model: dict[str, str] = {}
foundation_best_region: dict[str, str] = {}
foundation_on_demand: dict[str, bool] = {}

for name in sorted(os.listdir(tmp_dir)):
    if not name.startswith("foundation-") or not name.endswith(".json"):
        continue
    path = os.path.join(tmp_dir, name)
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
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
        foundation_on_demand[model_id] = foundation_on_demand.get(model_id, False) or (
            "ON_DEMAND" in inf_types
        )

        prior_region = foundation_best_region.get(model_id)
        if prior_region is None or region_rank(region) < region_rank(prior_region):
            foundation_best_region[model_id] = region


# ---------------------------------------------------------------------------
# Bedrock: build alias entries from inference profiles + uncovered foundations
# ---------------------------------------------------------------------------

selected: dict = {}
covered_model_ids: set[str] = set()

for name in sorted(os.listdir(tmp_dir)):
    if not name.startswith("inference-") or not name.endswith(".json"):
        continue
    path = os.path.join(tmp_dir, name)
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        continue

    region = region_from_filename(path)
    for summary in data.get("inferenceProfileSummaries", []):
        status = (summary.get("status") or "").upper()
        if status and status != "ACTIVE":
            continue
        profile_id = summary.get("inferenceProfileId")
        if not profile_id:
            continue
        if not (
            profile_id.startswith("eu.")
            or profile_id.startswith("global.")
            or region.startswith("eu-")
        ):
            continue

        referenced_ids = []
        for model_ref in summary.get("models", []):
            model_arn = (
                model_ref.get("modelArn") if isinstance(model_ref, dict) else None
            )
            mid = extract_model_id_from_arn(model_arn or "")
            if mid:
                referenced_ids.append(mid)

        if referenced_ids:
            has_active_or_unknown = any(
                foundation_status_by_model.get(mid, "") in ("", "ACTIVE")
                for mid in referenced_ids
            )
            if not has_active_or_unknown:
                continue
            for mid in referenced_ids:
                if foundation_status_by_model.get(mid, "") == "ACTIVE":
                    covered_model_ids.add(mid)

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


# ---------------------------------------------------------------------------
# Copilot: fetch live models the user has access to and has enabled
# ---------------------------------------------------------------------------


def fetch_copilot_models(token_file: str) -> list[str]:
    """Return chat model IDs that are enabled and visible in the model picker."""
    if not token_file or not os.path.exists(token_file):
        fallback_dir = os.environ.get(
            "GITHUB_COPILOT_TOKEN_DIR",
            os.path.expanduser("~/.config/litellm/github_copilot"),
        )
        token_file = os.path.join(fallback_dir, "api-key.json")

    if not os.path.exists(token_file):
        print(
            f"[generator] WARNING: Copilot token not found at {token_file}; skipping named Copilot entries"
        )
        return []

    try:
        with open(token_file) as fh:
            key_data = json.load(fh)
        token = key_data.get("token") or key_data.get("api_key")
        if not token and isinstance(key_data, dict):
            for value in key_data.values():
                if isinstance(value, str) and value.strip():
                    token = value.strip()
                    break
        if not token:
            print(
                f"[generator] WARNING: no usable token in {token_file}; skipping named Copilot entries"
            )
            return []
        req = urllib.request.Request(
            "https://api.githubcopilot.com/models",
            headers={
                "Authorization": f"Bearer {token}",
                "Copilot-Integration-Id": "vscode-chat",
                "editor-version": "vscode/1.99.0",
            },
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())

        models = []
        for m in data.get("data", []):
            model_id = m.get("id") or m.get("name")
            if not model_id:
                continue
            cap_type = (m.get("capabilities") or {}).get("type", "")
            policy_state = (m.get("policy") or {}).get("state", "")
            picker_enabled = m.get("model_picker_enabled", False)
            if cap_type == "chat" and policy_state == "enabled" and picker_enabled:
                models.append(model_id)

        print(f"[generator] Copilot chat models (enabled, picker): {len(models)}")
        return models
    except urllib.error.HTTPError as exc:
        print(
            f"[generator] WARNING: Copilot model API HTTP error ({exc.code}); skipping named entries"
        )
        return []
    except urllib.error.URLError as exc:
        print(
            f"[generator] WARNING: Copilot model API network error ({exc.reason}); skipping named entries"
        )
        return []
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(
            f"[generator] WARNING: could not fetch Copilot models ({exc}); skipping named entries"
        )
        return []


copilot_models = fetch_copilot_models(copilot_token_file)


# ---------------------------------------------------------------------------
# Write litellm_config.yaml
# ---------------------------------------------------------------------------

header = """# litellm_config.yaml
# AUTO-GENERATED by scripts/generate-litellm-config.sh
#
# Architecture:
#   bedrock-*   -> AWS Bedrock directly
#   copilot-*   -> GitHub Copilot (named, auto-discovered)
#   *           -> github_copilot/* (wildcard fallback)
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

for model_id in copilot_models:
    alias = "copilot-" + re.sub(r"[^a-z0-9]+", "-", model_id.lower()).strip("-")
    lines.append(
        f"  - model_name: {alias}\n"
        f"    litellm_params:\n"
        f"      model: github_copilot/{model_id}\n"
    )

lines.append(
    '\n  - model_name: "*"\n    litellm_params:\n      model: "github_copilot/*"\n'
)

lines.append("\nlitellm_settings:\n  drop_params: true\n  set_verbose: false\n")

with open(output_file, "w", encoding="utf-8") as f:
    f.write("".join(lines))

print(f"[generator] wrote {output_file}")
print(f"[generator] total bedrock aliases: {len(entries)}")
print(f"[generator] covered by active inference profiles: {len(covered_model_ids)}")
