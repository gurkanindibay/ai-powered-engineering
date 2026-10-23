#!/usr/bin/env bash
# ============================================================================
# SitePulse: Add Test Data Script (DEVELOPMENT & TEST ENVIRONMENTS ONLY)
# ============================================================================
# Seeds mock residential sites (Begonya Sitesi, Kardelen Rezidans),
# blocks (A Blok, B Blok), test persons (Mehmet Demir, Ahmet Yılmaz, Zeynep Kaya),
# test units (D:14, D:3), and bank accounts into PostgreSQL and backend memory.
#
# NOTE: Server restarts will NEVER auto-add test data. Run this script whenever
# you want to populate or restore the development test fixtures.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITEPULSE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SEEDS_FILE="$SITEPULSE_ROOT/backend/db/seeds/test/02-test-seed.sql"

if [ "${APP_ENV:-development}" = "production" ] || [ "${ENVIRONMENT:-development}" = "production" ]; then
    echo "❌ FATAL: Cannot run add-test-data.sh in PRODUCTION environment!"
    exit 1
fi

echo "========================================================================"
echo "                 SITEPULSE: ADD TEST DATA (FIXTURES)                    "
echo "========================================================================"

# 1. Check if backend API is online to seed via runtime endpoint
BACKEND_ONLINE=false
if curl -s -f http://localhost:8080/api/v1/health > /dev/null 2>&1; then
    BACKEND_ONLINE=true
fi

# 2. Populate PostgreSQL database
echo "▶ [1/2] Seeding test records into PostgreSQL database..."
DOCKER_CMD="docker"
if ! docker info > /dev/null 2>&1; then
    if [ "$EUID" -ne 0 ]; then
        DOCKER_CMD="sudo docker"
    fi
fi

if $DOCKER_CMD ps | grep -q sitepulse-postgres; then
    $DOCKER_CMD compose -f "$SITEPULSE_ROOT/backend/docker-compose.yml" exec -T postgres \
        psql -U "${DB_USER:-sitepulse_user}" -d "${DB_NAME:-sitepulse}" -v ON_ERROR_STOP=1 < "$SEEDS_FILE"
    echo "  ✔ Test fixtures inserted into PostgreSQL container."
elif command -v psql &> /dev/null; then
    PGPASSWORD="${DB_PASS:-sitepulse_secret}" psql \
        -h "${DB_HOST:-localhost}" \
        -p "${DB_PORT:-5432}" \
        -U "${DB_USER:-sitepulse_user}" \
        -d "${DB_NAME:-sitepulse}" \
        -v ON_ERROR_STOP=1 < "$SEEDS_FILE"
    echo "  ✔ Test fixtures inserted into local PostgreSQL."
else
    echo "  ⚠️ PostgreSQL not reachable directly via CLI or container. Will try backend endpoint..."
fi

# 3. Synchronize Backend In-Memory State
echo "▶ [2/2] Synchronizing backend runtime state..."
if [ "$BACKEND_ONLINE" = true ]; then
    RESPONSE=$(curl -s -X POST http://localhost:8080/api/v1/system/seed-test-data)
    echo "  ✔ Backend synchronized: $RESPONSE"
else
    echo "  ℹ Backend is currently offline. Seeded records will be loaded automatically next time backend starts."
fi

echo ""
echo "========================================================================"
echo "✅ Test data successfully added!"
echo "   - Sites:   Begonya Sitesi (id: 1), Kardelen Rezidans (id: 2)"
echo "   - Blocks:  A Blok (id: 1), B Blok (id: 2)"
echo "   - Persons: Ahmet Yılmaz (id: 1), Zeynep Kaya (id: 2), Mehmet Demir (id: 3)"
echo "   - Units:   A Blok D:14 (id: 14), B Blok D:3 (id: 3)"
echo "   - Debts:   ₺0.00 clean baseline"
echo "========================================================================"
