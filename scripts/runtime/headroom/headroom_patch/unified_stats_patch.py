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

# Pricing is loaded lazily from the models.dev cache synced by `./headway up/update/stats`.
# Path inside the container via the .data/headroom volume mount.
_MODELS_DEV_CACHE_PATH = os.getenv(
    "HEADWAY_MODELS_DEV_CACHE", "/home/nonroot/.headroom/models-dev.json"
)
# {normalized_model_id: {"input","output","cache_read","cache_write"}} in $/token.
_models_dev_pricing_cache: dict[str, dict[str, float]] | None = None


def _load_models_dev_pricing() -> dict[str, dict[str, float]]:
    """Load per-token pricing records from the local models.dev cache."""
    global _models_dev_pricing_cache
    if _models_dev_pricing_cache is not None:
        return _models_dev_pricing_cache

    result: dict[str, dict[str, float]] = {}
    try:
        with open(_MODELS_DEV_CACHE_PATH) as fh:
            data = json.load(fh)
    except Exception:
        _models_dev_pricing_cache = result
        return result

    if not isinstance(data, dict):
        _models_dev_pricing_cache = result
        return result

    for _provider, pdata in data.items():
        if not isinstance(pdata, dict):
            continue
        models = pdata.get("models")
        if not isinstance(models, dict):
            continue
        for model_id, mdata in models.items():
            if not isinstance(mdata, dict):
                continue
            cost = mdata.get("cost")
            if not isinstance(cost, dict):
                continue
            in_c = cost.get("input")
            out_c = cost.get("output")
            if not (isinstance(in_c, (int, float)) and isinstance(out_c, (int, float))):
                continue
            # cache_read / cache_write are optional; default to input when absent.
            cr = cost.get("cache_read")
            cw = cost.get("cache_write")
            # Normalize: lowercase, drop version qualifier after ":"
            norm = model_id.lower().split(":")[0]
            result[norm] = {
                "input": float(in_c) / 1_000_000,
                "output": float(out_c) / 1_000_000,
                "cache_read": (float(cr) / 1_000_000)
                if isinstance(cr, (int, float))
                else float(in_c) / 1_000_000,
                "cache_write": (float(cw) / 1_000_000)
                if isinstance(cw, (int, float))
                else float(in_c) / 1_000_000,
            }

    _models_dev_pricing_cache = result
    return result


def _lookup_record(display_model: str) -> dict[str, float] | None:
    """Return the full per-token pricing record for a model, or None."""
    pricing = _load_models_dev_pricing()
    if not pricing:
        return None

    key = display_model.lower().split(":")[0]
    if key in pricing:
        return pricing[key]

    # LiteLLM reports GitHub Copilot models as "copilot-<model>" but models.dev
    # stores them under "github-copilot/<model>" — try the canonical form first.
    if key.startswith("copilot-"):
        canonical = "github-copilot/" + key[len("copilot-") :]
        if canonical in pricing:
            return pricing[canonical]

    # Substring match: the display model id and stored ids may differ by region prefix
    # or version suffix. Pick the longest matching stored id (most specific).
    best: dict[str, float] | None = None
    best_len = 0
    for model_id, rec in pricing.items():
        if (model_id in key or key in model_id) and len(model_id) > best_len:
            best = rec
            best_len = len(model_id)
    return best


def _lookup_price(display_model: str) -> tuple[float, float] | None:
    """Return (input_price_per_tok, output_price_per_tok) from the models.dev cache, or None."""
    rec = _lookup_record(display_model)
    if rec is None:
        return None
    return rec["input"], rec["output"]


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


def _build_bedrock_shim_stats() -> dict[str, Any] | None:
    try:
        from headroom_patch import bedrock_native_patch

        payload = bedrock_native_patch.snapshot_stats()
    except Exception:
        return None

    if not isinstance(payload, dict):
        return None
    return payload


def _dominant_models_by_provider(payload: dict[str, Any]) -> dict[str, str]:
    """Most-frequent model per headroom provider, from the request logs.

    prefix_cache stats are aggregated per provider ("openai", "anthropic", ...)
    but carry no model id, so we attribute each provider's cached tokens to the
    model it served most often in order to price them.
    """
    logs = payload.get("request_logs") if isinstance(payload.get("request_logs"), list) else []
    counts: dict[str, dict[str, int]] = {}
    for row in logs:
        if not isinstance(row, dict):
            continue
        provider = str(row.get("provider") or "")
        model = str(row.get("model") or "")
        if not provider or not model:
            continue
        counts.setdefault(provider, {})
        counts[provider][model] = counts[provider].get(model, 0) + 1
    return {
        provider: max(models.items(), key=lambda kv: kv[1])[0]
        for provider, models in counts.items()
        if models
    }


