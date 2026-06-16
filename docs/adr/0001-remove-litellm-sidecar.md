# ADR-0001: Remove the LiteLLM sidecar and use headroom's native Copilot provider

**Status:** Accepted — pending implementation  
**Date:** 2026-06-16

## Context

Headway currently runs three containers for two proxy lanes:

```
Kilo/client → headroom :4000 → litellm :4001 → GitHub Copilot   (Copilot lane)
Kilo/client → headroom :4002 → headroom-proxy (SigV4) → Bedrock  (Bedrock lane)
```

The `litellm` container translates OpenAI-format requests into whatever GitHub
Copilot's API expects and manages Copilot device auth / token refresh.

Upstream headroom has carried a native Copilot provider since well before headway
was created. It lives at `headroom/providers/copilot/` and provides:

- Device-code OAuth flow against `github.com`
- Token caching and refresh (keychain on macOS, secret-service on Linux)
- Direct proxying to `api.githubcopilot.com` with the correct headers
- Quota tracking and per-model routing

LiteLLM is already a dependency of headroom itself (for model registry and pricing);
it is not providing anything that headroom cannot do on its own for the Copilot lane.

## Decision

Remove the standalone `litellm` container and configure headroom to proxy Copilot
natively using its built-in provider.

The Copilot lane becomes:

```
Kilo/client → headroom :4000 → GitHub Copilot   (Copilot lane)
Kilo/client → headroom :4002 → headroom-proxy → Bedrock  (Bedrock lane)
```

This collapses the stack from three containers to two.

## Consequences

**Positive**
- One fewer container to manage, pull, and restart.
- Copilot device auth is handled directly by headroom's existing flow — no separate
  LiteLLM auth step.
- Removes the `litellm_config.yaml` file and the `litellm:` service block from
  `docker-compose.yml`.
- Simpler `headway up` / `headway restart` / `headway logs` surface.
- LiteLLM's container startup time (~15–30 s) no longer gates Copilot availability.
- Compression savings on the Copilot lane (per-token billing since 2026-06-01) are
  still applied — headroom's compression middleware runs before the Copilot provider
  forwards the request.

**Negative / Risks**
- headroom's Copilot provider must be verified to work with the current Copilot API
  surface (chat completions, model list). Needs a live integration test.
- `headway config regen` currently discovers Bedrock models via LiteLLM's registry.
  The Copilot model list will need to come from headroom's provider registry instead.
- The `headway init` Copilot auth flow currently delegates device auth to LiteLLM's
  startup sequence. With this change, device auth is triggered through headroom's CLI
  or provider config — the UX needs to be preserved.
- LiteLLM's container is the only thing in `docker-compose.yml` with a `healthcheck`;
  removing it simplifies compose but means the `service_started` dependency on
  `headroom` → `litellm` goes away naturally.

## Implementation notes

1. Set headroom's Copilot provider as the upstream for `:4000` (remove `--openai-api-url`
   pointing at litellm).
2. Drop `litellm` service from `docker-compose.yml` and remove `litellm_config.yaml`.
3. Update `headway init` to trigger headroom's Copilot device auth rather than
   LiteLLM's.
4. Update `headway config regen` to use headroom's provider registry for the Copilot
   model list.
5. Update `scripts/cli/test.sh` Copilot lane smoke tests.
6. Remove `LITELLM_*` env vars from `.env.template`.
