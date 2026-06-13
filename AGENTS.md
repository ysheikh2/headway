# AGENTS - Headroom + LiteLLM Gateway Runbook

This file is the single source of truth for maintaining this workspace.
If anything in other docs conflicts with this file, follow this file.

## Purpose

This repo runs a local gateway for Kilo so both providers work through one endpoint:

- GitHub Copilot (through Headroom proxy compression + LiteLLM)
- AWS Bedrock (through Headroom proxy with native Bedrock routes, direct to AWS)

Kilo endpoints:

- GitHub Copilot: `http://127.0.0.1:4000/v1`
- AWS Bedrock: `http://127.0.0.1:4002`

## Live Architecture

### Containers

1. `headroom-gateway`
- Image: `ghcr.io/chopratejas/headroom:code`
- Port: `127.0.0.1:4000` (container `:8787`)
- Upstream: LiteLLM (`http://litellm:4000/v1`)
- Auth: none directly (auth handled by upstream/provider)
- Role: frontend compression/memory proxy for GitHub Copilot traffic

2. `litellm-gateway`
- Image: `ghcr.io/berriai/litellm:main-stable`
- Port: `127.0.0.1:4001` (container `:4000`)
- Auth: AWS profile chain (`AWS_PROFILE` + mounted writable `~/.aws` for SSO cache refresh)
- Role: upstream provider router (Bedrock + GitHub Copilot)

3. `headroom-bedrock-gateway`
- Image: `${HEADROOM_BEDROCK_IMAGE:-ghcr.io/ysheikh2/headroom-proxy:bedrock-native}`
- Port: `127.0.0.1:4002` (container `:8787`)
- Upstream: AWS Bedrock Runtime (native Bedrock routes)
- Auth: AWS profile chain (`BEDROCK_AWS_PROFILE`, mounted `~/.aws`)
- Role: dedicated native Bedrock lane with `converse` + `converse-stream` support

### Routing

Request flow:

- Kilo (Copilot) -> Headroom `:4000` -> LiteLLM `:4001`
  - `copilot-*` named aliases -> GitHub Copilot (auto-discovered)
  - all other models (`*`) -> `github_copilot/*` (wildcard fallback)

- Kilo (Bedrock) -> Headroom `:4002` -> AWS Bedrock Runtime
  - native Bedrock routes (`/model/{id}/converse`, `/model/{id}/converse-stream`)
  - Headroom signs and forwards requests directly to AWS

Practical effect:

- Copilot requests: compressed by Headroom `:4000` -> routed via LiteLLM.
- Bedrock requests: compressed by Headroom `:4002` -> routed directly to AWS Bedrock.

## Key Architecture Rule

Default: do not build custom Docker images or modify the headroom source repo.

The Bedrock lane (`headroom-bedrock-gateway`) uses a Rust binary built from
`chopratejas/headroom` via `.github/workflows/docker-bedrock-native.yml` and
published to `ghcr.io/ysheikh2/headroom-proxy:bedrock-native`.

## Provider/Auth Behavior

### GitHub Copilot

- Do not rely on old model names (for example `gpt-4o` may not be available).
- Use currently available Copilot models.
- 403 errors usually mean token refresh is needed.
- LiteLLM GitHub Copilot provider requires device-flow login on first use. Tokens persist under `.data/litellm` on the host.

### AWS Bedrock

- Uses AWS credential chain, not generic API key auth.
- Primary mode here: AWS SSO profile from `BEDROCK_AWS_PROFILE` (used by `:4002` Bedrock lane).
- LiteLLM lane (`:4001`) uses profile from `AWS_PROFILE` for Bedrock model discovery/aliases.
- If SSO expires, Bedrock requests fail until re-login.

## Files That Matter

- `headroom-proxy` - single CLI for stack lifecycle, auth, config, diagnostics, reset
- `docker-compose.yml` - all runtime wiring
- `litellm_config.yaml` - auto-generated model aliases and route policy
- `scripts/generate-litellm-config.sh` - internal helper invoked by CLI for Bedrock model discovery + `litellm_config.yaml` generation
- `scripts/test.sh` - full end-to-end smoke tests (Copilot + Bedrock)
- `scripts/secret-scan.sh` - lightweight local secret scan before publish
- `scripts/headroom_python.py` - shared Python helper module (config generation, env/kilo helpers, unified stats)
- `~/.config/kilo/kilo.jsonc` - Kilo provider baseURL settings

