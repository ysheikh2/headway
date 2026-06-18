# AGENTS - Headway Runbook

This file defines agent-specific operating rules for this repo.
Product/runtime usage details live in `README.md` and should not be duplicated here.

## Canonical Docs

- Read `README.md` first for architecture, commands, endpoints, and operational flows.
- If this file and README conflict, prefer this file for agent behavior and guardrails.

## Repo Intent

Headway is an integration/operations wrapper around upstream Headroom. This
branch refactors it to a **single native Rust `headroom-proxy`** as the one
front door for every lane:

- OpenAI-compatible / Copilot lane: `:4000/v1` -> proxy -> LiteLLM upstream.
- Bedrock lane: `:4002/model/{id}/invoke` -> proxy native SigV4 -> AWS.

The proxy compresses every lane, signs Bedrock natively, and serves a single
**unified `/stats` + `/dashboard`** across all backends (one process -> one
store), so there is no Python proxy, no `headroom-bedrock` sidecar, and no
runtime patches (`unified_stats_patch` / `bedrock_native_patch` are deleted).
LiteLLM stays only as the Copilot/OpenAI upstream + its auth.

Validate with `headway test` (which runs `scripts/cli/test-rust-stats.sh`; build
the headroom branch image first — see the comment header in that script).

The `headway` CLI is fully aligned to the single-proxy model: `headway stats`
reads the unified `/stats` directly, and `headway config regen` generates a
**Copilot-only** LiteLLM config (Bedrock is native in `headroom-proxy`, so there
is no Bedrock model discovery and no `bedrock-*` aliases).

## Non-Negotiable Rules

1. Do not build custom images from unrelated sources or fork behavior without clear need.
2. Keep runtime wiring in `docker-compose.yml` unless there is a strong reason not to.
3. Preserve the two-lane model:
   - OpenAI-compatible/Copilot lane via `http://127.0.0.1:4000/v1`
   - Bedrock-native lane via `http://127.0.0.1:4002`
4. Both lanes are served by the one `headroom-proxy` process; Bedrock is signed
   natively (SigV4) and never routed through LiteLLM.

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
- `docker-compose.yml` — single `headroom` (Rust proxy) service; `litellm` is an optional profile
- `litellm_config.yaml` — Copilot-only LiteLLM config (the Copilot/OpenAI upstream)
- `scripts/cli/headroom_python.py` — shared Python helpers for CLI commands
- `scripts/cli/generate-litellm-config.sh` — generates the Copilot-only LiteLLM config
- `scripts/cli/headway-completion.bash` — bash/zsh tab-completion script (sourced at init time)
- `scripts/cli/headway-unit-test.sh` — CLI unit tests (no live services required)
- `scripts/cli/test-rust-stats.sh` — single-proxy smoke test (`headway test`)

## Practical Maintenance Notes

- `headway config regen` regenerates the Copilot-only LiteLLM config (no Bedrock
  discovery — Bedrock is native in `headroom-proxy`).
- Keep edits minimal and targeted; avoid duplicating README runbook content here.
- `headway` reads only from `.env` — never inherit AWS env vars from the shell; `load_env` unsets all headway-managed vars before sourcing `.env`.
- `require_env` validates `AWS_PROFILE` and `AWS_REGION`. `BEDROCK_AWS_PROFILE` is not checked by `require_env` (it defaults to `AWS_PROFILE` in the shell and questionnaire), but `docker-compose.yml` does require it via `${BEDROCK_AWS_PROFILE:?}`; `.env.template` ensures it is always written during `headway init`.

## CI / Docker Build Triggers

The single `headroom` compose service runs from `HEADROOM_IMAGE`
(`ghcr.io/chopratejas/headroom:code`) with `entrypoint: ["headroom-proxy"]`. The
upstream `:code` image ships the native `headroom-proxy` binary, which fronts
every lane (Copilot/OpenAI via the optional LiteLLM upstream, Bedrock via native
SigV4) and serves the unified `/stats` + `/dashboard`. No headway-side Docker
build workflow is required, and there are no runtime patches.

The dashboard is embedded in the `headroom-proxy` binary and served at `/dashboard`;
headway no longer vendors or syncs a dashboard template, so the old
`sync-upstream-headroom` workflow and `scripts/runtime/headroom/` tree are gone.
GitHub Actions is permitted to create PRs in this repo
(`can_approve_pull_request_reviews: true` is set at the repo level).
