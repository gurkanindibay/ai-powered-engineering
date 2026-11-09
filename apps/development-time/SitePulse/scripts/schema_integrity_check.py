#!/usr/bin/env python3
"""SitePulse Schema Integrity Gate.

`backend/migrations/V*.sql` is the only schema source (applied by the backend's
migration runner). This gate:

1. replays every migration in version order into an empty database, loads the
   seeds, and checks that the integrity constraints reject the data they are
   meant to reject (and that the database-side rules do what they promise);
2. runs an upgrade test: applies V1..V7, inserts rows the way V7-era code did,
   applies the remaining migrations, and checks that the rows survived, the data
   backfills ran, every constraint ended up validated, and the upgraded schema
   is identical to a fresh install.

Released migrations are append-only; nothing in this repository rewrites them.

PostgreSQL access: `psql` on PATH using DB_HOST/DB_PORT/DB_USER/DB_PASS, or
`docker exec <container> psql` (SITEPULSE_PG_CONTAINER, default sitepulse-postgres).

Usage:
    python3 scripts/schema_integrity_check.py
    python3 scripts/schema_integrity_check.py --json
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys

BACKEND = pathlib.Path(__file__).resolve().parent.parent / "backend"
MIGRATIONS_DIR = BACKEND / "migrations"
SEED_DIR = BACKEND / "db" / "seed"
UPGRADE_FROM = 7

CONTAINER = os.environ.get("SITEPULSE_PG_CONTAINER", "sitepulse-postgres")
DB_USER = os.environ.get("DB_USER", "sitepulse_user")
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
           INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, expense_type, debtor_type,
                                         capital_project_id, installment_number)
           SELECT u.id, 'C', 10, CURRENT_DATE, 'CAPITAL_DUES', 'OWNER', cp.id, 1 FROM units u, capital_projects cp;
           INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, expense_type, debtor_type,
                                         capital_project_id, installment_number)
           SELECT u.id, 'C', 10, CURRENT_DATE, 'CAPITAL_DUES', 'OWNER', cp.id, 1 FROM units u, capital_projects cp;""",
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
        "INSERT INTO payment_entries (site_id, unit_id, payer_name, payer_role, amount, payment_channel, settlement_status) VALUES (1, 999999, 'X', 'OWNER', 10, 'CASH', 'UNMATCHED')",
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
        "INSERT INTO occupancy_members (occupancy_id, full_name, relationship) VALUES (999999, 'X', 'OTHER')",
    ),
    (
        "occupancy_members rejects phantom resident user",
        "INSERT INTO occupancy_members (occupancy_id, resident_user_id, full_name, relationship) VALUES (1, 999999, 'X', 'OTHER')",
    ),
]

NEGATIVE_CASES += [
    ("dues_liabilities rejects phantom unit (H11)",
     "INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date) VALUES (999999, 'P', 10, CURRENT_DATE)"),
    ("blocks rejects phantom site (H11)", "INSERT INTO blocks (site_id, block_name, total_floors) VALUES (999999, 'Z', 1)"),
    ("unit with financial history cannot be deleted (H12)",
     "INSERT INTO advance_ledger_entries (unit_id, debtor_type, entry_type, amount) SELECT id, 'OWNER', 'PAYMENT_SURPLUS', 5 FROM units LIMIT 1;"
     " DELETE FROM units WHERE id = (SELECT unit_id FROM advance_ledger_entries LIMIT 1)"),
    ("sites.status vocabulary (M3)", "UPDATE sites SET status = 'WHATEVER'"),
    ("payment channel vocabulary (M3)",
     "INSERT INTO payment_entries (site_id, unit_id, payer_name, payer_role, amount, payment_channel, settlement_status) SELECT site_id, id, 'X', 'OWNER', 10, 'TELEPATHY', 'UNMATCHED' FROM units LIMIT 1"),
    ("paid_amount must equal paid_principal + paid_penalty (M4)",
     "INSERT INTO dues_liabilities (unit_id, period, principal_amount, paid_amount, due_date) SELECT id, 'P-M4', 100, 10, CURRENT_DATE FROM units LIMIT 1"),
    ("advance balance cannot be negative (M4)",
     "INSERT INTO advance_balances (unit_id, debtor_type, balance) SELECT id, 'OWNER', -1 FROM units LIMIT 1"),
    ("e-mail uniqueness is case-insensitive (M8)",
     "INSERT INTO users (email, role) SELECT UPPER(email), role FROM users WHERE email IS NOT NULL LIMIT 1"),
    ("receipt counter cannot go negative (H3)",
     "INSERT INTO receipt_counters (site_id, last_sequence) SELECT id, -1 FROM sites LIMIT 1"),
]

