#!/usr/bin/env bash
# headway-e2e-test.sh — End-to-end install and gateway tests
#
# Tests the complete user journey from a clean state:
#   1. install.sh clones repo, creates symlink, configures shell
#   2. headway init configures .env and generates config
#   3. headway up starts the gateway stack
#   4. All smoke tests pass (headway test)
#   5. headway stats returns valid output
#   6. headway doctor passes
#   7. headway down stops the stack cleanly
#   8. headway cleanup removes data as expected
#
# Usage:
#   bash scripts/cli/headway-e2e-test.sh [--branch <branch>] [--repo <url>] [--aws-profile <profile>]
#
# Environment overrides (same as install.sh):
#   HEADWAY_BRANCH        git branch to clone (default: main)
#   HEADWAY_REPO_URL      git repo URL
#   HEADWAY_AWS_PROFILE   AWS profile for .env (default: uses headway default)
#   HEADWAY_AWS_REGION    AWS region for .env (default: eu-central-1)
#   E2E_INSTALL_DIR       where to clone headway (default: /tmp/headway-e2e-$$)
#   E2E_KEEP              set to 1 to skip cleanup at the end (for debugging)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── config ────────────────────────────────────────────────────────────────────

REPO_URL="${HEADWAY_REPO_URL:-https://github.com/ysheikh2/headway.git}"
REPO_BRANCH="${HEADWAY_BRANCH:-}"
AWS_PROFILE="${HEADWAY_AWS_PROFILE:-}"
AWS_REGION="${HEADWAY_AWS_REGION:-eu-central-1}"
INSTALL_DIR="${E2E_INSTALL_DIR:-/tmp/headway-e2e-$$}"
SYMLINK="$INSTALL_DIR/.bin/headway"
KEEP="${E2E_KEEP:-0}"

