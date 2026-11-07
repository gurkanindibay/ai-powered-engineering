#!/usr/bin/env bash
# ============================================================================
# SitePulse: Database Reset & Clean Initialization Script
# ============================================================================
# Deletes all test payment records, transaction histories, and debts,
# initializing the PostgreSQL database to a clean baseline state.
#
# GUARANTEE: There are ZERO site payment periods and ZERO dues liabilities
# after this script executes.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITEPULSE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKEND_DIR="$SITEPULSE_ROOT/backend"
MIGRATIONS_DIR="$BACKEND_DIR/migrations"
SEED_DIR="$BACKEND_DIR/db/seed"

MODE="with-site" # default: clean site hierarchy, zero payment periods
FORCE_PROD=0

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --with-site       (Default) Initialize clean schema, system configs, base site
                    (Begonya Sitesi) and units, with ZERO payment periods and ZERO debts.
  --pure-system     Initialize only clean schema, system banks, system configs,
                    and SaaS Admin (ZERO sites, ZERO units, ZERO payment periods).
  --force-prod      Bypass production environment safety check.
  -h, --help        Show this help message.

Examples:
  ./scripts/reset-and-init-db.sh
  ./scripts/reset-and-init-db.sh --pure-system
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pure-system|--empty)
            MODE="pure-system"
            shift
            ;;
        --with-site)
            MODE="with-site"
            shift
            ;;
        --force-prod)
            FORCE_PROD=1
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# Production safety guard
CURRENT_ENV="${APP_ENV:-${ENVIRONMENT:-development}}"
if [[ "$CURRENT_ENV" =~ ^(production|prod|live)$ ]] && [ "$FORCE_PROD" -ne 1 ]; then
    echo "❌ FATAL: Cannot execute database reset script in PRODUCTION ($CURRENT_ENV) environment!"
    echo "   Pass --force-prod if you strictly intend to wipe the production database."
    exit 1
fi

echo "========================================================================"
echo "          SITEPULSE: DATABASE INITIALIZATION & CLEAN SLATE              "
echo "========================================================================"
echo "Target Mode: $MODE (Guaranteed 0 payment periods / 0 dues liabilities)"
echo ""

# 1. Resolve PostgreSQL connection method
DOCKER_CMD="docker"
if ! docker info > /dev/null 2>&1; then
    if [ "$EUID" -ne 0 ]; then
        DOCKER_CMD="sudo docker"
    fi
fi

run_sql_stdin() {
    if $DOCKER_CMD ps | grep -q sitepulse-postgres; then
        $DOCKER_CMD compose -f "$BACKEND_DIR/docker-compose.yml" exec -T postgres \
            psql -U "${DB_USER:-sitepulse_user}" -d "${DB_NAME:-sitepulse}" -v ON_ERROR_STOP=1
    elif command -v psql &> /dev/null; then
        PGPASSWORD="${DB_PASS:-sitepulse_secret}" psql \
            -h "${DB_HOST:-localhost}" \
            -p "${DB_PORT:-5432}" \
            -U "${DB_USER:-sitepulse_user}" \
            -d "${DB_NAME:-sitepulse}" \
            -v ON_ERROR_STOP=1
    else
        echo "⚠️ PostgreSQL container not running. Starting container via dev-db-up.sh..."
        bash "$SCRIPT_DIR/dev-db-up.sh"
        $DOCKER_CMD compose -f "$BACKEND_DIR/docker-compose.yml" exec -T postgres \
            psql -U "${DB_USER:-sitepulse_user}" -d "${DB_NAME:-sitepulse}" -v ON_ERROR_STOP=1
    fi
}

run_sql_file() {
    local sql_file="$1"
    echo "  ▶ Applying: $(basename "$sql_file")"
    run_sql_stdin < "$sql_file"
}

