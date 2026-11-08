-- V16: Payment ledger integrity (SPEC-005 and docs/PAYMENTS_DATABASE_DESIGN_REVIEW.md).
--
-- P-01  KMK 20 segmented penalty accrual: dues_liabilities.penalty_accrued_through.
-- P-02  Payer identity on the ledger: payer_person_id / occupancy_id / on_behalf_of_person_id.
-- P-03  Every SETTLED entry carries a receipt (legacy rows are flagged, not faked).
-- P-04  One entry per receipt; one allocation row per (entry, liability).
-- P-05  The duplicated single-due link payment_entries.dues_liability_id is removed
--       (payment_allocations is the only allocation fact).
-- P-06  Ledger rows are append-only (triggers); payment_entries allows only the
--       documented status transitions. A transaction-scoped purge switch exists for
--       non-production test rollbacks only.
-- P-07  Timestamps that define the ledger order are NOT NULL.
-- P-08  Signed advance adjustments (ADJUSTMENT_CREDIT / ADJUSTMENT_DEBIT) so the
--       advance ledger explains every balance change; drift view extended.
-- P-09  Lookup indexes for external references and the unmatched queue.

-- ---------------------------------------------------------------------------
-- P-01: KMK 20 segmented penalty accrual.
-- delay_penalty is accrued up to penalty_accrued_through; the next evaluation adds
-- only the segment after that date, on the then-outstanding principal. Legacy
-- open rows with an accrued penalty are frozen at the migration date (never
-- over-charging: a later segment starts from today, not from the due date).
-- ---------------------------------------------------------------------------
ALTER TABLE dues_liabilities ADD COLUMN IF NOT EXISTS penalty_accrued_through DATE;
UPDATE dues_liabilities
SET penalty_accrued_through = GREATEST(due_date, CURRENT_DATE)
WHERE penalty_accrued_through IS NULL AND delay_penalty > 0 AND status NOT IN ('PAID', 'CANCELLED');
SELECT sp_add_constraint('dues_liabilities', 'chk_dues_penalty_accrued_after_due',
    $c$CHECK (penalty_accrued_through IS NULL OR penalty_accrued_through >= due_date)$c$);

-- ---------------------------------------------------------------------------
-- P-02: payer identity. Names stay as the printed snapshot; the person and the
-- occupancy are the relational facts used for sub-ledgers (STORY-09-03/05).
-- ---------------------------------------------------------------------------
ALTER TABLE payment_entries ADD COLUMN IF NOT EXISTS payer_person_id BIGINT;
ALTER TABLE payment_entries ADD COLUMN IF NOT EXISTS occupancy_id BIGINT;
ALTER TABLE payment_receipts ADD COLUMN IF NOT EXISTS payer_person_id BIGINT;
ALTER TABLE payment_receipts ADD COLUMN IF NOT EXISTS on_behalf_of_person_id BIGINT;
SELECT sp_set_fk('payment_entries', 'payer_person_id', 'persons', 'fk_payment_entries_payer_person', 'RESTRICT');
SELECT sp_set_fk('payment_entries', 'occupancy_id', 'unit_occupancies', 'fk_payment_entries_occupancy', 'RESTRICT');
SELECT sp_set_fk('payment_receipts', 'payer_person_id', 'persons', 'fk_payment_receipts_payer_person', 'RESTRICT');
SELECT sp_set_fk('payment_receipts', 'on_behalf_of_person_id', 'persons', 'fk_payment_receipts_on_behalf_person', 'RESTRICT');
CREATE INDEX IF NOT EXISTS idx_payment_entries_payer_person ON payment_entries (payer_person_id);
CREATE INDEX IF NOT EXISTS idx_payment_entries_occupancy ON payment_entries (occupancy_id);
CREATE INDEX IF NOT EXISTS idx_payment_receipts_payer_person ON payment_receipts (payer_person_id);
CREATE INDEX IF NOT EXISTS idx_payment_receipts_on_behalf_person ON payment_receipts (on_behalf_of_person_id);

