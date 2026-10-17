#!/usr/bin/env bash
# ============================================================================
# SitePulse Test Database Seeding Script (DEVELOPMENT & TEST ENVIRONMENTS ONLY)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITEPULSE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SEEDS_FILE="$SITEPULSE_ROOT/backend/db/seeds/test/02-test-seed.sql"

if [ "${APP_ENV:-development}" = "production" ] || [ "${ENVIRONMENT:-development}" = "production" ]; then
    echo "❌ FATAL: Cannot run seed-test-database.sh in PRODUCTION environment!"
    exit 1
fi

echo "🌱 Loading test fixtures into development PostgreSQL database..."
if docker ps | grep -q sitepulse-postgres; then
    docker compose -f "$SITEPULSE_ROOT/backend/docker-compose.yml" exec -T postgres \
        psql -U sitepulse_user -d sitepulse < "$SEEDS_FILE"
    echo "✅ Test database fixtures loaded successfully into PostgreSQL container."
elif command -v psql &> /dev/null; then
    PGPASSWORD="${DB_PASS:-sitepulse_secret}" psql \
        -h "${DB_HOST:-localhost}" \
        -p "${DB_PORT:-5432}" \
        -U "${DB_USER:-sitepulse_user}" \
        -d "${DB_NAME:-sitepulse}" < "$SEEDS_FILE"
    echo "✅ Test database fixtures loaded successfully into local PostgreSQL."
else
    echo "⚠️ PostgreSQL container not running. Start it with scripts/dev-db-up.sh"
    exit 1
fi