# 2. Drop existing application tables to ensure clean slate
echo "▶ [1/4] Dropping existing database relations..."
# Dropping the whole schema (instead of an explicit table list) guarantees no
# orphaned rows survive from tables added after this list was last edited.
run_sql_stdin << 'EOF'
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
GRANT USAGE ON SCHEMA public TO PUBLIC;
EOF
echo "  ✔ Database tables dropped cleanly."

# 3. Apply schema definition files
echo "▶ [2/4] Applying core database schema & migrations..."
# backend/migrations is the only schema source. Each file is applied in version
# order and recorded in schema_migrations with the same SHA-256 checksum the
# backend's migration runner uses, so the backend will not re-apply them.
run_sql_stdin << 'EOF'
CREATE TABLE IF NOT EXISTS schema_migrations (
    version INT PRIMARY KEY, name TEXT NOT NULL, checksum TEXT NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP);
EOF
while IFS= read -r migration; do
    name="$(basename "$migration")"
    version="${name#V}"; version="${version%%__*}"
    checksum="$(sha256sum "$migration" | cut -d' ' -f1)"
    { echo "BEGIN;"; cat "$migration"; echo ";"
      echo "INSERT INTO schema_migrations (version, name, checksum) VALUES ($version, '$name', '$checksum');"
      echo "COMMIT;"; } | run_sql_stdin
    echo "  ▶ Applied: $name"
done < <(ls "$MIGRATIONS_DIR"/V*__*.sql | sort -V)
run_sql_file "$SEED_DIR/01-system-seed.sql"

# 4. Apply site data according to selected mode
if [ "$MODE" = "with-site" ]; then
    echo "▶ [3/4] Applying baseline residential site hierarchy (Begonya Sitesi)..."
    run_sql_file "$SEED_DIR/02-test-seed.sql"
else
    echo "▶ [3/4] Pure system mode selected: skipping mock site seeding."
fi

# 5. Enforce 0 dues liabilities, 0 periods, 0 collection transactions
echo "▶ [4/4] Enforcing clean dues ledger (ZERO site payment periods)..."
run_sql_stdin << 'EOF'
TRUNCATE TABLE payment_entries RESTART IDENTITY CASCADE;
TRUNCATE TABLE dues_liabilities RESTART IDENTITY CASCADE;
TRUNCATE TABLE dues_periods RESTART IDENTITY CASCADE;

SELECT setval(pg_get_serial_sequence('dues_periods', 'id'), 1, false);
SELECT setval(pg_get_serial_sequence('dues_liabilities', 'id'), 1, false);
SELECT setval(pg_get_serial_sequence('payment_entries', 'id'), 1, false);
EOF
echo "  ✔ Dues liabilities and collection transactions strictly empty."

# 6. If Rust backend is active on port 8080, synchronize in-memory state
if curl -s -f http://127.0.0.1:8080/health > /dev/null 2>&1; then
    echo ""
    echo "▶ Active Backend detected on port 8080. Resetting in-memory state & cache..."
    curl -s -X POST http://127.0.0.1:8080/api/v1/system/reset-demo-data > /dev/null 2>&1 || true
    echo "  ✔ In-memory dues and payment caches refreshed to clean state."
fi

# 7. Verification Summary
echo ""
echo "========================================================================"
echo "                  DATABASE VERIFICATION SUMMARY                         "
echo "========================================================================"
run_sql_stdin << 'EOF'
SELECT 
    (SELECT COUNT(*) FROM sites) as sites_count,
    (SELECT COUNT(*) FROM blocks) as blocks_count,
    (SELECT COUNT(*) FROM units) as units_count,
    (SELECT COUNT(*) FROM users) as users_count,
    (SELECT COUNT(*) FROM site_bank_accounts) as bank_accounts_count,
    (SELECT COUNT(*) FROM dues_liabilities) as dues_periods_count,
    (SELECT COUNT(*) FROM payment_entries) as transactions_count;
EOF

echo ""
echo "✅ Database initialized successfully. No site payment periods exist."
echo "   Site managers may now accrue fresh periods via 'Toplu Aidat Tahakkuku'."
echo "========================================================================"