# V16 / SPEC-005: append-only payment ledger and its documented transitions.
V16_RECEIPT = ("INSERT INTO payment_receipts (site_id, unit_id, receipt_number, sequence_number, payer_name, payer_role,"
               " total_amount, allocated_principal, payment_channel, verification_hash)"
               " SELECT site_id, id, '{number}', {seq}, 'P', 'OWNER', 10, 10, 'MANUAL_CASH', 'h' FROM units ORDER BY id LIMIT 1")
V16_UNMATCHED = ("INSERT INTO payment_entries (site_id, unit_id, payer_name, payer_role, amount, payment_channel, settlement_status,"
                 " external_reference) SELECT site_id, id, 'P', 'OWNER', 10, 'BANK_TRANSFER', 'UNMATCHED', '{ref}'"
                 " FROM units ORDER BY id LIMIT 1")
NEGATIVE_CASES += [
    ("receipts are append-only: UPDATE (V16 P-06)",
     V16_RECEIPT.format(number="V16-N1", seq=9001) + "; UPDATE payment_receipts SET payer_name = 'X' WHERE receipt_number = 'V16-N1'"),
    ("receipts are append-only: DELETE (V16 P-06)",
     V16_RECEIPT.format(number="V16-N2", seq=9002) + "; DELETE FROM payment_receipts WHERE receipt_number = 'V16-N2'"),
    ("advance ledger is append-only (V16 P-06)",
     "INSERT INTO advance_ledger_entries (unit_id, debtor_type, entry_type, amount) SELECT id, 'OWNER', 'PAYMENT_SURPLUS', 5 FROM units LIMIT 1;"
     " DELETE FROM advance_ledger_entries"),
    ("a SETTLED entry needs a receipt (V16 P-03)",
     "INSERT INTO payment_entries (site_id, unit_id, payer_name, payer_role, amount, payment_channel)"
     " SELECT site_id, id, 'P', 'OWNER', 10, 'MANUAL_CASH' FROM units LIMIT 1"),
    ("entry amount is immutable (V16 P-06)",
     V16_UNMATCHED.format(ref="V16-N3") + "; UPDATE payment_entries SET amount = 11 WHERE external_reference = 'V16-N3'"),
    ("UNMATCHED cannot become SETTLED without a receipt (V16 P-06)",
     V16_UNMATCHED.format(ref="V16-N4") + "; UPDATE payment_entries SET settlement_status = 'SETTLED' WHERE external_reference = 'V16-N4'"),
    ("entries are append-only: DELETE (V16 P-06)",
     V16_UNMATCHED.format(ref="V16-N5") + "; DELETE FROM payment_entries WHERE external_reference = 'V16-N5'"),
    ("one entry per receipt (V16 P-04)",
     V16_RECEIPT.format(number="V16-N6", seq=9006) + ";"
     " INSERT INTO payment_entries (site_id, unit_id, payer_name, payer_role, amount, payment_channel, receipt_id)"
     " SELECT r.site_id, r.unit_id, 'P', 'OWNER', 10, 'MANUAL_CASH', r.id FROM payment_receipts r, generate_series(1, 2)"
     " WHERE r.receipt_number = 'V16-N6'"),
    ("penalty accrual date cannot precede the due date (V16 P-01)",
     "INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, penalty_accrued_through)"
     " SELECT id, 'P-V16', 10, DATE '2026-09-01', DATE '2026-08-01' FROM units LIMIT 1"),
]