-- Resolves the person holding `p_role` on a unit at a date: the history tables first,
-- then the unit's current owner/tenant column when no history row exists.
CREATE OR REPLACE FUNCTION sp_unit_party_at(p_unit BIGINT, p_role TEXT, p_at DATE)
RETURNS TABLE (person_id BIGINT, occupancy_id BIGINT) AS $$
BEGIN
    IF p_role = 'OWNER' THEN
        RETURN QUERY
        SELECT o.person_id, oc.id
        FROM unit_ownerships o
        LEFT JOIN unit_occupancies oc
               ON oc.unit_id = o.unit_id AND oc.person_id = o.person_id AND oc.occupancy_type = 'OWNER'
              AND oc.start_date <= p_at AND (oc.end_date IS NULL OR oc.end_date >= p_at)
        WHERE o.unit_id = p_unit AND o.start_date <= p_at AND (o.end_date IS NULL OR o.end_date >= p_at)
        ORDER BY o.share_percentage DESC, o.start_date DESC, o.id DESC
        LIMIT 1;
        IF NOT FOUND THEN
            -- No ownership history (pre-V7 data or direct seeds): the unit's owner column.
            RETURN QUERY SELECT u.owner_person_id, NULL::BIGINT FROM units u
                         WHERE u.id = p_unit AND u.owner_person_id IS NOT NULL;
        END IF;
    ELSE
        RETURN QUERY
        SELECT oc.person_id, oc.id
        FROM unit_occupancies oc
        WHERE oc.unit_id = p_unit AND oc.occupancy_type = 'TENANT'
          AND oc.start_date <= p_at AND (oc.end_date IS NULL OR oc.end_date >= p_at)
        ORDER BY oc.start_date DESC, oc.id DESC
        LIMIT 1;
        IF NOT FOUND THEN
            RETURN QUERY SELECT u.tenant_person_id, NULL::BIGINT FROM units u
                         WHERE u.id = p_unit AND u.tenant_person_id IS NOT NULL;
        END IF;
    END IF;
END;
$$ LANGUAGE plpgsql STABLE;

-- P-07 first, so the backfill below can rely on payment_date.
UPDATE payment_entries SET payment_date = created_at WHERE payment_date IS NULL;
ALTER TABLE payment_entries ALTER COLUMN payment_date SET NOT NULL;
UPDATE payment_receipts SET issued_at = CURRENT_TIMESTAMP WHERE issued_at IS NULL;
ALTER TABLE payment_receipts ALTER COLUMN issued_at SET NOT NULL;

UPDATE payment_entries e
SET (payer_person_id, occupancy_id) = (
    SELECT p.person_id, p.occupancy_id FROM sp_unit_party_at(e.unit_id, e.payer_role, e.payment_date::date) p)
WHERE e.payer_person_id IS NULL;

UPDATE payment_receipts r
SET payer_person_id = (SELECT p.person_id FROM sp_unit_party_at(r.unit_id, r.payer_role, r.issued_at::date) p)
WHERE r.payer_person_id IS NULL;

UPDATE payment_receipts r
SET on_behalf_of_person_id = (SELECT p.person_id FROM sp_unit_party_at(r.unit_id, 'OWNER', r.issued_at::date) p)
WHERE r.on_behalf_of_person_id IS NULL AND r.on_behalf_of_role = 'OWNER';

-- ---------------------------------------------------------------------------
-- P-05: payment_allocations is the only allocation fact. Rows that only had the
-- legacy single-due link are carried over first (same rule as V12), then the
-- duplicated column is dropped.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name = 'payment_entries' AND column_name = 'dues_liability_id') THEN
        INSERT INTO payment_allocations (payment_entry_id, dues_liability_id, principal_amount, penalty_amount, created_at)
        SELECT pe.id, pe.dues_liability_id,
               LEAST(pe.amount, d.principal_amount), 0.00,
               COALESCE(pe.payment_date, pe.created_at, CURRENT_TIMESTAMP)
        FROM payment_entries pe
        JOIN dues_liabilities d ON d.id = pe.dues_liability_id
        WHERE pe.dues_liability_id IS NOT NULL
          AND LEAST(pe.amount, d.principal_amount) > 0
          AND NOT EXISTS (SELECT 1 FROM payment_allocations pa WHERE pa.payment_entry_id = pe.id);
        ALTER TABLE payment_entries DROP COLUMN dues_liability_id;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- P-03: a SETTLED entry is backed by a receipt (TBK 103). Entries settled by the
-- pre-SPEC-005 code paths had none; they are flagged instead of being given a
-- fabricated receipt, and new rows can no longer be SETTLED without one.
-- ---------------------------------------------------------------------------
ALTER TABLE payment_entries ADD COLUMN IF NOT EXISTS legacy_unreceipted BOOLEAN NOT NULL DEFAULT FALSE;
UPDATE payment_entries SET legacy_unreceipted = TRUE
WHERE settlement_status = 'SETTLED' AND receipt_id IS NULL AND NOT legacy_unreceipted;
SELECT sp_add_constraint('payment_entries', 'chk_payment_entries_settled_has_receipt',
    $c$CHECK (settlement_status <> 'SETTLED' OR receipt_id IS NOT NULL OR legacy_unreceipted)$c$);