## Required Kilo Config

`~/.config/kilo/kilo.jsonc` should point providers to:

- github-copilot baseURL: `http://127.0.0.1:4000/v1`
- openai-compatible baseURL: `http://127.0.0.1:4000/v1`
- amazon-bedrock baseURL: `http://127.0.0.1:4002`

## Standard Operations

### First-time setup

```bash
./headroom-proxy init
```

### Start stack

```bash
./headroom-proxy up
```

### Update images + restart

```bash
./headroom-proxy update
```

### Stop stack

```bash
./headroom-proxy down
```

### Fix auth (no config regeneration)

```bash
./headroom-proxy auth
```

### Diagnostics snapshot

```bash
./headroom-proxy doctor
```

### End-to-end verification

```bash
./headroom-proxy test
```

### Savings and cache report

```bash
./headroom-proxy stats
```

### Regenerate Bedrock model config explicitly

```bash
./headroom-proxy config regen
```

### Enforce Kilo base URLs

```bash
./headroom-proxy config kilo
```

### Secret scan before publish

```bash
./headroom-proxy secret-scan
```

### Uninstall and cleanup

```bash
./headroom-proxy reset --yes
./headroom-proxy reset --yes --purge-data --prune-images --cleanup-kilo
```

## Diagnostics

### Check containers

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

Expected healthy containers:

- `litellm-gateway`
- `headroom-gateway`
- `headroom-bedrock-gateway`

### Check LiteLLM models

```bash
curl -sS http://127.0.0.1:4000/v1/models
```

Should include:

- `bedrock-*` aliases
- `copilot-*` named aliases (if available)
- `*` wildcard fallback

### Check Bedrock native gateway

```bash
curl -sS http://127.0.0.1:4002/healthz
```

### Check AWS SSO profile

```bash
aws sts get-caller-identity --profile "$BEDROCK_AWS_PROFILE"
```

If expired:

```bash
aws sso login --profile "$BEDROCK_AWS_PROFILE"
```

## Known Failure Modes and Fixes

1. Copilot 403 unauthorized
- Cause: stale/revoked GitHub OAuth token
- Fix: `./headroom-proxy auth`

2. Bedrock invalid model identifier
- Cause: wrong/stale model or profile ID
- Fix:
  - `./headroom-proxy config regen`
  - `./headroom-proxy up`

3. Bedrock auth failure
- Cause: expired AWS SSO session (`BEDROCK_AWS_PROFILE`)
- Fix:
  - `aws sso login --profile "$BEDROCK_AWS_PROFILE"`
  - `./headroom-proxy auth`

4. LiteLLM healthy endpoint works but Docker health says unhealthy
- Cause: healthcheck mismatch
- Fix: keep compose healthchecks aligned with runtime

5. Copilot intermittent 502 from gateway
- Cause: transient upstream/proxy errors
- Fix: retry; if persistent, run `./headroom-proxy auth`

## Model Maintenance Workflow

1. List currently available Bedrock models:

```bash
aws bedrock list-foundation-models --profile "$AWS_PROFILE" --region eu-central-1
aws bedrock list-inference-profiles --profile "$AWS_PROFILE" --region eu-central-1
```

2. Regenerate `litellm_config.yaml`:

```bash
./headroom-proxy config regen
```

3. Restart stack:

```bash
./headroom-proxy up
```

4. Validate:

```bash
./headroom-proxy test
```

## Agent Rules for This Repo

1. Keep runtime behavior in `docker-compose.yml` unless there is a strong reason not to.
2. Prefer alias-based Bedrock model mapping in `litellm_config.yaml`.
3. Do not assume old model names remain valid.
4. After changing routing/auth/model config, always run `./headroom-proxy test`.
5. When debugging provider failures, test Copilot and Bedrock independently via gateway before changing Kilo config.
