#!/usr/bin/env bash
# headway-unit-test.sh — CLI unit tests (no live services, no Docker, no AWS required)
#
# Covers:
#   - completion output is syntactically valid bash with no shebang lines
#   - require_env errors on missing .env / missing AWS_PROFILE / missing AWS_REGION / missing BEDROCK_AWS_PROFILE
#   - load_env: shell env cannot shadow .env values
#   - load_env: shell env is unset when no .env exists
#   - cleanup: invalid target is rejected
#   - install.sh: valid bash syntax
#   - install.sh helpers: detect_shell_rc, detect_shell_name, add_to_path_in_rc, add_completion_to_rc

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

# ── 1. completion output ──────────────────────────────────────────────────────
echo "[ Test 1: completion output syntax and format ]"
if "$HEADWAY" completion bash | bash -n 2>&1; then
  ok "completion bash — valid bash syntax"
else
  fail "completion bash — bash -n rejected output"
fi
if "$HEADWAY" completion zsh | bash -n 2>&1; then
  ok "completion zsh — valid bash syntax (loaded via bashcompinit)"
else
  fail "completion zsh — bash -n rejected output"
fi
if "$HEADWAY" completion fish | grep -q "complete -c headway"; then
  ok "completion fish — contains expected complete -c headway directives"
else
  fail "completion fish — missing expected complete -c headway directives"
fi
# Verify no shebang line in any completion output — a shebang mid-output looks
# garbled when zsh evals it via bashcompinit (the bug that wasn't caught before).
if "$HEADWAY" completion bash | grep -q "^#!"; then
  fail "completion bash — contains a shebang line (must not be present in sourced output)"
else
  ok "completion bash — no shebang line"
fi
if "$HEADWAY" completion zsh | grep -q "^#!"; then
  fail "completion zsh — contains a shebang line (must not be present in sourced output)"
else
  ok "completion zsh — no shebang line"
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

# ── 5. require_env: BEDROCK_AWS_PROFILE absent from .env ─────────────────────
echo
echo "[ Test 5: require_env — BEDROCK_AWS_PROFILE not in .env ]"
tmpdir="$(make_isolated_copy)"
printf 'AWS_PROFILE=test-profile\nAWS_REGION=us-east-1\n' >"$tmpdir/.env"
out="$(BEDROCK_AWS_PROFILE= "$tmpdir/headway" config setup kilo 2>&1)" && status=0 || status=$?
if [[ "$status" -ne 0 ]] && echo "$out" | grep -q "ERROR:.*BEDROCK_AWS_PROFILE"; then
  ok "missing BEDROCK_AWS_PROFILE → exit $status with correct error"
else
  fail "missing BEDROCK_AWS_PROFILE → exit $status, output: $out"
fi
rm -rf "$tmpdir"

# ── 6. load_env: .env value wins over shell env ──────────────────────────────
echo
echo "[ Test 6: load_env — .env value takes precedence over shell env ]"
tmpdir="$(make_isolated_copy)"
printf 'AWS_PROFILE=from-env-file\nAWS_REGION=eu-central-1\n' >"$tmpdir/.env"
out="$(AWS_PROFILE=from-shell "$tmpdir/headway" config show 2>&1)"
if echo "$out" | grep -q "AWS_PROFILE=from-env-file"; then
  ok "load_env: .env value wins over shell env"
else
  fail "load_env: shell env leaked — output: $out"
fi
rm -rf "$tmpdir"

# ── 7. load_env: shell env var unset when no .env ────────────────────────────
echo
echo "[ Test 7: load_env — shell env cleared when .env absent ]"
tmpdir="$(make_isolated_copy)"
out="$(AWS_PROFILE=from-shell "$tmpdir/headway" config show 2>&1)"
if echo "$out" | grep -q "AWS_PROFILE=<unset>"; then
  ok "load_env: shell var correctly cleared when no .env"
else
  fail "load_env: shell var visible when no .env — output: $out"
fi
rm -rf "$tmpdir"

# ── 8. cleanup: invalid target is rejected ───────────────────────────────────
echo
echo "[ Test 8: cleanup — invalid target rejected ]"
out="$("$HEADWAY" cleanup bogus 2>&1)" && status=0 || status=$?
if [[ "$status" -ne 0 ]] && echo "$out" | grep -q "Unknown cleanup arg"; then
  ok "cleanup bogus → exit $status with correct error"
else
  fail "cleanup bogus → exit $status, output: $out"
fi

# ── 9. install.sh syntax check ───────────────────────────────────────────────
echo
echo "[ Test 9: install.sh bash syntax ]"
if bash -n "$ROOT_DIR/install.sh" 2>&1; then
  ok "install.sh — valid bash syntax"
else
  fail "install.sh — bash -n rejected install.sh"
fi

# ── 10. install.sh helper functions ──────────────────────────────────────────
echo
echo "[ Test 10: install.sh helper functions ]"

# Source install.sh to load its functions without running do_install.
# The guard uses ${BASH_SOURCE[0]:-$0} == $0 so it works when piped
# through bash (BASH_SOURCE unbound) and still skips do_install when sourced.
# shellcheck source=../../install.sh
source "$ROOT_DIR/install.sh"

_orig_shell="${SHELL:-/bin/bash}"
_orig_home="$HOME"

# detect_shell_name
SHELL=/bin/bash
if [[ "$(detect_shell_name)" == "bash" ]]; then
  ok "detect_shell_name — bash"
else
  fail "detect_shell_name — expected bash, got: $(detect_shell_name)"