# V17 / SPEC-006: reversals, webhook claims, issuer details, status vocabularies.
# A settled collection (receipt + entry + allocation + paid due) to build on.
V17_SETTLED = (
    "INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, status, paid_principal, paid_amount)"
    " SELECT id, '{ref}', 10, CURRENT_DATE + 5, 'PAID', 10, 10 FROM units ORDER BY id LIMIT 1;"
    " INSERT INTO payment_receipts (site_id, unit_id, receipt_number, sequence_number, payer_name, payer_role,"
    " total_amount, allocated_principal, payment_channel, verification_hash)"
    " SELECT site_id, id, '{ref}', {seq}, 'P', 'OWNER', 10, 10, 'MANUAL_CASH', 'h' FROM units ORDER BY id LIMIT 1;"
    " INSERT INTO payment_entries (site_id, unit_id, payer_name, payer_role, amount, payment_channel, receipt_id, external_reference)"
    " SELECT r.site_id, r.unit_id, 'P', 'OWNER', 10, 'MANUAL_CASH', r.id, '{ref}' FROM payment_receipts r WHERE r.receipt_number = '{ref}';"
    " INSERT INTO payment_allocations (payment_entry_id, dues_liability_id, principal_amount)"
    " SELECT e.id, d.id, 10 FROM payment_entries e, dues_liabilities d WHERE e.external_reference = '{ref}' AND d.period = '{ref}'")
V17_REVERSAL_RECEIPT = (
    "INSERT INTO payment_receipts (site_id, unit_id, receipt_number, sequence_number, payer_name, payer_role, total_amount,"
    " allocated_principal, payment_channel, verification_hash, receipt_type, reverses_receipt_id)"
    " SELECT site_id, unit_id, '{number}', {seq}, 'P', 'OWNER', 10, 10, 'MANUAL_CASH', 'h', 'REVERSAL', id"
    " FROM payment_receipts WHERE receipt_number = '{ref}'")
V17_CONTRA = (
    "INSERT INTO payment_entries (site_id, unit_id, payer_name, payer_role, amount, payment_channel, settlement_status,"
    " receipt_id, entry_type, reverses_entry_id, reversal_reason, recorded_by)"
    " SELECT o.site_id, o.unit_id, 'P', 'OWNER', 10, 'MANUAL_CASH', 'REVERSED', rr.id, 'REVERSAL', o.id, {reason}, 'user:1'"
    " FROM payment_entries o, payment_receipts rr WHERE o.external_reference = '{ref}' AND rr.receipt_number = '{number}'")
V17_CLAIM = ("INSERT INTO processed_bank_webhooks (transaction_id, site_id, site_bank_account_id)"
             " SELECT '{txn}', a.site_id, a.id FROM site_bank_accounts a ORDER BY a.id LIMIT 1")
