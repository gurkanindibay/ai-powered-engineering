#!/usr/bin/env python3
"""SitePulse Schema Integrity Gate.

Replays both schema sources (`backend/db/init/00-*.sql` and `backend/migrations/V*.sql`)
into throwaway databases, asserts they produce the same schema, and asserts that the
integrity constraints reject the data they are meant to reject.

This guards against the historical failure mode where the docker init scripts, the
versioned migrations and the Rust bootstrap (src/db.rs) drifted apart.

Usage:
    python3 scripts/schema_integrity_check.py
    python3 scripts/schema_integrity_check.py --json
"""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys

BACKEND = pathlib.Path(__file__).resolve().parent.parent / "backend"
INIT_DIR = BACKEND / "db" / "init"
MIGRATIONS_DIR = BACKEND / "migrations"
# db/init is the single editable source; the versioned migrations are generated
# from it so the two trees cannot drift.
SYNC_MAP = {
    "00-01-init-schema.sql": "V1__init_schema.sql",
    "00-02-saas-multi-tenancy.sql": "V2__saas_multi_tenancy.sql",
    "00-03-auth-and-permission-providers.sql": "V3__auth_and_permission_providers.sql",
    "00-04-site-bank-account.sql": "V4__site_bank_account.sql",
    "00-05-payment-tracking-and-receipts.sql": "V5__payment_tracking_and_receipts.sql",
    "00-06-capital-expenditure-and-fixtures.sql": "V6__capital_expenditure_and_fixtures.sql",
    "00-07-viable-occupancy-ownership-and-identity.sql": "V7__viable_occupancy_ownership_and_identity.sql",
    "00-08-referential-and-financial-integrity.sql": "V9__referential_and_financial_integrity.sql",
    "00-09-ledger-and-referential-integrity.sql": "V10__ledger_and_referential_integrity.sql",
    "00-10-consolidate-household-members.sql": "V11__consolidate_household_members.sql",
    "00-11-financial-and-tenancy-remediation.sql": "V12__financial_and_tenancy_remediation.sql",
}

CONTAINER = "sitepulse-postgres"
DB_USER = "sitepulse_user"
ADMIN_DB = "postgres"

SCHEMA_DUMP = """
SELECT 'COLUMN|' || table_name || '|' || column_name || '|' || data_type || '|' ||
       coalesce(character_maximum_length::text, '') || '|' || is_nullable || '|' ||
       coalesce(column_default, '')
FROM information_schema.columns WHERE table_schema = 'public'
UNION ALL
SELECT 'CONSTRAINT|' || conrelid::regclass || '|' || conname || '|' || pg_get_constraintdef(oid)
FROM pg_constraint WHERE connamespace = 'public'::regnamespace
UNION ALL
SELECT 'INDEX|' || tablename || '|' || indexname || '|' || regexp_replace(indexdef, '^.*USING ', '')
FROM pg_indexes WHERE schemaname = 'public'
ORDER BY 1
"""

