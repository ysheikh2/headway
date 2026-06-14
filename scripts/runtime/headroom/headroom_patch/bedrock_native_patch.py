from __future__ import annotations

import copy
import json
import os
import re
import threading
from contextlib import suppress
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from typing import Any

import httpx
from fastapi.responses import JSONResponse, Response, StreamingResponse
from headroom.cache.compression_cache import CompressionCache
from headroom.proxy.helpers import read_request_json_with_bytes
from starlette.concurrency import run_in_threadpool


def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None:
        return default
    try:
        return int(raw.strip())
    except ValueError:
        return default


BEDROCK_UPSTREAM = os.getenv("HEADROOM_BEDROCK_PROXY_URL", "http://headroom-bedrock:8787")
AUTO_CACHE_CONTROL = _env_bool("HEADWAY_BEDROCK_AUTO_CACHE_CONTROL", True)
COMPRESS_USER_MESSAGES = _env_bool("HEADROOM_COMPRESS_USER_MESSAGES", True)
PROTECT_RECENT = _env_int("HEADROOM_PROTECT_RECENT", 2)
MIN_TOKENS = _env_int("HEADROOM_MIN_TOKENS", 120)

# Savings profile drives the real coding-agent savings: it forces Kompress past
# the conservative ratio gate (target_ratio=0.1, force_kompress) and tells
# SmartCrusher to drop/crush old items (max_items_after_crush). Without a
# profile the default 0.85 ratio gate discards the ~2% Kompress achieves on
# real code/file content, so net savings are ~0. `agent-90` is the profile
# headroom ships for coding agents; set HEADROOM_BEDROCK_SAVINGS_PROFILE to
# `balanced` for a gentler crush, or empty to disable.
SAVINGS_PROFILE = (os.getenv("HEADROOM_BEDROCK_SAVINGS_PROFILE") or "agent-90").strip() or None

# Size guard: bodies larger than this (raw request bytes) skip compression and
# forward unchanged. Compression on very large bodies can route to the slow
# Kompress ONNX path (multi-second CPU inference); the cap bounds worst-case
# latency. Generous default so normal agent traffic still compresses.
MAX_COMPRESS_BYTES = _env_int("HEADROOM_BEDROCK_COMPRESS_MAX_BYTES", 3_000_000)
MODEL_LIMIT = _env_int("HEADROOM_BEDROCK_MODEL_LIMIT", 200_000)
DEBUG_COMPRESS = _env_bool("HEADWAY_BEDROCK_DEBUG_COMPRESS", False)

# Aggressiveness knobs. The proxy's shared ContentRouter is deliberately
# conservative for correctness: it excludes coding-tool outputs (Bash/Read/Edit/
# Grep/Glob/Write — DEFAULT_EXCLUDE_TOOLS), skips user messages, and leaves
# assistant text uncompressed. On Kilo coding traffic that leaves ~nothing to
# compress (every tool result is `router:excluded:tool`). This lane is a
# token-savings lane, so by default we relax those guards; each can be turned
# back off via env if compression ever disturbs agent behavior.
COMPRESS_TOOL_OUTPUTS = _env_bool("HEADWAY_BEDROCK_COMPRESS_TOOL_OUTPUTS", True)
COMPRESS_ASSISTANT_TEXT = _env_bool("HEADWAY_BEDROCK_COMPRESS_ASSISTANT_TEXT", True)

_COMP_CACHE = CompressionCache(max_entries=20000)

_shim_pipeline: Any = None
_shim_pipeline_lock = threading.Lock()
_profile: Any = None
_profile_loaded = False


def _get_profile() -> Any:
    """Load the configured agent savings profile once (or None)."""
    global _profile, _profile_loaded
    if _profile_loaded:
        return _profile
    if SAVINGS_PROFILE:
        try:
            from headroom.agent_savings import get_agent_savings_profile

            _profile = get_agent_savings_profile(SAVINGS_PROFILE)
        except Exception:
            _profile = None
    _profile_loaded = True
    return _profile


def _get_shim_pipeline() -> Any:
    """Build (once) a ContentRouter tuned for the Bedrock token-savings lane.

    Same engine as the copilot lane (ContentRouter + SmartCrusher/compaction +
    code-aware + Kompress) but with the conservative safety guards relaxed so
    coding-tool outputs, user-message tool results, and assistant text actually
    get compressed, and with the active savings profile's SmartCrusher crush
    limit applied (so old items are dropped, not just shrunk).
    """
    global _shim_pipeline
    if _shim_pipeline is not None:
        return _shim_pipeline
    with _shim_pipeline_lock:
        if _shim_pipeline is not None:
            return _shim_pipeline
        from headroom.transforms import (
            ContentRouter,
            ContentRouterConfig,
            TransformPipeline,
        )

        profile = _get_profile()
        cfg = ContentRouterConfig(
            enable_code_aware=True,
            skip_user_messages=False,
            compress_assistant_text_blocks=COMPRESS_ASSISTANT_TEXT,
            protect_analysis_context=False,
            smart_crusher_with_compaction=(
                getattr(profile, "smart_crusher_with_compaction", True)
                if profile is not None
                else True
            ),
            smart_crusher_max_items_after_crush=(
                getattr(profile, "max_items_after_crush", None) if profile is not None else None
            ),
        )
        if COMPRESS_TOOL_OUTPUTS:
            # Empty (but non-None) set overrides DEFAULT_EXCLUDE_TOOLS so the
            # router stops skipping Bash/Read/Edit/Grep/Glob/Write outputs.
            cfg.exclude_tools = set()
        _shim_pipeline = TransformPipeline(transforms=[ContentRouter(cfg)])
        return _shim_pipeline


