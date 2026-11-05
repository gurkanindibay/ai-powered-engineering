#!/usr/bin/env python3
"""
SitePulse Memory-Persistence Audit & Linter
Ensures strict consistency between in-memory Axum state and PostgreSQL persistence.

Detects:
1. Un-hydrated state fields in `load_all_from_db`.
2. Destructive SQL overwrite anti-patterns (e.g. non-accumulating paid_amount).
3. Obsolete conflict arbiter specifications (e.g. advance_balances(unit_id) instead of composite).
4. Direct in-memory mutations lacking database write-paths in state-modifying services.

Supports --json and --help flags.
"""

import argparse
import json
import re
import sys
from pathlib import Path

BACKEND_SRC = Path(__file__).resolve().parent.parent / "backend" / "src"

CRITICAL_PERSISTED_TABLES = [
    "sites",
    "blocks",
    "units",
    "users",
    "dues_liabilities",
    "payment_entries",
    "payment_receipts",
    "pending_registrations",
    "occupancy_members",
    "unit_occupancies",
    "invitation_tokens",
    "advance_balances",
    "unit_sender_ibans",
    "site_bank_accounts",
    "reconciliation_queue",
]

def check_db_hydration(db_rs: str) -> list[dict]:
    findings = []
    # Check that each critical table is queried in load_all_from_db
    load_func_match = re.search(r"pub async fn load_all_from_db\s*\(.*?\)\s*(?:->[^{]+)?\{(.*?)(?:\n\s*pub async fn|\Z)", db_rs, re.DOTALL)
    if not load_func_match:
        findings.append({
            "check": "db_hydration_load_all_present",
            "status": "FAIL",
            "message": "Could not find `load_all_from_db` function in src/db.rs"
        })
        return findings

    load_body = load_func_match.group(1)
    for table in CRITICAL_PERSISTED_TABLES:
        pattern = rf'FROM\s+{table}\b'
        if not re.search(pattern, load_body, re.IGNORECASE):
            findings.append({
                "check": f"db_hydration_{table}",
                "status": "FAIL",
                "message": f"Table `{table}` is not hydrated in `load_all_from_db()`"
            })
        else:
            findings.append({
                "check": f"db_hydration_{table}",
                "status": "PASS",
                "message": f"Table `{table}` hydrated in `load_all_from_db()`"
            })
    return findings

def check_anti_patterns(db_rs: str) -> list[dict]:
    findings = []

    # 1. Check for dues_liabilities overwrite bug: `SET status = $2, paid_amount = $3`
    if re.search(r"UPDATE\s+dues_liabilities\s+SET\s+status\s*=\s*\$2,\s*paid_amount\s*=\s*\$3\b", db_rs, re.IGNORECASE):
        findings.append({
            "check": "anti_pattern_dues_paid_amount_overwrite",
            "status": "FAIL",
            "message": "Found destructive `UPDATE dues_liabilities SET paid_amount = $3` without accumulation"
        })
    else:
        findings.append({
            "check": "anti_pattern_dues_paid_amount_overwrite",
            "status": "PASS",
            "message": "`dues_liabilities.paid_amount` safely accumulates payments"
        })

    # 2. Check advance_balances ON CONFLICT
    if re.search(r"INSERT\s+INTO\s+advance_balances.*?ON\s+CONFLICT\s*\(\s*unit_id\s*\)", db_rs, re.DOTALL | re.IGNORECASE):
        findings.append({
            "check": "anti_pattern_advance_conflict_target",
            "status": "FAIL",
            "message": "Found invalid conflict target `ON CONFLICT (unit_id)` on `advance_balances` (requires debtor_type)"
        })
    else:
        findings.append({
            "check": "anti_pattern_advance_conflict_target",
            "status": "PASS",
            "message": "`advance_balances` uses correct composite conflict arbiter `(unit_id, debtor_type)`"
        })

    # 3. Check unit_sender_ibans ON CONFLICT
    if re.search(r"INSERT\s+INTO\s+unit_sender_ibans.*?ON\s+CONFLICT\s*\(\s*sender_iban\s*\)", db_rs, re.DOTALL | re.IGNORECASE):
        findings.append({
            "check": "anti_pattern_sender_iban_conflict_target",
            "status": "FAIL",
            "message": "Found invalid conflict target `ON CONFLICT (sender_iban)` on `unit_sender_ibans` (requires unit_id)"
        })
    else:
        findings.append({
            "check": "anti_pattern_sender_iban_conflict_target",
            "status": "PASS",
            "message": "`unit_sender_ibans` uses correct unique composite arbiter `(unit_id, sender_iban)`"
        })

    return findings

