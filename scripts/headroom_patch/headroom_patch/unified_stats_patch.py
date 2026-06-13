from __future__ import annotations

import asyncio
import json
import os
from copy import deepcopy
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any
from urllib.error import URLError
from urllib.request import urlopen


@dataclass
class _BedrockStats:
    available: bool
    endpoint: str
    error: str | None
    api_requests: int
    requests_failed: int
    requests_cached: int
    tokens_saved: int
    compression_tokens_saved: int
    raw: dict[str, Any] | None


def _utc_now_iso() -> str:
    return datetime.now(UTC).isoformat()


def _to_int(value: Any) -> int:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    return 0


def _fetch_json(url: str, timeout: float) -> tuple[dict[str, Any] | None, str | None]:
    try:
        with urlopen(url, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace").strip()
    except URLError as exc:
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


def _fetch_text(url: str, timeout: float) -> tuple[str | None, str | None]:
    try:
        with urlopen(url, timeout=timeout) as resp:
            return resp.read().decode("utf-8", errors="replace"), None
    except URLError as exc:
        return None, str(exc)
    except Exception as exc:  # pragma: no cover
        return None, str(exc)


def _parse_prometheus_metrics(text: str) -> dict[str, int]:
    out = {
        "bedrock_requests": 0,
        "bedrock_failures": 0,
    }
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        metric_name = line.split("{", 1)[0].split()[0]
        value_s = line.rsplit(" ", 1)[-1]
        try:
            value = float(value_s)
        except Exception:
            continue

        if metric_name == "bedrock_invoke_count_total":
            out["bedrock_requests"] += int(value)
        elif metric_name == "proxy_response_status_count_total":
            status = None
            if "{" in line and "}" in line:
                labels = line.split("{", 1)[1].split("}", 1)[0]
                for label in labels.split(","):
                    if label.startswith("status="):
                        status = label.split("=", 1)[1].strip().strip('"')
                        break
            if status and status.startswith(("4", "5")):
                out["bedrock_failures"] += int(value)

    return out


def _build_bedrock_stats() -> _BedrockStats:
    stats_url = os.getenv("HEADROOM_BEDROCK_STATS_URL", "http://headroom-bedrock:8787/stats")
    metrics_url = os.getenv("HEADROOM_BEDROCK_METRICS_URL", "http://headroom-bedrock:8787/metrics")
    timeout = float(os.getenv("HEADROOM_UNIFIED_FETCH_TIMEOUT_SECONDS", "2.5"))

    body, err = _fetch_json(stats_url, timeout)
    if body is not None:
        summary = body.get("summary", {}) if isinstance(body, dict) else {}
        tokens = body.get("tokens", {}) if isinstance(body, dict) else {}
        requests = body.get("requests", {}) if isinstance(body, dict) else {}
        return _BedrockStats(
            available=True,
            endpoint=stats_url,
            error=None,
            api_requests=_to_int(summary.get("api_requests")),
            requests_failed=_to_int(requests.get("failed")),
            requests_cached=_to_int(requests.get("cached")),
            tokens_saved=_to_int(tokens.get("saved")),
            compression_tokens_saved=_to_int(tokens.get("proxy_compression_saved")),
            raw=body,
        )

    metrics_text, metrics_err = _fetch_text(metrics_url, timeout)
    if metrics_text is None:
        return _BedrockStats(
            available=False,
            endpoint=stats_url,
            error=err or metrics_err or "unknown",
            api_requests=0,
            requests_failed=0,
            requests_cached=0,
            tokens_saved=0,
            compression_tokens_saved=0,
            raw=None,
        )

    parsed = _parse_prometheus_metrics(metrics_text)
    return _BedrockStats(
        available=True,
        endpoint=metrics_url,
        error=None,
        api_requests=parsed["bedrock_requests"],
        requests_failed=parsed["bedrock_failures"],
        requests_cached=0,
        tokens_saved=0,
        compression_tokens_saved=0,
        raw={"source": "prometheus", "metrics_url": metrics_url},
    )


def _as_dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _merge_unified_stats(base: dict[str, Any], bedrock: _BedrockStats) -> dict[str, Any]:
    payload = deepcopy(base)

    summary: dict[str, Any] = _as_dict(payload.get("summary"))
    tokens: dict[str, Any] = _as_dict(payload.get("tokens"))
    requests: dict[str, Any] = _as_dict(payload.get("requests"))

    copilot_api = _to_int(summary.get("api_requests"))
    copilot_saved = _to_int(tokens.get("saved"))
    copilot_comp_saved = _to_int(tokens.get("proxy_compression_saved"))
    copilot_cached = _to_int(requests.get("cached"))
    copilot_failed = _to_int(requests.get("failed"))

    unified = {
        "api_requests": copilot_api + bedrock.api_requests,
        "tokens_saved": copilot_saved + bedrock.tokens_saved,
        "compression_tokens_saved": copilot_comp_saved + bedrock.compression_tokens_saved,
        "requests_cached": copilot_cached + bedrock.requests_cached,
        "requests_failed": copilot_failed + bedrock.requests_failed,
    }

    lanes = {
        "copilot": {
            "available": True,
            "endpoint": "http://127.0.0.1:4000/stats",
            "api_requests": copilot_api,
            "tokens_saved": copilot_saved,
            "compression_tokens_saved": copilot_comp_saved,
            "requests_cached": copilot_cached,
            "requests_failed": copilot_failed,
        },
        "bedrock_native": {
            "available": bedrock.available,
            "endpoint": bedrock.endpoint,
            "error": bedrock.error,
            "api_requests": bedrock.api_requests,
            "tokens_saved": bedrock.tokens_saved,
            "compression_tokens_saved": bedrock.compression_tokens_saved,
            "requests_cached": bedrock.requests_cached,
            "requests_failed": bedrock.requests_failed,
        },
    }

    payload["unified"] = unified
    payload["lanes"] = lanes
    payload["raw_unified_sources"] = {
        "copilot": {
            "summary": summary,
            "tokens": tokens,
            "requests": requests,
        },
        "bedrock_native": bedrock.raw,
    }
    payload["unified_stats"] = {
        "ok": True,
        "generated_at": _utc_now_iso(),
        "unified": unified,
        "lanes": lanes,
    }
    return payload


def _merge_unified_history(base: dict[str, Any], bedrock: _BedrockStats) -> dict[str, Any]:
    payload = deepcopy(base)
    lifetime: dict[str, Any] = _as_dict(payload.get("lifetime"))
    payload["lifetime"] = lifetime
    lifetime["api_requests"] = _to_int(lifetime.get("api_requests")) + bedrock.api_requests
    lifetime["tokens_saved"] = _to_int(lifetime.get("tokens_saved")) + bedrock.tokens_saved

    display: dict[str, Any] = _as_dict(payload.get("display_session"))
    payload["display_session"] = display
    display["requests"] = _to_int(display.get("requests")) + bedrock.api_requests
    display["tokens_saved"] = _to_int(display.get("tokens_saved")) + bedrock.tokens_saved

    payload.setdefault("unified_history", {})
    payload["unified_history"] = {
        "bedrock_native": {
            "available": bedrock.available,
            "endpoint": bedrock.endpoint,
            "error": bedrock.error,
            "api_requests": bedrock.api_requests,
            "tokens_saved": bedrock.tokens_saved,
        }
    }
    return payload


def apply_patch() -> None:
    try:
        import headroom.proxy.server as server  # ty: ignore[unresolved-import]
    except Exception:
        return

    if getattr(server, "_unified_stats_patch_applied", False):
        return

    original_create_app = server.create_app

    def patched_create_app(config: Any | None = None):
        app = original_create_app(config)

        route_by_path = {r.path: r for r in app.routes if hasattr(r, "path")}
        stats_route = route_by_path.get("/stats")
        history_route = route_by_path.get("/stats-history")
        if stats_route is None or history_route is None:
            return app

        original_stats = stats_route.endpoint
        original_history = history_route.endpoint

        async def unified_stats(cached: bool = False):
            base_payload = await original_stats(cached=cached)
            bedrock = await asyncio.to_thread(_build_bedrock_stats)
            return _merge_unified_stats(base_payload, bedrock)

        async def unified_history(
            format: str = "json", series: str = "history", history_mode: str = "compact"
        ):
            base_payload = await original_history(
                format=format, series=series, history_mode=history_mode
            )
            if format != "json":
                return base_payload
            bedrock = await asyncio.to_thread(_build_bedrock_stats)
            return _merge_unified_history(base_payload, bedrock)

        stats_route.endpoint = unified_stats
        if getattr(stats_route, "dependant", None) is not None:
            stats_route.dependant.call = unified_stats
        history_route.endpoint = unified_history
        if getattr(history_route, "dependant", None) is not None:
            history_route.dependant.call = unified_history
        server._unified_stats_patch_applied = True
        return app

    server.create_app = patched_create_app
