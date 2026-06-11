#!/usr/bin/env bash
# secret-scan.sh — Lightweight local secret scan for this repository.
#
# Usage:
#   ./scripts/secret-scan.sh

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

echo "=== Secret Scan ==="
echo

echo "[1/2] Pattern scan"
PATTERN_HITS=$(grep -RInE '(AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z\-_]{35}|-----BEGIN (RSA|EC|OPENSSH|PRIVATE) KEY-----|password\s*=|secret\s*=|api[_-]?key\s*=|token\s*=)' . --exclude-dir=.data --exclude-dir=.git --exclude=litellm_config.yaml || true)
if [[ -n "$PATTERN_HITS" ]]; then
  echo "$PATTERN_HITS"
  PATTERN_FAIL=1
else
  echo "  No pattern matches found."
  PATTERN_FAIL=0
fi

echo
echo "[2/2] Entropy-ish scan"
ENTROPY_HITS=$(python3 - <<'PY'
import os,re
root='.'
skip_dirs={'.data','.git'}
pat=re.compile(r'[A-Za-z0-9+/=_-]{32,}')
ignore_ext={'.png','.jpg','.jpeg','.gif','.webp','.pdf','.zip','.gz'}
results=[]
for dp, dns, fns in os.walk(root):
    dns[:] = [d for d in dns if d not in skip_dirs]
    for fn in fns:
        p=os.path.join(dp,fn)
        if any(fn.lower().endswith(ext) for ext in ignore_ext):
            continue
        try:
            txt=open(p,'r',encoding='utf-8',errors='ignore').read()
        except Exception:
            continue
        for i,line in enumerate(txt.splitlines(),1):
            for m in pat.findall(line):
                if m.lower().startswith(('http','bedrock-','github_copilot','eu-','global-')):
                    continue
                uniq=len(set(m))/len(m)
                if uniq>0.45 and any(c.isdigit() for c in m) and any(c.isalpha() for c in m):
                    results.append(f"{p}:{i}:{m[:70]}")
print("\n".join(results))
PY
)
if [[ -n "$ENTROPY_HITS" ]]; then
  echo "$ENTROPY_HITS"
  ENTROPY_FAIL=1
else
  echo "  No suspicious high-entropy strings found."
  ENTROPY_FAIL=0
fi

echo
if [[ $PATTERN_FAIL -eq 0 && $ENTROPY_FAIL -eq 0 ]]; then
  echo "PASS: No obvious secrets detected by lightweight scan."
  exit 0
else
  echo "FAIL: Potential secrets detected. Review output above before publishing."
  exit 1
fi
