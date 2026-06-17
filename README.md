# Headway

Headway is a local AI gateway stack that routes GitHub Copilot and AWS Bedrock traffic through stable local endpoints, adding token compression, prompt-cache savings, and unified telemetry.

Headway combines:

- Headroom — request/response compression, savings telemetry, runtime proxying
- LiteLLM — provider/model routing for the OpenAI-compatible lane
- A native Bedrock lane for `converse` and `converse-stream`

This repository is an operations wrapper around upstream projects. It is not a fork or replacement of upstream Headroom or LiteLLM.

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ysheikh2/headway/main/install.sh)
```

This clones headway to `~/headway`, creates a `headway` symlink at `~/.local/bin/headway`, wires up shell tab-completion, and walks you through `headway init` and `headway up` interactively.

> **Note:** The `bash <(curl ...)` process-substitution form keeps your terminal attached so the guided setup prompts work. The traditional `curl | bash` pipe form installs without the guided flow (you'd run `headway init && headway up` manually afterward).

**Prerequisites:** `git`, `docker` (with Compose), `aws` CLI, `python3`.

To uninstall:

```bash
headway uninstall --yes
```

## Why Headway Is Useful

- Keep provider wiring stable locally while upstream model catalogs change often
- Use one local gateway for multiple AI coding clients and extensions
- Native Bedrock support (`:4002`) alongside OpenAI-compatible routing (`:4000/v1`)
- Token compression and prompt-cache savings surfaced in a unified dashboard and CLI
- Fast recovery from auth/config drift with `headway auth` and `headway doctor`

## Lanes and Endpoints

- GitHub Copilot + OpenAI-compatible lane: `http://127.0.0.1:4000/v1`
- Native Bedrock lane: `http://127.0.0.1:4002`

A single native Rust `headroom-proxy` process fronts both lanes. It compresses
every request, signs Bedrock natively (SigV4), and serves one unified `/stats` +
`/dashboard` — there is no Python proxy and no Bedrock sidecar.

```text
Client (Copilot/OpenAI-compatible) → headroom-proxy :4000 → LiteLLM :4001 → GitHub Copilot
Client (Bedrock native)            → headroom-proxy :4002 (compress+cache, native SigV4) → AWS Bedrock
```

## Client Compatibility

Headway works with any client that supports OpenAI-compatible base URLs or Bedrock base URLs.

- **Kilo** — first-class preset via `headway config setup kilo`
- **Claude Code (VS Code)** — Bedrock env preset via `headway config setup claude`
- **Other tools** — point at `http://127.0.0.1:4000/v1` (OpenAI-compatible) or `http://127.0.0.1:4002` (Bedrock)

## Quick Start

### First-time setup

```bash
headway init
```

`headway init` is the primary first-run command. It:

- Creates `.env` if missing, prompting for required values
- Verifies AWS sessions and triggers SSO login when needed
- Writes Kilo + Claude Code presets
- Generates the Copilot-only `litellm_config.yaml` (Bedrock is native in the proxy)

Optional shortcut if you already know your AWS profile:

```bash
headway init --aws-profile <your-profile>
```

AWS profile behavior:

- `AWS_PROFILE` (required): primary profile for the LiteLLM lane
- `BEDROCK_AWS_PROFILE` (defaults to `AWS_PROFILE`): native Bedrock runtime profile; set separately only if you use a different profile for Bedrock

### Start the gateway

```bash
headway up
```

### Validate

```bash
headway doctor    # containers, health, AWS session, client presets
headway stats     # savings and cost report
headway test      # single-proxy smoke test (/healthz, /stats, /dashboard, recorder)
```

Dashboard: `http://127.0.0.1:4000/dashboard`

## CLI Reference

```bash
headway <command>
```

| Command | Description |
|---|---|
| `init` | First-time setup — `.env`, AWS preflight, client presets, config generation |
| `up` | Start the stack with current config (no pull, no regen) |
| `down` | Stop the stack |
| `restart` | Stop and restart without pulling or regenerating config |
| `update` | Regenerate litellm config, pull latest images, restart |
| `reset` | Force-remove containers, regen, pull, restart — nuclear option, keeps `.env` |
| `auth` | Refresh AWS sessions and restart services |
| `doctor` | Diagnostics: containers, health, models, client presets, AWS sessions |
| `stats` | Savings, cost, and cache report |
| `test` | Single-proxy smoke test (`/healthz`, unified `/stats`, `/dashboard`, recorder) |
| `config regen` | Regenerate the Copilot-only `litellm_config.yaml` |
| `config setup [kilo\|claude\|all]` | Write client presets |
| `cleanup <data\|images\|kilo\|claude\|all>` | Remove specific local state or client configs |
| `uninstall` | Stop services, remove all data/images/configs, remove headway itself |
| `completion [bash\|zsh\|fish\|auto]` | Print shell tab-completion script |
| `secret-scan` | Run local secret scan |