# Each entry must be rejected by the schema.
NEGATIVE_CASES = [
    (
        "person_type domain",
        "INSERT INTO persons (full_name, person_type) VALUES ('X', 'KAT_MALIKI')",
    ),
    (
        "dues expense_type domain",
        """INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, expense_type)
           SELECT id, 'P', 10, CURRENT_DATE, 'RANDOM' FROM units LIMIT 1""",
    ),
    (
        "unit site must match block site",
        """INSERT INTO units (block_id, site_id, unit_number, floor)
           SELECT b.id, b.site_id + 1, 9001, 1 FROM blocks b LIMIT 1""",
    ),
    (
        "active occupancy cannot be ended",
        """INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, end_date, is_active)
           SELECT u.id, p.id, 'OWNER', CURRENT_DATE - 10, CURRENT_DATE, TRUE
           FROM units u, persons p LIMIT 1""",
    ),
    (
        "liability cannot be overpaid",
        """INSERT INTO dues_liabilities (unit_id, period, principal_amount, paid_amount, due_date)
           SELECT id, 'P-OVERPAY', 100, 150, CURRENT_DATE FROM units LIMIT 1""",
    ),
    (
        "duplicate capital installment",
        """INSERT INTO capital_projects (site_id, title, category, total_budget, target_start_date)
           VALUES (1, 'T', 'OTHER', 100, CURRENT_DATE);
           INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, expense_type,
                                         capital_project_id, installment_number)
           SELECT u.id, 'C', 10, CURRENT_DATE, 'CAPITAL_DUES', cp.id, 1 FROM units u, capital_projects cp;
           INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, expense_type,
                                         capital_project_id, installment_number)
           SELECT u.id, 'C', 10, CURRENT_DATE, 'CAPITAL_DUES', cp.id, 1 FROM units u, capital_projects cp;""",
    ),
    (
        "receipt allocation must equal total",
        """INSERT INTO payment_receipts (site_id, unit_id, receipt_number, sequence_number, payer_name,
                                        payer_role, total_amount, payment_channel, verification_hash)
           VALUES ('1', '1', 'R-1', 1, 'P', 'OWNER', 100, 'MANUAL_CASH', 'h')""",
    ),
    (
        "receipt sequence unique per site",
        """INSERT INTO payment_receipts (site_id, unit_id, receipt_number, sequence_number, payer_name,
                                        payer_role, total_amount, allocated_principal, payment_channel, verification_hash)
           VALUES ('1', '1', 'R-2', 7, 'P', 'OWNER', 10, 10, 'MANUAL_CASH', 'h');
           INSERT INTO payment_receipts (site_id, unit_id, receipt_number, sequence_number, payer_name,
                                        payer_role, total_amount, allocated_principal, payment_channel, verification_hash)
           VALUES ('1', '1', 'R-3', 7, 'P', 'OWNER', 10, 10, 'MANUAL_CASH', 'h');""",
    ),
    (
        "bank IBAN format",
        """INSERT INTO site_bank_accounts (site_id, bank_code, bank_name, iban, account_holder, statement_format)
           SELECT id, 'ZIRAAT', 'Ziraat', 'not-an-iban', 'Site', 'EXCEL' FROM sites LIMIT 1""",
    ),
    (
        "one active bank account per site",
        """INSERT INTO site_bank_accounts (site_id, bank_code, bank_name, iban, account_holder, statement_format, is_active)
           SELECT id, 'ZIRAAT', 'Ziraat', 'TR330006100519786457841326', 'Site', 'EXCEL', TRUE FROM sites LIMIT 1;
           INSERT INTO site_bank_accounts (site_id, bank_code, bank_name, iban, account_holder, statement_format, is_active)
           SELECT id, 'AKBANK', 'Akbank', 'TR330006100519786457841327', 'Site', 'EXCEL', TRUE FROM sites LIMIT 1""",
    ),
    (
        "payment_entries rejects phantom unit",
        "INSERT INTO payment_entries (site_id, unit_id, payer_name, amount, payment_channel) VALUES (1, 999999, 'X', 10, 'CASH')",
    ),
    (
        "advance_balances rejects phantom unit",
        "INSERT INTO advance_balances (unit_id, balance) VALUES (999999, 10)",
    ),
    (
        "capital_projects rejects phantom site",
        "INSERT INTO capital_projects (site_id, title, category, total_budget, target_start_date) VALUES (999999, 'T', 'OTHER', 100, CURRENT_DATE)",
    ),
    (
        "capital dues cannot be debtor_type TENANT",
        """INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, expense_type, debtor_type)
           SELECT id, 'P-CAPITAL', 100, CURRENT_DATE, 'CAPITAL_DUES', 'TENANT' FROM units LIMIT 1""",
    ),
    (
        "occupancy_members rejects phantom occupancy",
        "INSERT INTO occupancy_members (occupancy_id, full_name, relationship) VALUES (999999, 'X', 'self')",
    ),
    (
        "occupancy_members rejects phantom resident user",
        "INSERT INTO occupancy_members (occupancy_id, resident_user_id, full_name, relationship) VALUES (1, 999999, 'X', 'self')",
    ),
]


def sync_migrations() -> None:
    for source, target in SYNC_MAP.items():
        text = (INIT_DIR / source).read_text()
        version = target.split("__")[0]
        text = text.replace(f"-- {source.split('-')[0]}-{source.split('-')[1]}:", f"-- {version}:", 1)
        (MIGRATIONS_DIR / target).write_text(text)
        print(f"synced {source} -> {target}")


