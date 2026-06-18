#!/usr/bin/env python3
"""Shared Python helpers for the Headway CLI.

Subcommands:
- env-get <env_file> <key>
- env-set <env_file> <key> <value>
- kilo-setup <kilo_conf_path>
- kilo-cleanup <kilo_conf_path>
- kilo-check <kilo_conf_path>
- claude-setup <vscode_settings_path> <aws_profile> <aws_region>
- claude-cleanup <vscode_settings_path>
- claude-check <vscode_settings_path> <aws_profile> <aws_region>
- compose-image <service_name>  (reads compose JSON on stdin)
- models-summary                (reads /v1/models JSON on stdin)
- stats-report <raw_stats> [raw_history]
- generate-config <output_file> [copilot_token_file]
- build-bedrock-compression-payload <outfile>
- build-copilot-cache-payload <outfile> <model>
- build-copilot-compression-payload <outfile> <model>
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

# The single Rust proxy serves the unified /stats; the `headway stats` bash
# command fetches it directly and passes it to `stats-report`.


def _strip_jsonc_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"(^\s*)//.*$", "", text, flags=re.M)
    text = re.sub(r",(\s*[}\]])", r"\1", text)
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


def _upsert_env_var(items: list[dict[str, Any]], name: str, value: str) -> None:
    items[:] = [i for i in items if not (isinstance(i, dict) and i.get("name") == name)]
    items.append({"name": name, "value": value})


def cmd_claude_setup(vscode_settings: str, aws_profile: str, aws_region: str) -> int:
    path = Path(vscode_settings)
    path.parent.mkdir(parents=True, exist_ok=True)

    data: dict[str, Any]
    try:
        data = _load_jsonc(path)
    except Exception as exc:
        print(f"failed to parse VS Code settings JSONC: {exc}", file=sys.stderr)
        return 1

    env_vars = data.get("claudeCode.environmentVariables")
    if not isinstance(env_vars, list):
        env_vars = []
        data["claudeCode.environmentVariables"] = env_vars

    normalized: list[dict[str, Any]] = []
    for entry in env_vars:
        if isinstance(entry, dict):
            normalized.append(entry)
    env_vars = normalized
    data["claudeCode.environmentVariables"] = env_vars

    _upsert_env_var(env_vars, "CLAUDE_CODE_USE_BEDROCK", "1")
    _upsert_env_var(env_vars, "AWS_PROFILE", aws_profile)
    _upsert_env_var(env_vars, "AWS_REGION", aws_region)

    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print(path)
    return 0


def cmd_claude_cleanup(vscode_settings: str) -> int:
    path = Path(vscode_settings)
    if not path.exists():
        return 0

    text = path.read_text(encoding="utf-8").strip()
    if not text:
        return 0

    try:
        data = json.loads(_strip_jsonc_comments(text))
    except Exception:
        return 0
    if not isinstance(data, dict):
        return 0

    env_vars = data.get("claudeCode.environmentVariables")
    if not isinstance(env_vars, list):
        return 0

    remove_names = {
        "CLAUDE_CODE_USE_BEDROCK",
        "AWS_PROFILE",
        "AWS_REGION",
    }
    kept: list[dict[str, Any]] = []
    for entry in env_vars:
        if not isinstance(entry, dict):
            continue
        name = entry.get("name")
        if isinstance(name, str) and name in remove_names:
            continue
        kept.append(entry)

    data["claudeCode.environmentVariables"] = kept
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return 0


def cmd_claude_check(vscode_settings: str, aws_profile: str, aws_region: str) -> int:
    path = Path(vscode_settings)
    if not path.exists():
        return 1

    try:
        data = _load_jsonc(path)
    except Exception:
        return 1

    env_vars = data.get("claudeCode.environmentVariables")
    if not isinstance(env_vars, list):
        return 1

    expected = {
        "CLAUDE_CODE_USE_BEDROCK": "1",
        "AWS_PROFILE": aws_profile,
        "AWS_REGION": aws_region,
    }
    seen: dict[str, str] = {}
    for entry in env_vars:
        if not isinstance(entry, dict):
            continue
        name = entry.get("name")
        value = entry.get("value")
        if (
            isinstance(name, str)
            and isinstance(value, str)
            and name in expected
            and name not in seen
        ):
            seen[name] = value

    for key, val in expected.items():
        if seen.get(key) != val:
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


# ---- stats report ----


def _load_json_str(raw: str) -> dict[str, Any]:
    if not raw:
        return {}
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def cmd_stats_report(raw_stats: str, raw_history: str, _raw_combined: str = "") -> int:
    """Render the unified savings report from the single Rust proxy's `/stats`.

    The Rust proxy fronts every backend in one process, so `/stats` is already
    unified across providers/models — there is no per-lane merge to do here.
    """
    stats = _load_json_str(raw_stats)
    _ = _load_json_str(raw_history)  # reserved for future trend output

    requests = stats.get("requests", {}) or {}
    tokens = stats.get("tokens", {}) or {}
    cost = stats.get("cost", {}) or {}
    summary_cost = (stats.get("summary", {}) or {}).get("cost", {}) or {}
    persistent = stats.get("persistent_savings", {}) or {}
    lifetime = persistent.get("lifetime", {}) or {}
    session = persistent.get("display_session", {}) or {}

    def _i(d: dict[str, Any], k: str) -> int:
        v = d.get(k, 0)
        return int(v) if isinstance(v, (int, float)) else 0

    def _f(d: dict[str, Any], k: str) -> float:
        v = d.get(k, 0.0)
        return float(v) if isinstance(v, (int, float)) else 0.0

    def _usd(v: Any) -> str:
        return f"${float(v):.6f}" if isinstance(v, (int, float)) else "n/a"

    print("=== Headroom Savings Report (unified) ===")
    print(f"Requests: {_i(requests, 'total')} (failed: {_i(requests, 'failed')})")

    by_provider = requests.get("by_provider", {}) or {}
    if isinstance(by_provider, dict) and by_provider:
        parts = ", ".join(
            f"{k}={v}" for k, v in sorted(by_provider.items(), key=lambda kv: -int(kv[1]))
        )
        print(f"By backend: {parts}")

    print(
        f"Tokens: input={_i(tokens, 'input')}, output={_i(tokens, 'output')}, "
        f"saved={_i(tokens, 'saved')} ({_f(tokens, 'savings_percent'):.2f}%)"
    )
    total_usd = _f(summary_cost, "total_saved_usd") or _f(cost, "savings_usd")
    print(
        f"USD saved: {_usd(total_usd)} "
        f"(compression {_usd(_f(cost, 'compression_savings_usd'))}, "
        f"cache {_usd(_f(cost, 'cache_savings_usd'))})"
    )

    per_model = cost.get("per_model", {}) or {}
    if isinstance(per_model, dict) and per_model:
        print("Per-model:")
        ranked = sorted(
            (kv for kv in per_model.items() if isinstance(kv[1], dict)),
            key=lambda kv: -_i(kv[1], "tokens_saved"),
        )
        for model, m in ranked[:10]:
            print(
                f"  {model}: requests={_i(m, 'requests')}, saved={_i(m, 'tokens_saved')}, "
                f"compression={_usd(_f(m, 'compression_savings_usd'))}, "
                f"cache={_usd(_f(m, 'cache_savings_usd'))}"
            )

    print(
        f"Lifetime: requests={_i(lifetime, 'requests')}, "
        f"tokens_saved={_i(lifetime, 'tokens_saved')}, "
        f"compression={_usd(_f(lifetime, 'compression_savings_usd'))}"
    )
    print(
        f"Session:  requests={_i(session, 'requests')}, "
        f"tokens_saved={_i(session, 'tokens_saved')}, "
        f"savings={_f(session, 'savings_percent'):.2f}%"
    )
    hist_points = stats.get("history_points")
    if isinstance(hist_points, int):
        print(f"History points: {hist_points}")
    return 0


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


def cmd_generate_config(output_file: str, copilot_token_file: str) -> int:
    """Generate a Copilot-only LiteLLM config.

    Bedrock is served natively by the Rust `headroom-proxy` (SigV4 in-process), so
    LiteLLM only fronts the GitHub Copilot / OpenAI lane. The config therefore has
    just the auto-discovered named `copilot-*` entries plus the `*` wildcard.
    """
    copilot_models = _fetch_copilot_models(copilot_token_file)

    header = """# litellm_config.yaml
