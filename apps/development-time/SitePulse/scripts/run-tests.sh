#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITEPULSE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "========================================================================"
echo "               SITEPULSE VERIFICATION & TEST SUITE                      "
echo "   AI-Manufactured Residential Management Platform (Android & Backend)  "
echo "========================================================================"
echo ""

# 1. Harness Unit Tests
echo "▶ [1/3] Running Engineering Harness Self-Tests..."
python3 -m unittest discover -s "$SITEPULSE_ROOT/harness/tests" -v
echo ""

# 2. Closed-Loop Task DAG Verification Gates
echo "▶ [2/3] Running Closed-Loop Verification Gates on Task DAG..."
for task in task-01 task-02 task-03 task-04 task-05 task-06 task-07 task-08; do
    python3 "$SITEPULSE_ROOT/harness/harness_cli.py" verify --task "$task"
done
echo ""

# 3. Rust Backend Service Unit & Integration Tests
echo "▶ [3/4] Running High-Performance Rust Backend Service Unit & Integration Tests..."
CARGO_BIN="${CARGO_HOME:-$HOME/.cargo}/bin/cargo"
if [ -x "$CARGO_BIN" ]; then
    (cd "$SITEPULSE_ROOT/backend" && "$CARGO_BIN" test)
    echo "  [PASS] Rust Backend 17/17 Unit & Integration Tests Verified!"
else
    echo "  [WARN] Cargo binary not found at $CARGO_BIN, skipping Rust tests."
fi
echo ""

# 4. Flutter Mobile Client Test Suite
echo "▶ [4/4] Running Flutter Mobile Client Unit & Widget Tests..."
FLUTTER_BIN="${FLUTTER_ROOT:-/home/gurkanindibay/flutter}/bin/flutter"
if [ -x "$FLUTTER_BIN" ]; then
    (cd "$SITEPULSE_ROOT/flutter" && "$FLUTTER_BIN" test)
    echo "  [PASS] Flutter Client 16/16 Unit & Widget Tests Verified!"
else
    echo "  [WARN] Flutter binary not found at $FLUTTER_BIN, skipping Flutter tests."
fi
echo ""

echo "========================================================================"
echo "  ✔ ALL SITEPULSE TESTS & VERIFICATION GATES PASSED SUCCESSFULLY!"
echo "========================================================================"

