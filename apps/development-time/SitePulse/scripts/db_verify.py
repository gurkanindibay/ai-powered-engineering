#!/usr/bin/env python3
"""SitePulse Database Verification & Inspection CLI Tool.

Provides robust PostgreSQL database access, schema inspection, integrity audits,
and structured querying using Python.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from typing import Any, Dict, List, Optional, Tuple

DEFAULT_CONTAINER = "sitepulse-postgres"
DEFAULT_USER = "sitepulse_user"
DEFAULT_DB = "sitepulse"


class DbVerifier:
    def __init__(
        self,
        container: str = DEFAULT_CONTAINER,
        user: str = DEFAULT_USER,
        database: str = DEFAULT_DB,
    ):
        self.container = container
        self.user = user
        self.database = database

    def execute_raw(self, sql: str) -> str:
        """Executes a raw SQL statement via docker exec psql and returns stdout."""
        cmd = [
            "docker",
            "exec",
            "-i",
            self.container,
            "psql",
            "-U",
            self.user,
            "-d",
            self.database,
            "-c",
            sql,
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"psql execution failed:\n{result.stderr.strip()}")
        return result.stdout.strip()

    def query_json(self, sql: str, params: Optional[Dict[str, str]] = None) -> List[Dict[str, Any]]:
        """Runs a query and returns rows as dicts.

        Values are bound with psql variables (``-v name=value``) and referenced in
        the SQL as ``:'name'`` (quoted literal) or ``:"name"`` (quoted
        identifier), so psql escapes them; nothing is formatted into the SQL text.
        The SQL is sent on stdin because psql does not interpolate ``-c``.
        """
        clean_sql = sql.strip().rstrip(";").strip()
        json_sql = f"SELECT COALESCE(json_agg(t), '[]'::json) FROM ({clean_sql}) AS t;\n"
        cmd = ["docker", "exec", "-i", self.container, "psql", "-U", self.user, "-d", self.database,
               "-X", "-t", "-A", "-v", "ON_ERROR_STOP=1"]
        for name, value in (params or {}).items():
            if not re.fullmatch(r"[a-z_]+", name):
                raise ValueError(f"invalid parameter name {name!r}")
            cmd += ["-v", f"{name}={value}"]
        result = subprocess.run(cmd, input=json_sql, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"JSON query failed:\n{result.stderr.strip()}")
        output = result.stdout.strip()
        if not output:
            return []
        try:
            return json.loads(output)
        except json.JSONDecodeError as err:
            raise ValueError(f"Failed to parse query output as JSON: {output}") from err

    def query_table(self, sql: str) -> str:
        """Executes query and returns psql formatted table."""
        return self.execute_raw(sql)

    def list_tables(self) -> List[Dict[str, Any]]:
        """Lists all user tables and row counts."""
        sql = """
        SELECT 
            table_name,
            (SELECT COUNT(*) FROM information_schema.columns c WHERE c.table_name = t.table_name) AS column_count
        FROM information_schema.tables t
        WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
        ORDER BY table_name;
        """
        tables = self.query_json(sql)
        for t in tables:
            tname = t["table_name"]
            try:
                count_res = self.query_json('SELECT COUNT(*) AS cnt FROM :"table_name"', {"table_name": tname})
                t["row_count"] = count_res[0]["cnt"] if count_res else 0
            except Exception:
                t["row_count"] = "error"
        return tables

    def inspect_table(self, table_name: str) -> Dict[str, Any]:
        """Inspects table schema and returns column definitions plus sample rows."""
        schema_sql = """
        SELECT 
            column_name, 
            data_type, 
            is_nullable, 
            column_default
        FROM information_schema.columns
        WHERE table_name = :'table_name' AND table_schema = 'public'
        ORDER BY ordinal_position;
        """
        columns = self.query_json(schema_sql, {"table_name": table_name})
        if not columns:
            raise ValueError(f"Unknown table: {table_name}")
        samples = self.query_json('SELECT * FROM :"table_name" LIMIT 5', {"table_name": table_name})
        return {
            "table_name": table_name,
            "columns": columns,
            "sample_rows": samples,
            "sample_count": len(samples),
        }

    def get_residents(self, site_id: str = "1") -> List[Dict[str, Any]]:
        """Fetches units, owners, tenants, occupancy status, and dual-ledger balances for a site."""
        sql = """
        SELECT 
            u.id AS unit_id,
            b.block_name,
            u.unit_number,
            u.floor,
            u.house_type,
            COALESCE(u.occupancy_status, 'OWNER_OCCUPIED') AS occupancy_status,
            u.virtual_iban,
            po.id AS owner_id,
            po.full_name AS owner_name,
            po.phone AS owner_phone,
            pt.id AS tenant_id,
            pt.full_name AS tenant_name,
            pt.phone AS tenant_phone,
            COALESCE(
                (SELECT SUM(principal_amount + delay_penalty - paid_amount) 
                 FROM dues_liabilities dl 
                 WHERE dl.unit_id = u.id AND dl.status != 'PAID' AND (dl.expense_type = 'OPERATIONAL_DUES' OR dl.debtor_type = 'TENANT')), 
                0.00
            ) AS operational_debt,
            COALESCE(
                (SELECT SUM(principal_amount + delay_penalty - paid_amount) 
                 FROM dues_liabilities dl 
                 WHERE dl.unit_id = u.id AND dl.status != 'PAID' AND (dl.expense_type = 'CAPITAL_DUES' OR dl.debtor_type = 'OWNER')), 
                0.00
            ) AS capital_debt,
            COALESCE(
                (SELECT SUM(principal_amount + delay_penalty - paid_amount) 
                 FROM dues_liabilities dl 
                 WHERE dl.unit_id = u.id AND dl.status != 'PAID'), 
                0.00
            ) AS total_debt
        FROM units u
        JOIN blocks b ON u.block_id = b.id
        LEFT JOIN persons po ON u.owner_person_id = po.id
        LEFT JOIN persons pt ON u.tenant_person_id = pt.id
        WHERE u.site_id::text = :'site_id'
        ORDER BY b.block_name, u.unit_number;
        """
        return self.query_json(sql, {"site_id": site_id})

    def get_occupancy_history(self, unit_id: str) -> List[Dict[str, Any]]:
        """Fetches chronological occupancy and residency history for a unit."""
        clean_id = unit_id.replace("unit-", "").replace("d-", "")
        sql = """
        SELECT 
            uo.id,
            uo.unit_id,
            uo.person_id,
            p.full_name AS person_name,
            p.phone AS person_phone,
            p.email AS person_email,
            uo.occupancy_type AS role,
            uo.start_date::text AS start_date,
            uo.end_date::text AS end_date,
            uo.is_active,
            uo.exit_balance,
            uo.notes,
            uo.created_at::text AS created_at
        FROM unit_occupancies uo
        JOIN persons p ON uo.person_id = p.id
        WHERE uo.unit_id::text = :'unit_id'
        ORDER BY uo.start_date DESC, uo.id DESC;
        """
        return self.query_json(sql, {"unit_id": clean_id})

    def verify_integrity(self, site_id: str = "1") -> Dict[str, Any]:
        """Performs comprehensive integrity check and financial balance audits."""
        summary = {}

        # 1. Entity Counts
        counts_sql = """
        SELECT
            (SELECT COUNT(*) FROM sites WHERE id::text = :'site_id') AS sites,
            (SELECT COUNT(*) FROM blocks WHERE site_id::text = :'site_id') AS blocks,
            (SELECT COUNT(*) FROM units WHERE site_id::text = :'site_id') AS units,
            (SELECT COUNT(DISTINCT p.id) FROM persons p JOIN units u ON (u.owner_person_id = p.id OR u.tenant_person_id = p.id) WHERE u.site_id::text = :'site_id') AS site_persons,
            (SELECT COUNT(*) FROM persons) AS total_persons,
            (SELECT COUNT(*) FROM users) AS total_users,
            (SELECT COUNT(*) FROM dues_periods WHERE site_id::text = :'site_id') AS dues_periods,
            (SELECT COUNT(*) FROM dues_liabilities dl JOIN units u ON dl.unit_id = u.id WHERE u.site_id::text = :'site_id') AS dues_liabilities,
            (SELECT COUNT(*) FROM payment_entries pe JOIN units u ON pe.unit_id = u.id WHERE u.site_id::text = :'site_id') AS collections
        """
        summary["entity_counts"] = self.query_json(counts_sql, {"site_id": site_id})[0]

        # 2. Financial Totals
        fin_sql = """
        SELECT 
            COALESCE(SUM(principal_amount), 0) AS total_principal_accrued,
            COALESCE(SUM(paid_amount), 0) AS total_paid,
            COALESCE(SUM(principal_amount + delay_penalty - paid_amount), 0) AS total_remaining,
            COALESCE(SUM(delay_penalty), 0) AS total_penalties,
            COUNT(CASE WHEN status = 'PAID' THEN 1 END) AS count_paid,
            COUNT(CASE WHEN status = 'PARTIALLY_PAID' THEN 1 END) AS count_partial,
            COUNT(CASE WHEN status = 'PENDING' THEN 1 END) AS count_pending,
            COUNT(CASE WHEN status = 'OVERDUE' THEN 1 END) AS count_overdue
        FROM dues_liabilities dl
        JOIN units u ON dl.unit_id = u.id
        WHERE u.site_id::text = :'site_id';
        """
        summary["financial_summary"] = self.query_json(fin_sql, {"site_id": site_id})[0]

        # 3. Integrity Audits
        orphan_checks = {
            "units_without_owner": self.query_json(
                "SELECT id, block_id, unit_number FROM units WHERE site_id::text = :'site_id' AND owner_person_id IS NULL;", {"site_id": site_id}
            ),
            "units_with_invalid_owner": self.query_json(
                "SELECT u.id, u.unit_number FROM units u LEFT JOIN persons p ON u.owner_person_id = p.id WHERE u.site_id::text = :'site_id' AND u.owner_person_id IS NOT NULL AND p.id IS NULL;", {"site_id": site_id}
            ),
            "units_with_invalid_tenant": self.query_json(
                "SELECT u.id, u.unit_number FROM units u LEFT JOIN persons p ON u.tenant_person_id = p.id WHERE u.site_id::text = :'site_id' AND u.tenant_person_id IS NOT NULL AND p.id IS NULL;", {"site_id": site_id}
            ),
            "orphaned_dues_liabilities": self.query_json(
                "SELECT dl.id, dl.unit_id FROM dues_liabilities dl LEFT JOIN units u ON dl.unit_id = u.id WHERE u.id IS NULL;"
            ),
            "orphaned_household_members": self.query_json(
                "SELECT om.id, om.occupancy_id, om.full_name FROM occupancy_members om LEFT JOIN unit_occupancies uo ON om.occupancy_id = uo.id WHERE uo.id IS NULL;"
            ),
        }
        summary["integrity_issues"] = orphan_checks
        has_issues = any(len(v) > 0 for v in orphan_checks.values())
        summary["status"] = "WARNING" if has_issues else "HEALTHY"

        return summary


def format_table(data: List[Dict[str, Any]]) -> str:
    """Renders a list of dicts as an aligned ASCII table."""
    if not data:
        return "No records found."
    keys = list(data[0].keys())
    # Calculate widths
    widths = {k: len(str(k)) for k in keys}
    for row in data:
        for k in keys:
            val_str = str(row.get(k, ""))
            widths[k] = max(widths[k], len(val_str))

    header = " | ".join(k.ljust(widths[k]) for k in keys)
    separator = "-+-".join("-" * widths[k] for k in keys)
    rows = []
    for row in data:
        rows.append(" | ".join(str(row.get(k, "")).ljust(widths[k]) for k in keys))
    return f"{header}\n{separator}\n" + "\n".join(rows)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="SitePulse PostgreSQL Database Verification CLI (Python)"
    )
    parser.add_argument(
        "--container", default=DEFAULT_CONTAINER, help="PostgreSQL Docker container name"
    )
    parser.add_argument(
        "--user", default=DEFAULT_USER, help="PostgreSQL database user"
    )
    parser.add_argument(
        "--db", default=DEFAULT_DB, help="PostgreSQL database name"
    )
    parser.add_argument(
        "--json", action="store_true", help="Format output as JSON"
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    # query
    p_query = subparsers.add_parser("query", help="Run arbitrary SQL query")
    p_query.add_argument("sql", help="SQL statement to execute")

    # query-json
    p_qjson = subparsers.add_parser("query-json", help="Run SQL and output JSON")
    p_qjson.add_argument("sql", help="SQL statement to execute")

    # tables
    subparsers.add_parser("tables", help="List all tables and row counts")

    # inspect
    p_inspect = subparsers.add_parser("inspect", help="Inspect table schema and samples")
    p_inspect.add_argument("table_name", help="Name of table to inspect")

    # residents
    p_res = subparsers.add_parser("residents", help="List residents & owners for site")
    p_res.add_argument("site_id", nargs="?", default="1", help="Site ID (default: 1)")

    # occupancy-history
    p_hist = subparsers.add_parser("occupancy-history", help="Show move-in/out history for a unit")
    p_hist.add_argument("unit_id", help="Unit ID (e.g. 1 or unit-1)")

    # verify
    p_ver = subparsers.add_parser("verify", help="Run full health & integrity verification")
    p_ver.add_argument("site_id", nargs="?", default="1", help="Site ID (default: 1)")

    args = parser.parse_args()
    verifier = DbVerifier(args.container, args.user, args.db)

    try:
        if args.command == "query":
            if args.json:
                res = verifier.query_json(args.sql)
                print(json.dumps(res, indent=2, default=str))
            else:
                print(verifier.query_table(args.sql))

        elif args.command == "query-json":
            res = verifier.query_json(args.sql)
            print(json.dumps(res, indent=2, default=str))

        elif args.command == "tables":
            tables = verifier.list_tables()
            if args.json:
                print(json.dumps(tables, indent=2))
            else:
                print("=================================================================")
                print("              DATABASE TABLES & RECORD COUNTS                    ")
                print("=================================================================")
                print(format_table(tables))

        elif args.command == "inspect":
            data = verifier.inspect_table(args.table_name)
            if args.json:
                print(json.dumps(data, indent=2, default=str))
            else:
                print(f"=================================================================")
                print(f" SCHEMA: {args.table_name}")
                print(f"=================================================================")
                print(format_table(data["columns"]))
                print(f"\n=================================================================")
                print(f" SAMPLE ROWS (Limit 5): {args.table_name}")
                print(f"=================================================================")
                print(format_table(data["sample_rows"]))

        elif args.command == "residents":
            residents = verifier.get_residents(args.site_id)
            if args.json:
                print(json.dumps(residents, indent=2, default=str))
            else:
                print(f"=================================================================")
                print(f" RESIDENTS, OCCUPANCY & DUAL-LEDGER BALANCES (Site ID: {args.site_id})")
                print(f"=================================================================")
                print(format_table(residents))

        elif args.command == "occupancy-history":
            history = verifier.get_occupancy_history(args.unit_id)
            if args.json:
                print(json.dumps(history, indent=2, default=str))
            else:
                print(f"=================================================================")
                print(f" UNIT OCCUPANCY & RESIDENCY TIMELINE (Unit: {args.unit_id})")
                print(f"=================================================================")
                print(format_table(history))

        elif args.command == "verify":
            report = verifier.verify_integrity(args.site_id)
            if args.json:
                print(json.dumps(report, indent=2, default=str))
            else:
                status_color = "\033[92mHEALTHY\033[0m" if report["status"] == "HEALTHY" else "\033[93mWARNING\033[0m"
                print(f"=================================================================")
                print(f" SITEPULSE DATABASE HEALTH & INTEGRITY REPORT (Site: {args.site_id})")
                print(f" System Status: {status_color}")
                print(f"=================================================================")
                print("\n[CORE ENTITY COUNTS]")
                for k, v in report["entity_counts"].items():
                    print(f"  - {k.replace('_', ' ').capitalize()}: {v}")

                print("\n[FINANCIAL RECONCILIATION SUMMARY]")
                for k, v in report["financial_summary"].items():
                    print(f"  - {k.replace('_', ' ').capitalize()}: {v}")

                print("\n[INTEGRITY AUDIT & ORPHAN CHECKS]")
                for check, items in report["integrity_issues"].items():
                    tag = "OK" if len(items) == 0 else f"FOUND {len(items)}"
                    print(f"  - {check.replace('_', ' ').capitalize()}: {tag}")
                    for item in items:
                        print(f"      * {item}")
                print("=================================================================")
            # Integrity problems are a failure, so CI and scripts can act on them.
            if report["status"] != "HEALTHY":
                sys.exit(1)

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