# AUTO-GENERATED by scripts/cli/generate-litellm-config.sh
#
# Architecture (Copilot/OpenAI lane only — Bedrock is native in headroom-proxy):
#   copilot-*   -> GitHub Copilot (named, auto-discovered)
#   *           -> github_copilot/* (wildcard fallback)
#
# Do not edit this file manually; regenerate with:
#   ./scripts/cli/generate-litellm-config.sh

model_list:
"""

    lines = [header]

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
    print(f"[generator] named copilot aliases: {len(copilot_models)}")
    return 0


# ---- test payload builders ----


def cmd_build_bedrock_compression_payload(outfile: str) -> int:
    """Build a Bedrock Converse-format compression probe payload and write it to outfile."""
    probe_run_id = int(time.time() * 1000)
    arr = [
        {
            "id": i % 25,
            "name": f"item{i % 25}",
            "status": "ok",
            "count": i,
            "payload": "x" * 80,
            "run": probe_run_id,
        }
        for i in range(2000)
    ]
    msgs = [
        {"role": "user", "content": [{"type": "text", "text": "Start the analysis."}]},
        {
            "role": "assistant",
            "content": [
                {
                    "toolUse": {
                        "toolUseId": "toolu_probe_42",
                        "name": "custom_fetch",
                        "input": {"q": "all"},
                    }
                }
            ],
        },
        {
            "role": "user",
            "content": [
                {
                    "toolResult": {
                        "toolUseId": "toolu_probe_42",
                        "content": [{"json": arr}],
                    }
                }
            ],
        },
        {"role": "assistant", "content": [{"type": "text", "text": "Data fetched. Reviewing."}]},
        {"role": "user", "content": [{"type": "text", "text": "Any errors?"}]},
        {"role": "assistant", "content": [{"type": "text", "text": "No errors found."}]},
        {"role": "user", "content": [{"type": "text", "text": "Check the totals."}]},
        {"role": "assistant", "content": [{"type": "text", "text": "Totals look correct."}]},
        {"role": "user", "content": [{"type": "text", "text": "What about the averages?"}]},
        {"role": "assistant", "content": [{"type": "text", "text": "Averages are within range."}]},
        {"role": "user", "content": [{"type": "text", "text": "Anything else to check?"}]},
        {"role": "assistant", "content": [{"type": "text", "text": "All checks passed."}]},
        {"role": "user", "content": [{"type": "text", "text": "Summarize in one short line."}]},
        {"role": "assistant", "content": [{"type": "text", "text": "Ready."}]},
    ]
    payload = {"messages": msgs, "inferenceConfig": {"maxTokens": 32}}
    with open(outfile, "w", encoding="utf-8") as f:
        f.write(json.dumps(payload, separators=(",", ":")))
    return 0


def cmd_build_copilot_cache_payload(outfile: str, model: str) -> int:
    """Build a stable OpenAI-format cache probe payload (same content each run for cache hits)."""
    arr = [
        {"id": i % 25, "name": f"item{i % 25}", "status": "ok", "count": i, "payload": "x" * 60}
        for i in range(500)
    ]
    big = json.dumps(arr)
    msgs = [
        {"role": "user", "content": "Analyze this dataset and remember it."},
        {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {
                    "id": "call_cache",
                    "type": "function",
                    "function": {"name": "fetch", "arguments": "{}"},
                }
            ],
        },
        {"role": "tool", "tool_call_id": "call_cache", "content": big},
        {"role": "assistant", "content": "Loaded."},
        {"role": "user", "content": "Ready?"},
        {"role": "assistant", "content": "Yes."},
    ]
    payload = {"model": model, "messages": msgs, "max_tokens": 8, "stream": False}
    with open(outfile, "w", encoding="utf-8") as f:
        f.write(json.dumps(payload, separators=(",", ":")))
    return 0


def cmd_build_copilot_compression_payload(outfile: str, model: str) -> int:
    """Build a unique-per-run OpenAI-format compression probe payload."""
    run_id = int(time.time() * 1000)
    arr = [
        {
            "id": i % 25,
            "name": f"item{i % 25}",
            "status": "ok",
            "count": i,
            "payload": "x" * 80,
            "run": run_id,
        }
        for i in range(1200)
    ]
    big = json.dumps(arr)
    msgs = [
        {"role": "user", "content": "Start the analysis."},
        {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {
                    "id": "call_probe_42",
                    "type": "function",
                    "function": {"name": "custom_fetch", "arguments": '{"q":"all"}'},
                }
            ],
        },
        {"role": "tool", "tool_call_id": "call_probe_42", "content": big},
        {"role": "assistant", "content": "Data fetched. Reviewing."},
        {"role": "user", "content": "Any errors?"},
        {"role": "assistant", "content": "No errors found."},
        {"role": "user", "content": "Check the totals."},
        {"role": "assistant", "content": "Totals look correct."},
        {"role": "user", "content": "What about the averages?"},
        {"role": "assistant", "content": "Averages are within range."},
        {"role": "user", "content": "Anything else to check?"},
        {"role": "assistant", "content": "All checks passed."},
        {"role": "user", "content": "Summarize in one short line."},
        {"role": "assistant", "content": "Ready."},
    ]
    payload = {"model": model, "messages": msgs, "max_tokens": 16, "stream": False}
    with open(outfile, "w", encoding="utf-8") as f:
        f.write(json.dumps(payload, separators=(",", ":")))
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
    if sub == "claude-setup" and len(args) == 3:
        return cmd_claude_setup(args[0], args[1], args[2])
    if sub == "claude-cleanup" and len(args) == 1:
        return cmd_claude_cleanup(args[0])
    if sub == "claude-check" and len(args) == 3:
        return cmd_claude_check(args[0], args[1], args[2])

    if sub == "compose-image" and len(args) == 1:
        return cmd_compose_image(args[0])
    if sub == "models-summary" and len(args) == 0:
        return cmd_models_summary()

    if sub == "stats-report" and len(args) in (2, 3):
        return cmd_stats_report(args[0], args[1], args[2] if len(args) == 3 else "")

    if sub == "generate-config" and len(args) in (1, 2):
        token_file = args[1] if len(args) == 2 else ""
        return cmd_generate_config(args[0], token_file)

    if sub == "build-bedrock-compression-payload" and len(args) == 1:
        return cmd_build_bedrock_compression_payload(args[0])
    if sub == "build-copilot-cache-payload" and len(args) == 2:
        return cmd_build_copilot_cache_payload(args[0], args[1])
    if sub == "build-copilot-compression-payload" and len(args) == 2:
        return cmd_build_copilot_compression_payload(args[0], args[1])

    print(f"invalid arguments for subcommand: {sub}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
