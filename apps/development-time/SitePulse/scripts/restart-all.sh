#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITEPULSE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "========================================================================"
echo "                 RESTARTING FULL SITEPULSE STACK                        "
echo "========================================================================"

# 1. Clean stale processes on ports 8080, 9090, 9091
echo "▶ Freeing development ports (8080: Backend, 9090: Flutter, 9091: Prototype)..."
fuser -k -9 8080/tcp > /dev/null 2>&1 || true
fuser -k -9 9090/tcp > /dev/null 2>&1 || true
fuser -k -9 9091/tcp > /dev/null 2>&1 || true
sleep 1
echo "  [OK] All ports freed."

# 2. Start Prototype Web Server on port 9091 in background
echo "▶ Starting Prototype server on port 9091 (background)..."
nohup python3 -m http.server 9091 --directory "$SITEPULSE_ROOT" > /tmp/sitepulse-prototype.log 2>&1 &
disown 2>/dev/null || true
echo "  [OK] Prototype server active: http://localhost:9091/mvp_ux_prototype.html"

# 3. Start Rust Backend on port 8080 in background
echo "▶ Starting Rust Backend API on port 8080 (background)..."
nohup bash "$SCRIPT_DIR/run-backend.sh" > /tmp/sitepulse-backend.log 2>&1 &
disown 2>/dev/null || true
echo "  [OK] Backend active: http://localhost:8080/api/v1/health"
sleep 2

# 4. Launch Flutter Web in foreground
echo "▶ Starting Flutter client on port 9090..."
exec "$SCRIPT_DIR/run-flutter.sh" web
