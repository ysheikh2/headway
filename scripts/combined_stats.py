#!/usr/bin/env python3
"""Combine Headroom stats from :4000 and :4002 into one JSON document.

This is an operational aggregator used by repo scripts until upstream exposes
native cross-lane aggregation from :4000 itself.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any

COPILOT_STATS_URL = "http://127.0.0.1:4000/stats"
BEDROCK_STATS_URL = "http://127.0.0.1:4002/stats"
BEDROCK_METRICS_URL = "http://127.0.0.1:4002/metrics"


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
        # Bedrock native currently may forward /stats upstream and return XML.
        return None, f"non-json response: {raw[:120]}"

    if not isinstance(obj, dict):
        return None, "unexpected json payload"
    return obj, None


def _num(d: dict[str, Any], *path: str) -> float:
    cur: Any = d
    for p in path:
        if not isinstance(cur, dict):
            return 0.0
        cur = cur.get(p)
    return float(cur) if isinstance(cur, (int, float)) else 0.0


def _int_num(d: dict[str, Any], *path: str) -> int:
    return int(_num(d, *path))


def _fetch_text(url: str, timeout: int = 4) -> tuple[str | None, str | None]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return resp.read().decode("utf-8", errors="replace"), None
    except urllib.error.URLError as exc:
        return None, str(exc)
    except Exception as exc:  # pragma: no cover
        return None, str(exc)


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
        elif metric_name == "proxy_response_status_count_total":
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


def main() -> int:
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

    # If :4000 already exposes unified data (runtime patch), use it directly.
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

    # Fallback path: :4002 may not provide /stats JSON; attempt /metrics parse.
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
            "compression_tokens_saved": _int_num(bedrock or {}, "tokens", "proxy_compression_saved"),
            "requests_cached": _int_num(bedrock or {}, "requests", "cached"),
            "requests_failed": _int_num(bedrock or {}, "requests", "failed"),
        },
    }

    unified = {
        "api_requests": lanes["copilot"]["api_requests"] + lanes["bedrock_native"]["api_requests"],
        "tokens_saved": lanes["copilot"]["tokens_saved"] + lanes["bedrock_native"]["tokens_saved"],
        "compression_tokens_saved": lanes["copilot"]["compression_tokens_saved"]
        + lanes["bedrock_native"]["compression_tokens_saved"],
        "requests_cached": lanes["copilot"]["requests_cached"] + lanes["bedrock_native"]["requests_cached"],
        "requests_failed": lanes["copilot"]["requests_failed"] + lanes["bedrock_native"]["requests_failed"],
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


if __name__ == "__main__":
    raise SystemExit(main())
