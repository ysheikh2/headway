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
4. Keep naming and behavior consistent with Headway branding (`headway` as canonical entrypoint — not `./headway`).

## Required Validation After Routing/Auth/Model Changes

Run:

```bash
headway test
```

When debugging provider failures, test Copilot/OpenAI-compatible and Bedrock-native paths independently before changing client configs.

## Files Agents Commonly Touch

- `headway` — main CLI script
- `install.sh` — one-line installer (clones repo, symlinks `headway`, sets up shell completion)
- `docker-compose.yml`
- `litellm_config.yaml`
- `scripts/cli/headroom_python.py` — shared Python helpers for CLI commands
- `scripts/cli/generate-litellm-config.sh` — Bedrock model discovery and config generation
- `scripts/cli/headway-completion.bash` — bash/zsh tab-completion script (sourced at init time)
- `scripts/cli/headway-unit-test.sh` — CLI unit tests (no live services required)
- `scripts/cli/test.sh` — full end-to-end smoke tests
- `scripts/runtime/headroom/headroom_patch/unified_stats_patch.py` — unified stats merge (Copilot + Bedrock native)
- `scripts/runtime/headroom/dashboard.html` — web dashboard (served as read-only bind mount, no restart needed)

## Practical Maintenance Notes

- Keep Bedrock alias mapping flow driven by `headway config regen`.
- Keep edits minimal and targeted; avoid duplicating README runbook content here.
- `headway` reads only from `.env` — never inherit AWS env vars from the shell; `load_env` unsets all headway-managed vars before sourcing `.env`.
- `require_env` validates `AWS_PROFILE`, `AWS_REGION`, and `BEDROCK_AWS_PROFILE` — all three are required by `docker-compose.yml`.

## CI / Docker Build Triggers

The `docker-bedrock-native` workflow builds and pushes the Bedrock Rust image. It fires on push to `main` when any of these paths change:

- `Dockerfile.bedrock-native`
- `.github/workflows/docker-bedrock-native.yml`
- `scripts/build/**` — upstream patch scripts copied into the image at build time

If you change anything under `scripts/build/`, the image rebuild is automatic. If you need to rebuild without touching those files (e.g. to pick up a new upstream headroom commit), trigger the workflow manually via GitHub Actions → Docker Bedrock Native → Run workflow.

The `sync-upstream-patch-compat` workflow runs daily and auto-creates a PR when the upstream patch compatibility record changes. GitHub Actions is permitted to create PRs in this repo (`can_approve_pull_request_reviews: true` is set at the repo level).
