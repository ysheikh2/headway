# AGENTS - Headway Runbook

This file defines agent-specific operating rules for this repo.
Product/runtime usage details live in `README.md` and should not be duplicated here.

## Canonical Docs

- Read `README.md` first for architecture, commands, endpoints, and operational flows.
- If this file and README conflict, prefer this file for agent behavior and guardrails.

## Repo Intent

Headway is an integration/operations wrapper around upstream Headroom + LiteLLM,
with a dedicated native Bedrock lane.

## Non-Negotiable Rules

1. Do not build custom images from unrelated sources or fork behavior without clear need.
2. Keep runtime wiring in `docker-compose.yml` unless there is a strong reason not to.
3. Preserve the two-lane model:
   - OpenAI-compatible/Copilot lane via `http://127.0.0.1:4000/v1`
   - Bedrock-native lane via `http://127.0.0.1:4002`
4. Do not assume stale model names remain valid; prefer discovery/regen flows.

## Code Organization Preferences (Important)

1. Keep shared CLI Python logic centralized in `scripts/cli/headroom_python.py`.
2. Avoid spreading common helper logic across multiple Python files when a shared helper can own it.
3. Prefer thin shell wrappers that delegate common behavior to shared helpers.
4. Keep naming and behavior consistent with Headway branding (`headway` as canonical entrypoint).

## Required Validation After Routing/Auth/Model Changes

Run:

```bash
./headway test
```

When debugging provider failures, test Copilot/OpenAI-compatible and Bedrock-native paths independently before changing client configs.

## Files Agents Commonly Touch

- `headway`
- `docker-compose.yml`
- `litellm_config.yaml`
- `scripts/cli/headroom_python.py`
- `scripts/cli/generate-litellm-config.sh`
- `scripts/cli/test.sh`

## Practical Maintenance Notes

- Keep Bedrock alias mapping flow driven by `./headway config regen`.
- Keep edits minimal and targeted; avoid duplicating README runbook content here.
