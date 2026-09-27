#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITEPULSE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CARGO_BIN="${CARGO_HOME:-$HOME/.cargo}/bin/cargo"

if [ ! -x "$CARGO_BIN" ] && command -v cargo &> /dev/null; then
    CARGO_BIN="cargo"
fi

if [ ! -x "$CARGO_BIN" ] && ! command -v cargo &> /dev/null; then
    echo "Error: Cargo not found. Please install Rust and Cargo or verify ~/.cargo/bin is in PATH."
    exit 1
fi

echo "========================================================================"
echo "               SITEPULSE RUST HIGH-PERFORMANCE BACKEND                  "
echo "         Axum 0.7 + Tokio + rust_decimal Financial Engine               "
echo "========================================================================"
echo "Port: 8080 (Listening on 0.0.0.0:8080)"
echo "Endpoints:"
echo "  - GET  /api/v1/health"
echo "  - POST /api/v1/saas/tenants"
echo "  - GET  /api/v1/saas/tenants"
echo "  - POST /api/v1/site/home-owners"
echo "  - POST /api/v1/site/invitations/site"
echo "  - POST /api/v1/site/invitations/unit"
echo "  - GET  /api/v1/site/registration-requests"
echo "  - POST /api/v1/site/registration-requests/:id/approve"
echo "  - POST /api/v1/site/registration-requests/:id/reject"
echo "  - POST /api/v1/auth/login"
echo "  - POST /api/v1/auth/google"
echo "========================================================================"

cd "$SITEPULSE_ROOT/backend"
"$CARGO_BIN" run --release
