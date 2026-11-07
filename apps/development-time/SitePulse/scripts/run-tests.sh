#!/usr/bin/env bash
# Thin wrapper: the verification logic lives in scripts/run_tests.py.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/run_tests.py" "$@"
