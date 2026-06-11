# Security Policy

## Reporting a Vulnerability

Please report security issues privately via GitHub Security Advisories for this repository.

If that is unavailable, open a private channel with the maintainer and include:

- affected file(s) or script(s)
- reproduction steps
- potential impact
- suggested mitigation

Please do not publish sensitive details in public issues until a fix is available.

## Secret Hygiene

Before pushing changes, run:

```bash
./scripts/secret-scan.sh
```

The project is configured to keep runtime-sensitive files out of version control:

- `.env`
- `.data/`
- local auth/token caches
