-- V17: Payment ledger hardening (SPEC-006, docs/PAYMENTS_DATABASE_DESIGN_REVIEW.md §4).
--
-- O-1  Advance balances are per debtor end to end: receipts record which debtor's
--      advance received the surplus (advance_debtor_type).
-- O-2  Reversals: contra entries (entry_type REVERSAL, reverses_entry_id), a reversal
--      receipt series (receipt_type REVERSAL, IAD-YYYY-NNNNNN, own counter), an audit
--      reason and actor. A reversed entry's allocations no longer count as paid.
-- O-3  processed_bank_webhooks is keyed by (bank account | site, transaction_id) and
--      records the receipt and a payload hash.
-- O-4  Idempotency lives only in payment_idempotency_keys (legacy IDEMPOTENCY:<key>
--      channel references are carried over).
-- O-5  sites.tax_id / tax_office plus an issuer snapshot on every new receipt.
-- O-6  Paid-derived liability statuses are constrained; v_dues_effective_status
--      derives the time-dependent status (OVERDUE) on read.
-- O-7  reconciliation_queue: one English status vocabulary, the duplicated
--      status_code column dropped, bank account FK RESTRICT.
-- O-10 payment_entries.payer_role has no default (every writer sets it).
--
-- Receipts are append-only (V16). The two backfills below that touch issued
-- receipts only fill a newly added column; they lift the guard inside a single DO
-- statement, so the switch never outlives that statement.

-- ---------------------------------------------------------------------------
-- O-2: reversal receipts and their own number series.
-- ---------------------------------------------------------------------------
ALTER TABLE payment_receipts ADD COLUMN IF NOT EXISTS receipt_type VARCHAR(20) NOT NULL DEFAULT 'COLLECTION';
ALTER TABLE payment_receipts ADD COLUMN IF NOT EXISTS reverses_receipt_id BIGINT;
SELECT sp_add_constraint('payment_receipts', 'chk_payment_receipts_type',
    $c$CHECK (receipt_type IN ('COLLECTION', 'REVERSAL'))$c$);
SELECT sp_add_constraint('payment_receipts', 'chk_payment_receipts_reversal_link',
    $c$CHECK ((receipt_type = 'REVERSAL') = (reverses_receipt_id IS NOT NULL))$c$);
SELECT sp_set_fk('payment_receipts', 'reverses_receipt_id', 'payment_receipts', 'fk_payment_receipts_reverses', 'RESTRICT');
CREATE UNIQUE INDEX IF NOT EXISTS uq_payment_receipts_reverses
    ON payment_receipts (reverses_receipt_id) WHERE reverses_receipt_id IS NOT NULL;

-- The sequence is unique per (site, series): TAH- collections and IAD- reversals
-- are numbered independently.
DROP INDEX IF EXISTS uq_site_receipt_sequence;
CREATE UNIQUE INDEX IF NOT EXISTS uq_site_receipt_series_sequence
    ON payment_receipts (site_id, receipt_type, sequence_number);

ALTER TABLE receipt_counters ADD COLUMN IF NOT EXISTS receipt_type VARCHAR(20) NOT NULL DEFAULT 'COLLECTION';
SELECT sp_add_constraint('receipt_counters', 'chk_receipt_counters_type',
    $c$CHECK (receipt_type IN ('COLLECTION', 'REVERSAL'))$c$);
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
        WHERE c.conrelid = 'receipt_counters'::regclass AND c.contype = 'p' AND a.attname = 'receipt_type'
    ) THEN
        ALTER TABLE receipt_counters DROP CONSTRAINT IF EXISTS receipt_counters_pkey;
        ALTER TABLE receipt_counters ADD CONSTRAINT receipt_counters_pkey PRIMARY KEY (site_id, receipt_type);
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- O-2: contra entries. A reversal is a new row (the ledger is append-only); the
-- original moves SETTLED -> REVERSED only once its contra entry exists.
-- ---------------------------------------------------------------------------
ALTER TABLE payment_entries ADD COLUMN IF NOT EXISTS entry_type VARCHAR(20) NOT NULL DEFAULT 'COLLECTION';
ALTER TABLE payment_entries ADD COLUMN IF NOT EXISTS reverses_entry_id BIGINT;
ALTER TABLE payment_entries ADD COLUMN IF NOT EXISTS reversal_reason TEXT;
ALTER TABLE payment_entries ADD COLUMN IF NOT EXISTS recorded_by VARCHAR(255);
SELECT sp_add_constraint('payment_entries', 'chk_payment_entries_entry_type',
    $c$CHECK (entry_type IN ('COLLECTION', 'REVERSAL'))$c$);
