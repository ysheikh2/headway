# LiteLLM + Headroom Gateway (Kilo + OpenAI-Compatible Clients)

This repository runs a local three-container gateway so clients can use both providers through dedicated endpoints:

- GitHub Copilot (Headroom compression/memory + LiteLLM)
- AWS Bedrock (Headroom native Bedrock routes, direct to AWS)

Local endpoints:

- GitHub Copilot: `http://127.0.0.1:4000/v1`
- AWS Bedrock: `http://127.0.0.1:4002`

## Request Flow

```text
Kilo (Copilot)  -> Headroom :4000 -> LiteLLM :4001 -> GitHub Copilot
Kilo (Bedrock)  -> Headroom :4002 (native Bedrock routes) -> AWS Bedrock
```

## Single CLI

Use the repo-root CLI for all operations:

```bash
./headroom-proxy <command>
```

Primary commands:

- `init` - first-time setup (`.env`, AWS preflight, Kilo config, model config generation)
- `up` - start/reconcile stack and wait for health
- `down` - stop stack
- `auth` - refresh AWS sessions and restart services (no model-config regeneration)
- `doctor` - diagnostics (containers, health, models, Kilo config, AWS status)
- `test` - full end-to-end smoke tests (`scripts/test.sh`)
- `update` - pull/restart images
- `stats` - savings/cost/cache report
- `config regen` - regenerate `litellm_config.yaml` explicitly
- `config kilo` - enforce Kilo provider base URLs
- `reset` - remove stack and optional local state
- `secret-scan` - run local secret scan

## Quick Start

1. Ensure Docker Desktop is running.
2. Ensure AWS profiles are usable:

```bash
aws sts get-caller-identity --profile "$AWS_PROFILE"
aws sts get-caller-identity --profile "$BEDROCK_AWS_PROFILE"
```

3. Initialize once:

```bash
./headroom-proxy init
```

4. Start stack:

```bash
./headroom-proxy up
```

5. Validate end-to-end:

```bash
./headroom-proxy test
./headroom-proxy doctor
```

## Daily Usage

- Start: `./headroom-proxy up`
- Check health: `./headroom-proxy doctor`
- Run full tests: `./headroom-proxy test`
- Stop: `./headroom-proxy down`

## Auth Recovery

If Copilot returns 403 or Bedrock credentials expire:

```bash
./headroom-proxy auth
```

If Bedrock model aliases are stale or missing, regenerate explicitly:

```bash
./headroom-proxy config regen
./headroom-proxy up
```

## Kilo Configuration

`./headroom-proxy config kilo` writes:

- `github-copilot.options.baseURL = "http://127.0.0.1:4000/v1"`
- `openai-compatible.options.baseURL = "http://127.0.0.1:4000/v1"`
- `amazon-bedrock.options.baseURL = "http://127.0.0.1:4002"`

## Local Persistence

Runtime state is persisted under this repo (gitignored):

- `.data/headroom` - Copilot lane Headroom state
- `.data/headroom-bedrock` - Bedrock lane Headroom state
- `.data/litellm` - LiteLLM local token/provider cache

## Bedrock Image Strategy

- Copilot lane image: `ghcr.io/chopratejas/headroom:code`
- Bedrock lane image default: `ghcr.io/ysheikh2/headroom-proxy:bedrock-native`
- Override Bedrock lane image by setting `HEADROOM_BEDROCK_IMAGE` in `.env`

## Model Notes

- Bedrock aliases are generated into `litellm_config.yaml` by `./headroom-proxy config regen`.
- Copilot aliases are discovered dynamically with wildcard fallback.
- Do not rely on old Copilot model names remaining available.

## Uninstall / Cleanup

```bash
./headroom-proxy reset --yes
./headroom-proxy reset --yes --purge-data --prune-images --cleanup-kilo
```

## Security and Trust

Run a local secret scan before publishing:

```bash
./headroom-proxy secret-scan
```

Repository trust docs:

- [LICENSE](LICENSE)
- [SECURITY.md](SECURITY.md)
- [CONTRIBUTING.md](CONTRIBUTING.md)