def _apply_prefix_cache_pricing(payload: dict[str, Any]) -> None:
    """Price provider prefix-cache reads/writes using models.dev rates.

    Headroom records cache_read/cache_write token counts (e.g. GitHub Copilot
    auto-caches Claude prompts and reports ``cached_tokens``) but cannot value
    them without per-model pricing. We attribute each provider's cached tokens
    to its dominant model and compute the dollar discount vs. uncached input.
    Mutates payload in place; adds to cache savings, never to compression.
    """
    prefix_cache = _as_dict(payload.get("prefix_cache"))
    by_provider = _as_dict(prefix_cache.get("by_provider"))
    if not by_provider:
        return

    provider_model = _dominant_models_by_provider(payload)
    total_read_savings = 0.0
    total_write_premium = 0.0
    total_read_tokens = 0
    total_write_tokens = 0

    for provider, raw in by_provider.items():
        prov = _as_dict(raw)
        read_toks = _to_int(prov.get("cache_read_tokens"))
        write_toks = _to_int(prov.get("cache_write_tokens"))
        if read_toks <= 0 and write_toks <= 0:
            continue
        model = provider_model.get(provider, "")
        rec = _lookup_record(model) if model else None
        if rec is None:
            continue
        # Reads cost cache_read instead of input → saved = (input - cache_read).
        read_savings = read_toks * max(0.0, rec["input"] - rec["cache_read"])
        # Writes cost a premium over input → (cache_write - input), if any.
        write_premium = write_toks * max(0.0, rec["cache_write"] - rec["input"])
        prov["savings_usd"] = read_savings
        prov["write_premium_usd"] = write_premium
        prov["net_savings_usd"] = read_savings - write_premium
        by_provider[provider] = prov
        total_read_savings += read_savings
        total_write_premium += write_premium
        total_read_tokens += read_toks
        total_write_tokens += write_toks

    if total_read_tokens <= 0 and total_write_tokens <= 0:
        return

    net = total_read_savings - total_write_premium
    totals = _as_dict(prefix_cache.get("totals"))
    totals["savings_usd"] = total_read_savings
    totals["write_premium_usd"] = total_write_premium
    totals["net_savings_usd"] = net
    prefix_cache["totals"] = totals
    prefix_cache["by_provider"] = by_provider
    payload["prefix_cache"] = prefix_cache

    # Surface in the cost block and summary breakdown the dashboard/CLI read from.
    # savings_usd tracks gross read savings only — never goes negative.
    # write_premium_usd is a separate cost field so the dashboard can show both.
    cost = _as_dict(payload.get("cost"))
    cost["cache_savings_usd"] = float(cost.get("cache_savings_usd") or 0.0) + total_read_savings
    cost["savings_usd"] = float(cost.get("savings_usd") or 0.0) + total_read_savings
    cost["write_premium_usd"] = float(cost.get("write_premium_usd") or 0.0) + total_write_premium
    payload["cost"] = cost

    summary = _as_dict(payload.get("summary"))
    sum_cost = _as_dict(summary.get("cost"))
    breakdown = _as_dict(sum_cost.get("breakdown"))
    breakdown["cache_savings_usd"] = (
        float(breakdown.get("cache_savings_usd") or 0.0) + total_read_savings
    )
    sum_cost["breakdown"] = breakdown
    sum_cost["total_saved_usd"] = float(sum_cost.get("total_saved_usd") or 0.0) + net
    summary["cost"] = sum_cost
    payload["summary"] = summary