-- A receipt can never be deleted out from under its entry (was ON DELETE SET NULL).
SELECT sp_set_fk('payment_entries', 'receipt_id', 'payment_receipts', 'fk_payment_entries_receipt', 'RESTRICT');

-- ---------------------------------------------------------------------------
-- P-04: one entry per receipt; one allocation line per (entry, liability).
-- Duplicates (if any) are merged before the unique index is built.
-- ---------------------------------------------------------------------------
UPDATE payment_entries e SET receipt_id = NULL, legacy_unreceipted = TRUE
WHERE e.receipt_id IS NOT NULL
  AND e.id <> (SELECT min(x.id) FROM payment_entries x WHERE x.receipt_id = e.receipt_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_payment_entries_receipt ON payment_entries (receipt_id) WHERE receipt_id IS NOT NULL;

WITH merged AS (
    SELECT payment_entry_id, dues_liability_id, min(id) AS keep_id,
           sum(principal_amount) AS principal_amount, sum(penalty_amount) AS penalty_amount
    FROM payment_allocations
    GROUP BY payment_entry_id, dues_liability_id
    HAVING count(*) > 1
)
UPDATE payment_allocations pa
SET principal_amount = m.principal_amount, penalty_amount = m.penalty_amount
FROM merged m WHERE pa.id = m.keep_id;
DELETE FROM payment_allocations pa
USING payment_allocations k
WHERE pa.payment_entry_id = k.payment_entry_id AND pa.dues_liability_id = k.dues_liability_id AND pa.id > k.id;
CREATE UNIQUE INDEX IF NOT EXISTS uq_payment_allocation_line ON payment_allocations (payment_entry_id, dues_liability_id);

-- ---------------------------------------------------------------------------
-- P-09: lookup indexes.
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_payment_entries_external_ref
    ON payment_entries (site_id, external_reference) WHERE external_reference IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_payment_entries_unmatched
    ON payment_entries (site_id, payment_date) WHERE settlement_status = 'UNMATCHED';
CREATE INDEX IF NOT EXISTS idx_advance_ledger_reference
    ON advance_ledger_entries (reference_id) WHERE reference_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- P-08: signed advance adjustments and an extended drift view.
-- ---------------------------------------------------------------------------
ALTER TABLE advance_ledger_entries DROP CONSTRAINT IF EXISTS chk_advance_ledger_entry_type;
SELECT sp_add_constraint('advance_ledger_entries', 'chk_advance_ledger_entry_type',
    $c$CHECK (entry_type IN ('PAYMENT_SURPLUS', 'OFFSET_APPLIED', 'VIRMAN_DEBIT', 'REFUND', 'ADJUSTMENT',
                             'ADJUSTMENT_CREDIT', 'ADJUSTMENT_DEBIT'))$c$);

CREATE OR REPLACE VIEW v_integrity_violations AS
SELECT 'advance_balance_vs_ledger' AS check_name, ab.unit_id::text || '/' || ab.debtor_type AS subject,
       ab.balance - COALESCE(l.net, 0) AS difference
FROM advance_balances ab
LEFT JOIN (
    SELECT unit_id, debtor_type,
           SUM(CASE WHEN entry_type IN ('PAYMENT_SURPLUS', 'ADJUSTMENT_CREDIT') THEN amount
                    WHEN entry_type = 'ADJUSTMENT' THEN 0
                    ELSE -amount END) AS net
    FROM advance_ledger_entries GROUP BY unit_id, debtor_type
) l ON l.unit_id = ab.unit_id AND l.debtor_type = ab.debtor_type
WHERE ab.balance <> COALESCE(l.net, 0)
UNION ALL
SELECT 'installment_percentages', project_id::text, SUM(percentage) - 100
FROM capital_project_installments GROUP BY project_id HAVING SUM(percentage) <> 100
UNION ALL
SELECT 'allocations_vs_dues_paid', d.id::text,
       (d.paid_principal + d.paid_penalty) - COALESCE(SUM(pa.principal_amount + pa.penalty_amount), 0)
FROM dues_liabilities d
LEFT JOIN payment_allocations pa ON pa.dues_liability_id = d.id
GROUP BY d.id
HAVING EXISTS (SELECT 1 FROM payment_allocations x WHERE x.dues_liability_id = d.id)
   AND (d.paid_principal + d.paid_penalty) <> COALESCE(SUM(pa.principal_amount + pa.penalty_amount), 0)
UNION ALL
SELECT 'allocations_exceed_entry_amount', e.id::text,
       COALESCE(SUM(pa.principal_amount + pa.penalty_amount), 0) - e.amount
FROM payment_entries e
JOIN payment_allocations pa ON pa.payment_entry_id = e.id
GROUP BY e.id, e.amount
HAVING COALESCE(SUM(pa.principal_amount + pa.penalty_amount), 0) > e.amount
UNION ALL
SELECT 'entry_vs_receipt_amount', e.id::text, e.amount - r.total_amount
FROM payment_entries e
JOIN payment_receipts r ON r.id = e.receipt_id
WHERE e.amount <> r.total_amount AND e.payment_channel <> 'INTER_LEDGER';

-- ---------------------------------------------------------------------------
-- P-06: append-only ledger.
-- Receipts, allocations, advance ledger entries and idempotency keys are never
-- updated or deleted. A payment entry may only move UNMATCHED -> SETTLED (taking
-- its receipt) or SETTLED -> REVERSED, and may have its payer identity filled in;
-- its amount, unit, site, channel, date and reference are fixed.
-- `SET LOCAL sitepulse.allow_ledger_purge = 'on'` (non-production test rollback,
-- see handlers::purge_site_cascade) lifts the guard for one transaction.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sp_ledger_append_only() RETURNS trigger AS $$
BEGIN
    IF current_setting('sitepulse.allow_ledger_purge', true) = 'on' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    RAISE EXCEPTION '% rows are append-only (% rejected)', TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'integrity_constraint_violation';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_payment_receipts_append_only ON payment_receipts;
CREATE TRIGGER trg_payment_receipts_append_only BEFORE UPDATE OR DELETE ON payment_receipts
    FOR EACH ROW EXECUTE FUNCTION sp_ledger_append_only();
DROP TRIGGER IF EXISTS trg_payment_allocations_append_only ON payment_allocations;
CREATE TRIGGER trg_payment_allocations_append_only BEFORE UPDATE OR DELETE ON payment_allocations
    FOR EACH ROW EXECUTE FUNCTION sp_ledger_append_only();
DROP TRIGGER IF EXISTS trg_advance_ledger_append_only ON advance_ledger_entries;
CREATE TRIGGER trg_advance_ledger_append_only BEFORE UPDATE OR DELETE ON advance_ledger_entries
    FOR EACH ROW EXECUTE FUNCTION sp_ledger_append_only();
DROP TRIGGER IF EXISTS trg_idempotency_keys_append_only ON payment_idempotency_keys;
CREATE TRIGGER trg_idempotency_keys_append_only BEFORE UPDATE OR DELETE ON payment_idempotency_keys
    FOR EACH ROW EXECUTE FUNCTION sp_ledger_append_only();

CREATE OR REPLACE FUNCTION sp_payment_entry_guard() RETURNS trigger AS $$
BEGIN
    IF current_setting('sitepulse.allow_ledger_purge', true) = 'on' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'payment_entries rows are append-only (DELETE rejected)'
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    IF NEW.amount IS DISTINCT FROM OLD.amount
       OR NEW.site_id IS DISTINCT FROM OLD.site_id
       OR NEW.unit_id IS DISTINCT FROM OLD.unit_id
       OR NEW.payment_channel IS DISTINCT FROM OLD.payment_channel
       OR NEW.payment_date IS DISTINCT FROM OLD.payment_date
       OR NEW.external_reference IS DISTINCT FROM OLD.external_reference
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR (OLD.payer_person_id IS NOT NULL AND NEW.payer_person_id IS DISTINCT FROM OLD.payer_person_id)
       OR (OLD.occupancy_id IS NOT NULL AND NEW.occupancy_id IS DISTINCT FROM OLD.occupancy_id) THEN
        RAISE EXCEPTION 'payment_entries %: financial columns are immutable', OLD.id
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    IF NEW.settlement_status IS DISTINCT FROM OLD.settlement_status THEN
        IF NOT ((OLD.settlement_status IN ('UNMATCHED', 'PENDING') AND NEW.settlement_status = 'SETTLED'
                 AND OLD.receipt_id IS NULL AND NEW.receipt_id IS NOT NULL)
                OR (OLD.settlement_status = 'SETTLED' AND NEW.settlement_status = 'REVERSED')) THEN
            RAISE EXCEPTION 'payment_entries %: transition % -> % is not allowed',
                OLD.id, OLD.settlement_status, NEW.settlement_status
                USING ERRCODE = 'integrity_constraint_violation';
        END IF;
    ELSIF NEW.receipt_id IS DISTINCT FROM OLD.receipt_id THEN
        RAISE EXCEPTION 'payment_entries %: receipt_id changes only with UNMATCHED -> SETTLED', OLD.id
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_payment_entries_guard ON payment_entries;
CREATE TRIGGER trg_payment_entries_guard BEFORE UPDATE OR DELETE ON payment_entries
    FOR EACH ROW EXECUTE FUNCTION sp_payment_entry_guard();
