#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT=8080

echo "========================================================================"
echo "                 RESTARTING SITEPULSE RUST BACKEND                      "
echo "========================================================================"

# Terminate any existing process on port 8080
if lsof -ti :$PORT > /dev/null 2>&1; then
    echo "▶ Stopping existing process on port $PORT..."
    fuser -k -9 ${PORT}/tcp > /dev/null 2>&1 || true
    sleep 1
    echo "  [OK] Port $PORT freed."
else
    echo "  [OK] Port $PORT is clean."
fi

echo "▶ Launching Rust backend service..."
exec "$SCRIPT_DIR/run-backend.sh"
