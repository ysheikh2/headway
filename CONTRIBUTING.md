# Contributing

Thanks for helping improve this gateway.

## Local workflow

1. Run one-shot bootstrap:

```bash
./scripts/oneshot.sh
```

2. Make your changes.
3. Re-run validation:

```bash
./scripts/secret-scan.sh
./scripts/test.sh
./scripts/status.sh
```

## Expectations

- Keep changes small and focused.
- Preserve stable routing behavior:
  - Kilo -> Headroom (:4000) -> LiteLLM (:4001)
- Do not commit secrets or runtime cache/state files.
- Keep README/AGENTS docs in sync with behavior changes.
- Open PRs against `main`; branch protection requires passing CI before merge.
