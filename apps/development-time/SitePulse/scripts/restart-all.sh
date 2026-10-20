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

# 2. Start PostgreSQL 16 & Adminer database containers
echo "▶ Starting PostgreSQL 16 Database & Adminer Web Client..."
bash "$SCRIPT_DIR/dev-db-up.sh" || {
    echo "  [WARN] Could not auto-start database containers. You can run 'sudo ./dev-db-up.sh' manually."
}

# 3. Start Prototype Web Server on port 9091 in background
echo "▶ Starting Prototype server on port 9091 (background)..."
nohup python3 -m http.server 9091 --directory "$SITEPULSE_ROOT" > /tmp/sitepulse-prototype.log 2>&1 &
disown 2>/dev/null || true
echo "  [OK] Prototype server active: http://localhost:9091/mvp_ux_prototype.html"
echo "  [OK] Bank & FAST Simulator:   http://localhost:9091/bank_transfer_simulator.html"

# 4. Start Rust Backend on port 8080 in background
echo "▶ Starting Rust Backend API on port 8080 (background)..."
nohup bash "$SCRIPT_DIR/run-backend.sh" > /tmp/sitepulse-backend.log 2>&1 &
disown 2>/dev/null || true
echo "  [OK] Backend active: http://localhost:8080/api/v1/health"
sleep 2

if [ "${SEED_DEMO_TRANSACTIONS:-false}" = "true" ]; then
    echo "▶ Seeding settled Virtual IBAN demo state (SEED_DEMO_TRANSACTIONS=true)..."
    bash "$SCRIPT_DIR/test-virtual-iban-e2e.sh" > /dev/null 2>&1 || true
    echo "  [OK] Demo settlement & advance balance seeded."
fi

# 5. Launch Flutter Web in foreground
echo "▶ Starting Flutter client on port 9090..."
exec "$SCRIPT_DIR/run-flutter.sh" web