def _compress_messages(
    messages: list[dict[str, Any]],
    model_id: str,
) -> tuple[list[dict[str, Any]], int, int]:
    """Compress an Anthropic-format message list with the shim's tuned router.

    Returns ``(messages, tokens_before, tokens_after)``; on any failure returns
    a no-savings passthrough.
    """
    try:
        pipeline = _get_shim_pipeline()
    except Exception:
        return messages, 0, 0

    context = None
    try:
        from headroom.utils import extract_user_query

        context = extract_user_query(messages)
    except Exception:
        context = None

    profile = _get_profile()
    kwargs: dict[str, Any] = {
        "protect_recent": PROTECT_RECENT,
        "compress_user_messages": COMPRESS_USER_MESSAGES,
        "min_tokens_to_compress": MIN_TOKENS,
    }
    if profile is not None:
        # The profile is what pushes Kompress past the default ratio gate; on
        # real code/file content this is the difference between ~0% and ~25%+.
        kwargs["protect_recent"] = getattr(profile, "protect_recent", PROTECT_RECENT)
        kwargs["min_tokens_to_compress"] = getattr(profile, "min_tokens_to_compress", MIN_TOKENS)
        target_ratio = getattr(profile, "target_ratio", None)
        if target_ratio is not None:
            kwargs["target_ratio"] = target_ratio
        force_kompress = getattr(profile, "force_kompress", None)
        if force_kompress is not None:
            kwargs["force_kompress"] = force_kompress

    try:
        result = pipeline.apply(
            messages=messages,
            model=model_id,
            model_limit=MODEL_LIMIT,
            context=context,
            **kwargs,
        )
    except Exception:
        return messages, 0, 0

    tokens_before = int(getattr(result, "tokens_before", 0) or 0)
    tokens_after = int(getattr(result, "tokens_after", 0) or 0)
    out = getattr(result, "messages", None) or messages

    if DEBUG_COMPRESS:
        try:
            msg_summary = []
            for m in messages:
                if not isinstance(m, dict):
                    msg_summary.append({"role": "?", "blocks": "non-dict"})
                    continue
                content = m.get("content")
                blocks = []
                if isinstance(content, list):
                    for blk in content:
                        if isinstance(blk, dict):
                            btype = blk.get("type") or next(iter(blk), "?")
                            blen = len(json.dumps(blk, ensure_ascii=False))
                            blocks.append(f"{btype}:{blen}")
                        else:
                            blocks.append(f"raw:{len(str(blk))}")
                elif isinstance(content, str):
                    blocks.append(f"str:{len(content)}")
                msg_summary.append({"role": m.get("role"), "blocks": blocks})
            with open("/tmp/headway_compress_debug.jsonl", "a") as fh:
                fh.write(
                    json.dumps(
                        {
                            "ts": _utc_now_iso(),
                            "model": model_id,
                            "tokens_before": tokens_before,
                            "tokens_after": tokens_after,
                            "num_messages": len(messages),
                            "transforms_applied": list(
                                getattr(result, "transforms_applied", []) or []
                            ),
                            "kwargs": {k: str(v) for k, v in kwargs.items()},
                            "messages": msg_summary,
                        }
                    )
                    + "\n"
                )
            # Dump the full converted message list for the first large request
            # so it can be replayed offline against the pipeline with verbose
            # logging (which transform compressed what, and by how much).
            if tokens_before > 8000 and not os.path.exists("/tmp/headway_last_full.json"):
                with open("/tmp/headway_last_full.json", "w") as fh:
                    json.dump({"model": model_id, "messages": messages}, fh)
        except Exception as exc:  # noqa: BLE001
            try:
                with open("/tmp/headway_compress_debug.jsonl", "a") as fh:
                    fh.write(json.dumps({"ts": _utc_now_iso(), "debug_error": repr(exc)}) + "\n")
            except Exception:  # noqa: BLE001
                pass

    # Inflation guard: never forward more tokens than we received.
    if tokens_after > tokens_before:
        return messages, tokens_before, tokens_before
    return out, tokens_before, tokens_after


@dataclass
class _BedrockNativeStats:
    api_requests: int = 0
    failed_requests: int = 0
    compressed_requests: int = 0
    tokens_before: int = 0
    tokens_after: int = 0
    tokens_saved: int = 0
    output_tokens: int = 0
    cache_markers_applied: int = 0
    cache_read_tokens: int = 0
    cache_write_tokens: int = 0
    best_before: int = 0
    best_after: int = 0
    by_model: dict[str, dict[str, int]] | None = None
    recent_requests: list[dict[str, Any]] | None = None

    @property
    def best_pct(self) -> float:
        if self.best_before <= 0:
            return 0.0
        return max(0.0, (self.best_before - self.best_after) * 100.0 / self.best_before)


_stats_lock = threading.Lock()
_stats = _BedrockNativeStats()


def _utc_now_iso() -> str:
    return datetime.now(UTC).isoformat()


def _is_anthropic_model(model_id: str) -> bool:
    return model_id.startswith("anthropic.") or ".anthropic." in model_id


def _extract_model_action(path: str) -> tuple[str, str] | None:
    if not path.startswith("/model/"):
        return None
    remainder = path[len("/model/") :]
    if "/" not in remainder:
        return None
    model_id, action = remainder.rsplit("/", 1)
    if not model_id:
        return None
    if action not in {"invoke", "invoke-with-response-stream", "converse", "converse-stream"}:
        return None
    return model_id, action


def _is_bedrock_lane_host(host_header: str) -> bool:
    host = (host_header or "").strip().lower()
    if not host:
        return False
    # Requests arriving via docker port mapping 127.0.0.1:4002 should keep Host: *:4002.
    return host.endswith(":4002")


def _is_streaming_action(action: str) -> bool:
    return action in {"invoke-with-response-stream", "converse-stream"}


