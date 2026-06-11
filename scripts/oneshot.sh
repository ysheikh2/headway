#!/usr/bin/env bash
# oneshot.sh — One-shot setup for new users.
#
# Usage:
#   ./scripts/oneshot.sh [--aws-profile <profile>]

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_PROFILE_NAME="d2i_stg"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --aws-profile) AWS_PROFILE_NAME="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

echo "=== One-Shot Bootstrap (Kilo + Gateway) ==="
echo

bash "$DIR/scripts/setup-kilo.sh"
echo

bash "$DIR/scripts/start.sh" --aws-profile "$AWS_PROFILE_NAME"
echo

bash "$DIR/scripts/test.sh"
echo

bash "$DIR/scripts/status.sh"
echo

echo "=== Complete ==="
echo "Kilo providers now point to: http://127.0.0.1:4000/v1"