Tab completion is set up automatically by `install.sh`. To add it manually:

```bash
eval "$(headway completion)"                                        # bash/zsh — add to rc file
headway completion fish > ~/.config/fish/completions/headway.fish   # fish
```

## Client Setup

Set up both presets at once:

```bash
headway config setup all
```

**Kilo** writes to `~/.config/kilo/kilo.jsonc`:

- `github-copilot.options.baseURL = "http://127.0.0.1:4000/v1"`
- `openai-compatible.options.baseURL = "http://127.0.0.1:4000/v1"`
- `amazon-bedrock.options.baseURL = "http://127.0.0.1:4002"`

**Claude Code (VS Code)** writes `claudeCode.environmentVariables` into your VS Code `settings.json`:

- `CLAUDE_CODE_USE_BEDROCK=1`
- `AWS_PROFILE=<BEDROCK_AWS_PROFILE>`
- `AWS_REGION=<AWS_REGION>`

Default settings path (auto-detected by OS):

| OS | Default path |
|---|---|
| macOS | `~/Library/Application Support/Code/User/settings.json` |
| Linux | `~/.config/Code/User/settings.json` |
| Windows (WSL2) | Set `CLAUDE_CODE_SETTINGS` to your Windows path (see below) |

Override for any platform:

```bash
export CLAUDE_CODE_SETTINGS="/path/to/settings.json"
headway config setup claude
```

Windows users running VS Code natively (not VS Code Remote) should point `CLAUDE_CODE_SETTINGS` at `$APPDATA/Code/User/settings.json` from within WSL2.

## Daily Operations

| Task | Command |
|---|---|
| Start | `headway up` |
| Stop | `headway down` |
| Health check | `headway doctor` |
| Savings report | `headway stats` |
| Dashboard | `http://127.0.0.1:4000/dashboard` |
| Full smoke test | `headway test` |

## Failure Recovery

**Copilot 403 or expired Bedrock credentials:**

```bash
headway auth
```

**Stale or missing Bedrock model aliases:**

```bash
headway config regen
headway up
```

**Something badly broken:**

```bash
headway reset
```

## Savings

### Copilot / OpenAI-compatible lane

- **Compression** — stale context removed before sending; surfaced as `tokens_saved` in stats and dashboard
- **Prefix cache** — Copilot caches stable Claude prefixes at ~10% input cost; Headway prices the discount from a models.dev snapshot and surfaces it as `cache_savings_usd`

### Bedrock native lane

`:4002` traffic passes through Headway's Python patch before Rust SigV4 forwarding. For Anthropic Bedrock models, Headway applies compression, compression-cache reuse across turns, and optional `cache_control` marker placement (`HEADWAY_BEDROCK_AUTO_CACHE_CONTROL=1`).

Bedrock savings metrics roll into unified `headway stats` output and the dashboard alongside Copilot data.

USD figures are estimated from a local [models.dev](https://models.dev/api.json) pricing snapshot, refreshed by `headway update`. If the snapshot is missing, token savings still display but USD figures are omitted.

### Optional compression tuning (Copilot lane)

Override in `.env`:

- `HEADROOM_COMPRESS_USER_MESSAGES=1`
- `HEADROOM_MIN_TOKENS=120`
- `HEADROOM_PROTECT_RECENT=2`

## Local Persistence

Runtime state lives under this repo (gitignored):

- `.data/headroom` — shared state for `:4000` and `:4002` lanes
- `.data/litellm` — LiteLLM token/provider cache

## Images

- Headroom: `ghcr.io/chopratejas/headroom:code` (override with `HEADROOM_IMAGE` in `.env`)
  — the upstream `:code` image ships the native `headroom-proxy` binary; the compose
  service sets `entrypoint: ["headroom-proxy"]` to run it as the single front door
  for both the `:4000` and `:4002` lanes.
- LiteLLM (optional Copilot upstream, `--profile litellm`): `ghcr.io/berriai/litellm:main-stable`

## Uninstall and Cleanup

```bash
headway cleanup data        # delete runtime data (.data/)
headway cleanup images      # remove Docker images
headway cleanup kilo        # remove Kilo preset
headway cleanup claude      # remove Claude Code preset
headway cleanup all --yes   # remove all of the above

headway uninstall --yes     # full removal including headway itself
```

## Supported Systems

- **macOS** — Docker Desktop
- **Linux** — Docker Engine + Compose plugin
- **Windows (WSL2)** — Docker Desktop WSL2 integration or Docker Engine inside WSL2

## Security

```bash
headway secret-scan
```

- [LICENSE](LICENSE)
- [SECURITY.md](SECURITY.md)
- [CONTRIBUTING.md](CONTRIBUTING.md)

## Credits

- [Headroom](https://github.com/chopratejas/headroom) — proxy and compression core
- [LiteLLM](https://github.com/BerriAI/litellm) — provider routing
- [Headway](https://github.com/ysheikh2/headway) — this integration wrapper