die() {
  echo "  [FATAL] $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      [[ $# -ge 2 && "$2" != --* ]] || die "--branch requires a value"
      REPO_BRANCH="$2"
      shift 2
      ;;
    --repo)
      [[ $# -ge 2 && "$2" != --* ]] || die "--repo requires a value"
      REPO_URL="$2"
      shift 2
      ;;
    --aws-profile)
      [[ $# -ge 2 && "$2" != --* ]] || die "--aws-profile requires a value"
      AWS_PROFILE="$2"
      shift 2
      ;;
    --region)
      [[ $# -ge 2 && "$2" != --* ]] || die "--region requires a value"
      AWS_REGION="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1"
      exit 1
      ;;
  esac
done

# ── helpers ───────────────────────────────────────────────────────────────────

PASS=0
FAIL=0
_section=""

section() {
  _section="$*"
  echo
  echo "[ $* ]"
}
ok() {
  echo "  [PASS] $*"
  PASS=$((PASS + 1))
}
fail() {
  echo "  [FAIL] $*" >&2
  FAIL=$((FAIL + 1))
}

# ── cleanup trap ──────────────────────────────────────────────────────────────

_cleanup() {
  if [[ "$KEEP" == "1" ]]; then
    echo
    echo "E2E_KEEP=1 — leaving install dir at $INSTALL_DIR"
    return
  fi
  echo
  echo "[ Teardown ]"
  if command -v "$SYMLINK" >/dev/null 2>&1; then
    "$SYMLINK" down 2>/dev/null || true
    "$SYMLINK" cleanup all --yes 2>/dev/null || true
  fi
  rm -rf "$INSTALL_DIR"
  echo "  cleaned up $INSTALL_DIR"
}
trap _cleanup EXIT

# ── 1. install.sh ─────────────────────────────────────────────────────────────

section "1. install.sh — fresh clone and symlink"

export HEADWAY_REPO_URL="$REPO_URL"
export HEADWAY_BRANCH="$REPO_BRANCH"
export HEADWAY_INSTALL_DIR="$INSTALL_DIR"
export HEADWAY_SYMLINK="$SYMLINK"

# Run the installer non-interactively (stdin not a tty → skips headway init/up prompts).
# Variables are already exported above; no need to repeat them inline.
if bash "$ROOT_DIR/install.sh" </dev/null 2>&1; then
  ok "install.sh exited 0"
else
  fail "install.sh failed"
fi

if [[ -L "$SYMLINK" ]]; then
  ok "symlink created: $SYMLINK → $(readlink "$SYMLINK")"
else
  fail "symlink not created at $SYMLINK"
fi

if [[ "$(readlink "$SYMLINK")" == "$INSTALL_DIR/headway" ]]; then
  ok "symlink target is correct"
else
  fail "symlink target wrong: $(readlink "$SYMLINK")"
fi

# Idempotency: run install.sh again — must not error or duplicate anything
if bash "$ROOT_DIR/install.sh" </dev/null 2>&1; then
  ok "install.sh idempotent (second run exited 0)"
else
  fail "install.sh second run failed"
fi

# ── 2. headway via symlink ────────────────────────────────────────────────────

section "2. headway invoked via symlink"

if _ver="$("$SYMLINK" help 2>&1 | sed -n '1p')"; then
  ok "headway help via symlink: $_ver"
else
  fail "headway help via symlink failed"
fi

if "$SYMLINK" completion bash | grep -q "_headway_bash_completion"; then
  ok "completion bash works via symlink (ROOT_DIR resolved)"
else
  fail "completion bash failed via symlink"
fi

if _bash_compl="$("$SYMLINK" completion bash 2>&1)"; then
  if echo "$_bash_compl" | grep -q "^#!"; then
    fail "completion bash has shebang line"
  else
    ok "completion bash — no shebang"
  fi
else
  fail "completion bash failed: $_bash_compl"
fi

if "$SYMLINK" completion zsh | grep -q "bashcompinit"; then
  ok "completion zsh works via symlink"
else
  fail "completion zsh failed via symlink"
fi

# ── 3. unit tests ─────────────────────────────────────────────────────────────

section "3. unit tests (no live services)"

if bash "$ROOT_DIR/scripts/cli/headway-unit-test.sh" 2>&1; then
  ok "all unit tests passed"
else
  fail "unit tests failed"
fi

# ── 4. headway init ───────────────────────────────────────────────────────────

section "4. headway init — configure and preflight"

# Pre-populate .env so init runs non-interactively.
# AWS_PROFILE must be provided via --aws-profile or HEADWAY_AWS_PROFILE env var.
_env_file="$INSTALL_DIR/.env"
if [[ -z "$AWS_PROFILE" ]]; then
  die "AWS profile required — pass --aws-profile <name> or set HEADWAY_AWS_PROFILE"
fi
{
  echo "AWS_PROFILE=$AWS_PROFILE"
  echo "BEDROCK_AWS_PROFILE=$AWS_PROFILE"
  echo "BEDROCK_DISCOVERY_AWS_PROFILE=$AWS_PROFILE"
  echo "AWS_REGION=$AWS_REGION"
  echo "HEADROOM_IMAGE=ghcr.io/ysheikh2/headway:headroom-bundled"
  echo "HEADROOM_COMPRESS_USER_MESSAGES=1"
  echo "HEADROOM_MIN_TOKENS=120"
  echo "HEADROOM_PROTECT_RECENT=2"
  echo "HEADWAY_BEDROCK_AUTO_CACHE_CONTROL=1"
} >"$_env_file"

if "$SYMLINK" init 2>&1; then
  ok "headway init exited 0"
else
  fail "headway init failed"
fi

if [[ -f "$_env_file" ]]; then
  ok ".env exists after init"
else
  fail ".env missing after init"
fi

for _key in AWS_PROFILE AWS_REGION BEDROCK_AWS_PROFILE; do
  if grep -q "^${_key}=" "$_env_file"; then
    ok ".env has $_key"
  else
    fail ".env missing $_key"
  fi
done

if [[ -f "$HOME/.config/kilo/kilo.jsonc" ]]; then
  ok "kilo.jsonc written"
else
  fail "kilo.jsonc not found"
fi

# ── 5. headway config show ────────────────────────────────────────────────────

section "5. headway config show"

if _config_out="$("$SYMLINK" config show 2>&1)"; then
  if echo "$_config_out" | grep -q "AWS_PROFILE"; then
    ok "config show includes AWS_PROFILE"
  else
    fail "config show output unexpected: $_config_out"
  fi
else
  fail "config show failed: $_config_out"
fi

# ── 6. headway up ─────────────────────────────────────────────────────────────

section "6. headway up — start gateway stack"

echo "  (pulling images and starting containers — may take 2–3 min on first run)"
_UP_OK=true
_up_out=""
if _up_out="$("$SYMLINK" up 2>&1)"; then
  ok "headway up exited 0"
  echo "$_up_out"
else
  echo "$_up_out"
  # Distinguish expected Copilot device-auth requirement (no token file in CI)
  # from real infrastructure failures (docker errors, AWS auth, config bugs).
  if echo "$_up_out" | grep -qiE "copilot|device auth|github.com/login/device"; then
    echo "  NOTE: headway up paused for Copilot device auth (expected in CI)."
    echo "        Run interactively: $SYMLINK auth"
    echo "  Skipping live-gateway sections (7–9)."
    _UP_OK=false
  else
    fail "headway up failed (not a Copilot auth issue — see output above)"
    _UP_OK=false
  fi
fi

# ── 7. smoke tests ────────────────────────────────────────────────────────────

section "7. headway test — full smoke suite"

if [[ "$_UP_OK" == "false" ]]; then
  echo "  (skipped — gateway not running)"
elif "$SYMLINK" test 2>&1; then
  ok "all smoke tests passed"
else
  fail "smoke tests failed"
fi

# ── 8. headway stats ──────────────────────────────────────────────────────────

section "8. headway stats"

if [[ "$_UP_OK" == "false" ]]; then
  echo "  (skipped — gateway not running)"
elif _stats_out="$("$SYMLINK" stats 2>&1)"; then
  if echo "$_stats_out" | grep -qiE "requests|tokens|savings"; then
    ok "headway stats returned usage data"
  else
    fail "headway stats output unexpected: $_stats_out"
  fi
else
  fail "headway stats failed: $_stats_out"
fi

# ── 9. headway doctor ─────────────────────────────────────────────────────────

section "9. headway doctor"

if [[ "$_UP_OK" == "false" ]]; then
  echo "  (skipped — gateway not running)"
elif "$SYMLINK" doctor 2>&1; then
  ok "headway doctor passed"
else
  fail "headway doctor reported issues"
fi

# ── 10. headway down ──────────────────────────────────────────────────────────

section "10. headway down — stop stack"

if [[ "$_UP_OK" == "false" ]]; then
  echo "  (skipped — gateway was not running)"
elif "$SYMLINK" down 2>&1; then
  ok "headway down exited 0"
else
  fail "headway down failed"
fi

# Verify containers stopped
_running="$(docker ps --filter "name=litellm-gateway" --filter "name=headroom-gateway" --filter "name=headroom-bedrock-gateway" -q 2>/dev/null || true)"
if [[ -z "$_running" ]]; then
  ok "containers stopped (or never started)"
else
  fail "containers still running after headway down"
fi

# ── 11. headway cleanup data ──────────────────────────────────────────────────

section "11. headway cleanup data"

if "$SYMLINK" cleanup data --yes 2>&1; then
  ok "headway cleanup data exited 0"
else
  fail "headway cleanup data failed"
fi

_data_dir="$INSTALL_DIR/.data"
if [[ ! -d "$_data_dir" ]]; then
  ok ".data dir removed by cleanup"
else
  fail ".data dir still exists after cleanup data"
fi

# ── summary ───────────────────────────────────────────────────────────────────

echo
echo "=== E2E Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