def psql(db: str, sql: str, stop: bool = True) -> subprocess.CompletedProcess:
    cmd = ["docker", "exec", "-i", CONTAINER, "psql", "-U", DB_USER, "-d", db, "-X", "-q", "-t", "-A"]
    if stop:
        cmd += ["-v", "ON_ERROR_STOP=1"]
    return subprocess.run(cmd, input=sql, capture_output=True, text=True)


def recreate(db: str) -> None:
    psql(ADMIN_DB, f'DROP DATABASE IF EXISTS "{db}";')
    result = psql(ADMIN_DB, f'CREATE DATABASE "{db}";')
    if result.returncode != 0:
        raise RuntimeError(f"cannot create {db}: {result.stderr.strip()}")


def replay(db: str, files: list[pathlib.Path]) -> None:
    for path in files:
        result = psql(db, path.read_text())
        if result.returncode != 0:
            raise RuntimeError(f"{path.name} failed: {result.stderr.strip()}")


def schema_of(db: str) -> list[str]:
    result = psql(db, SCHEMA_DUMP)
    if result.returncode != 0:
        raise RuntimeError(f"schema dump failed: {result.stderr.strip()}")
    return result.stdout.strip().splitlines()


def check(init_sql: list[pathlib.Path], migration_sql: list[pathlib.Path]) -> dict:
    findings: list[dict] = []
    recreate("sitepulse_check_init")
    recreate("sitepulse_check_mig")
    try:
        replay("sitepulse_check_init", init_sql)
        replay("sitepulse_check_mig", migration_sql)

        init_schema = schema_of("sitepulse_check_init")
        mig_schema = schema_of("sitepulse_check_mig")
        drift = sorted(set(init_schema).symmetric_difference(mig_schema))
        findings.append(
            {
                "check": "db/init and migrations produce the same schema",
                "ok": not drift,
                "detail": drift[:20],
            }
        )

        # Seed data is only needed to exercise the constraints below.
        replay("sitepulse_check_init", sorted(INIT_DIR.glob("0[12]-*.sql")))

        for name, sql in NEGATIVE_CASES:
            result = psql("sitepulse_check_init", sql)
            findings.append(
                {
                    "check": f"rejects: {name}",
                    "ok": result.returncode != 0,
                    "detail": [] if result.returncode != 0 else ["statement was accepted"],
                }
            )

        # Memory-persistence consistency checks
        try:
            sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
            from memory_persistence_lint import run_all_checks as run_persistence_checks
            for pcheck in run_persistence_checks():
                findings.append({
                    "check": f"persistence: {pcheck['check']}",
                    "ok": pcheck["status"] == "PASS",
                    "detail": [] if pcheck["status"] == "PASS" else [pcheck["message"]],
                })
        except Exception as e:
            findings.append({
                "check": "persistence: linter_execution",
                "ok": False,
                "detail": [str(e)],
            })
    finally:
        psql("postgres", 'DROP DATABASE IF EXISTS "sitepulse_check_init";')
        psql("postgres", 'DROP DATABASE IF EXISTS "sitepulse_check_mig";')
    return {"ok": all(item["ok"] for item in findings), "findings": findings}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON")
    parser.add_argument("--sync", action="store_true", help="Regenerate migrations/ from db/init/ then check")
    args = parser.parse_args()

    if args.sync:
        sync_migrations()

    init_sql = sorted(INIT_DIR.glob("00-*.sql"))
    migration_sql = sorted(MIGRATIONS_DIR.glob("V*.sql"), key=lambda p: int(p.stem.split("__")[0][1:]))
    if not init_sql or not migration_sql:
        print("schema sources not found", file=sys.stderr)
        return 2

    try:
        report = check(init_sql, migration_sql)
    except RuntimeError as exc:
        report = {"ok": False, "findings": [{"check": "replay", "ok": False, "detail": [str(exc)]}]}

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        for item in report["findings"]:
            print(f"{'PASS' if item['ok'] else 'FAIL'}  {item['check']}")
            for line in item["detail"]:
                print(f"      {line}")
        print("\nSCHEMA INTEGRITY: " + ("OK" if report["ok"] else "FAILED"))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
