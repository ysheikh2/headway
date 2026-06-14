# Headway

Headway is a local AI gateway stack that makes GitHub Copilot and AWS Bedrock work through stable local endpoints while preserving provider-native behavior.

Headway combines:

- Headroom for request/response compression, savings telemetry, and runtime proxying
- LiteLLM for provider/model routing in the OpenAI-compatible lane
- A native Bedrock route lane for `converse` and `converse-stream`

This repository is an operations wrapper around upstream projects. It is not a fork or replacement of upstream Headroom or LiteLLM.

## Why Headway Is Useful

- Keep provider wiring stable locally while upstream model catalogs change often
- Use one local gateway for multiple AI coding clients and extensions
- Get native Bedrock support (`:4002`) alongside OpenAI-compatible routing (`:4000/v1`)
- Improve token efficiency and monitor savings with unified stats and diagnostics
- Recover auth/config drift quickly with one CLI (`auth`, `doctor`, `test`)

## Core Design Goal

Headway is built so extensions/tools can be pointed to endpoints that behave like the actual providers with minimal friction.

- Copilot/OpenAI-compatible traffic goes to `http://127.0.0.1:4000/v1`
- Bedrock-native traffic goes to `http://127.0.0.1:4002`
- Clients keep their normal provider modes while Headway handles local orchestration, routing, and auth lifecycle

## Lanes and Endpoints

- GitHub Copilot + OpenAI-compatible lane: `http://127.0.0.1:4000/v1`
- Native Bedrock lane: `http://127.0.0.1:4002`

Request flow:

```text
Client/Extension (Copilot/OpenAI-compatible) -> Headroom :4000 -> LiteLLM :4001 -> Provider
Client/Extension (Bedrock native)            -> Headroom :4002 (Python patch: compress+cache) -> headroom-bedrock (Rust SigV4) -> AWS Bedrock
```

## Client and Extension Compatibility

Headway is not Kilo-only.

- Kilo: first-class preset via `./headway config setup kilo`
- Claude Code (VS Code): Bedrock env preset via `./headway config setup claude`
- Claude Code: works when pointed at the same local provider endpoints
- Other IDE/CLI extensions and tools: any client that supports OpenAI-compatible base URLs and/or Bedrock base URLs can use Headway

Kilo-specific examples are included because this repo ships a built-in Kilo config helper, but the gateway is intentionally reusable across clients.

## Headway CLI

Use the repo-root CLI for all operations:

```bash
./headway <command>
```

Primary commands:

- `init` - first-time setup (`.env`, AWS preflight, Kilo + Claude Code presets, model config generation)
- `up` - start/reconcile stack and wait for health
- `down` - stop stack
- `auth` - refresh AWS sessions and restart services (no model-config regeneration)
- `doctor` - diagnostics (containers, health, models, client preset checks, AWS session status)
- `test` - full end-to-end smoke tests (`scripts/cli/test.sh`)
- `update` - pull/restart images
- `stats` - savings/cost/cache report
- `config regen` - regenerate `litellm_config.yaml` explicitly
- `config setup [kilo|claude|all]` - write client presets (Kilo and/or Claude Code)
- `reset` - remove stack and optional local state
- `secret-scan` - run local secret scan

## Supported Systems

- macOS: supported with Docker Desktop.
- Linux: supported with Docker Engine + Docker Compose plugin.
- Windows (WSL2): supported when a container runtime is available inside WSL2 (Docker Desktop integration, or Docker Engine running in WSL2).
- Restricted environments: if you cannot run any Docker-compatible daemon, Headway cannot start.

Headway requires `docker compose` and a working Docker-compatible daemon. Docker Desktop is common, but not strictly required when equivalent runtime support exists.

## Quick Start

1. Ensure your Docker-compatible runtime is running (`docker info` should succeed).
2. Ensure AWS profiles are usable:

```bash
aws sts get-caller-identity --profile "$AWS_PROFILE"
aws sts get-caller-identity --profile "${BEDROCK_AWS_PROFILE:-$AWS_PROFILE}"
```

3. Initialize once:

```bash
./headway init
```

`./headway init` is the primary first-run command.

- It creates `.env` if missing.
- If required values are missing and you're in an interactive terminal, it prompts for them with sensible defaults.
- It verifies AWS sessions and triggers SSO login when needed.
- It writes Kilo + Claude Code presets and generates `litellm_config.yaml`.

Optional first-run shortcut if you already know your AWS profile:

```bash
./headway init --aws-profile <your-profile>
```

Environment profile behavior:

- `AWS_PROFILE` (required): primary profile for LiteLLM lane and baseline fallback.
- `BEDROCK_AWS_PROFILE` (optional): native Bedrock runtime profile; defaults to `AWS_PROFILE` when unset.
- `BEDROCK_DISCOVERY_AWS_PROFILE` (optional): profile used by `./headway config regen`; defaults to `BEDROCK_AWS_PROFILE`, then `AWS_PROFILE`.

4. Start stack:

```bash
./headway up
```

