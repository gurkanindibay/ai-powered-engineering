-- 00-09: Unified Payment Ledger & Referential Integrity (English Schema Standard)
-- Migrates the two legacy payment ledgers into payment_entries and converts every
-- VARCHAR site_id/unit_id reference to a BIGINT foreign key.

-- 1. Extend the canonical ledger with the dues-allocation link previously held only
--    by collection_transactions.
ALTER TABLE payment_entries ADD COLUMN IF NOT EXISTS dues_liability_id BIGINT;
CREATE INDEX IF NOT EXISTS idx_payment_entries_dues ON payment_entries (dues_liability_id);

-- 2. Convert VARCHAR id columns to BIGINT (idempotent). Legacy values such as
--    'site-1', 'd-14' and 'unit-14' are reduced to their numeric portion.
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT table_name, column_name
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND data_type = 'character varying'
          AND ((table_name, column_name) IN (
                ('payment_receipts', 'site_id'), ('payment_receipts', 'unit_id'),
                ('payment_entries', 'site_id'), ('payment_entries', 'unit_id'),
                ('advance_balances', 'unit_id'),
                ('debt_aging_snapshots', 'site_id'), ('debt_aging_snapshots', 'unit_id'),
                ('capital_projects', 'site_id'),
                ('unit_sender_ibans', 'unit_id'),
                ('unit_payer_names', 'unit_id'),
                ('reconciliation_queue', 'matched_unit_id'), ('reconciliation_queue', 'matched_due_id'),
                ('invitation_tokens', 'site_id'), ('invitation_tokens', 'unit_id'),
                ('pending_registrations', 'site_id'),
                ('dues_periods', 'site_id')))
    LOOP
        EXECUTE format(
            'ALTER TABLE %I ALTER COLUMN %I TYPE BIGINT USING NULLIF(regexp_replace(%I, ''\D'', '''', ''g''), '''')::BIGINT',
            r.table_name, r.column_name, r.column_name
        );
    END LOOP;
END $$;

-- 3. Add the foreign keys that were previously impossible on VARCHAR columns.
ALTER TABLE payment_receipts DROP CONSTRAINT IF EXISTS fk_payment_receipts_site;
ALTER TABLE payment_receipts ADD CONSTRAINT fk_payment_receipts_site FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE payment_receipts DROP CONSTRAINT IF EXISTS fk_payment_receipts_unit;
ALTER TABLE payment_receipts ADD CONSTRAINT fk_payment_receipts_unit FOREIGN KEY (unit_id) REFERENCES units(id) ON DELETE CASCADE;

ALTER TABLE payment_entries DROP CONSTRAINT IF EXISTS fk_payment_entries_site;
ALTER TABLE payment_entries ADD CONSTRAINT fk_payment_entries_site FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE payment_entries DROP CONSTRAINT IF EXISTS fk_payment_entries_unit;
ALTER TABLE payment_entries ADD CONSTRAINT fk_payment_entries_unit FOREIGN KEY (unit_id) REFERENCES units(id) ON DELETE CASCADE;
ALTER TABLE payment_entries DROP CONSTRAINT IF EXISTS payment_entries_dues_liability_id_fkey;
ALTER TABLE payment_entries DROP CONSTRAINT IF EXISTS fk_payment_entries_dues;
ALTER TABLE payment_entries ADD CONSTRAINT fk_payment_entries_dues FOREIGN KEY (dues_liability_id) REFERENCES dues_liabilities(id) ON DELETE SET NULL;

ALTER TABLE advance_balances DROP CONSTRAINT IF EXISTS fk_advance_balances_unit;
ALTER TABLE advance_balances ADD CONSTRAINT fk_advance_balances_unit FOREIGN KEY (unit_id) REFERENCES units(id) ON DELETE CASCADE;

ALTER TABLE debt_aging_snapshots DROP CONSTRAINT IF EXISTS fk_debt_aging_site;
ALTER TABLE debt_aging_snapshots ADD CONSTRAINT fk_debt_aging_site FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE debt_aging_snapshots DROP CONSTRAINT IF EXISTS fk_debt_aging_unit;
ALTER TABLE debt_aging_snapshots ADD CONSTRAINT fk_debt_aging_unit FOREIGN KEY (unit_id) REFERENCES units(id) ON DELETE CASCADE;

ALTER TABLE capital_projects DROP CONSTRAINT IF EXISTS fk_capital_projects_site;
ALTER TABLE capital_projects ADD CONSTRAINT fk_capital_projects_site FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;