def _as_dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _display_model_name(model_id: str) -> str:
    model = (model_id or "unknown").strip()
    if not model:
        return "unknown"
    # Bedrock model ids may include region/vendor prefix and version suffix.
    # Keep a readable dashboard label while preserving full id in tags.
    if model.startswith("eu.") or model.startswith("us.") or model.startswith("ap."):
        parts = model.split(".")
        if len(parts) >= 3:
            model = ".".join(parts[2:])
    if ":" in model:
        model = model.split(":", 1)[0]
    return model


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

    shim = _build_bedrock_shim_stats()
    if isinstance(shim, dict):
        saved = _to_int(shim.get("tokens_saved"))
        comp_saved = saved
        api = _to_int(shim.get("api_requests"))
        failed = _to_int(shim.get("failed_requests"))
        cached = _to_int((_as_dict(shim.get("cache"))).get("hits"))
        # snapshot_stats() returns flat asdict() fields: tokens_before, tokens_after, output_tokens
        input_toks = _to_int(shim.get("tokens_before"))
        output_toks = _to_int(shim.get("output_tokens"))
        tokens_after = _to_int(shim.get("tokens_after"))
        avg_compression_pct = (
            100.0 * saved / (saved + tokens_after) if (saved + tokens_after) > 0 else 0.0
        )

        lanes["bedrock_native"]["api_requests"] = api
        lanes["bedrock_native"]["tokens_saved"] = saved
        lanes["bedrock_native"]["compression_tokens_saved"] = comp_saved
        lanes["bedrock_native"]["requests_cached"] = cached
        lanes["bedrock_native"]["requests_failed"] = failed
        lanes["bedrock_native"]["input_tokens"] = input_toks
        lanes["bedrock_native"]["output_tokens"] = output_toks
        lanes["bedrock_native"]["compression_pct"] = round(avg_compression_pct, 2)
        lanes["bedrock_native"]["shim_stats"] = shim

        unified["api_requests"] = copilot_api + api
        unified["tokens_saved"] = copilot_saved + saved
        unified["compression_tokens_saved"] = copilot_comp_saved + comp_saved
        unified["requests_cached"] = copilot_cached + cached
        unified["requests_failed"] = copilot_failed + failed

        # Merge Bedrock native token counts into the top-level tokens block so
        # dashboard sections that read stats.tokens.* (Token Usage box, sparklines)
        # show unified data instead of copilot-only zeros.
        tokens["total_before_compression"] = (
            _to_int(tokens.get("total_before_compression")) + input_toks
        )
        tokens["saved"] = _to_int(tokens.get("saved")) + saved
        tokens["proxy_compression_saved"] = (
            _to_int(tokens.get("proxy_compression_saved")) + comp_saved
        )
        tokens["input"] = _to_int(tokens.get("input")) + tokens_after
        tokens["output"] = _to_int(tokens.get("output")) + output_toks

        # Merge Bedrock native request counts into the top-level requests block
        # so the Providers box shows a bedrock-native entry (only when there's traffic).
        if api > 0:
            by_provider = _as_dict(requests.get("by_provider"))
            by_provider["bedrock-native"] = _to_int(by_provider.get("bedrock-native")) + api
            requests["by_provider"] = by_provider

        payload["tokens"] = tokens
        payload["requests"] = requests

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

    # Surface Bedrock-native shim traffic in dashboard tables even when savings are 0.
    # This augments (does not replace) copilot-lane stats.
    if isinstance(shim, dict):
        by_model = shim.get("by_model") if isinstance(shim.get("by_model"), dict) else {}
        recent = (
            shim.get("recent_requests") if isinstance(shim.get("recent_requests"), list) else []
        )

        cost_block = _as_dict(payload.get("cost"))
        per_model = _as_dict(cost_block.get("per_model"))

        # Accumulate Bedrock USD savings to add to the cost block afterwards.
        # Track gross read savings and write premium separately so savings_usd never goes negative.
        bedrock_compression_savings_usd = 0.0
        bedrock_cache_read_savings_usd = 0.0
        bedrock_write_premium_usd = 0.0
        bedrock_without_usd = 0.0
        bedrock_with_usd = 0.0

        for model, row in by_model.items():
            if not isinstance(row, dict):
                continue
            display_model = _display_model_name(str(model))
            req = _to_int(row.get("requests"))
            sent = _to_int(row.get("tokens_before"))  # input tokens BEFORE compression
            after_toks = _to_int(row.get("tokens_after"))  # input tokens AFTER compression
            saved = _to_int(row.get("tokens_saved"))
            out_toks = _to_int(row.get("output_tokens", 0))
            cr_toks = _to_int(row.get("cache_read_tokens", 0))
            cw_toks = _to_int(row.get("cache_write_tokens", 0))
            reduction = (100.0 * saved / sent) if sent > 0 else 0.0

            # USD savings: compression (tokens removed) + cache reads (10% of input).
            compression_savings_usd = 0.0
            cache_read_savings_usd = 0.0
            write_premium_usd = 0.0
            rec = _lookup_record(display_model)
            if rec is not None:
                in_price, out_price = rec["input"], rec["output"]
                bedrock_without_usd += sent * in_price + out_toks * out_price
                bedrock_with_usd += after_toks * in_price + out_toks * out_price
                if saved > 0:
                    compression_savings_usd = saved * in_price
                    bedrock_compression_savings_usd += compression_savings_usd
                if cr_toks > 0 or cw_toks > 0:
                    # Cache reads bill at cache_read price (90% off) instead of input.
                    cache_read_savings_usd = cr_toks * max(0.0, rec["input"] - rec["cache_read"])
                    # Cache writes bill a 25% premium over input.
                    write_premium_usd = cw_toks * max(0.0, rec["cache_write"] - rec["input"])
                    bedrock_cache_read_savings_usd += cache_read_savings_usd
                    bedrock_write_premium_usd += write_premium_usd

            cur = _as_dict(per_model.get(display_model))
            cur["requests"] = _to_int(cur.get("requests")) + req
            cur["tokens_sent"] = _to_int(cur.get("tokens_sent")) + sent
            cur["tokens_saved"] = _to_int(cur.get("tokens_saved")) + saved
            cur["output_tokens"] = _to_int(cur.get("output_tokens", 0)) + out_toks
            cur["cache_read_tokens"] = _to_int(cur.get("cache_read_tokens", 0)) + cr_toks
            cur["cache_write_tokens"] = _to_int(cur.get("cache_write_tokens", 0)) + cw_toks
            cur["compression_savings_usd"] = (
                float(cur.get("compression_savings_usd") or 0.0) + compression_savings_usd
            )
            # cache_savings_usd = gross read savings; write_premium_usd tracked separately.
            cur["cache_savings_usd"] = (
                float(cur.get("cache_savings_usd") or 0.0) + cache_read_savings_usd
            )
            cur["write_premium_usd"] = (
                float(cur.get("write_premium_usd") or 0.0) + write_premium_usd
            )
            # Recompute aggregate reduction against aggregate totals.
            total_sent = _to_int(cur.get("tokens_sent"))
            total_saved_cur = _to_int(cur.get("tokens_saved"))
            cur["reduction_pct"] = (
                (100.0 * total_saved_cur / total_sent) if total_sent > 0 else reduction
            )
            per_model[display_model] = cur

        cost_block["per_model"] = per_model

        # Merge Bedrock USD savings into the session cost block so the dashboard shows them.
        # savings_usd tracks gross read savings only — never goes negative.
        if bedrock_compression_savings_usd > 0:
            cost_block["savings_usd"] = (
                float(cost_block.get("savings_usd") or 0.0) + bedrock_compression_savings_usd
            )
            cost_block["compression_savings_usd"] = (
                float(cost_block.get("compression_savings_usd") or 0.0)
                + bedrock_compression_savings_usd
            )
        if bedrock_cache_read_savings_usd > 0:
            cost_block["cache_savings_usd"] = (
                float(cost_block.get("cache_savings_usd") or 0.0) + bedrock_cache_read_savings_usd
            )
            cost_block["savings_usd"] = (
                float(cost_block.get("savings_usd") or 0.0) + bedrock_cache_read_savings_usd
            )
        if bedrock_write_premium_usd > 0:
            cost_block["write_premium_usd"] = (
                float(cost_block.get("write_premium_usd") or 0.0) + bedrock_write_premium_usd
            )

        payload["cost"] = cost_block

        bedrock_gross_savings_usd = bedrock_compression_savings_usd + bedrock_cache_read_savings_usd
        bedrock_net_savings_usd = bedrock_gross_savings_usd - bedrock_write_premium_usd

        # Merge into summary.cost so the top-level dashboard metrics also update.
        summary = _as_dict(payload.get("summary"))
        sum_cost = _as_dict(summary.get("cost"))
        if bedrock_gross_savings_usd > 0 or bedrock_write_premium_usd > 0:
            sum_cost["total_saved_usd"] = (
                float(sum_cost.get("total_saved_usd") or 0.0) + bedrock_net_savings_usd
            )
            breakdown = _as_dict(sum_cost.get("breakdown"))
            breakdown["compression_savings_usd"] = (
                float(breakdown.get("compression_savings_usd") or 0.0)
                + bedrock_compression_savings_usd
            )
            breakdown["cache_savings_usd"] = (
                float(breakdown.get("cache_savings_usd") or 0.0) + bedrock_cache_read_savings_usd
            )
            breakdown["write_premium_usd"] = (
                float(breakdown.get("write_premium_usd") or 0.0) + bedrock_write_premium_usd
            )
            sum_cost["breakdown"] = breakdown
        if bedrock_without_usd > 0:
            # Recompute without/with totals whenever any Bedrock savings occurred.
            sum_cost["without_headroom_usd"] = (
                float(sum_cost.get("without_headroom_usd") or 0.0) + bedrock_without_usd
            )
            sum_cost["with_headroom_usd"] = (
                float(sum_cost.get("with_headroom_usd") or 0.0) + bedrock_with_usd
            )
            tot_without = float(sum_cost.get("without_headroom_usd") or 0.0)
            tot_saved = float(sum_cost.get("total_saved_usd") or 0.0)
            sum_cost["savings_pct"] = (
                round(100.0 * tot_saved / tot_without, 2) if tot_without > 0 else 0.0
            )
        summary["cost"] = sum_cost
        payload["summary"] = summary

        request_logs = (
            payload.get("request_logs") if isinstance(payload.get("request_logs"), list) else []
        )
        recent_requests = (
            payload.get("recent_requests")
            if isinstance(payload.get("recent_requests"), list)
            else []
        )
        for entry in recent:
            if not isinstance(entry, dict):
                continue
            raw_model = str(entry.get("model", "unknown"))
            display_model = _display_model_name(raw_model)
            before = _to_int(entry.get("input_tokens_original"))
            after = _to_int(entry.get("input_tokens_optimized"))
            out_toks = _to_int(entry.get("output_tokens", 0))
            saved = _to_int(entry.get("tokens_saved"))
            cr_toks = _to_int(entry.get("cache_read_tokens", 0))
            cw_toks = _to_int(entry.get("cache_write_tokens", 0))
            action = str(entry.get("action", ""))

            # Per-request USD: compression savings + cache read savings.
            req_compression_usd = 0.0
            req_cache_usd = 0.0
            req_rec = _lookup_record(display_model)
            if req_rec is not None:
                if saved > 0:
                    req_compression_usd = saved * req_rec["input"]
                if cr_toks > 0 or cw_toks > 0:
                    read_savings = cr_toks * max(0.0, req_rec["input"] - req_rec["cache_read"])
                    write_premium = cw_toks * max(0.0, req_rec["cache_write"] - req_rec["input"])
                    req_cache_usd = read_savings - write_premium

            # Build meaningful per-request transforms from what the Bedrock shim
            # actually did, so the dashboard's expandable row shows real detail
            # instead of a single opaque shim tag.
            transforms: list[str] = []
            if bool(entry.get("compressed")):
                transforms.append("bedrock_native:compress")
            if bool(entry.get("marker_applied")):
                transforms.append("bedrock_native:cache_control")
            if cr_toks > 0:
                transforms.append("bedrock_native:cache_hit")
            if action:
                transforms.append(f"bedrock_native:{action}")
            if not transforms:
                transforms.append("bedrock_native:passthrough")

            # Surface compressed input as a single "context" waste signal so the
            # per-request Waste Detected panel renders for Bedrock rows too.
            waste_signals = {"redundant_context": saved} if saved > 0 else None

            req_row = {
                "request_id": f"bedrock-native-{entry.get('timestamp', '')}",
                "timestamp": entry.get("timestamp", _utc_now_iso()),
                "provider": "bedrock_native",
                "model": display_model,
                "input_tokens_original": before,
                "input_tokens_optimized": after,
                "output_tokens": out_toks,
                "tokens_saved": saved,
                "savings_percent": (100.0 * saved / before) if before > 0 else 0.0,
                "compression_savings_usd": req_compression_usd,
                "cache_savings_usd": req_cache_usd,
                "cache_read_tokens": cr_toks,
                "cache_write_tokens": cw_toks,
                "optimization_latency_ms": 0.0,
                "total_latency_ms": 0.0,
                "tags": {
                    "lane": "bedrock_native",
                    "action": action,
                    "raw_model": raw_model,
                },
                "cache_hit": cr_toks > 0,
                "transforms_applied": transforms,
                "waste_signals": waste_signals,
                "error": "request_failed" if bool(entry.get("failed", False)) else None,
                "turn_id": None,
            }
            request_logs.append(req_row)
            recent_requests.append(req_row)

        # Keep most recent 500 by timestamp string (ISO-8601 sortable)
        request_logs.sort(key=lambda r: str(_as_dict(r).get("timestamp", "")))
        payload["request_logs"] = request_logs[-500:]
        recent_requests.sort(key=lambda r: str(_as_dict(r).get("timestamp", "")), reverse=True)
        payload["recent_requests"] = recent_requests[:10]

    # Price provider prefix-cache reads (e.g. Copilot's automatic Claude prompt
    # caching) that headroom records but cannot value without per-model pricing.
    _apply_prefix_cache_pricing(payload)

    return payload