NEGATIVE_CASES += [
    ("a reversal receipt names its original (V17 O-2)",
     "INSERT INTO payment_receipts (site_id, unit_id, receipt_number, sequence_number, payer_name, payer_role, total_amount,"
     " allocated_principal, payment_channel, verification_hash, receipt_type)"
     " SELECT site_id, id, 'V17-N1', 1, 'P', 'OWNER', 10, 10, 'MANUAL_CASH', 'h', 'REVERSAL' FROM units ORDER BY id LIMIT 1"),
    ("a receipt is reversed at most once (V17 O-2)",
     V17_SETTLED.format(ref="V17-N2", seq=9201) + "; " + V17_REVERSAL_RECEIPT.format(number="V17-N2-R1", seq=1, ref="V17-N2")
     + "; " + V17_REVERSAL_RECEIPT.format(number="V17-N2-R2", seq=2, ref="V17-N2")),
    ("a contra entry needs a reason (V17 O-2)",
     V17_SETTLED.format(ref="V17-N3", seq=9202) + "; " + V17_REVERSAL_RECEIPT.format(number="V17-N3-R", seq=3, ref="V17-N3")
     + "; " + V17_CONTRA.format(reason="''", ref="V17-N3", number="V17-N3-R")),
    ("SETTLED -> REVERSED needs a contra entry (V17 O-2)",
     V17_SETTLED.format(ref="V17-N4", seq=9203) + "; UPDATE payment_entries SET settlement_status = 'REVERSED' WHERE external_reference = 'V17-N4'"),
    ("a contra entry's reason is immutable (V17 O-2)",
     V17_SETTLED.format(ref="V17-N5", seq=9204) + "; " + V17_REVERSAL_RECEIPT.format(number="V17-N5-R", seq=4, ref="V17-N5")
     + "; " + V17_CONTRA.format(reason="'Bounced transfer'", ref="V17-N5", number="V17-N5-R")
     + "; UPDATE payment_entries SET reversal_reason = 'edited' WHERE entry_type = 'REVERSAL'"),
    ("a receipt with advance names the advance debtor (V17 O-1)",
     "INSERT INTO payment_receipts (site_id, unit_id, receipt_number, sequence_number, payer_name, payer_role, total_amount,"
     " allocated_advance, payment_channel, verification_hash)"
     " SELECT site_id, id, 'V17-N6', 9205, 'P', 'OWNER', 10, 10, 'MANUAL_CASH', 'h' FROM units ORDER BY id LIMIT 1"),
    ("site tax id is 10 or 11 digits (V17 O-5)", "UPDATE sites SET tax_id = '12AB'"),
    ("one claim per (bank account, transaction) (V17 O-3)",
     V17_CLAIM.format(txn="V17-N7") + "; " + V17_CLAIM.format(txn="V17-N7")),
    ("webhook payload hash is a SHA-256 hex digest (V17 O-3)",
     "INSERT INTO processed_bank_webhooks (transaction_id, payload_hash) VALUES ('V17-N8', 'not-a-hash')"),
    ("reconciliation status has one vocabulary (V17 O-7)",
     "INSERT INTO reconciliation_queue (match_id, transaction_id, txn_date, amount, description, status, site_id)"
     " SELECT 'V17-N9', 'V17-N9', CURRENT_DATE, 1, 'd', 'Approved', id FROM sites LIMIT 1"),
    ("a bank account with statement history cannot be deleted (V17 O-7)",
     "INSERT INTO reconciliation_queue (match_id, transaction_id, txn_date, amount, description, status, site_id, site_bank_account_id)"
     " SELECT 'V17-N10', 'V17-N10', CURRENT_DATE, 1, 'd', 'UNMATCHED', a.site_id, a.id FROM site_bank_accounts a ORDER BY a.id LIMIT 1;"
     " DELETE FROM site_bank_accounts WHERE id = (SELECT site_bank_account_id FROM reconciliation_queue WHERE match_id = 'V17-N10')"),
    ("PAID requires the liability to be fully paid (V17 O-6)",
     "INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, status) SELECT id, 'V17-N11', 10, CURRENT_DATE, 'PAID' FROM units LIMIT 1"),
    ("a fully paid liability cannot stay open (V17 O-6)",
     "INSERT INTO dues_liabilities (unit_id, period, principal_amount, paid_principal, paid_amount, due_date, status)"
     " SELECT id, 'V17-N12', 10, 10, 10, CURRENT_DATE, 'PENDING' FROM units LIMIT 1"),
    ("payer_role has no silent default (V17 O-10)",
     "INSERT INTO payment_entries (site_id, unit_id, payer_name, amount, payment_channel, settlement_status)"
     " SELECT site_id, id, 'X', 10, 'BANK_TRANSFER', 'UNMATCHED' FROM units LIMIT 1"),
]

