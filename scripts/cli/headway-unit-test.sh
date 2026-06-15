#!/usr/bin/env bash
# headway-unit-test.sh — CLI unit tests (no live services, no Docker, no AWS required)
#
# Covers:
#   - completion output is syntactically valid bash
#   - require_env errors on missing .env / missing AWS_PROFILE / missing AWS_REGION
#   - load_env: shell env cannot shadow .env values
#   - load_env: shell env is unset when no .env exists
#   - cleanup: invalid target is rejected

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HEADWAY="$ROOT_DIR/headway"

PASS=0
FAIL=0

ok() {
  echo "  PASS: $*"
  PASS=$((PASS + 1))
}
fail() {
  echo "  FAIL: $*" >&2
  FAIL=$((FAIL + 1))
}

# Create a minimal isolated headway copy in a temp dir for env tests.
# ENV_FILE for that copy resolves to <tmpdir>/.env, independent of the real repo.
make_isolated_copy() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cp "$HEADWAY" "$tmpdir/headway"
  chmod +x "$tmpdir/headway"
  mkdir -p "$tmpdir/scripts/cli"
  cp "$SCRIPT_DIR/headway-completion.bash" "$tmpdir/scripts/cli/"
  echo "$tmpdir"
}

echo "=== headway unit tests ==="
echo

# ── 1. completion output is valid bash ───────────────────────────────────────
echo "[ Test 1: completion output syntax ]"
if "$HEADWAY" completion bash | bash -n 2>&1; then
  ok "completion bash — valid bash"
else
  fail "completion bash — bash -n rejected output"
fi
if "$HEADWAY" completion zsh | bash -n 2>&1; then
  ok "completion zsh — valid bash (loaded via bashcompinit)"
else
  fail "completion zsh — bash -n rejected output"
fi
if "$HEADWAY" completion fish | grep -q "complete -c headway"; then
  ok "completion fish — contains expected complete -c headway directives"
else
  fail "completion fish — missing expected complete -c headway directives"
fi

# ── 2. require_env: missing .env ─────────────────────────────────────────────
echo
echo "[ Test 2: require_env — missing .env ]"
tmpdir="$(make_isolated_copy)"
out="$("$tmpdir/headway" config setup kilo 2>&1)" && status=0 || status=$?
if [[ "$status" -ne 0 ]] && echo "$out" | grep -q "ERROR:.*\.env not found"; then
  ok "missing .env → exit $status with correct error"
else
  fail "missing .env → exit $status, output: $out"
fi
rm -rf "$tmpdir"

# ── 3. require_env: AWS_PROFILE absent from .env ─────────────────────────────
echo
echo "[ Test 3: require_env — AWS_PROFILE not in .env ]"
tmpdir="$(make_isolated_copy)"
echo "AWS_REGION=us-east-1" >"$tmpdir/.env"
out="$(AWS_PROFILE= "$tmpdir/headway" config setup kilo 2>&1)" && status=0 || status=$?
if [[ "$status" -ne 0 ]] && echo "$out" | grep -q "ERROR:.*AWS_PROFILE"; then
  ok "missing AWS_PROFILE → exit $status with correct error"
else
  fail "missing AWS_PROFILE → exit $status, output: $out"
fi
rm -rf "$tmpdir"

# ── 4. require_env: AWS_REGION absent from .env ──────────────────────────────
echo
echo "[ Test 4: require_env — AWS_REGION not in .env ]"
tmpdir="$(make_isolated_copy)"
echo "AWS_PROFILE=test-profile" >"$tmpdir/.env"
out="$(AWS_REGION= "$tmpdir/headway" config setup kilo 2>&1)" && status=0 || status=$?
if [[ "$status" -ne 0 ]] && echo "$out" | grep -q "ERROR:.*AWS_REGION"; then
  ok "missing AWS_REGION → exit $status with correct error"
else
  fail "missing AWS_REGION → exit $status, output: $out"
fi
rm -rf "$tmpdir"

# ── 5. load_env: .env value wins over shell env ──────────────────────────────
echo
echo "[ Test 5: load_env — .env value takes precedence over shell env ]"
tmpdir="$(make_isolated_copy)"
printf 'AWS_PROFILE=from-env-file\nAWS_REGION=eu-central-1\n' >"$tmpdir/.env"
out="$(AWS_PROFILE=from-shell "$tmpdir/headway" config show 2>&1)"
if echo "$out" | grep -q "AWS_PROFILE=from-env-file"; then
  ok "load_env: .env value wins over shell env"
else
  fail "load_env: shell env leaked — output: $out"
fi
rm -rf "$tmpdir"

# ── 6. load_env: shell env var unset when no .env ────────────────────────────
echo
echo "[ Test 6: load_env — shell env cleared when .env absent ]"
tmpdir="$(make_isolated_copy)"
out="$(AWS_PROFILE=from-shell "$tmpdir/headway" config show 2>&1)"
if echo "$out" | grep -q "AWS_PROFILE=<unset>"; then
  ok "load_env: shell var correctly cleared when no .env"
else
  fail "load_env: shell var visible when no .env — output: $out"
fi
rm -rf "$tmpdir"

# ── 7. cleanup: invalid target is rejected ───────────────────────────────────
echo
echo "[ Test 7: cleanup — invalid target rejected ]"
out="$("$HEADWAY" cleanup bogus 2>&1)" && status=0 || status=$?
if [[ "$status" -ne 0 ]] && echo "$out" | grep -q "Unknown cleanup arg"; then
  ok "cleanup bogus → exit $status with correct error"
else
  fail "cleanup bogus → exit $status, output: $out"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