ALTER TABLE unit_sender_ibans DROP CONSTRAINT IF EXISTS fk_unit_sender_ibans_unit;
ALTER TABLE unit_sender_ibans ADD CONSTRAINT fk_unit_sender_ibans_unit FOREIGN KEY (unit_id) REFERENCES units(id) ON DELETE CASCADE;

ALTER TABLE unit_payer_names DROP CONSTRAINT IF EXISTS fk_unit_payer_names_unit;
ALTER TABLE unit_payer_names ADD CONSTRAINT fk_unit_payer_names_unit FOREIGN KEY (unit_id) REFERENCES units(id) ON DELETE CASCADE;

ALTER TABLE reconciliation_queue DROP CONSTRAINT IF EXISTS fk_reconciliation_unit;
ALTER TABLE reconciliation_queue ADD CONSTRAINT fk_reconciliation_unit FOREIGN KEY (matched_unit_id) REFERENCES units(id) ON DELETE SET NULL;
ALTER TABLE reconciliation_queue DROP CONSTRAINT IF EXISTS fk_reconciliation_due;
ALTER TABLE reconciliation_queue ADD CONSTRAINT fk_reconciliation_due FOREIGN KEY (matched_due_id) REFERENCES dues_liabilities(id) ON DELETE SET NULL;

ALTER TABLE invitation_tokens DROP CONSTRAINT IF EXISTS fk_invitation_tokens_site;
ALTER TABLE invitation_tokens ADD CONSTRAINT fk_invitation_tokens_site FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE invitation_tokens DROP CONSTRAINT IF EXISTS fk_invitation_tokens_unit;
ALTER TABLE invitation_tokens ADD CONSTRAINT fk_invitation_tokens_unit FOREIGN KEY (unit_id) REFERENCES units(id) ON DELETE CASCADE;

ALTER TABLE pending_registrations DROP CONSTRAINT IF EXISTS fk_pending_registrations_site;
ALTER TABLE pending_registrations ADD CONSTRAINT fk_pending_registrations_site FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;

ALTER TABLE dues_periods DROP CONSTRAINT IF EXISTS fk_dues_periods_site;
ALTER TABLE dues_periods ADD CONSTRAINT fk_dues_periods_site FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;

-- 4. Migrate legacy ledgers into payment_entries, then drop the legacy tables.
DO $$
BEGIN
    IF to_regclass('public.collection_transactions') IS NOT NULL THEN
        INSERT INTO payment_entries (site_id, unit_id, dues_liability_id, payer_name, payer_role, amount,
                                     payment_channel, settlement_status, description, external_reference,
                                     payment_date, created_at)
        SELECT u.site_id,
               ct.unit_id,
               ct.dues_liability_id,
               COALESCE(ct.description, 'Unknown payer'),
               'OWNER',
               ct.paid_amount,
               CASE ct.transaction_type
                   WHEN 'CREDIT_CARD_POS' THEN 'CREDIT_CARD'
                   WHEN 'BANK_TRANSFER' THEN 'BANK_TRANSFER'
                   WHEN 'CASH' THEN 'MANUAL_CASH'
                   ELSE 'MANUAL_CASH'
               END,
               'SETTLED',
               ct.description,
               ct.reference_code,
               ct.transaction_date,
               ct.transaction_date
        FROM collection_transactions ct
        LEFT JOIN units u ON u.id = ct.unit_id
        WHERE ct.unit_id IS NOT NULL;
        DROP TABLE IF EXISTS collection_transactions CASCADE;
    END IF;

    IF to_regclass('public.homeowner_payments') IS NOT NULL THEN
        INSERT INTO payment_entries (site_id, unit_id, dues_liability_id, payer_name, payer_role, amount,
                                     payment_channel, settlement_status, description, external_reference,
                                     payment_date, created_at)
        SELECT u.site_id,
               u.id,
               NULL,
               COALESCE(hp.homeowner_name, 'Unknown payer'),
               'OWNER',
               hp.amount,
               CASE hp.payment_method
                   WHEN 'BANK_TRANSFER' THEN 'BANK_TRANSFER'
                   WHEN 'CREDIT_CARD_POS' THEN 'CREDIT_CARD'
                   WHEN 'CASH' THEN 'MANUAL_CASH'
                   WHEN 'VIRTUAL_IBAN' THEN 'VIRTUAL_IBAN'
                   ELSE 'MANUAL_CASH'
               END,
               'SETTLED',
               hp.note,
               hp.reference_code,
               hp.created_at,
               hp.created_at
        FROM homeowner_payments hp
        JOIN units u ON u.id = NULLIF(regexp_replace(hp.unit_id, '\D', '', 'g'), '')::BIGINT;
        DROP TABLE IF EXISTS homeowner_payments CASCADE;
    END IF;
END $$;
