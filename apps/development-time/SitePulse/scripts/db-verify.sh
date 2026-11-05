#!/usr/bin/env bash
# ==============================================================================
# SitePulse Database Verification & Inspection Tool
# Usage:
#   ./scripts/db-verify.sh query "SELECT * FROM persons;"
#   ./scripts/db-verify.sh query-json "SELECT * FROM units;"
#   ./scripts/db-verify.sh tables
#   ./scripts/db-verify.sh inspect <table_name>
#   ./scripts/db-verify.sh verify [site_id]
#   ./scripts/db-verify.sh residents [site_id]
# ==============================================================================
set -eo pipefail

DB_CONTAINER="${DB_CONTAINER:-sitepulse-postgres}"
DB_NAME="${DB_NAME:-sitepulse}"
DB_USER="${DB_USER:-sitepulse_user}"
DB_PASS="${DB_PASS:-sitepulse_secret}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"

run_sql() {
    local sql="$1"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${DB_CONTAINER}$"; then
        docker exec -i "${DB_CONTAINER}" psql -U "${DB_USER}" -d "${DB_NAME}" -c "${sql}"
    elif command -v psql >/dev/null 2>&1; then
        PGPASSWORD="${DB_PASS}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "${sql}"
    else
        echo "Error: Neither active docker container '${DB_CONTAINER}' nor local 'psql' client found." >&2
        exit 1
    fi
}

run_sql_json() {
    local sql="$1"
    local json_sql="SELECT json_agg(t) FROM (${sql}) t;"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${DB_CONTAINER}$"; then
        docker exec -i "${DB_CONTAINER}" psql -U "${DB_USER}" -d "${DB_NAME}" -t -A -c "${json_sql}"
    elif command -v psql >/dev/null 2>&1; then
        PGPASSWORD="${DB_PASS}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -A -c "${json_sql}"
    else
        echo "Error: Neither active docker container '${DB_CONTAINER}' nor local 'psql' client found." >&2
        exit 1
    fi
}

do_tables() {
    echo "================================================================="
    echo "              DATABASE TABLES & RECORD COUNTS                    "
    echo "================================================================="
    run_sql "
        SELECT 
            schemaname || '.' || relname AS table_name,
            n_live_tup AS estimated_rows
        FROM pg_stat_user_tables
        ORDER BY relname;
    "
}

do_inspect() {
    local table_name="${1:-}"
    if [ -z "${table_name}" ]; then
        echo "Usage: $0 inspect <table_name>" >&2
        exit 1
    fi
    echo "================================================================="
    echo " SCHEMA: ${table_name}"
    echo "================================================================="
    run_sql "
        SELECT 
            column_name, 
            data_type, 
            is_nullable, 
            column_default 
        FROM information_schema.columns 
        WHERE table_name = '${table_name}' 
        ORDER BY ordinal_position;
    "
    echo "================================================================="
    echo " SAMPLE ROWS (Limit 5): ${table_name}"
    echo "================================================================="
    run_sql "SELECT * FROM ${table_name} LIMIT 5;"
}

do_residents() {
    local site_id="${1:-1}"
    echo "================================================================="
    echo " RESIDENTS & HOME OWNERS DIRECTORY (Site ID: ${site_id})"
    echo "================================================================="
    run_sql "
        SELECT 
            COALESCE(u.id::text, 'p-' || p.id::text) AS unit_or_ref,
            COALESCE(b.block_name, 'A Blok') AS block,
            COALESCE(u.unit_number, 0) AS unit_no,
            COALESCE(u.floor, 1) AS floor,
            p.full_name,
            p.email,
            p.phone,
            p.person_type,
            CASE 
                WHEN u.tenant_person_id = p.id THEN 'Sakin (Kiracı)'
                WHEN u.owner_person_id = p.id AND u.tenant_person_id IS NULL THEN 'Malik (Oturuyor)'
                WHEN u.owner_person_id = p.id THEN 'Malik (Ev Sahibi)'
                WHEN p.person_type IN ('HOME_RESIDENT', 'KAT_SAKINI', 'TENANT', 'RESIDENT') THEN 'Sakin'
                ELSE 'Malik'
            END AS role_status
        FROM persons p
        LEFT JOIN units u ON (u.owner_person_id = p.id OR u.tenant_person_id = p.id)
        LEFT JOIN blocks b ON u.block_id = b.id
        LEFT JOIN users usr ON LOWER(usr.email) = LOWER(p.email)
        WHERE (u.site_id::text = '${site_id}' OR (u.site_id IS NULL AND (usr.site_id::text = '${site_id}' OR usr.site_id IS NULL)))
        ORDER BY b.block_name NULLS LAST, u.unit_number NULLS LAST, p.full_name;
    "
}

