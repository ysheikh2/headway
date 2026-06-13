# Contributing

Thanks for helping improve this gateway.

## Local workflow

1. Bootstrap and start the gateway:

```bash
./headroom-proxy init
./headroom-proxy up
```

2. Make your changes.
3. Re-run validation:

```bash
./headroom-proxy secret-scan
./headroom-proxy test
./headroom-proxy doctor
```

## Expectations

- Keep changes small and focused.
- Preserve stable routing behavior:
  - Client -> Headroom (:4000) -> LiteLLM (:4001)
- Do not commit secrets or runtime cache/state files.
- Keep README/AGENTS docs in sync with behavior changes.
- Open PRs against `main`; branch protection requires passing CI before merge.
- For same-repo PRs, CI may auto-commit formatting fixes (`shfmt`, `ruff format`) to your branch.