fi
SHELL=/bin/zsh
if [[ "$(detect_shell_name)" == "zsh" ]]; then
  ok "detect_shell_name — zsh"
else
  fail "detect_shell_name — expected zsh, got: $(detect_shell_name)"
fi
SHELL="$_orig_shell"

# detect_shell_rc (override HOME so we get predictable paths)
HOME=/test/home
SHELL=/bin/zsh
if [[ "$(detect_shell_rc)" == "/test/home/.zshrc" ]]; then
  ok "detect_shell_rc — zsh → .zshrc"
else
  fail "detect_shell_rc — expected /test/home/.zshrc, got: $(detect_shell_rc)"
fi
SHELL=/bin/bash
if [[ "$(detect_shell_rc)" == "/test/home/.bashrc" ]]; then
  ok "detect_shell_rc — bash → .bashrc"
else
  fail "detect_shell_rc — expected /test/home/.bashrc, got: $(detect_shell_rc)"
fi
SHELL=/bin/fish
if [[ "$(detect_shell_rc)" == "" ]]; then
  ok "detect_shell_rc — fish → empty (uses separate completions dir)"
else
  fail "detect_shell_rc — expected empty for fish, got: $(detect_shell_rc)"
fi
HOME="$_orig_home"
SHELL="$_orig_shell"

# add_to_path_in_rc: fresh add
_rc_tmp="$(mktemp)"
add_to_path_in_rc "$_rc_tmp" "/test/bin" 2>/dev/null
if grep -qF "/test/bin" "$_rc_tmp" && grep -qF "headway PATH" "$_rc_tmp"; then
  ok "add_to_path_in_rc — writes PATH export with marker"
else
  fail "add_to_path_in_rc — expected PATH line not found"
fi

# add_to_path_in_rc: idempotent
_lines_before="$(wc -l <"$_rc_tmp")"
add_to_path_in_rc "$_rc_tmp" "/test/bin" 2>/dev/null
_lines_after="$(wc -l <"$_rc_tmp")"
if [[ "$_lines_before" -eq "$_lines_after" ]]; then
  ok "add_to_path_in_rc — idempotent (no duplicate added)"
else
  fail "add_to_path_in_rc — added duplicate PATH line"
fi
rm -f "$_rc_tmp"

# add_completion_to_rc: fresh add
_rc_tmp="$(mktemp)"
INSTALL_DIR="/fake/headway"
add_completion_to_rc "$_rc_tmp" "bash" 2>/dev/null
if grep -qF "/fake/headway/headway" "$_rc_tmp" && grep -qF "headway tab completion" "$_rc_tmp"; then
  ok "add_completion_to_rc — writes eval line"
else
  fail "add_completion_to_rc — expected completion line not found"
fi

# add_completion_to_rc: idempotent for same path
_bytes_before="$(wc -c <"$_rc_tmp")"
add_completion_to_rc "$_rc_tmp" "bash" 2>/dev/null
_bytes_after="$(wc -c <"$_rc_tmp")"
if [[ "$_bytes_before" -eq "$_bytes_after" ]]; then
  ok "add_completion_to_rc — idempotent for same install path"
else
  fail "add_completion_to_rc — added duplicate for same path"
fi

# add_completion_to_rc: updates stale path from a different install dir
INSTALL_DIR="/new/headway"
add_completion_to_rc "$_rc_tmp" "bash" 2>/dev/null
if grep -qF "/new/headway/headway" "$_rc_tmp" && ! grep -qF "/fake/headway/headway" "$_rc_tmp"; then
  ok "add_completion_to_rc — replaces stale completion path"
else
  fail "add_completion_to_rc — stale path not replaced"
fi
rm -f "$_rc_tmp"

# Restore INSTALL_DIR to its original value
INSTALL_DIR="${HEADWAY_INSTALL_DIR:-$HOME/headway}"

# ── 11. symlink invocation — ROOT_DIR resolves to repo, not symlink parent ───
echo
echo "[ Test 11: headway invoked via symlink resolves ROOT_DIR correctly ]"
_sym_tmp="$(mktemp -d)"
ln -sf "$HEADWAY" "$_sym_tmp/headway"
# completion bash/zsh cat the completion script from $ROOT_DIR/scripts/cli/
# If ROOT_DIR is wrong (symlink parent), the cat fails and output is empty/error.
# Capture without relying on set -e to abort on failure — use explicit status capture.
if _sym_out="$("$_sym_tmp/headway" completion bash 2>&1)"; then
  _sym_status=0
else
  _sym_status=$?
fi
if [[ "$_sym_status" -eq 0 ]] && echo "$_sym_out" | grep -q "_headway_bash_completion"; then
  ok "symlink invocation — completion bash works (ROOT_DIR resolved correctly)"
else
  fail "symlink invocation — completion bash failed (ROOT_DIR not resolved): $_sym_out"
fi
if _sym_out="$("$_sym_tmp/headway" completion zsh 2>&1)"; then
  _sym_status=0
else
  _sym_status=$?
fi
if [[ "$_sym_status" -eq 0 ]] &&
  echo "$_sym_out" | grep -q "bashcompinit" &&
  echo "$_sym_out" | grep -q "_headway_bash_completion" &&
  ! echo "$_sym_out" | grep -q "^#!"; then
  ok "symlink invocation — completion zsh clean output"
else
  fail "symlink invocation — completion zsh unexpected output: $_sym_out"
fi
rm -rf "$_sym_tmp"

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