do_verify() {
    local site_id="${1:-1}"
    echo "================================================================="
    echo " SITEPULSE DATABASE HEALTH & INTEGRITY REPORT (Site ID: ${site_id})"
    echo "================================================================="
    echo ""
    echo "1. Core Entity Counts:"
    run_sql "
        SELECT 
            (SELECT count(*) FROM sites) AS sites_count,
            (SELECT count(*) FROM blocks WHERE site_id::text = '${site_id}') AS blocks_count,
            (SELECT count(*) FROM units WHERE site_id::text = '${site_id}') AS units_count,
            (SELECT count(*) FROM persons) AS persons_count,
            (SELECT count(*) FROM users WHERE site_id::text = '${site_id}' OR site_id IS NULL) AS users_count,
            (SELECT count(*) FROM dues_periods WHERE site_id::text = '${site_id}') AS periods_count,
            (SELECT count(*) FROM dues_liabilities dl JOIN units u ON dl.unit_id = u.id WHERE u.site_id::text = '${site_id}') AS dues_count,
            (SELECT count(*) FROM collection_transactions ct JOIN units u ON ct.unit_id = u.id WHERE u.site_id::text = '${site_id}') AS tx_count;
    "

    echo "2. Financial Balance Summary (Site ID: ${site_id}):"
    run_sql "
        SELECT 
            COALESCE(SUM(principal_amount), 0.00) AS total_accrued_dues,
            COALESCE(SUM(paid_amount), 0.00) AS total_paid_amount,
            COALESCE(SUM(delay_penalty), 0.00) AS total_delay_penalties,
            COUNT(CASE WHEN status = 'PAID' THEN 1 END) AS paid_dues_count,
            COUNT(CASE WHEN status = 'OVERDUE' THEN 1 END) AS overdue_dues_count,
            COUNT(CASE WHEN status = 'PENDING' THEN 1 END) AS pending_dues_count
        FROM dues_liabilities dl
        JOIN units u ON dl.unit_id = u.id
        WHERE u.site_id::text = '${site_id}';
    "

    echo "3. Data Integrity & Orphan Checks:"
    run_sql "
        SELECT 
            (SELECT count(*) FROM units WHERE block_id NOT IN (SELECT id FROM blocks)) AS orphaned_units_block,
            (SELECT count(*) FROM units WHERE site_id NOT IN (SELECT id FROM sites)) AS orphaned_units_site,
            (SELECT count(*) FROM dues_liabilities WHERE unit_id NOT IN (SELECT id FROM units)) AS orphaned_dues_unit,
            (SELECT count(*) FROM collection_transactions WHERE unit_id IS NOT NULL AND unit_id NOT IN (SELECT id FROM units)) AS orphaned_tx_unit,
            (SELECT count(*) FROM unit_members WHERE unit_id NOT IN (SELECT id::text FROM units) AND unit_id NOT LIKE 'd-%') AS orphaned_members;
    "

    echo "4. Virtual IBAN Allocations (Site ID: ${site_id}):"
    run_sql "
        SELECT 
            u.id, 
            b.block_name, 
            u.unit_number, 
            u.virtual_iban,
            po.full_name AS owner_name,
            pt.full_name AS tenant_name
        FROM units u
        JOIN blocks b ON u.block_id = b.id
        LEFT JOIN persons po ON u.owner_person_id = po.id
        LEFT JOIN persons pt ON u.tenant_person_id = pt.id
        WHERE u.site_id::text = '${site_id}'
        ORDER BY b.block_name, u.unit_number;
    "
}

cmd="${1:-verify}"
shift || true

case "${cmd}" in
    query)
        if [ -z "${1:-}" ]; then
            echo "Usage: $0 query \"<SQL_STATEMENT>\"" >&2
            exit 1
        fi
        run_sql "$1"
        ;;
    query-json)
        if [ -z "${1:-}" ]; then
            echo "Usage: $0 query-json \"<SQL_STATEMENT>\"" >&2
            exit 1
        fi
        run_sql_json "$1"
        ;;
    tables)
        do_tables
        ;;
    inspect)
        do_inspect "${1:-}"
        ;;
    residents)
        do_residents "${1:-1}"
        ;;
    verify)
        do_verify "${1:-1}"
        ;;
    *)
        echo "Usage: $0 {query <sql>|query-json <sql>|tables|inspect <table>|residents [site_id]|verify [site_id]}" >&2
        exit 1
        ;;
esac
