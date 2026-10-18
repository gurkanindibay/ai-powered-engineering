#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITEPULSE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FLUTTER_BIN="${FLUTTER_ROOT:-/home/gurkanindibay/flutter}/bin/flutter"
CARGO_BIN="${CARGO_HOME:-$HOME/.cargo}/bin/cargo"

if [ ! -x "$CARGO_BIN" ] && command -v cargo &> /dev/null; then
    CARGO_BIN="cargo"
fi

echo "========================================================================"
echo "          SITEPULSE FULL-STACK SERVICE MANAGER (RESTART ALL)            "
echo "========================================================================"

# 1. Stop existing services on ports 8080, 9090, 9091
echo "▶ [1/4] Terminating existing services on ports 8080, 9090, 9091..."
fuser -k -9 8080/tcp > /dev/null 2>&1 || true
fuser -k -9 9090/tcp > /dev/null 2>&1 || true
fuser -k -9 9091/tcp > /dev/null 2>&1 || true
rm -f "$SITEPULSE_ROOT/flutter/.dart_tool/package_config.json.lock" 2>/dev/null || true
sleep 1
echo "  ✔ Development ports freed."

# 2. Start PostgreSQL 16 & Adminer database containers
echo "▶ [2/5] Starting PostgreSQL 16 Database & Adminer Web Client..."
bash "$SCRIPT_DIR/dev-db-up.sh" || {
    echo "  [WARN] Could not auto-start database containers. You can run 'sudo ./dev-db-up.sh' manually."
}

# 3. Launch High-Performance Rust Backend Service (Axum 0.7 + Tokio)
echo "▶ [3/5] Starting Rust Backend API on port 8080..."
cd "$SITEPULSE_ROOT/backend"
if [ -f ".env" ]; then
    set -a
    source .env
    set +a
fi
export SITEPULSE_SEED_TEST_DATA=true
nohup "$CARGO_BIN" run --release > /tmp/sitepulse-backend.log 2>&1 &
BACKEND_PID=$!
disown $BACKEND_PID 2>/dev/null || true

echo -n "  Waiting for backend health check..."
BACKEND_READY=0
for i in {1..20}; do
    if curl -s -f http://127.0.0.1:8080/health > /dev/null 2>&1; then
        BACKEND_READY=1
        break
    fi
    echo -n "."
    sleep 0.5
done

if [ "$BACKEND_READY" -eq 1 ]; then
    echo " [ONLINE] (PID: $BACKEND_PID)"
else
    echo " [WARN: check /tmp/sitepulse-backend.log]"
fi

# 3. Launch Prototype Server (Port 9091)
echo "▶ [3/4] Starting Interactive Prototype Server on port 9091..."
nohup python3 -m http.server 9091 --directory "$SITEPULSE_ROOT" > /tmp/sitepulse-prototype.log 2>&1 &
PROTO_PID=$!
disown $PROTO_PID 2>/dev/null || true
echo "  ✔ Prototype Server online (PID: $PROTO_PID)"

# 4. Launch Flutter Native Web App (Port 9090)
echo "▶ [4/4] Starting Flutter Web Client on port 9090..."
cd "$SITEPULSE_ROOT/flutter"
nohup "$FLUTTER_BIN" run -d web-server --web-port 9090 --web-hostname 0.0.0.0 < /dev/null > /tmp/sitepulse-flutter.log 2>&1 &
FLUTTER_PID=$!
disown $FLUTTER_PID 2>/dev/null || true

echo -n "  Waiting for Flutter Web server..."
FLUTTER_READY=0
for i in {1..30}; do
    if curl -s -f http://127.0.0.1:9090/index.html > /dev/null 2>&1 || curl -s -f http://127.0.0.1:9090/ > /dev/null 2>&1; then
        FLUTTER_READY=1
        break
    fi
    echo -n "."
    sleep 1
done

if [ "$FLUTTER_READY" -eq 1 ]; then
    echo " [ONLINE] (PID: $FLUTTER_PID)"
else
    echo " [STARTING in background - see /tmp/sitepulse-flutter.log]"
fi

echo ""
echo "========================================================================"
echo "                  SITEPULSE SERVICES RUNNING                            "
echo "========================================================================"
echo "  ● Backend API (Rust Axum):    http://localhost:8080/api/v1/health"
echo "  ● Flutter Web Client:         http://localhost:9090/"
echo "  ● Papara UX Prototype:        http://localhost:9091/mvp_ux_prototype.html"
echo "  ● Bank FAST & IBAN Simulator: http://localhost:9091/bank_transfer_simulator.html"
echo "  ● UX Spec & Gherkin Review:   http://localhost:9091/ux_prototype_review.html"
echo "------------------------------------------------------------------------"
echo "  Logs:"
echo "    - Backend:   tail -f /tmp/sitepulse-backend.log"
echo "    - Flutter:   tail -f /tmp/sitepulse-flutter.log"
echo "    - Prototype: tail -f /tmp/sitepulse-prototype.log"
echo "========================================================================"
echo ""
echo "▶ QUICK TERMINAL TESTS:"
echo "  1. Test backend health:       curl -s http://localhost:8080/api/v1/health | jq ."
echo "  2. Test resident dashboard:   curl -s http://localhost:8080/api/v1/residents/1/dashboard | jq ."
echo "  3. Test SaaS tenant stats:    curl -s http://localhost:8080/api/v1/saas/stats | jq ."
echo "  4. Test Flutter web status:   curl -I http://localhost:9090/"
echo "  5. Run automated test runner: ./apps/development-time/SitePulse/scripts/test-terminal.sh"
echo "========================================================================"

# If --test flag was passed, run the terminal test suite immediately
if [ "$1" == "--test" ]; then
    echo ""
    "$SCRIPT_DIR/test-terminal.sh"
fi
