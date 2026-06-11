# AGENTS - Headroom + LiteLLM Gateway Runbook

This file is the single source of truth for maintaining this workspace.
If anything in other docs conflicts with this file, follow this file.

## Purpose

This repo runs a local gateway for Kilo so both providers work through one endpoint:

- GitHub Copilot (through Headroom proxy compression)
- AWS Bedrock (through LiteLLM Bedrock provider)

Kilo endpoint used by both providers:

- http://127.0.0.1:4000/v1

## Live Architecture

### Containers

1. `headroom-gateway`
- Image: `ghcr.io/chopratejas/headroom:code`
- Port: `127.0.0.1:4000` (container `:8787`)
- Upstream: LiteLLM (`http://litellm:4000/v1`)
- Auth: none directly (auth handled by upstream/provider)
- Role: frontend compression/memory proxy for all traffic

2. `litellm-gateway`
- Image: `ghcr.io/berriai/litellm:main-stable`
- Port: `127.0.0.1:4001` (container `:4000`)
- Auth: AWS profile chain (`AWS_PROFILE` + mounted writable `~/.aws` for SSO cache refresh)
- Role: upstream provider router (Bedrock + GitHub Copilot)

### Routing

Request flow:

- Kilo -> Headroom (`:4000`) -> LiteLLM (`:4001` host / `:4000` container)
  - `bedrock-*` aliases -> AWS Bedrock
  - `copilot-*` named aliases -> GitHub Copilot (auto-discovered from your account)
  - all other models (`*`) -> `github_copilot/*` (wildcard fallback)

Important semantics:

- Headroom has a single upstream connection (LiteLLM).
- LiteLLM handles both provider routes.
- Named `copilot-*` entries are generated dynamically by `generate-litellm-config.sh` from the live Copilot models API (chat-only, enabled, picker-visible). The wildcard catches anything not explicitly listed.

Practical effect:

- Copilot requests are compressed by Headroom proxy.
- Bedrock requests are handled natively by LiteLLM Bedrock.

## Why Bedrock Uses Converse Paths

The user-supplied hint from Kilo source was correct in spirit:

- Bedrock Converse APIs use modelId in the path (for example `.../model/{modelId}/converse-stream`).
- Therefore Bedrock model IDs and inference-profile IDs must be exact and valid.
- Wrong ID format gives errors like "provided model identifier is invalid".

In this repo we avoid raw IDs in Kilo by using LiteLLM aliases in `litellm_config.yaml`.

## Provider/Auth Behavior

### GitHub Copilot

- Do not rely on old model names (for example `gpt-4o` may not be available).
- Use currently available Copilot models; tests should prefer low-cost models (for example `claude-haiku-4.5`) with fallback.
- 403 errors usually mean token refresh is needed.
- LiteLLM GitHub Copilot provider requires device-flow login on first use. Tokens persist under `.data/litellm` on the host (mounted to `/root/.config/litellm` in the container).

### AWS Bedrock

- Uses AWS credential chain, not generic API key auth.
- Primary mode here: AWS SSO profile `d2i_stg`.
- If SSO expires, Bedrock requests fail until re-login.

## Files That Matter

- `docker-compose.yml` - all runtime wiring
- `litellm_config.yaml` - auto-generated model aliases and route policy
- `scripts/generate-litellm-config.sh` - discovers Bedrock models in EU regions and writes `litellm_config.yaml` (one alias per model, ACTIVE-only)
- `scripts/start.sh` - refresh auth, pull images, start stack
- `scripts/stop.sh` - stop the running stack (preserves volumes and tokens)
- `scripts/auth-fix.sh` - refresh AWS auth and restart (prints Copilot device-code hints if pending)
- `scripts/setup-kilo.sh` - enforce Kilo provider baseURLs for this gateway
- `scripts/oneshot.sh` - one-command bootstrap for new users (setup, start, test, status)
- `scripts/secret-scan.sh` - lightweight local secret scan before publish
- `scripts/uninstall.sh` - stop/remove stack with optional deep cleanup
- `scripts/status.sh` - health, models, config, AWS status, headroom stats
- `scripts/test.sh` - end-to-end smoke tests (Copilot + Bedrock)
- `scripts/stats.sh` - concise savings/cost/cache/latency report
- `~/.config/kilo/kilo.jsonc` - Kilo provider baseURL settings

