# Contributing

Thanks for helping improve this gateway.

## Local workflow

1. Bootstrap and start the gateway:

```bash
./headway init
./headway up
```

2. Make your changes.
3. Re-run validation:

```bash
./headway secret-scan
./headway test
./headway doctor
```

## Expectations

- Keep changes small and focused.
- Preserve stable routing behavior (one `headroom-proxy` process fronts both lanes):
  - Copilot/OpenAI lane: Client -> headroom-proxy (:4000) -> LiteLLM (:4001)
  - Bedrock native lane: Client -> headroom-proxy (:4002, native SigV4) -> AWS Bedrock
- Do not commit secrets or runtime cache/state files.
- Keep README/AGENTS docs in sync with behavior changes.
- Open PRs against `main`; branch protection requires passing CI before merge.
- For same-repo PRs, CI may auto-commit formatting fixes (`shfmt`, `ruff format`) to your branch.