# SPEC-007 / V18: immutable evidence and bounded support elevation.
NEGATIVE_CASES += [
    ("audit events reject UPDATE", "UPDATE audit_events SET action='TAMPERED'"),
    ("audit events reject DELETE", "DELETE FROM audit_events"),
    ("audit events reject TRUNCATE", "TRUNCATE audit_events"),
    ("support grants reject self approval", "INSERT INTO support_grants(id,operator_user_id,site_id,permissions,reason,approved_by,expires_at) SELECT 'self-approved',u.id,s.id,ARRAY['UNIT_READ'],'Test support access',u.id,now()+interval '5 minutes' FROM users u,sites s LIMIT 1"),
    ("support grants reject excessive duration", "INSERT INTO support_grants(id,operator_user_id,site_id,permissions,reason,expires_at) SELECT 'too-long',u.id,s.id,ARRAY['UNIT_READ'],'Test support access',now()+interval '61 minutes' FROM users u,sites s LIMIT 1"),
]

# (name, statement, assertion query that must return 't')
POSITIVE_CASES = [
    ("audit projection removes credentials and preserves decimal amounts",
     "SELECT 1",
     "SELECT sp_audit_projection('{\"password_hash\":\"SECRET\",\"token\":\"SECRET\",\"status\":\"ACTIVE\",\"amount\":12.34}'::jsonb) = '{\"status\":\"ACTIVE\",\"amount\":\"12.34\"}'::jsonb"),

    ("national id is never stored in clear text (M6)",
     "INSERT INTO persons (national_id, full_name, person_type) VALUES ('11111111110', 'PII Check', 'HOME_OWNER')",
     "SELECT national_id IS NULL AND national_id_masked = '*******1110' AND length(national_id_hash) = 64 FROM persons WHERE full_name = 'PII Check'"),
    ("unit owner follows the ownership history (M1)",
     "INSERT INTO unit_ownerships (unit_id, person_id, share_percentage, start_date, is_active)"
     " SELECT (SELECT min(id) FROM units), id, 100, CURRENT_DATE, TRUE FROM persons WHERE full_name = 'PII Check'",
     "SELECT owner_person_id = (SELECT id FROM persons WHERE full_name = 'PII Check') FROM units WHERE id = (SELECT min(id) FROM units)"),
    ("an UNMATCHED entry settles in place with its receipt (V16 P-06)",
     V16_RECEIPT.format(number="V16-P1", seq=9101) + "; " + V16_UNMATCHED.format(ref="V16-P1") + ";"
     " UPDATE payment_entries e SET settlement_status = 'SETTLED', receipt_id = r.id FROM payment_receipts r"
     " WHERE r.receipt_number = 'V16-P1' AND e.external_reference = 'V16-P1'",
     "SELECT settlement_status = 'SETTLED' AND receipt_id IS NOT NULL FROM payment_entries WHERE external_reference = 'V16-P1'"),
    ("payer identity is resolved from the ownership history (V16 P-02)",
     "SELECT 1",
     "SELECT (SELECT owner_person_id FROM units WHERE id = (SELECT min(id) FROM units)) IS NOT NULL"
     " AND (SELECT p.person_id FROM sp_unit_party_at((SELECT min(id) FROM units), 'OWNER', CURRENT_DATE) p)"
     "     = (SELECT owner_person_id FROM units WHERE id = (SELECT min(id) FROM units))"),
    ("the purge switch lifts the ledger guard for one transaction only (V16 P-06)",
     V16_RECEIPT.format(number="V16-P2", seq=9102) + ";"
     " BEGIN; SET LOCAL sitepulse.allow_ledger_purge = 'on'; DELETE FROM payment_receipts WHERE receipt_number = 'V16-P2'; COMMIT;",
     "SELECT NOT EXISTS (SELECT 1 FROM payment_receipts WHERE receipt_number = 'V16-P2')"
     " AND coalesce(current_setting('sitepulse.allow_ledger_purge', true), '') <> 'on'"),
    ("a reversal restores the paid amounts and keeps the drift views clean (V17 O-2)",
     V17_SETTLED.format(ref="V17-P1", seq=9301) + "; " + V17_REVERSAL_RECEIPT.format(number="V17-P1-R", seq=9301, ref="V17-P1")
     + "; " + V17_CONTRA.format(reason="'Bounced transfer'", ref="V17-P1", number="V17-P1-R")
     + "; UPDATE dues_liabilities SET paid_principal = 0, paid_amount = 0, status = 'PENDING' WHERE period = 'V17-P1'"
     + "; UPDATE payment_entries SET settlement_status = 'REVERSED' WHERE external_reference = 'V17-P1'",
     "SELECT (SELECT settlement_status FROM payment_entries WHERE external_reference = 'V17-P1') = 'REVERSED'"
     " AND NOT EXISTS (SELECT 1 FROM v_integrity_violations)"
     " AND NOT EXISTS (SELECT 1 FROM v_duplicated_fact_drift f JOIN payment_receipts r ON r.id::text = f.subject"
     "                 WHERE f.fact LIKE 'payment_receipts%' AND r.receipt_number LIKE 'V17-P1%')"),
    ("TAH and IAD series number independently per site (V17 O-2)",
     "SELECT 1",
     "SELECT count(DISTINCT receipt_type) = 2 AND count(DISTINCT site_id) = 1 AND count(DISTINCT sequence_number) = 1"
     " FROM payment_receipts WHERE receipt_number IN ('V17-P1', 'V17-P1-R')"),
    ("the same transaction id is accepted for another bank account or site (V17 O-3)",
     V17_CLAIM.format(txn="V17-P2") + "; INSERT INTO processed_bank_webhooks (transaction_id, site_id) SELECT 'V17-P2', site_id FROM site_bank_accounts ORDER BY id LIMIT 1"
     "; INSERT INTO processed_bank_webhooks (transaction_id) VALUES ('V17-P2')",
     "SELECT count(*) = 3 AND count(DISTINCT scope_key) = 3 FROM processed_bank_webhooks WHERE transaction_id = 'V17-P2'"),
    ("the effective status of an unpaid past-due liability is OVERDUE (V17 O-6)",
     "INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, status) SELECT id, 'V17-P3', 10, CURRENT_DATE - 3, 'PENDING' FROM units LIMIT 1",
     "SELECT effective_status = 'OVERDUE' FROM v_dues_effective_status WHERE period = 'V17-P3'"),
    ("no integrity violations on seeded data (M4)", "SELECT 1", "SELECT count(*) = 0 FROM v_integrity_violations"),
]