5. Validate end-to-end:

```bash
./headway test
./headway doctor
./headway stats
```

Optional compression tuning (Copilot/OpenAI lane; enabled by Headway defaults):

- `HEADROOM_COMPRESS_USER_MESSAGES=1`
- `HEADROOM_MIN_TOKENS=120`
- `HEADROOM_PROTECT_RECENT=2`

These defaults improve practical savings for coding-agent workloads (large user turns and older tool outputs) while keeping the last recent context protected. Override any of them in `.env` if you want a more conservative or more aggressive tradeoff.

Bedrock native lane savings (enabled by default):

- `:4002` traffic passes through Headway's Python runtime patch before Rust SigV4 forwarding.
- For Anthropic Bedrock models, Headway applies:
  - request compression (same headroom `compress()` pipeline)
  - local compression cache reuse across turns
  - optional auto-placement of `cache_control` markers (`HEADWAY_BEDROCK_AUTO_CACHE_CONTROL=1`)
- Bedrock-native savings metrics (input/output tokens, compression %, and USD) are exposed at `/bedrock-native/stats` and rolled into unified `./headway stats` output and the dashboard.

USD savings are estimated from a local pricing snapshot of [models.dev](https://models.dev/api.json), refreshed by `./headway up` and `./headway update` into `.data/headroom/models-dev.json` (gitignored). If the snapshot is missing (e.g. first run while offline), token savings still display but USD figures are omitted rather than guessed.

## Configuration Examples

Set up both client presets in one command:

```bash
./headway config setup all
```

Set up only Kilo:

```bash
./headway config setup kilo
```

Set up only Claude Code (VS Code settings):

```bash
./headway config setup claude
```

Kilo preset writes:

- `github-copilot.options.baseURL = "http://127.0.0.1:4000/v1"`
- `openai-compatible.options.baseURL = "http://127.0.0.1:4000/v1"`
- `amazon-bedrock.options.baseURL = "http://127.0.0.1:4002"`

Claude Code preset writes `claudeCode.environmentVariables` entries in VS Code settings:

- `CLAUDE_CODE_USE_BEDROCK=1`
- `AWS_PROFILE=<BEDROCK_AWS_PROFILE>`
- `AWS_REGION=<AWS_REGION>`

Model selection is intentionally left to the user in Claude Code settings.

By default, Headway writes Claude Code settings to:

- macOS: `~/Library/Application Support/Code/User/settings.json`
- Override path: set `CLAUDE_CODE_SETTINGS` before running `./headway config setup claude`

For other tools/extensions, use equivalent provider settings:

- OpenAI-compatible base URL -> `http://127.0.0.1:4000/v1`
- Bedrock base URL -> `http://127.0.0.1:4002`

## Daily Operations

- Start: `./headway up`
- Health snapshot: `./headway doctor`
- Full smoke tests: `./headway test`
- Savings/usage view: `./headway stats`
- Stop: `./headway down`

## Failure Recovery

If Copilot returns 403 or Bedrock credentials expire:

```bash
./headway auth
```

If Bedrock aliases are stale/missing:

```bash
./headway config regen
./headway up
```

## Example Scenarios

- Multi-client local setup: Kilo + Claude Code share one gateway with consistent routing
- Bedrock feature usage: native `converse`/`converse-stream` while keeping OpenAI-compatible workflows for other traffic
- Cost-awareness workflow: run `./headway stats` after sessions to inspect compression and cache impact
- Auth disruption recovery: run `./headway auth` instead of reworking client configs
- Model drift handling: run `./headway config regen` when upstream Bedrock model availability changes

## Local Persistence

Runtime state is persisted under this repo (gitignored):

- `.data/headroom` - Shared Headroom state for both `:4000` and `:4002` lanes
- `.data/litellm` - LiteLLM token/provider cache

## Bedrock Image Strategy

- Copilot/OpenAI-compatible lane image: `ghcr.io/chopratejas/headroom:code`
- Bedrock lane default image: `ghcr.io/ysheikh2/headway:bedrock-native`
- Override Bedrock lane image by setting `HEADROOM_BEDROCK_IMAGE` in `.env`

## Model Notes

- Bedrock aliases are generated into `litellm_config.yaml` by `./headway config regen`
- Copilot aliases are discovered dynamically with wildcard fallback
- Do not rely on old Copilot model names remaining available

## Security and Trust

Run a local secret scan before publishing:

```bash
./headway secret-scan
```

Repository trust docs:

- [LICENSE](LICENSE)
- [SECURITY.md](SECURITY.md)
- [CONTRIBUTING.md](CONTRIBUTING.md)

## Uninstall and Cleanup

```bash
./headway reset --yes
./headway reset --yes --purge-data --prune-images --cleanup-kilo
```

## Credits

- Headroom (proxy/compression core): https://github.com/chopratejas/headroom
- LiteLLM (provider routing/gateway): https://github.com/BerriAI/litellm
- Headway (this integration wrapper): https://github.com/ysheikh2/headway