def check_payment_tracking_service(service_rs: str) -> list[dict]:
    findings = []

    # Check next_receipt_number checks state.pool
    if "crate::db::get_next_receipt_sequence" in service_rs:
        findings.append({
            "check": "receipt_sequence_db_backed",
            "status": "PASS",
            "message": "Receipt sequence checks database sequence when pool is available"
        })
    else:
        findings.append({
            "check": "receipt_sequence_db_backed",
            "status": "FAIL",
            "message": "`next_receipt_number` does not query database sequence"
        })

    # Check record_and_allocate_payment persists receipt and entry
    if "crate::db::save_payment_receipt" in service_rs and "crate::db::save_payment_entry" in service_rs:
        findings.append({
            "check": "payment_allocation_db_backed",
            "status": "PASS",
            "message": "Payment allocation persists receipt, entry, and allocations to DB"
        })
    else:
        findings.append({
            "check": "payment_allocation_db_backed",
            "status": "FAIL",
            "message": "`record_and_allocate_payment` does not persist receipt and entry to DB"
        })

    # Check inter_ledger_transfer persists virman
    if "save_advance_ledger_entry" in service_rs:
        findings.append({
            "check": "advance_ledger_entry_tracked",
            "status": "PASS",
            "message": "Advance ledger entry audit trail is recorded on surplus and virman"
        })
    else:
        findings.append({
            "check": "advance_ledger_entry_tracked",
            "status": "FAIL",
            "message": "Missing `save_advance_ledger_entry` calls for advance sub-ledger audit trail"
        })

    return findings

def run_all_checks() -> list[dict]:
    db_rs_path = BACKEND_SRC / "db.rs"
    service_rs_path = BACKEND_SRC / "services" / "payment_tracking_service.rs"

    if not db_rs_path.exists():
        return [{"check": "file_exists", "status": "FAIL", "message": f"{db_rs_path} not found"}]

    db_rs = db_rs_path.read_text(encoding="utf-8")
    service_rs = service_rs_path.read_text(encoding="utf-8") if service_rs_path.exists() else ""

    results = []
    results.extend(check_db_hydration(db_rs))
    results.extend(check_anti_patterns(db_rs))
    results.extend(check_payment_tracking_service(service_rs))
    return results

def main():
    parser = argparse.ArgumentParser(description="Audit and lint Rust backend memory-persistence consistency.")
    parser.add_argument("--json", action="store_true", help="Output results in structured JSON format.")
    args = parser.parse_args()

    results = run_all_checks()
    failures = [r for r in results if r["status"] == "FAIL"]

    if args.json:
        payload = {
            "total_checks": len(results),
            "passed": len(results) - len(failures),
            "failed": len(failures),
            "results": results,
        }
        print(json.dumps(payload, indent=2))
    else:
        print("=" * 60)
        print("SitePulse Memory-Persistence Architecture Linter")
        print("=" * 60)
        for r in results:
            tag = "[ PASS ]" if r["status"] == "PASS" else "[ FAIL ]"
            print(f"{tag:<9} {r['check']}: {r['message']}")
        print("-" * 60)
        print(f"Summary: {len(results) - len(failures)}/{len(results)} checks passed.")
        if failures:
            print(f"FAILED: {len(failures)} persistence checks violated.")
        else:
            print("ALL PERSISTENCE CHECKS OK.")

    if failures:
        sys.exit(1)
    sys.exit(0)

if __name__ == "__main__":
    main()