# Rows inserted the way the V7-era application wrote them (before V8 and later).
V7_DATA = """
INSERT INTO sites (id, name, address, slug) VALUES (1, 'Upgrade Site', 'Istanbul', 'upgrade-site');
INSERT INTO blocks (id, site_id, block_name, total_floors) VALUES (1, 1, 'A Blok', 5);
INSERT INTO persons (id, national_id, full_name, email, person_type) VALUES (1, '12345678901', 'Legacy Owner', 'legacy.owner@example.com', 'KAT_MALIKI');
INSERT INTO units (id, block_id, site_id, unit_number, floor, land_share, owner_person_id) VALUES (1, 1, 1, 1, 1, 10, 1);
INSERT INTO users (id, site_id, person_id, email, password_hash, role, must_change_password)
    VALUES (1, 1, 1, 'Legacy.Owner@Example.com', 'ARGON2_HASH_legacy', 'HOME_OWNER', FALSE);
INSERT INTO dues_liabilities (id, unit_id, period, principal_amount, delay_penalty, paid_amount, due_date, status)
    VALUES (1, 1, 'Ocak 2026', 100.00, 5.00, 102.00, '2026-01-15', 'PENDING');
INSERT INTO payment_receipts (site_id, unit_id, receipt_number, sequence_number, payer_name, payer_role, total_amount,
                              allocated_principal, payment_channel, channel_reference, verification_hash)
    VALUES (1, 1, 'TAH-2026-000001', 1, 'Legacy Owner', 'OWNER', 10.00, 10.00, 'MANUAL_CASH', 'IDEMPOTENCY:legacy-key-1', 'h');
INSERT INTO reconciliation_queue (match_id, transaction_id, txn_date, amount, description, status, status_code, matched_unit_id)
    VALUES ('MATCH-LEGACY-1', 'TXN-LEGACY-1', '2026-01-20', 10.00, 'legacy', 'Approved', 'ONAYLANDI', 1);
"""