SELECT sp_add_constraint('payment_entries', 'chk_payment_entries_reversal_shape',
    $c$CHECK ((entry_type = 'REVERSAL') = (reverses_entry_id IS NOT NULL)
              AND (entry_type <> 'REVERSAL'
                   OR (settlement_status = 'REVERSED' AND receipt_id IS NOT NULL
                       AND length(btrim(COALESCE(reversal_reason, ''))) >= 3
                       AND length(btrim(COALESCE(recorded_by, ''))) > 0)))$c$);
SELECT sp_set_fk('payment_entries', 'reverses_entry_id', 'payment_entries', 'fk_payment_entries_reverses', 'RESTRICT');
CREATE UNIQUE INDEX IF NOT EXISTS uq_payment_entries_reverses
    ON payment_entries (reverses_entry_id) WHERE reverses_entry_id IS NOT NULL;

-- O-1: the debtor whose advance received a receipt's surplus.
ALTER TABLE payment_receipts ADD COLUMN IF NOT EXISTS advance_debtor_type VARCHAR(20);
DO $$
BEGIN
    PERFORM set_config('sitepulse.allow_ledger_purge', 'on', true);
    UPDATE payment_receipts r
    SET advance_debtor_type = COALESCE(
        (SELECT l.debtor_type FROM advance_ledger_entries l
         WHERE l.reference_id = r.receipt_number AND l.entry_type = 'PAYMENT_SURPLUS'
         ORDER BY l.id LIMIT 1),
        r.payer_role)
    WHERE r.allocated_advance > 0 AND r.advance_debtor_type IS NULL;
    PERFORM set_config('sitepulse.allow_ledger_purge', 'off', true);
END $$;
SELECT sp_add_constraint('payment_receipts', 'chk_payment_receipts_advance_debtor',
    $c$CHECK ((advance_debtor_type IS NULL OR advance_debtor_type IN ('OWNER', 'TENANT'))
              AND ((allocated_advance > 0) = (advance_debtor_type IS NOT NULL)))$c$);