def _deep_has_key(obj: Any, key: str) -> bool:
    if isinstance(obj, dict):
        if key in obj:
            return True
        return any(_deep_has_key(v, key) for v in obj.values())
    if isinstance(obj, list):
        return any(_deep_has_key(v, key) for v in obj)
    return False


def _bedrock_content_to_anthropic(content: Any) -> list[dict[str, Any]]:
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    if not isinstance(content, list):
        return [{"type": "text", "text": str(content)}]

    out: list[dict[str, Any]] = []
    for item in content:
        if isinstance(item, str):
            out.append({"type": "text", "text": item})
            continue
        if not isinstance(item, dict):
            out.append({"type": "text", "text": str(item)})
            continue

        if "toolUse" in item and isinstance(item["toolUse"], dict):
            tu = item["toolUse"]
            out.append(
                {
                    "type": "tool_use",
                    "id": tu.get("toolUseId", ""),
                    "name": tu.get("name", ""),
                    "input": tu.get("input", {}),
                }
            )
            continue

        if "toolResult" in item and isinstance(item["toolResult"], dict):
            tr = item["toolResult"]
            tr_content = tr.get("content")
            text_parts: list[str] = []
            if isinstance(tr_content, list):
                for block in tr_content:
                    if isinstance(block, dict):
                        if isinstance(block.get("text"), str):
                            text_parts.append(block["text"])
                        elif "json" in block:
                            text_parts.append(json.dumps(block.get("json"), ensure_ascii=False))
                    elif isinstance(block, str):
                        text_parts.append(block)
            elif isinstance(tr_content, str):
                text_parts.append(tr_content)

            out.append(
                {
                    "type": "tool_result",
                    "tool_use_id": tr.get("toolUseId", ""),
                    "content": "\n".join(text_parts),
                }
            )
            continue

        if item.get("type") == "text" or "text" in item:
            next_item = dict(item)
            next_item["type"] = "text"
            next_item["text"] = item.get("text", "")
            out.append(next_item)
            continue

        out.append(dict(item))

    return out


def _anthropic_content_to_bedrock(
    content: Any,
    *,
    prefer_bedrock_blocks: bool,
) -> list[dict[str, Any]]:
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    if not isinstance(content, list):
        return [{"type": "text", "text": str(content)}]

    out: list[dict[str, Any]] = []
    for item in content:
        if isinstance(item, str):
            if prefer_bedrock_blocks:
                out.append({"text": item})
            else:
                out.append({"type": "text", "text": item})
            continue
        if not isinstance(item, dict):
            if prefer_bedrock_blocks:
                out.append({"text": str(item)})
            else:
                out.append({"type": "text", "text": str(item)})
            continue

        t = str(item.get("type", ""))
        if t == "tool_use":
            if not prefer_bedrock_blocks:
                out.append(
                    {
                        "type": "tool_use",
                        "id": item.get("id", ""),
                        "name": item.get("name", ""),
                        "input": item.get("input", {}),
                    }
                )
                continue
            out.append(
                {
                    "toolUse": {
                        "toolUseId": item.get("id", ""),
                        "name": item.get("name", ""),
                        "input": item.get("input", {}),
                    }
                }
            )
            continue

        if t == "tool_result":
            if not prefer_bedrock_blocks:
                out.append(
                    {
                        "type": "tool_result",
                        "tool_use_id": item.get("tool_use_id", ""),
                        "content": item.get("content", ""),
                    }
                )
                continue
            tr_content = item.get("content", "")
            if isinstance(tr_content, list):
                normalized_content = tr_content
            elif isinstance(tr_content, dict):
                normalized_content = [{"json": tr_content}]
            else:
                normalized_content = [{"text": str(tr_content)}]
            out.append(
                {
                    "toolResult": {
                        "toolUseId": item.get("tool_use_id", ""),
                        "content": normalized_content,
                    }
                }
            )
            continue

        if "toolUse" in item and isinstance(item["toolUse"], dict):
            tu = item["toolUse"]
            if not prefer_bedrock_blocks:
                out.append(
                    {
                        "type": "tool_use",
                        "id": tu.get("toolUseId", ""),
                        "name": tu.get("name", ""),
                        "input": tu.get("input", {}),
                    }
                )
                continue
            out.append(
                {
                    "toolUse": {
                        "toolUseId": tu.get("toolUseId", ""),
                        "name": tu.get("name", ""),
                        "input": tu.get("input", {}),
                    }
                }
            )
            continue

        if "toolResult" in item and isinstance(item["toolResult"], dict):
            tr = item["toolResult"]
            if not prefer_bedrock_blocks:
                out.append(
                    {
                        "type": "tool_result",
                        "tool_use_id": tr.get("toolUseId", ""),
                        "content": tr.get("content", ""),
                    }
                )
                continue
            out.append(
                {
                    "toolResult": {
                        "toolUseId": tr.get("toolUseId", ""),
                        "content": tr.get("content", []),
                    }
                }
            )
            continue

        if t == "text" or "text" in item:
            next_item = dict(item)
            if prefer_bedrock_blocks:
                next_item.pop("type", None)
                next_item["text"] = item.get("text", "")
            else:
                next_item["type"] = "text"
                next_item["text"] = item.get("text", "")
            out.append(next_item)
            continue

        out.append(dict(item))

    return out