UPGRADE_ASSERTIONS = [
    ("legacy rows survive the upgrade",
     "SELECT (SELECT count(*) FROM units) = 1 AND (SELECT count(*) FROM dues_liabilities) = 1 AND (SELECT count(*) FROM users WHERE id = 1) = 1"),
    ("paid_penalty backfilled consistently", "SELECT bool_and(paid_amount = paid_principal + paid_penalty) FROM dues_liabilities"),
    ("legacy person_type translated (V8)", "SELECT person_type = 'HOME_OWNER' FROM persons WHERE id = 1"),
    ("legacy national id no longer in clear text (V15)", "SELECT national_id IS NULL AND national_id_masked IS NOT NULL FROM persons WHERE id = 1"),
    ("e-mails lower-cased (V14)", "SELECT bool_and(email = lower(email)) FROM users"),
    ("created_at is never NULL",
     "SELECT count(*) = 0 FROM information_schema.columns c JOIN information_schema.tables t USING (table_schema, table_name)"
     " WHERE c.table_schema = 'public' AND t.table_type = 'BASE TABLE' AND c.column_name = 'created_at' AND c.is_nullable = 'YES'"),
    ("every constraint is validated", "SELECT count(*) = 0 FROM pg_constraint WHERE connamespace = 'public'::regnamespace AND NOT convalidated"),
    ("open overdue penalties carry their accrual date (V16 P-01)",
     "SELECT bool_and(penalty_accrued_through IS NOT NULL) FROM dues_liabilities WHERE delay_penalty > 0 AND status NOT IN ('PAID', 'CANCELLED')"),
    ("legacy IDEMPOTENCY:<key> references carried into payment_idempotency_keys (V17 O-4)",
     "SELECT EXISTS (SELECT 1 FROM payment_idempotency_keys k JOIN payment_receipts r ON r.id = k.receipt_id"
     " WHERE k.idempotency_key = 'legacy-key-1' AND r.receipt_number = 'TAH-2026-000001')"),
    ("legacy reconciliation statuses translated, status_code dropped (V17 O-7)",
     "SELECT (SELECT status FROM reconciliation_queue WHERE match_id = 'MATCH-LEGACY-1') = 'APPROVED'"
     " AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'reconciliation_queue' AND column_name = 'status_code')"),
    ("legacy partially paid liability carries a consistent status (V17 O-6)",
     "SELECT status IN ('PENDING', 'PARTIALLY_PAID') FROM dues_liabilities WHERE id = 1"),
    ("legacy receipts default to the collection series (V17 O-2)",
     "SELECT bool_and(receipt_type = 'COLLECTION') FROM payment_receipts"),
    ("ledger triggers installed (V16 P-06)",
     "SELECT count(*) = 5 FROM pg_trigger WHERE tgname IN ('trg_payment_receipts_append_only', 'trg_payment_allocations_append_only',"
     " 'trg_advance_ledger_append_only', 'trg_idempotency_keys_append_only', 'trg_payment_entries_guard')"),
]


