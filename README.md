# LiteLLM + Headroom Gateway (Kilo + Any OpenAI-Compatible Client)

This repository runs a local three-container gateway so clients can use both providers through dedicated endpoints:

- GitHub Copilot (via Headroom proxy compression + LiteLLM)
- AWS Bedrock (via Headroom proxy with native Bedrock routes, direct to AWS)

Primary usage in this repo is Kilo, but any client/extension that supports an OpenAI-compatible `baseURL` can use the same endpoint.

Local endpoints:

- GitHub Copilot: `http://127.0.0.1:4000/v1`
- AWS Bedrock: `http://127.0.0.1:4002`

Learn more about [Headroom](https://github.com/chopratejas/headroom) and [LiteLLM](https://github.com/BerriAI/litellm) at their Github repos.

## Request Flow

```
Kilo (Copilot)  -> Headroom :4000 -> LiteLLM :4001 -> GitHub Copilot
Kilo (Bedrock)  -> Headroom :4002 (native Bedrock routes) -> AWS Bedrock
```

Copilot lane:
- `copilot-*` named aliases → GitHub Copilot (auto-discovered)
- all other models (`*`) → `github_copilot/*` (wildcard fallback)

Bedrock lane:
- native Bedrock routes (`/model/{id}/converse`, `/model/{id}/converse-stream`)
- Headroom signs and forwards requests directly to AWS using `d2i_prod` SSO profile

## Why this setup

- Separate dedicated endpoints for Copilot and Bedrock
- Copilot traffic goes through Headroom compression/memory
- Bedrock traffic uses native Converse routes required by Kilo's `amazon-bedrock` provider
- Bedrock auth uses AWS SSO profile chain (`d2i_prod`) — no API keys needed
- No custom local Python/pipx/npm install required

## Local Persistence

Runtime state is persisted under this repo (gitignored):

- `.data/headroom` — Headroom memory/compression state (Copilot lane)
- `.data/headroom-bedrock` — Headroom state (Bedrock lane)
- `.data/litellm` — LiteLLM local provider/token cache state

## Quick Start

1. Ensure Docker Desktop is running.
2. Ensure AWS profiles are valid:

```bash
aws sts get-caller-identity --profile d2i_stg   # LiteLLM model discovery
aws sts get-caller-identity --profile d2i_prod  # Bedrock native lane
```

3. Build the Bedrock-native Headroom image (required until upstream PR #917 is released):

```bash
# From the headroom source repo at commit c9e4822e:
docker buildx build -f Dockerfile.bedrock-native -t headroom-local:bedrock-c9e4822e .
```

4. Configure Kilo providers to use this gateway:

```bash
./scripts/setup-kilo.sh
```

5. Start everything:

```bash
./scripts/start.sh
```

6. Validate:

```bash
./scripts/test.sh
./scripts/status.sh
```

## One-Shot Bootstrap (New Users)

Run everything end-to-end in order (configure Kilo, start gateway, run tests, print status):

```bash
./scripts/oneshot.sh
```

## Stop the Stack

Stop containers without removing data or tokens:

```bash
./scripts/stop.sh
```

## Uninstall and Cleanup

Stop and remove the stack:

```bash
./scripts/uninstall.sh
```

Full cleanup (including runtime data and local Kilo gateway baseURL cleanup):

```bash
./scripts/uninstall.sh --yes --purge-data --cleanup-kilo
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

CI runs on pull requests and `main` pushes, covering shell syntax/formatting, Python formatting/lint/type checks, YAML validation, compose rendering, and secret scanning. For same-repo pull requests, formatting is auto-fixed and committed by CI before validation runs.

## Kilo Config

File:

- ~/.config/kilo/kilo.jsonc

Set it automatically:

```bash
./scripts/setup-kilo.sh
```

Provider routing:

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
    },
    "amazon-bedrock": {
      "options": {
        "baseURL": "http://127.0.0.1:4002"
      }
    }
  }
}
```

## VS Code Chat Integration

Use these settings for chat tools that support OpenAI-compatible custom endpoints:

1. Add a custom model/provider using `OpenAI` (or `OpenAI-compatible`) in the tool UI.
2. Set base URL to `http://127.0.0.1:4000/v1`.
3. Set API key to `local` (or any non-empty placeholder expected by the UI).
4. Use model names exposed by this gateway:
  - Copilot route: `claude-haiku-4.5`, `gemini-3.5-flash`, etc.
  - Bedrock route via Kilo: configure `amazon-bedrock` provider with `baseURL: http://127.0.0.1:4002`.

Important: Native GitHub Copilot Chat in VS Code does not provide a standard custom `baseURL` override for replacing GitHub backend calls. For gateway usage in VS Code, prefer chat tools/providers that support OpenAI-compatible endpoint configuration.

## Other Clients

Any client that supports an OpenAI-compatible API endpoint can use the Copilot lane by setting:

- base URL: `http://127.0.0.1:4000/v1`
- API key: `local` (or any non-empty placeholder if the client requires one)

For Bedrock, configure the client's `amazon-bedrock` (or equivalent) provider to use `http://127.0.0.1:4002`.

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
- scripts/update.sh: pull latest images and restart in-place
- scripts/stop.sh: stop the running stack (preserves volumes and tokens)
- scripts/auth-fix.sh: refresh AWS auth, restart stack, and print Copilot device code hints if needed
- scripts/setup-kilo.sh: enforce Kilo provider baseURLs for this gateway
- scripts/oneshot.sh: one-command bootstrap for new users (setup, start, test, status)
- scripts/secret-scan.sh: lightweight secrets scan before publishing
- scripts/uninstall.sh: remove stack with optional deep cleanup flags
- scripts/generate-litellm-config.sh: auto-discover Bedrock models in EU regions and write litellm_config.yaml
- scripts/status.sh: container health, models, config checks, AWS status, Headroom stats
- scripts/test.sh: end-to-end smoke tests for Copilot and Bedrock (cheap model preference)
- scripts/stats.sh: concise savings/cost/cache/latency report from Headroom

## Troubleshooting

- 403 from Copilot:

```bash
./scripts/auth-fix.sh
```

- Bedrock native lane auth failures (`d2i_prod`):

```bash
aws sso login --profile d2i_prod
./scripts/auth-fix.sh
```

- Bedrock model discovery failures (`d2i_stg`):

```bash
aws sso login --profile d2i_stg
./scripts/auth-fix.sh
```

- Gateway not reachable:

```bash
docker compose down
docker compose up -d
docker logs litellm-gateway --tail 100
docker logs headroom-gateway --tail 100
docker logs headroom-bedrock-gateway --tail 100
```

## Compose Services

- headroom-gateway: `ghcr.io/chopratejas/headroom:code` on `127.0.0.1:4000` (Copilot lane)
- litellm-gateway: `ghcr.io/berriai/litellm:main-stable` on `127.0.0.1:4001`
- headroom-bedrock-gateway: `headroom-local:bedrock-c9e4822e` on `127.0.0.1:4002` (Bedrock lane)

All are managed from docker-compose.yml.