def _bedrock_savings_usd(shim: dict[str, Any]) -> tuple[float, float]:
    """Return (compression_savings_usd, cache_savings_usd) across all Bedrock native models."""
    by_model = shim.get("by_model") if isinstance(shim.get("by_model"), dict) else {}
    comp_total = 0.0
    cache_total = 0.0
    for model, row in by_model.items():
        if not isinstance(row, dict):
            continue
        display_model = _display_model_name(str(model))
        rec = _lookup_record(display_model)
        if rec is None:
            continue
        saved = _to_int(row.get("tokens_saved"))
        if saved > 0:
            comp_total += saved * rec["input"]
        cr_toks = _to_int(row.get("cache_read_tokens", 0))
        cw_toks = _to_int(row.get("cache_write_tokens", 0))
        if cr_toks > 0 or cw_toks > 0:
            read_savings = cr_toks * max(0.0, rec["input"] - rec["cache_read"])
            write_premium = cw_toks * max(0.0, rec["cache_write"] - rec["input"])
            cache_total += read_savings - write_premium
    return comp_total, cache_total


def _bedrock_compression_savings_usd(shim: dict[str, Any]) -> float:
    """Backward-compat wrapper — returns only compression savings."""
    comp, _ = _bedrock_savings_usd(shim)
    return comp


