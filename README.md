# LiteLLM + Headroom Gateway for Kilo

This repository runs a local two-container gateway so Kilo can use both providers through one endpoint:

- GitHub Copilot (via Headroom proxy compression)
- AWS Bedrock (via LiteLLM with AWS profile auth)

Kilo points to one base URL:

- http://127.0.0.1:4000/v1

## Request Flow

Both providers are handled by LiteLLM, with Headroom as the single frontend:

Kilo -> Headroom (:4000) -> LiteLLM (:4001 backend)
- bedrock-* models -> AWS Bedrock
- all non-bedrock models (`*`) -> LiteLLM GitHub Copilot provider (`github_copilot/*`)

Why this topology:

- Headroom has one upstream connection (LiteLLM).
- LiteLLM remains the provider router for both Bedrock and GitHub Copilot.
- Headroom compression/memory still applies to all traffic entering through Headroom.

## Why this setup

- One endpoint in Kilo for both providers
- Copilot traffic still goes through Headroom compression
- Bedrock works with normal AWS SSO/profile auth
- No custom local Python/pipx/npm install required

## Local Persistence

Runtime state is persisted under this repo (gitignored):

- `.data/headroom` — Headroom memory/compression state
- `.data/litellm` — LiteLLM local provider/token cache state

## Quick Start

1. Ensure Docker Desktop is running.
2. Ensure AWS profile is valid (default profile used by scripts is d2i_stg):

```bash
aws sts get-caller-identity --profile d2i_stg
```

3. Configure Kilo providers to use this gateway:

```bash
./scripts/setup-kilo.sh
```

4. Start everything:

```bash
./scripts/start.sh
```

5. Validate:

```bash
./scripts/test.sh
./scripts/status.sh
```

## One-Shot Bootstrap (New Users)

Run everything end-to-end in order (configure Kilo, start gateway, run tests, print status):

```bash
./scripts/oneshot.sh
```

## Security and Trust

Run lightweight local secret scanning before publishing or opening a PR:

```bash
./scripts/secret-scan.sh
```

Repository trust docs:

- [LICENSE](LICENSE)
- [SECURITY.md](SECURITY.md)
- [CONTRIBUTING.md](CONTRIBUTING.md)

## Kilo Config

File:

- ~/.config/kilo/kilo.jsonc

Set it automatically:

```bash
./scripts/setup-kilo.sh
```

Provider routing should point to port 4000:

```json
{
  "provider": {
    "github-copilot": {
      "options": {
        "baseURL": "http://127.0.0.1:4000/v1"
      }
    },
    "openai-compatible": {
      "options": {
        "baseURL": "http://127.0.0.1:4000/v1",
        "apiKey": "local"
      }
    }
  }
}
```

## Model Notes

- Do not rely on older aliases like gpt-4o if your Copilot account no longer exposes them.
- Tests prefer low-cost models automatically (for example `claude-haiku-4.5`, then other low-cost fallbacks).
- Bedrock aliases are auto-generated into litellm_config.yaml from AWS Bedrock discovery across EU regions.
- Copilot uses a wildcard route in LiteLLM (`model_name: "*"` -> `github_copilot/*`) so model availability can change without regenerating copilot entries.
- Generator keeps one alias per model (best EU region preference), not one per region.
- Generator keeps ACTIVE models only and skips LEGACY/deprecated entries.
- Generator prefers ACTIVE inference profiles (account-scoped), then fills remaining ACTIVE ON_DEMAND foundation models.
- scripts/start.sh and scripts/auth-fix.sh regenerate litellm_config.yaml automatically.

Manual regeneration (optional):

```bash
./scripts/generate-litellm-config.sh --aws-profile d2i_stg
```

List Bedrock models available to your profile:

```bash
aws bedrock list-foundation-models --profile d2i_stg --region eu-central-1
aws bedrock list-inference-profiles --profile d2i_stg --region eu-central-1
```

## Copilot Auth In LiteLLM

LiteLLM GitHub Copilot provider uses GitHub device flow and stores tokens in `.data/litellm`.

If LiteLLM logs show:

- `Please visit https://github.com/login/device and enter code ...`

complete that login once. After success, tokens persist in `.data/litellm` and restarts should not require re-auth unless tokens expire.

## Scripts

- scripts/start.sh: refresh creds, pull images, start stack
- scripts/auth-fix.sh: refresh AWS auth, restart stack, and print Copilot device code hints if needed
- scripts/setup-kilo.sh: enforce Kilo provider baseURLs for this gateway
- scripts/oneshot.sh: one-command bootstrap for new users (setup, start, test, status)
- scripts/secret-scan.sh: lightweight secrets scan before publishing
- scripts/generate-litellm-config.sh: auto-discover Bedrock models in EU regions and write litellm_config.yaml
- scripts/status.sh: container health, models, config checks, AWS status, Headroom stats
- scripts/test.sh: end-to-end smoke tests for Copilot and Bedrock (cheap model preference)
- scripts/stats.sh: concise savings/cost/cache/latency report from Headroom

## Troubleshooting

- 403 from Copilot:

```bash
./scripts/auth-fix.sh
```

- Bedrock auth failures:

```bash
aws sso login --profile d2i_stg
./scripts/auth-fix.sh
```

- Gateway not reachable:

```bash
docker compose down
docker compose up -d
docker logs litellm-gateway --tail 100
docker logs headroom-kilo --tail 100
```

## Compose Services

- headroom-kilo: ghcr.io/chopratejas/headroom:code on 127.0.0.1:4000
- litellm-gateway: ghcr.io/berriai/litellm:main-stable on 127.0.0.1:4001

Both are managed from docker-compose.yml.
