#!/usr/bin/env python3
"""Shared Python helpers for the headroom-proxy CLI.

Subcommands:
- env-get <env_file> <key>
- env-set <env_file> <key> <value>
- kilo-setup <kilo_conf_path>
- kilo-cleanup <kilo_conf_path>
- kilo-check <kilo_conf_path>
- compose-image <service_name>  (reads compose JSON on stdin)
- models-summary                (reads /v1/models JSON on stdin)
- combined-stats
- stats-report <raw_stats> <raw_history> <raw_combined>
- generate-config <tmp_dir> <output_file> [copilot_token_file]
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

COPILOT_STATS_URL = "http://127.0.0.1:4000/stats"
BEDROCK_STATS_URL = "http://127.0.0.1:4002/stats"
BEDROCK_METRICS_URL = "http://127.0.0.1:4002/metrics"


def _strip_jsonc_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"(^\s*)//.*$", "", text, flags=re.M)
    return text


def cmd_env_get(env_file: str, key: str) -> int:
    path = Path(env_file)
    if not path.exists():
        print("")
        return 0
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith(f"{key}="):
            print(line.split("=", 1)[1].strip())
            return 0
    print("")
    return 0


def cmd_env_set(env_file: str, key: str, value: str) -> int:
    path = Path(env_file)
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    out: list[str] = []
    updated = False
    for line in lines:
        if line.startswith(f"{key}=") and not updated:
            out.append(f"{key}={value}")
            updated = True
        else:
            out.append(line)
    if not updated:
        out.append(f"{key}={value}")
    path.write_text("\n".join(out) + "\n", encoding="utf-8")
    return 0


def _load_jsonc(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8").strip()
    if not text:
        return {}
    return json.loads(_strip_jsonc_comments(text))


def cmd_kilo_setup(kilo_conf: str) -> int:
    path = Path(kilo_conf)
    path.parent.mkdir(parents=True, exist_ok=True)
    data = _load_jsonc(path)

    provider = data.setdefault("provider", {})

    gh = provider.setdefault("github-copilot", {})
    gh_opts = gh.setdefault("options", {})
    gh_opts["baseURL"] = "http://127.0.0.1:4000/v1"

    oa = provider.setdefault("openai-compatible", {})
    oa_opts = oa.setdefault("options", {})
    oa_opts["baseURL"] = "http://127.0.0.1:4000/v1"
    oa_opts.setdefault("apiKey", "local")

    br = provider.setdefault("amazon-bedrock", {})
    br_opts = br.setdefault("options", {})
    br_opts["baseURL"] = "http://127.0.0.1:4002"

    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print(path)
    return 0


def cmd_kilo_cleanup(kilo_conf: str) -> int:
    path = Path(kilo_conf)
    if not path.exists():
        return 0

    text = path.read_text(encoding="utf-8").strip()
    if not text:
        return 0

    data = json.loads(_strip_jsonc_comments(text))
    provider = data.get("provider", {})

    for key in ("github-copilot", "openai-compatible"):
        block = provider.get(key)
        if isinstance(block, dict):
            opts = block.get("options")
            if isinstance(opts, dict) and opts.get("baseURL") == "http://127.0.0.1:4000/v1":
                opts.pop("baseURL", None)

    bedrock = provider.get("amazon-bedrock")
    if isinstance(bedrock, dict):
        opts = bedrock.get("options")
        if isinstance(opts, dict) and opts.get("baseURL") in (
            "http://127.0.0.1:4002",
            "http://127.0.0.1:4002/v1",
        ):
            opts.pop("baseURL", None)

    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return 0


def cmd_kilo_check(kilo_conf: str) -> int:
    path = Path(kilo_conf)
    if not path.exists():
        return 1

    data = _load_jsonc(path)
    provider = data.get("provider", {})

    for key in ("github-copilot", "openai-compatible"):
        opts = (provider.get(key, {}) or {}).get("options", {})
        url = opts.get("baseURL", "") if isinstance(opts, dict) else ""
        if url and url != "http://127.0.0.1:4000/v1":
            return 1

    br_opts = (provider.get("amazon-bedrock", {}) or {}).get("options", {})
    br_url = br_opts.get("baseURL", "") if isinstance(br_opts, dict) else ""
    if br_url and br_url not in ("http://127.0.0.1:4002", "http://127.0.0.1:4002/v1"):
        return 1

    return 0


def cmd_compose_image(service_name: str) -> int:
    raw = sys.stdin.read().strip()
    if not raw:
        print("")
        return 0
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        print("")
        return 0
    image = ((data.get("services", {}) or {}).get(service_name, {}) or {}).get("image", "")
    print(image)
    return 0


def cmd_models_summary() -> int:
    raw = sys.stdin.read().strip()
    if not raw:
        print("unable to fetch model list")
        return 1
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        print("unable to parse model list")
        return 1

    ids = [m.get("id", "") for m in data.get("data", []) if isinstance(m, dict)]
    bedrock = [x for x in ids if x.startswith("bedrock-")]
    copilot = [x for x in ids if not x.startswith("bedrock-")]
    print(f"total={len(ids)} copilot={len(copilot)} bedrock={len(bedrock)}")
    return 0


# ---- combined stats ----


def _fetch_json(url: str, timeout: int = 4) -> tuple[dict[str, Any] | None, str | None]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace").strip()
    except urllib.error.URLError as exc:
        return None, str(exc)
    except Exception as exc:  # pragma: no cover
        return None, str(exc)

    if not raw:
        return None, "empty response"

    try:
        obj = json.loads(raw)
    except Exception:
        return None, f"non-json response: {raw[:120]}"

    if not isinstance(obj, dict):
        return None, "unexpected json payload"
    return obj, None


def _fetch_text(url: str, timeout: int = 4) -> tuple[str | None, str | None]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return resp.read().decode("utf-8", errors="replace"), None
    except urllib.error.URLError as exc:
        return None, str(exc)
    except Exception as exc:  # pragma: no cover
        return None, str(exc)


def _num(d: dict[str, Any], *path: str) -> float:
    cur: Any = d
    for p in path:
        if not isinstance(cur, dict):
            return 0.0
        cur = cur.get(p)
    return float(cur) if isinstance(cur, (int, float)) else 0.0


def _int_num(d: dict[str, Any], *path: str) -> int:
    return int(_num(d, *path))


def _parse_metrics(text: str) -> dict[str, int]:
    out = {"api_requests": 0, "requests_failed": 0}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        metric_name = line.split("{", 1)[0].split()[0]
        value_s = line.rsplit(" ", 1)[-1]
        try:
            value = int(float(value_s))
        except Exception:
            continue

        if metric_name == "bedrock_invoke_count_total":
            out["api_requests"] += value
            continue

        if metric_name == "proxy_response_status_count_total":
            labels = ""
            if "{" in line and "}" in line:
                labels = line.split("{", 1)[1].split("}", 1)[0]
            status = None
            for label in labels.split(","):
                if label.startswith("status="):
                    status = label.split("=", 1)[1].strip().strip('"')
                    break
            if status and status.startswith(("4", "5")):
                out["requests_failed"] += value
    return out


def cmd_combined_stats() -> int:
    copilot, copilot_err = _fetch_json(COPILOT_STATS_URL)
    bedrock, bedrock_err = _fetch_json(BEDROCK_STATS_URL)

    if copilot is None:
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": "copilot_stats_unavailable",
                    "details": copilot_err or "unknown",
                }
            )
        )
        return 1

    if isinstance(copilot.get("unified"), dict) and isinstance(copilot.get("lanes"), dict):
        out = {
            "ok": True,
            "unified": copilot.get("unified", {}),
            "lanes": copilot.get("lanes", {}),
            "raw": {
                "copilot": copilot,
                "bedrock_native": (copilot.get("raw_unified_sources", {}) or {}).get(
                    "bedrock_native"
                ),
            },
        }
        print(json.dumps(out))
        return 0

    bedrock_metrics_raw = None
    if bedrock is None:
        metrics_text, metrics_err = _fetch_text(BEDROCK_METRICS_URL)
        if metrics_text is not None:
            parsed = _parse_metrics(metrics_text)
            bedrock = {
                "summary": {"api_requests": parsed["api_requests"]},
                "tokens": {"saved": 0, "proxy_compression_saved": 0},
                "requests": {"cached": 0, "failed": parsed["requests_failed"]},
            }
            bedrock_metrics_raw = {
                "source": "prometheus",
                "endpoint": BEDROCK_METRICS_URL,
            }
            bedrock_err = None
        else:
            bedrock_err = bedrock_err or metrics_err

    lanes = {
        "copilot": {
            "available": True,
            "endpoint": COPILOT_STATS_URL,
            "api_requests": _int_num(copilot, "summary", "api_requests"),
            "tokens_saved": _int_num(copilot, "tokens", "saved"),
            "compression_tokens_saved": _int_num(copilot, "tokens", "proxy_compression_saved"),
            "requests_cached": _int_num(copilot, "requests", "cached"),
            "requests_failed": _int_num(copilot, "requests", "failed"),
        },
        "bedrock_native": {
            "available": bedrock is not None,
            "endpoint": BEDROCK_STATS_URL,
            "error": bedrock_err,
            "api_requests": _int_num(bedrock or {}, "summary", "api_requests"),
            "tokens_saved": _int_num(bedrock or {}, "tokens", "saved"),
            "compression_tokens_saved": _int_num(
                bedrock or {}, "tokens", "proxy_compression_saved"
            ),
            "requests_cached": _int_num(bedrock or {}, "requests", "cached"),
            "requests_failed": _int_num(bedrock or {}, "requests", "failed"),
        },
    }

    unified = {
        "api_requests": lanes["copilot"]["api_requests"] + lanes["bedrock_native"]["api_requests"],
        "tokens_saved": lanes["copilot"]["tokens_saved"] + lanes["bedrock_native"]["tokens_saved"],
        "compression_tokens_saved": lanes["copilot"]["compression_tokens_saved"]
        + lanes["bedrock_native"]["compression_tokens_saved"],
        "requests_cached": lanes["copilot"]["requests_cached"]
        + lanes["bedrock_native"]["requests_cached"],
        "requests_failed": lanes["copilot"]["requests_failed"]
        + lanes["bedrock_native"]["requests_failed"],
    }

    out = {
        "ok": True,
        "unified": unified,
        "lanes": lanes,
        "raw": {
            "copilot": copilot,
            "bedrock_native": bedrock_metrics_raw if bedrock_metrics_raw is not None else bedrock,
        },
    }
    print(json.dumps(out))
    return 0


def _load_json_str(raw: str) -> dict[str, Any]:
    if not raw:
        return {}
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def cmd_stats_report(raw_stats: str, raw_history: str, raw_combined: str) -> int:
    stats = _load_json_str(raw_stats)
    history = _load_json_str(raw_history)
    combined = _load_json_str(raw_combined)

    summary = stats.get("summary", {})
    tokens = stats.get("tokens", {})
    requests = stats.get("requests", {})
    cost = summary.get("cost", {})

    def _fmt_pct(numerator: float, denominator: float) -> str:
        if denominator <= 0:
            return "n/a"
        return f"{(100.0 * numerator / denominator):.2f}%"

    def _fmt_float_pct(value: Any) -> str:
        if isinstance(value, (int, float)):
            return f"{float(value):.2f}%"
        return "n/a"

    def _fmt_usd(value: Any) -> str:
        if isinstance(value, (int, float)):
            return f"${float(value):.6f}"
        return "n/a"

    def _safe_int(value: Any) -> int:
        return int(value) if isinstance(value, (int, float)) else 0

    print("=== Headroom Savings Report ===")
    if isinstance(combined, dict) and combined.get("ok"):
        unified = combined.get("unified", {})
        print(f"Unified API requests: {unified.get('api_requests', 0)}")
        print(f"Unified tokens saved: {unified.get('tokens_saved', 0)}")

        lanes = combined.get("lanes", {}) if isinstance(combined.get("lanes"), dict) else {}
        copilot_lane = lanes.get("copilot", {}) if isinstance(lanes.get("copilot"), dict) else {}
        bedrock_lane = (
            lanes.get("bedrock_native", {})
            if isinstance(lanes.get("bedrock_native"), dict)
            else {}
        )
        print(
            "Unified lanes: "
            f"copilot(saved={copilot_lane.get('tokens_saved', 0)}, cached={copilot_lane.get('requests_cached', 0)}) "
            f"bedrock(saved={bedrock_lane.get('tokens_saved', 0)}, cached={bedrock_lane.get('requests_cached', 0)})"
        )
        if (
            bedrock_lane.get("available") is True
            and _safe_int(bedrock_lane.get("api_requests")) > 0
            and _safe_int(bedrock_lane.get("tokens_saved")) == 0
        ):
            print(
                "Bedrock lane note: request counts are visible, but token/cost savings are "
                "not exposed by current :4002 metrics yet."
            )

    print(f"API requests: {summary.get('api_requests', 0)}")
    print(f"Input tokens: {tokens.get('input', 0)}")
    print(f"Output tokens: {tokens.get('output', 0)}")
    print(f"Saved tokens: {tokens.get('saved', 0)}")
    print(f"Cached requests: {requests.get('cached', 0)}")
    print(
        f"Cache hit rate: {_fmt_pct(float(_safe_int(requests.get('cached', 0))), float(_safe_int(summary.get('api_requests', 0))))}"
    )
    print(
        f"Active token savings: {_fmt_float_pct(tokens.get('savings_percent'))} "
        f"(proxy-only: {_fmt_float_pct(tokens.get('proxy_savings_percent'))})"
    )

    compression = summary.get("compression", {}) if isinstance(summary.get("compression"), dict) else {}
    print(
        "Compression details: "
        f"requests_compressed={compression.get('requests_compressed', 0)}, "
        f"avg={_fmt_float_pct(compression.get('avg_compression_pct'))}, "
        f"best={_fmt_float_pct(compression.get('best_compression_pct'))}, "
        f"best_detail={compression.get('best_detail', 'n/a')}"
    )

    print(f"Cost without headroom: {_fmt_usd(cost.get('without_headroom_usd'))}")
    print(f"Cost with headroom: {_fmt_usd(cost.get('with_headroom_usd'))}")
    print(f"Total saved USD: {_fmt_usd(cost.get('total_saved_usd'))}")

    breakdown = cost.get("breakdown", {}) if isinstance(cost.get("breakdown"), dict) else {}
    if breakdown:
        print(
            "Cost breakdown: "
            f"compression={_fmt_usd(breakdown.get('compression_savings_usd'))}, "
            f"cache={_fmt_usd(breakdown.get('cache_savings_usd'))}"
        )

    cost_block = stats.get("cost", {}) if isinstance(stats.get("cost"), dict) else {}
    per_model = cost_block.get("per_model", {}) if isinstance(cost_block.get("per_model"), dict) else {}
    if per_model:
        print("Top models by token savings:")
        rows: list[tuple[str, int, float, int, float]] = []
        for model, model_stats in per_model.items():
            if not isinstance(model_stats, dict):
                continue
            rows.append(
                (
                    str(model),
                    _safe_int(model_stats.get("tokens_saved")),
                    float(model_stats.get("reduction_pct", 0.0) or 0.0),
                    _safe_int(model_stats.get("requests")),
                    float(model_stats.get("tokens_sent", 0.0) or 0.0),
                )
            )
        rows.sort(key=lambda item: item[1], reverse=True)
        for model, saved_toks, reduction_pct, reqs, sent_toks in rows[:6]:
            print(
                f"  - {model}: saved={saved_toks}, reduction={reduction_pct:.2f}%, "
                f"requests={reqs}, sent={int(sent_toks)}"
            )

        zero_usd_models = [
            m
            for m, ms in per_model.items()
            if isinstance(ms, dict)
            and _safe_int(ms.get("tokens_saved")) > 0
            and float(ms.get("reduction_pct", 0.0) or 0.0) > 0
            and float(ms.get("tokens_sent", 0.0) or 0.0) > 0
            and (
                float(cost.get("total_saved_usd", 0.0) or 0.0) == 0.0
                or float(cost_block.get("compression_savings_usd", 0.0) or 0.0) == 0.0
            )
        ]
        if zero_usd_models:
            print(
                "Note: token savings are present but USD savings are zero. "
                "This usually means missing/unknown price metadata for one or more models."
            )

    request_logs = stats.get("request_logs") if isinstance(stats.get("request_logs"), list) else []
    if request_logs:
        model_rollup: dict[str, dict[str, float]] = {}
        for row in request_logs:
            if not isinstance(row, dict):
                continue
            model = str(row.get("model", "unknown"))
            slot = model_rollup.setdefault(
                model,
                {
                    "requests": 0.0,
                    "cache_hits": 0.0,
                    "tokens_saved": 0.0,
                    "input_original": 0.0,
                    "input_optimized": 0.0,
                },
            )
            slot["requests"] += 1.0
            if bool(row.get("cache_hit")):
                slot["cache_hits"] += 1.0
            slot["tokens_saved"] += float(row.get("tokens_saved", 0.0) or 0.0)
            slot["input_original"] += float(row.get("input_tokens_original", 0.0) or 0.0)
            slot["input_optimized"] += float(row.get("input_tokens_optimized", 0.0) or 0.0)

        ranked = sorted(
            model_rollup.items(),
            key=lambda kv: (int(kv[1]["requests"]), float(kv[1]["tokens_saved"])),
            reverse=True,
        )
        print("Model-level recent behavior (from request logs):")
        for model, data in ranked[:6]:
            reqs = int(data["requests"])
            cache_hits = int(data["cache_hits"])
            cache_hit_pct = _fmt_pct(float(cache_hits), float(reqs))
            saved = int(data["tokens_saved"])
            reduction_pct = _fmt_pct(
                float(saved),
                float(data["input_original"]),
            )
            print(
                f"  - {model}: req={reqs}, cache_hit={cache_hits}/{reqs} ({cache_hit_pct}), "
                f"saved={saved} ({reduction_pct})"
            )

    if isinstance(history, dict) and history.get("display_session"):
        ds = history.get("display_session", {})
        print(f"Session requests: {ds.get('requests', 0)}")
        print(f"Session tokens saved: {ds.get('tokens_saved', 0)}")
        if isinstance(ds, dict):
            print(
                f"Session compression USD: {_fmt_usd(ds.get('compression_savings_usd'))}"
            )
            print(
                "Session savings percent: "
                f"{_fmt_float_pct(ds.get('savings_percent'))}"
            )

    return 0


# ---- litellm config generation ----


def _slugify(value: str) -> str:
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", value.lower())).strip("-")


def _region_from_filename(path: str) -> str:
    base = os.path.basename(path)
    parts = base.split("-")
    return "-".join(parts[1:4]).split(".")[0]


def _extract_model_id_from_arn(arn: str) -> str:
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


def _region_rank(region: str) -> int:
    return PREFERRED_REGION_ORDER.get(region, 99)


def _lifecycle_rank(status: str) -> int:
    s = (status or "").upper()
    if s == "ACTIVE":
        return 3
    if s == "LEGACY":
        return 2
    if s == "DEPRECATED":
        return 1
    return 0


def _pick_better(
    existing: tuple[str, str, str] | None, candidate: tuple[str, str, str]
) -> tuple[str, str, str]:
    if existing is None:
        return candidate
    return candidate if _region_rank(candidate[2]) < _region_rank(existing[2]) else existing


def _fetch_copilot_models(token_file: str) -> list[str]:
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
        with open(token_file, encoding="utf-8") as fh:
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

        models: list[str] = []
        for model in data.get("data", []):
            if not isinstance(model, dict):
                continue
            model_id = model.get("id") or model.get("name")
            if not model_id:
                continue
            cap_type = (model.get("capabilities") or {}).get("type", "")
            policy_state = (model.get("policy") or {}).get("state", "")
            picker_enabled = model.get("model_picker_enabled", False)
            if cap_type == "chat" and policy_state == "enabled" and picker_enabled:
                models.append(str(model_id))

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


def cmd_generate_config(tmp_dir: str, output_file: str, copilot_token_file: str) -> int:
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

        region = _region_from_filename(path)
        for model in data.get("modelSummaries", []):
            if not isinstance(model, dict):
                continue
            model_id = model.get("modelId")
            if not model_id:
                continue

            status = ((model.get("modelLifecycle") or {}).get("status") or "").upper()
            old_status = foundation_status_by_model.get(model_id, "")
            if _lifecycle_rank(status) > _lifecycle_rank(old_status):
                foundation_status_by_model[model_id] = status

            inf_types = {str(x).upper() for x in model.get("inferenceTypesSupported", [])}
            foundation_on_demand[model_id] = foundation_on_demand.get(model_id, False) or (
                "ON_DEMAND" in inf_types
            )

            prior_region = foundation_best_region.get(model_id)
            if prior_region is None or _region_rank(region) < _region_rank(prior_region):
                foundation_best_region[model_id] = region

    selected: dict[str, tuple[str, str, str]] = {}
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

        region = _region_from_filename(path)
        for summary in data.get("inferenceProfileSummaries", []):
            if not isinstance(summary, dict):
                continue
            status = (summary.get("status") or "").upper()
            if status and status != "ACTIVE":
                continue
            profile_id = summary.get("inferenceProfileId")
            if not profile_id:
                continue
            if not (
                str(profile_id).startswith("eu.")
                or str(profile_id).startswith("global.")
                or region.startswith("eu-")
            ):
                continue

            referenced_ids: list[str] = []
            for model_ref in summary.get("models", []):
                if not isinstance(model_ref, dict):
                    continue
                model_arn = model_ref.get("modelArn")
                mid = _extract_model_id_from_arn(model_arn or "")
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
            candidate = (
                f"bedrock-{_slugify(str(profile_id))}",
                f"bedrock/{profile_id}",
                region,
            )
            selected[key] = _pick_better(selected.get(key), candidate)

    for model_id, status in foundation_status_by_model.items():
        if status != "ACTIVE":
            continue
        if not foundation_on_demand.get(model_id, False):
            continue
        if model_id in covered_model_ids:
            continue
        region = foundation_best_region.get(model_id, "eu-central-1")
        key = f"foundation::{model_id}"
        candidate = (f"bedrock-{_slugify(model_id)}", f"bedrock/{model_id}", region)
        selected[key] = _pick_better(selected.get(key), candidate)

    entries = sorted(selected.values(), key=lambda x: x[0])
    copilot_models = _fetch_copilot_models(copilot_token_file)

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
            "    litellm_params:\n"
            f"      model: github_copilot/{model_id}\n"
        )

    lines.append('\n  - model_name: "*"\n    litellm_params:\n      model: "github_copilot/*"\n')
    lines.append("\nlitellm_settings:\n  drop_params: true\n  set_verbose: false\n")

    with open(output_file, "w", encoding="utf-8") as f:
        f.write("".join(lines))

    print(f"[generator] wrote {output_file}")
    print(f"[generator] total bedrock aliases: {len(entries)}")
    print(f"[generator] covered by active inference profiles: {len(covered_model_ids)}")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: headroom_python.py <subcommand> [args...]", file=sys.stderr)
        return 1

    sub = sys.argv[1]
    args = sys.argv[2:]

    if sub == "env-get" and len(args) == 2:
        return cmd_env_get(args[0], args[1])
    if sub == "env-set" and len(args) == 3:
        return cmd_env_set(args[0], args[1], args[2])

    if sub == "kilo-setup" and len(args) == 1:
        return cmd_kilo_setup(args[0])
    if sub == "kilo-cleanup" and len(args) == 1:
        return cmd_kilo_cleanup(args[0])
    if sub == "kilo-check" and len(args) == 1:
        return cmd_kilo_check(args[0])

    if sub == "compose-image" and len(args) == 1:
        return cmd_compose_image(args[0])
    if sub == "models-summary" and len(args) == 0:
        return cmd_models_summary()

    if sub == "combined-stats" and len(args) == 0:
        return cmd_combined_stats()
    if sub == "stats-report" and len(args) == 3:
        return cmd_stats_report(args[0], args[1], args[2])

    if sub == "generate-config" and len(args) in (2, 3):
        token_file = args[2] if len(args) == 3 else ""
        return cmd_generate_config(args[0], args[1], token_file)

    print(f"invalid arguments for subcommand: {sub}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