def psql(db: str, sql: str, stop: bool = True) -> subprocess.CompletedProcess:
    if shutil.which("psql"):
        dsn = (f"postgresql://{DB_USER}:{os.environ.get('DB_PASS', '')}@{os.environ.get('DB_HOST', '127.0.0.1')}:"
               f"{os.environ.get('DB_PORT', '5432')}/{db}")
        cmd = ["psql", dsn, "-X", "-q", "-t", "-A"]
    else:
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


def assert_true(db: str, query: str) -> tuple[bool, list[str]]:
    result = psql(db, query)
    if result.returncode != 0:
        return False, [result.stderr.strip()]
    return result.stdout.strip() == "t", [] if result.stdout.strip() == "t" else [f"returned {result.stdout.strip()!r}"]


def migrations() -> list[pathlib.Path]:
    files = sorted(MIGRATIONS_DIR.glob("V*__*.sql"), key=lambda p: int(p.stem.split("__")[0][1:]))
    versions = [int(p.stem.split("__")[0][1:]) for p in files]
    if versions != list(range(1, len(files) + 1)):
        raise RuntimeError(f"migration versions are not contiguous from V1: {versions}")
    return files


def check() -> dict:
    findings: list[dict] = []
    files = migrations()
    fresh, upgraded = "sitepulse_check_fresh", "sitepulse_check_upgrade"
    recreate(fresh)
    recreate(upgraded)
    try:
        # 1. Fresh install + constraint behaviour.
        replay(fresh, files)
        fresh_schema = schema_of(fresh)
        replay(fresh, sorted(SEED_DIR.glob("0[12]-*.sql")))
        for name, sql in NEGATIVE_CASES:
            result = psql(fresh, f"BEGIN; {sql}; ROLLBACK;")
            findings.append({"check": f"rejects: {name}", "ok": result.returncode != 0,
                             "detail": [] if result.returncode != 0 else ["statement was accepted"]})
        for name, sql, query in POSITIVE_CASES:
            done = psql(fresh, sql)
            ok, detail = (False, [done.stderr.strip()]) if done.returncode != 0 else assert_true(fresh, query)
            findings.append({"check": f"enforces: {name}", "ok": ok, "detail": detail})

        # 2. Upgrade path on existing rows.
        old = [p for p in files if int(p.stem.split("__")[0][1:]) <= UPGRADE_FROM]
        new = [p for p in files if int(p.stem.split("__")[0][1:]) > UPGRADE_FROM]
        replay(upgraded, old)
        data = psql(upgraded, V7_DATA)
        findings.append({"check": f"upgrade: V{UPGRADE_FROM}-era rows load", "ok": data.returncode == 0, "detail": [data.stderr.strip()] if data.returncode else []})
        try:
            replay(upgraded, new)
            findings.append({"check": f"upgrade: V{UPGRADE_FROM + 1}..V{len(files)} apply on existing rows", "ok": True, "detail": []})
        except RuntimeError as exc:
            findings.append({"check": f"upgrade: V{UPGRADE_FROM + 1}..V{len(files)} apply on existing rows", "ok": False, "detail": [str(exc)]})
        for name, query in UPGRADE_ASSERTIONS:
            ok, detail = assert_true(upgraded, query)
            findings.append({"check": f"upgrade: {name}", "ok": ok, "detail": detail})
        drift = sorted(set(fresh_schema).symmetric_difference(schema_of(upgraded)))
        findings.append({"check": "upgrade: upgraded schema equals a fresh install", "ok": not drift, "detail": drift[:20]})
    finally:
        psql(ADMIN_DB, f'DROP DATABASE IF EXISTS "{fresh}";')
        psql(ADMIN_DB, f'DROP DATABASE IF EXISTS "{upgraded}";')
    return {"ok": all(item["ok"] for item in findings), "findings": findings}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON")
    args = parser.parse_args()
    try:
        report = check()
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