## Required Kilo Config

`~/.config/kilo/kilo.jsonc` should point both providers to `:4000`:

- github-copilot baseURL: `http://127.0.0.1:4000/v1`
- openai-compatible baseURL: `http://127.0.0.1:4000/v1`

## Standard Operations

### Start everything

```bash
./scripts/start.sh
```

### Stop the stack

```bash
./scripts/stop.sh
```

### Fix auth issues (Copilot 403, Bedrock auth failure)

```bash
./scripts/auth-fix.sh
```

### Status snapshot

```bash
./scripts/status.sh
```

### End-to-end verification

```bash
./scripts/test.sh
```

### One-shot bootstrap for new users

```bash
./scripts/oneshot.sh
```

### Savings and cache report

```bash
./scripts/stats.sh
```

### Secret scan before publish

```bash
./scripts/secret-scan.sh
```

### Uninstall and cleanup

```bash
./scripts/uninstall.sh
./scripts/uninstall.sh --yes --purge-data --cleanup-kilo
```

## Diagnostics

### Check containers

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

Expected healthy containers:

- `litellm-gateway`
- `headroom-gateway`

### Check LiteLLM models

```bash
curl -sS http://127.0.0.1:4000/v1/models
```

Should include:

- `bedrock-*` aliases (for example `bedrock-claude-sonnet-4`)
- `copilot-*` named aliases (auto-discovered from your Copilot account)
- `*` wildcard fallback for any other Copilot model

### Check Headroom health/stats

```bash
curl -sS http://127.0.0.1:4000/livez
curl -sS http://127.0.0.1:4000/stats
```

`summary.api_requests` should increment when Copilot calls are routed through gateway.

### Check AWS SSO profile

```bash
aws sts get-caller-identity --profile d2i_stg
```

If expired:

```bash
aws sso login --profile d2i_stg
```

## Known Failure Modes and Fixes

1. Copilot 403 unauthorized
- Cause: stale/revoked GitHub OAuth token
- Fix: `./scripts/auth-fix.sh`

2. Bedrock invalid model identifier
- Cause: wrong/stale model/inference profile ID
- Fix: regenerate config from AWS and restart:
  - `./scripts/generate-litellm-config.sh --aws-profile d2i_stg`
  - `docker compose up -d`

3. Bedrock auth failure
- Cause: expired AWS SSO session
- Fix:
  - `aws sso login --profile d2i_stg`
  - `./scripts/auth-fix.sh`

4. LiteLLM healthy endpoint works but Docker health says unhealthy
- Cause: bad healthcheck command for image runtime
- Fix: keep compose healthcheck using Python (not curl dependency)

5. Copilot intermittent 502 from gateway
- Cause: transient upstream/proxy errors
- Fix: retry logic in `scripts/test.sh`; for runtime, re-run `./scripts/auth-fix.sh` if persistent

## Model Maintenance Workflow

When models change (common for Copilot and Bedrock):

1. List currently available Bedrock models:

```bash
aws bedrock list-foundation-models --profile d2i_stg --region eu-central-1
aws bedrock list-inference-profiles --profile d2i_stg --region eu-central-1
```

2. Regenerate `litellm_config.yaml`:

```bash
./scripts/generate-litellm-config.sh --aws-profile d2i_stg
```

3. Restart stack:

```bash
docker compose up -d
```

4. Validate:

```bash
./scripts/test.sh
```

## External References Used for This Setup

These informed this runbook and should be preferred references:

- LiteLLM Bedrock provider docs
- LiteLLM GitHub Copilot provider docs
- LiteLLM GitHub Copilot integration tutorial
- Bedrock setup notes from mrkaran.dev

## Agent Rules for This Repo

1. Keep runtime behavior in `docker-compose.yml` unless there is a strong reason not to.
2. Prefer alias-based Bedrock model mapping in `litellm_config.yaml`.
3. Do not assume old model names remain valid.
4. After changing routing/auth/model config, always run `./scripts/test.sh`.
5. When debugging provider failures, test Copilot and Bedrock independently via gateway before changing Kilo config.