def _merge_unified_history(base: dict[str, Any], bedrock: _BedrockStats) -> dict[str, Any]:
    payload = deepcopy(base)
    lifetime: dict[str, Any] = _as_dict(payload.get("lifetime"))
    payload["lifetime"] = lifetime
    shim = _build_bedrock_shim_stats()
    bedrock_api = (
        _to_int(shim.get("api_requests")) if isinstance(shim, dict) else bedrock.api_requests
    )
    bedrock_saved = (
        _to_int(shim.get("tokens_saved")) if isinstance(shim, dict) else bedrock.tokens_saved
    )

    lifetime["api_requests"] = _to_int(lifetime.get("api_requests")) + bedrock_api
    lifetime["tokens_saved"] = _to_int(lifetime.get("tokens_saved")) + bedrock_saved

    display: dict[str, Any] = _as_dict(payload.get("display_session"))
    payload["display_session"] = display
    display["requests"] = _to_int(display.get("requests")) + bedrock_api
    display["tokens_saved"] = _to_int(display.get("tokens_saved")) + bedrock_saved

    if isinstance(shim, dict):
        bedrock_comp_usd, bedrock_cache_usd = _bedrock_savings_usd(shim)
        if bedrock_comp_usd > 0:
            display["compression_savings_usd"] = (
                float(display.get("compression_savings_usd") or 0.0) + bedrock_comp_usd
            )
        if bedrock_cache_usd != 0:
            display["cache_savings_usd"] = (
                float(display.get("cache_savings_usd") or 0.0) + bedrock_cache_usd
            )

    payload.setdefault("unified_history", {})
    payload["unified_history"] = {
        "bedrock_native": {
            "available": bedrock.available,
            "endpoint": bedrock.endpoint,
            "error": bedrock.error,
            "api_requests": bedrock.api_requests,
            "tokens_saved": bedrock.tokens_saved,
            "shim_stats": shim,
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