-- ---------------------------------------------------------------------------
-- O-5: issuer legal details. sites carries the tax id (VKN 10 digits; a site
-- registered under a manager's T.C. Kimlik No has 11). Each receipt snapshots
-- the issuer as printed; pre-V17 receipts keep NULL (their issuer details at
-- issue time are unknown and are not invented).
-- ---------------------------------------------------------------------------
ALTER TABLE sites ADD COLUMN IF NOT EXISTS tax_id VARCHAR(11);
ALTER TABLE sites ADD COLUMN IF NOT EXISTS tax_office VARCHAR(100);
SELECT sp_add_constraint('sites', 'chk_sites_tax_id_format',
    $c$CHECK (tax_id IS NULL OR tax_id ~ '^[0-9]{10,11}$')$c$);
ALTER TABLE payment_receipts ADD COLUMN IF NOT EXISTS issuer_name VARCHAR(150);
ALTER TABLE payment_receipts ADD COLUMN IF NOT EXISTS issuer_address TEXT;
ALTER TABLE payment_receipts ADD COLUMN IF NOT EXISTS issuer_tax_id VARCHAR(11);
ALTER TABLE payment_receipts ADD COLUMN IF NOT EXISTS issuer_tax_office VARCHAR(100);

-- ---------------------------------------------------------------------------
-- O-4: idempotency is a fact of payment_idempotency_keys only. Keys that were
-- only recorded in channel_reference ('IDEMPOTENCY:<key>') are carried over.
-- ---------------------------------------------------------------------------
INSERT INTO payment_idempotency_keys (site_id, idempotency_key, receipt_id, created_at)
SELECT r.site_id, substr(r.channel_reference, length('IDEMPOTENCY:') + 1), r.id, r.issued_at
FROM payment_receipts r
WHERE r.channel_reference LIKE 'IDEMPOTENCY:%'
  AND length(r.channel_reference) > length('IDEMPOTENCY:')
ON CONFLICT (site_id, idempotency_key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- O-3: webhook claims scoped by bank account (or site), with receipt and hash.
-- ---------------------------------------------------------------------------
ALTER TABLE processed_bank_webhooks ADD COLUMN IF NOT EXISTS id BIGINT GENERATED BY DEFAULT AS IDENTITY;
ALTER TABLE processed_bank_webhooks ADD COLUMN IF NOT EXISTS site_id BIGINT;
ALTER TABLE processed_bank_webhooks ADD COLUMN IF NOT EXISTS site_bank_account_id BIGINT;
ALTER TABLE processed_bank_webhooks ADD COLUMN IF NOT EXISTS receipt_id BIGINT;
ALTER TABLE processed_bank_webhooks ADD COLUMN IF NOT EXISTS payload_hash VARCHAR(64);
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
        WHERE c.conrelid = 'processed_bank_webhooks'::regclass AND c.contype = 'p' AND a.attname = 'transaction_id'
    ) THEN
        ALTER TABLE processed_bank_webhooks DROP CONSTRAINT processed_bank_webhooks_pkey;
        ALTER TABLE processed_bank_webhooks ADD CONSTRAINT processed_bank_webhooks_pkey PRIMARY KEY (id);
    END IF;
END $$;

-- Backfill the scope of pre-V17 claims, so a bank retry of an old transaction is
-- still recognised as a duplicate: the receipt's site (idempotency key BANK:<id>)
-- or the unmatched queue row's site, and that site's active bank account.
UPDATE processed_bank_webhooks w
SET site_id = k.site_id, receipt_id = k.receipt_id
FROM payment_idempotency_keys k
WHERE w.site_id IS NULL AND k.idempotency_key = 'BANK:' || w.transaction_id;
UPDATE processed_bank_webhooks w
SET site_id = q.site_id, site_bank_account_id = COALESCE(w.site_bank_account_id, q.site_bank_account_id)
FROM reconciliation_queue q
WHERE w.site_id IS NULL AND q.transaction_id = w.transaction_id;
UPDATE processed_bank_webhooks w
SET site_bank_account_id = a.id
FROM site_bank_accounts a
WHERE w.site_bank_account_id IS NULL AND w.site_id IS NOT NULL AND a.site_id = w.site_id AND a.is_active;

SELECT sp_set_fk('processed_bank_webhooks', 'site_id', 'sites', 'fk_processed_webhooks_site', 'RESTRICT');
SELECT sp_set_fk('processed_bank_webhooks', 'site_bank_account_id', 'site_bank_accounts', 'fk_processed_webhooks_bank_account', 'RESTRICT');
SELECT sp_set_fk('processed_bank_webhooks', 'receipt_id', 'payment_receipts', 'fk_processed_webhooks_receipt', 'RESTRICT');
SELECT sp_add_constraint('processed_bank_webhooks', 'chk_processed_webhooks_scope',
    $c$CHECK (site_bank_account_id IS NULL OR site_id IS NOT NULL)$c$);
SELECT sp_add_constraint('processed_bank_webhooks', 'chk_processed_webhooks_payload_hash',
    $c$CHECK (payload_hash IS NULL OR payload_hash ~ '^[0-9a-f]{64}$')$c$);
-- 'A<account>' when the receiving account is known, else 'S<site>', else '-'.
ALTER TABLE processed_bank_webhooks ADD COLUMN IF NOT EXISTS scope_key VARCHAR(40)
    GENERATED ALWAYS AS (COALESCE('A' || site_bank_account_id::text, 'S' || site_id::text, '-')) STORED;
CREATE UNIQUE INDEX IF NOT EXISTS uq_processed_webhooks_scope_txn
    ON processed_bank_webhooks (scope_key, transaction_id);
CREATE INDEX IF NOT EXISTS idx_processed_webhooks_site ON processed_bank_webhooks (site_id);
CREATE INDEX IF NOT EXISTS idx_processed_webhooks_bank_account ON processed_bank_webhooks (site_bank_account_id);
CREATE INDEX IF NOT EXISTS idx_processed_webhooks_receipt ON processed_bank_webhooks (receipt_id);

-- ---------------------------------------------------------------------------
-- O-7: reconciliation_queue. One vocabulary (UPPER_SNAKE English); the Turkish
-- status_code duplicate is derived in code; statement history survives the
-- removal of a bank account; matched_* columns are the snapshot shown to the
-- manager at match time (matched_unit_id / matched_due_id remain the facts).
-- ---------------------------------------------------------------------------
ALTER TABLE reconciliation_queue DROP CONSTRAINT IF EXISTS chk_reconciliation_status;
UPDATE reconciliation_queue SET status = CASE status
    WHEN 'PendingApproval' THEN 'PENDING_APPROVAL'
    WHEN 'Approved' THEN 'APPROVED'
    WHEN 'Unmatched' THEN 'UNMATCHED'
    WHEN 'Rejected' THEN 'REJECTED'
    WHEN 'AlreadyProcessed' THEN 'ALREADY_PROCESSED'
    ELSE status END
WHERE status IN ('PendingApproval', 'Approved', 'Unmatched', 'Rejected', 'AlreadyProcessed');
SELECT sp_add_constraint('reconciliation_queue', 'chk_reconciliation_status',
    $c$CHECK (status IN ('PENDING_APPROVAL', 'APPROVED', 'UNMATCHED', 'REJECTED', 'ALREADY_PROCESSED'))$c$);
ALTER TABLE reconciliation_queue DROP COLUMN IF EXISTS status_code;
SELECT sp_set_fk('reconciliation_queue', 'site_bank_account_id', 'site_bank_accounts', 'fk_reconciliation_bank_account', 'RESTRICT');
COMMENT ON COLUMN reconciliation_queue.matched_block IS 'Snapshot at match time; the fact is matched_unit_id';
COMMENT ON COLUMN reconciliation_queue.matched_unit_number IS 'Snapshot at match time; the fact is matched_unit_id';
COMMENT ON COLUMN reconciliation_queue.matched_resident_name IS 'Snapshot at match time; the fact is matched_unit_id';

-- ---------------------------------------------------------------------------
-- O-6: paid-derived statuses must agree with the paid amounts; OVERDUE (time
-- derived) is a cache, recomputed on read by the code and by the view below.
-- ---------------------------------------------------------------------------
UPDATE dues_liabilities SET status = 'PAID'
WHERE status NOT IN ('PAID', 'CANCELLED') AND paid_principal >= principal_amount AND paid_penalty >= delay_penalty;
UPDATE dues_liabilities SET status = CASE WHEN paid_amount > 0 THEN 'PARTIALLY_PAID' ELSE 'PENDING' END
WHERE status = 'PAID' AND NOT (paid_principal >= principal_amount AND paid_penalty >= delay_penalty);
UPDATE dues_liabilities SET status = 'PENDING' WHERE status = 'PARTIALLY_PAID' AND paid_amount = 0;
SELECT sp_add_constraint('dues_liabilities', 'chk_dues_paid_status_consistent',
    $c$CHECK (status = 'CANCELLED'
              OR ((status = 'PAID') = (paid_principal >= principal_amount AND paid_penalty >= delay_penalty)
                  AND (status <> 'PARTIALLY_PAID' OR paid_amount > 0)))$c$);

CREATE OR REPLACE VIEW v_dues_effective_status AS
SELECT d.id, d.unit_id, d.period, d.status AS stored_status,
       CASE
           WHEN d.status = 'CANCELLED' THEN 'CANCELLED'
           WHEN d.paid_principal >= d.principal_amount AND d.paid_penalty >= d.delay_penalty THEN 'PAID'
           WHEN d.due_date < CURRENT_DATE THEN 'OVERDUE'
           WHEN d.paid_amount > 0 THEN 'PARTIALLY_PAID'
           ELSE 'PENDING'
       END AS effective_status,
       (d.principal_amount - d.paid_principal) AS outstanding_principal,
       (d.delay_penalty - d.paid_penalty) AS outstanding_penalty
FROM dues_liabilities d;

-- ---------------------------------------------------------------------------
-- O-10: no silent default for the payer role.
-- ---------------------------------------------------------------------------
ALTER TABLE payment_entries ALTER COLUMN payer_role DROP DEFAULT;

-- ---------------------------------------------------------------------------
-- O-2 / O-1: entry guard (reversal columns immutable; SETTLED -> REVERSED needs
-- its contra entry) and drift views that understand reversals.
-- ---------------------------------------------------------------------------
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
       OR NEW.entry_type IS DISTINCT FROM OLD.entry_type
       OR NEW.reverses_entry_id IS DISTINCT FROM OLD.reverses_entry_id
       OR NEW.reversal_reason IS DISTINCT FROM OLD.reversal_reason
       OR NEW.recorded_by IS DISTINCT FROM OLD.recorded_by
       OR (OLD.payer_person_id IS NOT NULL AND NEW.payer_person_id IS DISTINCT FROM OLD.payer_person_id)
       OR (OLD.occupancy_id IS NOT NULL AND NEW.occupancy_id IS DISTINCT FROM OLD.occupancy_id) THEN
        RAISE EXCEPTION 'payment_entries %: financial columns are immutable', OLD.id
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    IF NEW.settlement_status IS DISTINCT FROM OLD.settlement_status THEN
        IF NOT ((OLD.settlement_status IN ('UNMATCHED', 'PENDING') AND NEW.settlement_status = 'SETTLED'
                 AND OLD.receipt_id IS NULL AND NEW.receipt_id IS NOT NULL)
                OR (OLD.settlement_status = 'SETTLED' AND NEW.settlement_status = 'REVERSED'
                    AND OLD.entry_type = 'COLLECTION'
                    AND EXISTS (SELECT 1 FROM payment_entries x WHERE x.reverses_entry_id = OLD.id))) THEN
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
-- A reversed entry's allocations no longer count as paid (O-2).
SELECT 'allocations_vs_dues_paid', d.id::text,
       (d.paid_principal + d.paid_penalty) - COALESCE(SUM(pa.principal_amount + pa.penalty_amount), 0)
FROM dues_liabilities d
LEFT JOIN payment_allocations pa ON pa.dues_liability_id = d.id
    AND NOT EXISTS (SELECT 1 FROM payment_entries re WHERE re.id = pa.payment_entry_id AND re.settlement_status = 'REVERSED')
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
WHERE e.amount <> r.total_amount AND e.payment_channel <> 'INTER_LEDGER'
UNION ALL
-- A reversal mirrors its original exactly (O-2).
SELECT 'reversal_vs_original', re.id::text, re.amount - o.amount
FROM payment_entries re
JOIN payment_entries o ON o.id = re.reverses_entry_id
WHERE re.amount <> o.amount OR o.settlement_status <> 'REVERSED' OR re.unit_id <> o.unit_id
UNION ALL
SELECT 'reversal_receipt_vs_original', rr.id::text, rr.total_amount - orr.total_amount
FROM payment_receipts rr
JOIN payment_receipts orr ON orr.id = rr.reverses_receipt_id
WHERE rr.total_amount <> orr.total_amount OR rr.allocated_principal <> orr.allocated_principal
   OR rr.allocated_penalty <> orr.allocated_penalty OR rr.allocated_advance <> orr.allocated_advance;

CREATE OR REPLACE VIEW v_duplicated_fact_drift AS
SELECT 'units.owner_person_id' AS fact, u.id::text AS subject,
       u.owner_person_id::text AS legacy_value, o.person_id::text AS source_value
FROM units u
JOIN LATERAL (SELECT person_id FROM unit_ownerships x WHERE x.unit_id = u.id AND x.is_active
              ORDER BY share_percentage DESC, start_date DESC, id DESC LIMIT 1) o ON TRUE
WHERE u.owner_person_id IS DISTINCT FROM o.person_id
UNION ALL
SELECT 'users.site_id/role', us.id::text, us.site_id::text || '/' || us.role, r.site_id::text || '/' || r.role
FROM users us JOIN user_site_roles r ON r.user_id = us.id
WHERE us.site_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM user_site_roles r2 WHERE r2.user_id = us.id AND r2.site_id = us.site_id AND r2.role = us.role)
UNION ALL
SELECT 'dues_liabilities.period/dues_period_id', d.id::text, d.period, p.period_name
FROM dues_liabilities d JOIN dues_periods p ON p.id = d.dues_period_id
WHERE d.period <> p.period_name
UNION ALL
-- O-11: allocation_breakdown / allocated_* are the issued document's snapshot;
-- collection receipts are checked against their allocation rows. A reversal
-- receipt has none of its own (it is checked against its original above).
SELECT 'payment_receipts.allocated_*/payment_allocations', r.id::text,
       (r.allocated_principal + r.allocated_penalty)::text, COALESCE(SUM(pa.principal_amount + pa.penalty_amount), 0)::text
FROM payment_receipts r
JOIN payment_entries e ON e.receipt_id = r.id
LEFT JOIN payment_allocations pa ON pa.payment_entry_id = e.id
WHERE r.receipt_type = 'COLLECTION'
GROUP BY r.id
HAVING (r.allocated_principal + r.allocated_penalty) <> COALESCE(SUM(pa.principal_amount + pa.penalty_amount), 0);