def _bedrock_messages_to_anthropic(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    converted: list[dict[str, Any]] = []
    for msg in messages:
        if not isinstance(msg, dict):
            continue
        role = msg.get("role")
        if not isinstance(role, str):
            continue
        converted.append(
            {
                "role": role,
                "content": _bedrock_content_to_anthropic(msg.get("content", [])),
            }
        )
    return converted


def _anthropic_messages_to_bedrock(
    messages: list[dict[str, Any]],
    *,
    prefer_bedrock_blocks: bool,
) -> list[dict[str, Any]]:
    converted: list[dict[str, Any]] = []
    for msg in messages:
        if not isinstance(msg, dict):
            continue
        role = msg.get("role")
        if not isinstance(role, str):
            continue
        converted.append(
            {
                "role": role,
                "content": _anthropic_content_to_bedrock(
                    msg.get("content", []),
                    prefer_bedrock_blocks=prefer_bedrock_blocks,
                ),
            }
        )
    return converted


def _add_system_cache_control(body: dict[str, Any]) -> bool:
    """Add cache_control to the last block of the system prompt if present and unmarked.

    The system prompt is the most valuable caching target — it's stable across turns
    and often large. Marking it yields cache reads (90% off) on every subsequent turn.
    Returns True if a marker was added.
    """
    system = body.get("system")
    if not system:
        return False
    # Anthropic Messages API: system is a string or list of content blocks.
    if isinstance(system, str):
        if system and "cache_control" not in body:
            body["system"] = [
                {"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}
            ]
            return True
        return False
    if isinstance(system, list) and system:
        if _deep_has_key(system, "cache_control"):
            return False
        last = system[-1]
        if isinstance(last, dict) and not last.get("cache_control"):
            last["cache_control"] = {"type": "ephemeral"}
            return True
    return False


def _add_cache_control_marker(messages: list[dict[str, Any]]) -> bool:
    """Add cache_control to a stable message in the frozen prefix (best-effort).

    Called after system-prompt marking; this adds a second breakpoint on the most
    recently frozen tool result or user turn for multi-breakpoint cache coverage.
    """
    if not messages or _deep_has_key(messages, "cache_control"):
        return False

    frozen = _COMP_CACHE.compute_frozen_count(messages)
    candidate = min(max(frozen - 1, 0), max(0, len(messages) - 2))
    for i in range(candidate, -1, -1):
        content = messages[i].get("content")
        if not isinstance(content, list):
            continue
        for j in range(len(content) - 1, -1, -1):
            block = content[j]
            if not isinstance(block, dict):
                continue
            if (
                block.get("type") == "text" or "text" in block or block.get("type") == "tool_result"
            ) and "cache_control" not in block:
                block["cache_control"] = {"type": "ephemeral"}
                return True
    return False


def _compress_bedrock_body(
    body: dict[str, Any],
    model_id: str,
    *,
    action: str,
) -> tuple[dict[str, Any], int, int, bool]:
    messages = body.get("messages")
    if not isinstance(messages, list) or not messages:
        return body, 0, 0, False

    if DEBUG_COMPRESS:
        try:
            with open("/tmp/headway_compress_debug.jsonl", "a") as fh:
                fh.write(
                    json.dumps(
                        {
                            "ts": _utc_now_iso(),
                            "event": "converse_body",
                            "action": action,
                            "top_level_keys": sorted(body.keys()),
                            "system_chars": len(
                                json.dumps(body.get("system", ""), ensure_ascii=False)
                            ),
                            "toolConfig_chars": len(
                                json.dumps(body.get("toolConfig", ""), ensure_ascii=False)
                            ),
                            "num_messages": len(messages),
                        }
                    )
                    + "\n"
                )
        except Exception:  # noqa: BLE001
            pass

    anthropic_messages = _bedrock_messages_to_anthropic(messages)
    if not anthropic_messages:
        return body, 0, 0, False

    cached_input = _COMP_CACHE.apply_cached(anthropic_messages)
    compressed_messages, tokens_before, tokens_after = _compress_messages(cached_input, model_id)
    _COMP_CACHE.update_from_result(cached_input, compressed_messages)

    outgoing_messages = copy.deepcopy(compressed_messages)
    marker_applied = False
    if AUTO_CACHE_CONTROL and _is_anthropic_model(model_id):
        # Mark the system prompt first (stable, highest caching value), then
        # add a second breakpoint in the frozen message prefix if one exists.
        updated_body = dict(body)
        sys_marked = _add_system_cache_control(updated_body)
        msg_marked = _add_cache_control_marker(outgoing_messages)
        marker_applied = sys_marked or msg_marked

    updated = updated_body if marker_applied else dict(body)
    updated["messages"] = _anthropic_messages_to_bedrock(
        outgoing_messages,
        # Converse-stream is stricter about Bedrock-native content-block keys.
        prefer_bedrock_blocks=(action == "converse-stream"),
    )

    # Normalize system blocks: Bedrock Converse uses {"text": "..."} but
    # headroom-bedrock forwards to InvokeModel which requires {"type": "text", "text": "..."}.
    system = updated.get("system")
    if isinstance(system, list):
        for block in system:
            if isinstance(block, dict) and "text" in block and "type" not in block:
                block["type"] = "text"

    # Bedrock Anthropic expects Anthropic wire fields at top-level even on
    # /converse surfaces in this lane. Normalize common Converse-style fields.
    inf = updated.get("inferenceConfig")
    inferred_max_tokens: int | None = None
    if isinstance(inf, dict):
        raw_max = inf.get("maxTokens") if "maxTokens" in inf else inf.get("max_tokens")
        if isinstance(raw_max, (int, float)):
            inferred_max_tokens = int(raw_max)
        elif isinstance(raw_max, str) and raw_max.strip().isdigit():
            inferred_max_tokens = int(raw_max.strip())

        if "temperature" not in updated and isinstance(inf.get("temperature"), (int, float)):
            updated["temperature"] = inf.get("temperature")
        if "top_p" not in updated and isinstance(inf.get("topP"), (int, float)):
            updated["top_p"] = inf.get("topP")
        if "top_p" not in updated and isinstance(inf.get("top_p"), (int, float)):
            updated["top_p"] = inf.get("top_p")
        if "stop_sequences" not in updated and isinstance(inf.get("stopSequences"), list):
            updated["stop_sequences"] = inf.get("stopSequences")

    if "max_tokens" not in updated and inferred_max_tokens is not None:
        updated["max_tokens"] = inferred_max_tokens

    if "anthropic_version" not in updated:
        updated["anthropic_version"] = "bedrock-2023-05-31"

    if isinstance(updated.get("inferenceConfig"), dict):
        # Keep the outbound envelope Anthropic-native and avoid duplicate
        # max-token fields that trigger Bedrock validation errors.
        cleaned = dict(updated["inferenceConfig"])
        cleaned.pop("maxTokens", None)
        cleaned.pop("max_tokens", None)
        if cleaned:
            updated["inferenceConfig"] = cleaned
        else:
            updated.pop("inferenceConfig", None)

    return updated, int(tokens_before), int(tokens_after), marker_applied


def _compress_anthropic_v1_body(
    body: dict[str, Any],
    model_id: str,
) -> tuple[dict[str, Any], int, int, bool]:
    """Compress an Anthropic Messages API (``/v1/messages``) body.

    Unlike the Bedrock Converse surface, ``/v1/messages`` already carries
    Anthropic-native content blocks, so no Bedrock<->Anthropic conversion is
    needed — we compress the message list directly.
    """
    messages = body.get("messages")
    if not isinstance(messages, list) or not messages:
        return body, 0, 0, False

    work = copy.deepcopy(messages)
    cached_input = _COMP_CACHE.apply_cached(work)
    compressed_messages, tokens_before, tokens_after = _compress_messages(cached_input, model_id)
    _COMP_CACHE.update_from_result(cached_input, compressed_messages)

    outgoing = copy.deepcopy(compressed_messages)
    marker_applied = False
    if AUTO_CACHE_CONTROL and _is_anthropic_model(model_id):
        updated_body = dict(body)
        sys_marked = _add_system_cache_control(updated_body)
        msg_marked = _add_cache_control_marker(outgoing)
        marker_applied = sys_marked or msg_marked
    else:
        updated_body = dict(body)

    updated_body["messages"] = outgoing
    return updated_body, int(tokens_before), int(tokens_after), marker_applied


def _record_stats(
    *,
    model_id: str,
    action: str,
    before: int,
    after: int,
    output_tokens: int = 0,
    cache_read_tokens: int = 0,
    cache_write_tokens: int = 0,
    compressed: bool,
    marker_applied: bool,
    failed: bool,
) -> None:
    with _stats_lock:
        if _stats.by_model is None:
            _stats.by_model = {}
        if _stats.recent_requests is None:
            _stats.recent_requests = []

        _stats.api_requests += 1
        if failed:
            _stats.failed_requests += 1
        if output_tokens > 0:
            _stats.output_tokens += output_tokens
        if cache_read_tokens > 0:
            _stats.cache_read_tokens += cache_read_tokens
        if cache_write_tokens > 0:
            _stats.cache_write_tokens += cache_write_tokens

        _default_row: dict[str, int] = {
            "requests": 0,
            "tokens_before": 0,
            "tokens_after": 0,
            "tokens_saved": 0,
            "output_tokens": 0,
            "cache_read_tokens": 0,
            "cache_write_tokens": 0,
            "failed": 0,
        }

        if before > 0:
            _stats.tokens_before += before
            _stats.tokens_after += after if after > 0 else before
            saved = max(0, before - (after if after > 0 else before))
            _stats.tokens_saved += saved
            if saved > 0 and before > _stats.best_before:
                _stats.best_before = before
                _stats.best_after = after

            model_row = _stats.by_model.setdefault(model_id, dict(_default_row))
            model_row["requests"] += 1
            model_row["tokens_before"] += before
            model_row["tokens_after"] += after if after > 0 else before
            model_row["tokens_saved"] += saved
            model_row["output_tokens"] = model_row.get("output_tokens", 0) + output_tokens
            model_row["cache_read_tokens"] = (
                model_row.get("cache_read_tokens", 0) + cache_read_tokens
            )
            model_row["cache_write_tokens"] = (
                model_row.get("cache_write_tokens", 0) + cache_write_tokens
            )
            if failed:
                model_row["failed"] += 1
        else:
            model_row = _stats.by_model.setdefault(model_id, dict(_default_row))
            model_row["requests"] += 1
            model_row["output_tokens"] = model_row.get("output_tokens", 0) + output_tokens
            model_row["cache_read_tokens"] = (
                model_row.get("cache_read_tokens", 0) + cache_read_tokens
            )
            model_row["cache_write_tokens"] = (
                model_row.get("cache_write_tokens", 0) + cache_write_tokens
            )
            if failed:
                model_row["failed"] += 1

        _stats.recent_requests.append(
            {
                "timestamp": _utc_now_iso(),
                "model": model_id,
                "action": action,
                "input_tokens_original": before,
                "input_tokens_optimized": after if after > 0 else before,
                "output_tokens": output_tokens,
                "tokens_saved": max(0, before - (after if after > 0 else before)),
                "cache_read_tokens": cache_read_tokens,
                "cache_write_tokens": cache_write_tokens,
                "failed": failed,
                "compressed": compressed,
                "marker_applied": marker_applied,
            }
        )
        if len(_stats.recent_requests) > 50:
            _stats.recent_requests = _stats.recent_requests[-50:]
        if compressed:
            _stats.compressed_requests += 1
        if marker_applied:
            _stats.cache_markers_applied += 1


def _parse_output_tokens_from_response(body_bytes: bytes, action: str) -> int:
    """Extract output token count from a non-streaming Bedrock/Anthropic response."""
    if not body_bytes:
        return 0
    try:
        resp = json.loads(body_bytes)
    except Exception:
        return 0
    if not isinstance(resp, dict):
        return 0

    usage = resp.get("usage")
    if isinstance(usage, dict):
        out = usage.get("output_tokens") or usage.get("outputTokens") or 0
        if isinstance(out, (int, float)) and out > 0:
            return int(out)

    return 0


def _parse_cache_tokens_from_response(body_bytes: bytes) -> tuple[int, int]:
    """Extract (cache_read_tokens, cache_write_tokens) from a Bedrock/Anthropic response.

    Handles both formats:
    - Anthropic Messages API (InvokeModel): cache_read_input_tokens / cache_creation_input_tokens
    - Bedrock Converse API: cacheReadInputTokens / cacheWriteInputTokens
    """
    if not body_bytes:
        return 0, 0
    try:
        resp = json.loads(body_bytes)
    except Exception:
        return 0, 0
    if not isinstance(resp, dict):
        return 0, 0

    usage = resp.get("usage")
    if not isinstance(usage, dict):
        return 0, 0

    # Anthropic Messages API format (InvokeModel path through headroom-bedrock)
    cr = int(usage.get("cache_read_input_tokens") or 0)
    cw = int(usage.get("cache_creation_input_tokens") or 0)
    # Bedrock Converse API format (cacheReadInputTokens / cacheWriteInputTokens)
    if cr == 0:
        cr = int(usage.get("cacheReadInputTokens") or 0)
    if cw == 0:
        cw = int(usage.get("cacheWriteInputTokens") or 0)

    return cr, cw


class _StreamUsageScanner:
    """Extract the final usage counts from a streaming response body.

    Scans for output tokens, cache-read tokens, and cache-write tokens in both
    Anthropic SSE and Bedrock Converse event-stream formats.
    """

    _MAX_TAIL = 65536
    _OUT_PATTERN = re.compile(rb'"(?:output_tokens|outputTokens)"\s*:\s*(\d+)')
    _CR_PATTERN = re.compile(rb'"(?:cache_read_input_tokens|cacheReadInputTokens)"\s*:\s*(\d+)')
    _CW_PATTERN = re.compile(
        rb'"(?:cache_creation_input_tokens|cacheWriteInputTokens)"\s*:\s*(\d+)'
    )

    def __init__(self) -> None:
        self._buf = bytearray()

    def feed(self, chunk: bytes) -> None:
        if not chunk:
            return
        self._buf.extend(chunk)
        if len(self._buf) > self._MAX_TAIL:
            del self._buf[: -self._MAX_TAIL]

    def _max_match(self, pattern: re.Pattern) -> int:  # type: ignore[type-arg]
        best = 0
        for match in pattern.finditer(bytes(self._buf)):
            try:
                value = int(match.group(1))
            except Exception:
                continue
            if value > best:
                best = value
        return best

    def output_tokens(self) -> int:
        return self._max_match(self._OUT_PATTERN)

    def cache_read_tokens(self) -> int:
        return self._max_match(self._CR_PATTERN)

    def cache_write_tokens(self) -> int:
        return self._max_match(self._CW_PATTERN)


def snapshot_stats() -> dict[str, Any]:
    with _stats_lock:
        snapshot = copy.deepcopy(_stats)
    payload = asdict(snapshot)
    payload["by_model"] = snapshot.by_model or {}
    payload["recent_requests"] = snapshot.recent_requests or []
    payload["best_compression_pct"] = snapshot.best_pct
    payload["cache"] = _COMP_CACHE.get_stats()
    return payload


def _stats_payload() -> dict[str, Any]:
    with _stats_lock:
        snapshot = copy.deepcopy(_stats)
    cache_stats = _COMP_CACHE.get_stats()
    pct = 0.0
    if snapshot.tokens_before > 0:
        pct = (snapshot.tokens_saved * 100.0) / snapshot.tokens_before
    best_detail = "n/a"
    if snapshot.best_before > 0 and snapshot.best_after >= 0:
        best_detail = f"{snapshot.best_before:,} -> {snapshot.best_after:,} tokens"

    return {
        "ok": True,
        "service": "headroom-bedrock-native-shim",
        "summary": {
            "api_requests": snapshot.api_requests,
            "compression": {
                "requests_compressed": snapshot.compressed_requests,
                "avg_compression_pct": round(pct, 2),
                "best_compression_pct": round(snapshot.best_pct, 2),
                "best_detail": best_detail,
                "cache_markers_applied": snapshot.cache_markers_applied,
            },
        },
        "tokens": {
            "input": snapshot.tokens_before,
            "output": snapshot.output_tokens,
            "saved": snapshot.tokens_saved,
            "proxy_compression_saved": snapshot.tokens_saved,
            "savings_percent": round(pct, 2),
            "proxy_savings_percent": round(pct, 2),
            "cache_read": snapshot.cache_read_tokens,
            "cache_write": snapshot.cache_write_tokens,
        },
        "requests": {
            "failed": snapshot.failed_requests,
            "cached": int(cache_stats.get("hits", 0)),
        },
        "cache": {
            "entries": int(cache_stats.get("entries", 0)),
            "stable_hashes": int(cache_stats.get("stable_hashes", 0)),
            "hits": int(cache_stats.get("hits", 0)),
            "misses": int(cache_stats.get("misses", 0)),
        },
    }


async def _forward_request(
    request,
    *,
    upstream_base: str,
    body: bytes,
    stream: bool,
    on_stream_complete=None,
):
    """Forward to the Bedrock gateway.

    For streaming responses, ``on_stream_complete(output_tokens, status_code)``
    is invoked after the stream is fully consumed so the caller can record
    output-token stats (which are only known once the stream ends).
    """
    query = request.url.query
    url = f"{upstream_base.rstrip('/')}{request.url.path}"
    if query:
        url = f"{url}?{query}"

    headers = {
        k: v
        for (k, v) in request.headers.items()
        if k.lower() not in {"host", "content-length", "connection"}
    }
    if body:
        headers["content-length"] = str(len(body))

    client = request.app.state.bedrock_proxy_client
    req = client.build_request(request.method, url, headers=headers, content=body)

    if stream:
        upstream = await client.send(req, stream=True)
        status_code = upstream.status_code
        passthrough_headers = {
            k: v
            for (k, v) in upstream.headers.items()
            if k.lower() not in {"connection", "transfer-encoding", "content-length"}
        }
        scanner = _StreamUsageScanner()

        async def _iter_bytes():
            try:
                async for chunk in upstream.aiter_raw():
                    scanner.feed(chunk)
                    yield chunk
            finally:
                await upstream.aclose()
                if on_stream_complete is not None:
                    with suppress(Exception):
                        on_stream_complete(
                            scanner.output_tokens(),
                            scanner.cache_read_tokens(),
                            scanner.cache_write_tokens(),
                            status_code,
                        )

        return StreamingResponse(
            _iter_bytes(),
            status_code=status_code,
            headers=passthrough_headers,
            media_type=upstream.headers.get("content-type"),
        )

    upstream = await client.send(req)
    payload = await upstream.aread()
    passthrough_headers = {
        k: v
        for (k, v) in upstream.headers.items()
        if k.lower() not in {"connection", "transfer-encoding", "content-length"}
    }
    return Response(
        content=payload,
        status_code=upstream.status_code,
        headers=passthrough_headers,
        media_type=upstream.headers.get("content-type"),
    )


async def _handle_v1_messages(request):
    """Compress + forward an Anthropic ``POST /v1/messages`` on the Bedrock lane.

    Real Bedrock agent traffic uses this surface; left alone it would fall
    through to the proxy's default Anthropic upstream (api.anthropic.com). We
    compress the body off the event loop (threadpool) and forward it to the
    Bedrock gateway, which re-signs with SigV4.
    """
    body_bytes: bytes = b""
    body_json: dict[str, Any] | None = None
    before = 0
    after = 0
    marker_applied = False
    compressed = False
    failed = False

    try:
        body_json, body_bytes = await read_request_json_with_bytes(request)
    except Exception:
        body_bytes = await request.body()

    model_id = "unknown"
    stream = False
    if isinstance(body_json, dict):
        model_id = str(body_json.get("model") or "unknown")
        stream = bool(body_json.get("stream"))

    # Size guard: skip compression for oversized bodies (bounds worst-case
    # Kompress latency) and run the CPU-bound compress off the event loop.
    if body_json is not None and len(body_bytes) <= MAX_COMPRESS_BYTES:
        try:
            updated, before, after, marker_applied = await run_in_threadpool(
                lambda: _compress_anthropic_v1_body(body_json, model_id)
            )
            body_bytes = json.dumps(updated, ensure_ascii=False, separators=(",", ":")).encode(
                "utf-8"
            )
            compressed = before > 0 and after > 0 and after < before
        except Exception:  # noqa: BLE001
            pass  # compression is optional; forward original body

    try:
        # For streaming, output/cache tokens are only known once the stream is
        # fully consumed; defer the stats record into the stream-complete callback.
        def _on_stream_complete(
            out_tokens: int, cr_tokens: int, cw_tokens: int, status_code: int
        ) -> None:
            _record_stats(
                model_id=model_id,
                action="v1/messages",
                before=before,
                after=after,
                output_tokens=out_tokens,
                cache_read_tokens=cr_tokens,
                cache_write_tokens=cw_tokens,
                compressed=compressed,
                marker_applied=marker_applied,
                failed=failed or status_code >= 400,
            )

        response = await _forward_request(
            request,
            upstream_base=BEDROCK_UPSTREAM,
            body=body_bytes,
            stream=stream,
            on_stream_complete=_on_stream_complete if stream else None,
        )
        if stream:
            return response
        if response.status_code >= 400:
            failed = True
        out_tokens = 0
        cr_tokens = 0
        cw_tokens = 0
        if not failed and hasattr(response, "body"):
            try:
                out_tokens = _parse_output_tokens_from_response(response.body, "v1/messages")
                cr_tokens, cw_tokens = _parse_cache_tokens_from_response(response.body)
            except Exception:  # noqa: BLE001
                pass
        _record_stats(
            model_id=model_id,
            action="v1/messages",
            before=before,
            after=after,
            output_tokens=out_tokens,
            cache_read_tokens=cr_tokens,
            cache_write_tokens=cw_tokens,
            compressed=compressed,
            marker_applied=marker_applied,
            failed=failed,
        )
        return response
    except Exception:
        _record_stats(
            model_id=model_id,
            action="v1/messages",
            before=before,
            after=after,
            compressed=False,
            marker_applied=False,
            failed=True,
        )
        raise


def _prewarm() -> None:
    """Load the Kompress ONNX model now (in a background thread) so the first
    real request doesn't eat the ~30s cold model-load. Warm compression is ~40ms.
    """
    try:
        warm_msgs = [
            {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": "warm",
                        "content": "warmup log line repeated for compression model load\n" * 200,
                    }
                ],
            },
            {"role": "user", "content": [{"type": "text", "text": "ok"}]},
        ]
        _compress_messages(warm_msgs, "anthropic.claude-3-5-sonnet-20240620-v1:0")
    except Exception:  # noqa: BLE001
        pass


