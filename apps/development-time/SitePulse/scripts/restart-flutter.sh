#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITEPULSE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PORT=9090
TARGET="${1:-web}"

echo "========================================================================"
echo "                   RESTARTING SITEPULSE FLUTTER APP                     "
echo "========================================================================"

# 1. Terminate any existing process on port 9090
if lsof -ti :$PORT > /dev/null 2>&1; then
    echo "▶ Stopping existing process on port $PORT..."
    fuser -k -9 ${PORT}/tcp > /dev/null 2>&1 || true
    sleep 1
    echo "  [OK] Port $PORT freed."
else
    echo "  [OK] Port $PORT is clean."
fi

# 2. Clean stale lockfiles if any
rm -f "$SITEPULSE_ROOT/flutter/.dart_tool/package_config.json.lock" 2>/dev/null || true

# 3. Launch Flutter
echo "▶ Launching Flutter client (Target: $TARGET)..."
exec "$SCRIPT_DIR/run-flutter.sh" "$@"