def apply_patch() -> None:
    try:
        import headroom.proxy.server as server  # ty: ignore[import-not-found]
    except Exception:
        return

    if getattr(server, "_bedrock_native_patch_applied", False):
        return

    threading.Thread(target=_prewarm, name="bedrock-shim-prewarm", daemon=True).start()

    original_create_app = server.create_app

    def patched_create_app(config: Any | None = None):
        app = original_create_app(config)

        if not hasattr(app.state, "bedrock_proxy_client"):
            app.state.bedrock_proxy_client = httpx.AsyncClient(timeout=600.0)

        @app.on_event("shutdown")
        async def _close_bedrock_proxy_client() -> None:
            client = getattr(app.state, "bedrock_proxy_client", None)
            if client is not None:
                await client.aclose()

        @app.middleware("http")
        async def _bedrock_native_proxy_middleware(request, call_next):
            if request.url.path in {"/bedrock-native/stats", "/healthz"}:
                if request.url.path == "/bedrock-native/stats":
                    return JSONResponse(status_code=200, content=_stats_payload())
                return JSONResponse(
                    status_code=200,
                    content={"ok": True, "service": "headroom-proxy"},
                )

            parsed = _extract_model_action(request.url.path)
            host_header = request.headers.get("host", "")
            bedrock_lane_host = _is_bedrock_lane_host(host_header)

            # Anthropic Messages API surface on the Bedrock lane. Real Kilo
            # Bedrock traffic uses POST /v1/messages; intercept it here so it is
            # compressed and forwarded to the Bedrock gateway instead of leaking
            # to the proxy's default Anthropic upstream (api.anthropic.com).
            if (
                bedrock_lane_host
                and request.method == "POST"
                and request.url.path == "/v1/messages"
            ):
                return await _handle_v1_messages(request)

            if parsed is None:
                # Visibility guarantee: log requests that reached the Bedrock lane
                # even when they do not use native /model/* paths (e.g. /v1 routes).
                if bedrock_lane_host and request.url.path not in {
                    "/stats",
                    "/stats-history",
                    "/dashboard",
                    "/metrics",
                    "/livez",
                    "/health",
                    "/healthz",
                }:
                    model_hint = "unknown"
                    action_hint = request.url.path.strip("/") or "unknown"
                    try:
                        body_json, _ = await read_request_json_with_bytes(request)
                        if isinstance(body_json, dict):
                            model_hint = str(body_json.get("model") or model_hint)
                    except Exception:  # noqa: BLE001
                        pass

                    response = await call_next(request)
                    _record_stats(
                        model_id=model_hint,
                        action=action_hint,
                        before=0,
                        after=0,
                        compressed=False,
                        marker_applied=False,
                        failed=response.status_code >= 400,
                    )
                    return response

                return await call_next(request)

            model_id, action = parsed
            body_bytes: bytes = b""
            body_json: dict[str, Any] | None = None
            before = 0
            after = 0
            marker_applied = False
            compressed = False
            failed = False

            try:
                body_json, body_bytes = await read_request_json_with_bytes(request)
            except Exception:
                body_bytes = await request.body()

            if (
                body_json is not None
                and _is_anthropic_model(model_id)
                and action in {"converse", "converse-stream"}
                and len(body_bytes) <= MAX_COMPRESS_BYTES
            ):
                try:
                    updated, before, after, marker_applied = await run_in_threadpool(
                        lambda: _compress_bedrock_body(
                            body_json,
                            model_id,
                            action=action,
                        )
                    )
                    body_bytes = json.dumps(
                        updated, ensure_ascii=False, separators=(",", ":")
                    ).encode("utf-8")
                    compressed = before > 0 and after > 0 and after < before
                except Exception:  # noqa: BLE001
                    pass  # compression is optional; forward original body

            is_stream = _is_streaming_action(action)
            try:
                # For streaming, output/cache tokens are only known once the
                # stream is fully consumed; defer into the callback.
                def _on_stream_complete(
                    out_tokens: int, cr_tokens: int, cw_tokens: int, status_code: int
                ) -> None:
                    _record_stats(
                        model_id=model_id,
                        action=action,
                        before=before,
                        after=after,
                        output_tokens=out_tokens,
                        cache_read_tokens=cr_tokens,
                        cache_write_tokens=cw_tokens,
                        compressed=compressed,
                        marker_applied=marker_applied,
                        failed=failed or status_code >= 400,
                    )

                response = await _forward_request(
                    request,
                    upstream_base=BEDROCK_UPSTREAM,
                    body=body_bytes,
                    stream=is_stream,
                    on_stream_complete=_on_stream_complete if is_stream else None,
                )
                if is_stream:
                    return response
                if response.status_code >= 400:
                    failed = True
                out_tokens = 0
                cr_tokens = 0
                cw_tokens = 0
                if not failed and hasattr(response, "body"):
                    try:
                        out_tokens = _parse_output_tokens_from_response(response.body, action)
                        cr_tokens, cw_tokens = _parse_cache_tokens_from_response(response.body)
                    except Exception:  # noqa: BLE001
                        pass
                _record_stats(
                    model_id=model_id,
                    action=action,
                    before=before,
                    after=after,
                    output_tokens=out_tokens,
                    cache_read_tokens=cr_tokens,
                    cache_write_tokens=cw_tokens,
                    compressed=compressed,
                    marker_applied=marker_applied,
                    failed=failed,
                )
                return response
            except Exception:
                _record_stats(
                    model_id=model_id,
                    action=action,
                    before=before,
                    after=after,
                    compressed=False,
                    marker_applied=False,
                    failed=True,
                )
                raise

        existing_paths = {getattr(route, "path", "") for route in app.router.routes}

        if "/bedrock-native/stats" not in existing_paths:

            @app.get("/bedrock-native/stats")
            async def bedrock_native_stats():
                return JSONResponse(status_code=200, content=_stats_payload())

        if "/healthz" not in existing_paths:

            @app.get("/healthz")
            async def bedrock_healthz():
                return JSONResponse(
                    status_code=200, content={"ok": True, "service": "headroom-proxy"}
                )

        return app

    server.create_app = patched_create_app
    server._bedrock_native_patch_applied = True
