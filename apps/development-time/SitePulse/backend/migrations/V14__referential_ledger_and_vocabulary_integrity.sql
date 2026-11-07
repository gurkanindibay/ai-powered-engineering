-- V14: Referential, ledger and vocabulary integrity
-- (report items H11, H12, M2, M3, M4, M5, M8).
--
-- New constraints are added NOT VALID (enforced for every new or updated row)
-- and then validated. If existing rows violate one, validation is skipped with a
-- WARNING naming the constraint, so an upgrade never fails half way; the
-- v_integrity_violations view lists what still needs cleaning up.

CREATE OR REPLACE FUNCTION sp_try_validate(p_table regclass, p_constraint text) RETURNS void AS $$
BEGIN
    EXECUTE format('ALTER TABLE %s VALIDATE CONSTRAINT %I', p_table, p_constraint);
EXCEPTION WHEN others THEN
    RAISE WARNING 'Constraint % on % left NOT VALID (existing rows violate it): %', p_constraint, p_table, SQLERRM;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION sp_add_constraint(p_table regclass, p_name text, p_definition text) RETURNS void AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = p_table AND conname = p_name) THEN
        EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s NOT VALID', p_table, p_name, p_definition);
    END IF;
    PERFORM sp_try_validate(p_table, p_name);
END;
$$ LANGUAGE plpgsql;

-- Replaces a foreign key's delete rule (drops every FK on that column first).
CREATE OR REPLACE FUNCTION sp_set_fk(p_table regclass, p_column text, p_ref regclass, p_name text, p_rule text) RETURNS void AS $$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT c.conname FROM pg_constraint c
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
        WHERE c.contype = 'f' AND c.conrelid = p_table AND a.attname = p_column AND array_length(c.conkey, 1) = 1
    LOOP
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', p_table, r.conname);
    END LOOP;
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %s(id) ON DELETE %s NOT VALID',
                   p_table, p_name, p_column, p_ref, p_rule);
    PERFORM sp_try_validate(p_table, p_name);
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- H11: missing foreign keys on core tables.
-- ---------------------------------------------------------------------------
SELECT sp_set_fk('dues_liabilities', 'unit_id', 'units', 'fk_dues_liabilities_unit', 'RESTRICT');
SELECT sp_set_fk('unit_occupancies', 'unit_id', 'units', 'fk_unit_occupancies_unit', 'RESTRICT');
SELECT sp_set_fk('blocks', 'site_id', 'sites', 'fk_blocks_site', 'RESTRICT');
SELECT sp_set_fk('house_types', 'site_id', 'sites', 'fk_house_types_site', 'RESTRICT');
SELECT sp_set_fk('users', 'site_id', 'sites', 'fk_users_site', 'RESTRICT');

-- ---------------------------------------------------------------------------
-- H12: financial history is never cascade-deleted. Ledgers, receipts and
-- ownership history RESTRICT deletion of their unit/site; sites and units are
-- soft-deleted instead.
-- ---------------------------------------------------------------------------
SELECT sp_set_fk('payment_receipts', 'unit_id', 'units', 'fk_payment_receipts_unit', 'RESTRICT');
SELECT sp_set_fk('payment_receipts', 'site_id', 'sites', 'fk_payment_receipts_site', 'RESTRICT');
SELECT sp_set_fk('payment_entries', 'unit_id', 'units', 'fk_payment_entries_unit', 'RESTRICT');
SELECT sp_set_fk('payment_entries', 'site_id', 'sites', 'fk_payment_entries_site', 'RESTRICT');
SELECT sp_set_fk('payment_allocations', 'payment_entry_id', 'payment_entries', 'fk_payment_allocations_entry', 'RESTRICT');
SELECT sp_set_fk('advance_ledger_entries', 'unit_id', 'units', 'fk_advance_ledger_unit', 'RESTRICT');
SELECT sp_set_fk('advance_balances', 'unit_id', 'units', 'fk_advance_balances_unit', 'RESTRICT');
SELECT sp_set_fk('debt_aging_snapshots', 'unit_id', 'units', 'fk_debt_aging_unit', 'RESTRICT');
SELECT sp_set_fk('debt_aging_snapshots', 'site_id', 'sites', 'fk_debt_aging_site', 'RESTRICT');
SELECT sp_set_fk('unit_ownerships', 'unit_id', 'units', 'fk_unit_ownerships_unit', 'RESTRICT');
SELECT sp_set_fk('reconciliation_queue', 'site_id', 'sites', 'fk_reconciliation_queue_site', 'RESTRICT');
SELECT sp_set_fk('units', 'site_id', 'sites', 'units_site_id_fkey', 'RESTRICT');
-- units.block_id: drop both single-column FKs; the composite (block_id, site_id) FK is kept.
DO $$
DECLARE r record;
BEGIN
    FOR r IN SELECT conname FROM pg_constraint WHERE conrelid = 'units'::regclass AND contype = 'f'
             AND conname IN ('units_block_id_fkey') LOOP
        EXECUTE format('ALTER TABLE units DROP CONSTRAINT %I', r.conname);
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'units'::regclass AND conname = 'fk_units_block_site') THEN
        ALTER TABLE units DROP CONSTRAINT fk_units_block_site;
        ALTER TABLE units ADD CONSTRAINT fk_units_block_site FOREIGN KEY (block_id, site_id)
            REFERENCES blocks (id, site_id) ON DELETE RESTRICT NOT VALID;
        PERFORM sp_try_validate('units', 'fk_units_block_site');
    ELSE
        PERFORM sp_set_fk('units', 'block_id', 'blocks', 'units_block_id_fkey', 'RESTRICT');
    END IF;
END $$;

ALTER TABLE sites ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE units ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- ---------------------------------------------------------------------------
-- M2: one consistent rule for capital projects: a project that has
-- installments or dues cannot be deleted (cancel it via status instead).
-- ---------------------------------------------------------------------------
SELECT sp_set_fk('capital_project_installments', 'project_id', 'capital_projects', 'fk_capital_installments_project', 'RESTRICT');
SELECT sp_set_fk('dues_liabilities', 'capital_project_id', 'capital_projects', 'fk_dues_capital_project', 'RESTRICT');

-- ---------------------------------------------------------------------------
-- M3: closed vocabularies.
-- ---------------------------------------------------------------------------
SELECT sp_add_constraint('sites', 'chk_sites_status', $c$CHECK (status IN ('ACTIVE', 'SUSPENDED', 'TRIAL', 'DELETED'))$c$);
SELECT sp_add_constraint('sites', 'chk_sites_plan_type', $c$CHECK (plan_type IN ('STANDARD', 'PREMIUM', 'ENTERPRISE'))$c$);
SELECT sp_add_constraint('dues_periods', 'chk_dues_periods_status', $c$CHECK (status IN ('DRAFT', 'OPEN', 'ACTIVE', 'ACCRUED', 'CLOSED'))$c$);
SELECT sp_add_constraint('pending_registrations', 'chk_pending_registrations_status', $c$CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))$c$);
SELECT sp_add_constraint('reconciliation_queue', 'chk_reconciliation_status',
    $c$CHECK (status IN ('PendingApproval', 'Approved', 'Unmatched', 'Rejected', 'AlreadyProcessed',
                         'PENDING_APPROVAL', 'APPROVED', 'UNMATCHED', 'REJECTED', 'ALREADY_PROCESSED'))$c$);
SELECT sp_add_constraint('capital_projects', 'chk_capital_projects_status', $c$CHECK (status IN ('DRAFT', 'PLANNED', 'ACTIVE', 'ON_HOLD', 'COMPLETED', 'CANCELLED'))$c$);
SELECT sp_add_constraint('capital_projects', 'chk_capital_projects_category',
    $c$CHECK (category IN ('ELEVATOR', 'FACADE_INSULATION', 'ROOF_WATERPROOFING', 'GENERATOR', 'SECURITY_SYSTEM', 'FIRE_SAFETY', 'OTHER'))$c$);
SELECT sp_add_constraint('capital_projects', 'chk_capital_projects_allocation_basis', $c$CHECK (allocation_basis IN ('BY_LAND_SHARE', 'EQUAL_PER_UNIT'))$c$);
-- BANK_TRANSFER is included: V10 maps legacy rows to it, which the V5 list omitted.
SELECT sp_add_constraint('payment_entries', 'chk_payment_entries_channel',
    $c$CHECK (payment_channel IN ('VIRTUAL_IBAN', 'BANK_STATEMENT', 'BANK_TRANSFER', 'CREDIT_CARD', 'MANUAL_CASH', 'CASH', 'INTER_LEDGER', 'ONLINE_PAYMENT'))$c$);
SELECT sp_add_constraint('payment_receipts', 'chk_payment_receipts_channel',
    $c$CHECK (payment_channel IN ('VIRTUAL_IBAN', 'BANK_STATEMENT', 'BANK_TRANSFER', 'CREDIT_CARD', 'MANUAL_CASH', 'CASH', 'INTER_LEDGER', 'ONLINE_PAYMENT'))$c$);
SELECT sp_add_constraint('payment_entries', 'chk_payment_entries_settlement_status', $c$CHECK (settlement_status IN ('SETTLED', 'UNMATCHED', 'PENDING', 'REVERSED'))$c$);
SELECT sp_add_constraint('payment_entries', 'chk_payment_entries_payer_role', $c$CHECK (payer_role IN ('OWNER', 'TENANT'))$c$);
SELECT sp_add_constraint('advance_ledger_entries', 'chk_advance_ledger_entry_type',
    $c$CHECK (entry_type IN ('PAYMENT_SURPLUS', 'OFFSET_APPLIED', 'VIRMAN_DEBIT', 'REFUND', 'ADJUSTMENT'))$c$);
SELECT sp_add_constraint('advance_ledger_entries', 'chk_advance_ledger_amount_positive', $c$CHECK (amount > 0)$c$);
SELECT sp_add_constraint('users', 'chk_users_auth_provider', $c$CHECK (auth_provider IN ('LOCAL', 'GOOGLE', 'HYBRID'))$c$);

-- ---------------------------------------------------------------------------
-- M4: aggregate invariants.
-- ---------------------------------------------------------------------------
-- Backfill paid_penalty where only paid_amount/paid_principal were maintained.
UPDATE dues_liabilities
SET paid_penalty = LEAST(delay_penalty, paid_amount - paid_principal)
WHERE paid_amount > paid_principal + paid_penalty;
UPDATE dues_liabilities
SET paid_amount = paid_principal + paid_penalty
WHERE paid_amount <> paid_principal + paid_penalty;
SELECT sp_add_constraint('dues_liabilities', 'chk_dues_paid_components', $c$CHECK (paid_amount = paid_principal + paid_penalty)$c$);
SELECT sp_add_constraint('dues_liabilities', 'chk_dues_paid_principal_within', $c$CHECK (paid_principal >= 0 AND paid_principal <= principal_amount)$c$);
SELECT sp_add_constraint('dues_liabilities', 'chk_dues_paid_penalty_within', $c$CHECK (paid_penalty >= 0 AND paid_penalty <= delay_penalty)$c$);
SELECT sp_add_constraint('advance_balances', 'chk_advance_balance_non_negative', $c$CHECK (balance >= 0)$c$);

-- Drift detection for invariants that span rows.
CREATE OR REPLACE VIEW v_integrity_violations AS
SELECT 'advance_balance_vs_ledger' AS check_name, ab.unit_id::text || '/' || ab.debtor_type AS subject,
       ab.balance - COALESCE(l.net, 0) AS difference
FROM advance_balances ab
LEFT JOIN (
    SELECT unit_id, debtor_type,
           SUM(CASE WHEN entry_type IN ('PAYMENT_SURPLUS', 'REFUND') THEN amount
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
   AND (d.paid_principal + d.paid_penalty) <> COALESCE(SUM(pa.principal_amount + pa.penalty_amount), 0);

-- ---------------------------------------------------------------------------
-- M5: reconciliation tenancy.
-- ---------------------------------------------------------------------------
-- Rows V12 parked in site 1 get their real site back from the bank account.
UPDATE reconciliation_queue rq
SET site_id = sba.site_id
FROM site_bank_accounts sba
WHERE rq.site_bank_account_id = sba.id AND rq.site_id IS DISTINCT FROM sba.site_id;

-- Sender IBANs are scoped to a site: one IBAN maps to at most one unit per site.
ALTER TABLE unit_sender_ibans ADD COLUMN IF NOT EXISTS site_id BIGINT;
UPDATE unit_sender_ibans s SET site_id = u.site_id FROM units u WHERE u.id = s.unit_id AND s.site_id IS NULL;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM unit_sender_ibans WHERE site_id IS NULL) THEN
        ALTER TABLE unit_sender_ibans ALTER COLUMN site_id SET NOT NULL;
    END IF;
END $$;
SELECT sp_set_fk('unit_sender_ibans', 'site_id', 'sites', 'fk_unit_sender_ibans_site', 'RESTRICT');
DO $$
BEGIN
    IF NOT EXISTS (SELECT site_id, sender_iban FROM unit_sender_ibans GROUP BY 1, 2 HAVING COUNT(*) > 1) THEN
        CREATE UNIQUE INDEX IF NOT EXISTS uq_site_sender_iban ON unit_sender_ibans (site_id, sender_iban);
    ELSE
        RAISE WARNING 'uq_site_sender_iban not created: some IBANs map to several units of one site';
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- M8: smaller schema issues.
-- ---------------------------------------------------------------------------
-- E-mail uniqueness is case-insensitive (the code lower-cases e-mails).
UPDATE users SET email = LOWER(email) WHERE email <> LOWER(email)
    AND NOT EXISTS (SELECT 1 FROM users u2 WHERE u2.email = LOWER(users.email) AND u2.id <> users.id);
DO $$
BEGIN
    IF NOT EXISTS (SELECT LOWER(email) FROM users GROUP BY 1 HAVING COUNT(*) > 1) THEN
        CREATE UNIQUE INDEX IF NOT EXISTS uq_users_email_lower ON users (LOWER(email));
    ELSE
        RAISE WARNING 'uq_users_email_lower not created: duplicate e-mails differing only by case exist';
    END IF;
END $$;
DROP INDEX IF EXISTS idx_user_email; -- duplicated users_email_key

-- created_at is never NULL.
DO $$
DECLARE r record;
BEGIN
    FOR r IN SELECT table_name FROM information_schema.columns
             WHERE table_schema = 'public' AND column_name = 'created_at' AND is_nullable = 'YES'
               AND table_name IN (SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE') LOOP
        EXECUTE format('UPDATE %I SET created_at = CURRENT_TIMESTAMP WHERE created_at IS NULL', r.table_name);
        EXECUTE format('ALTER TABLE %I ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP', r.table_name);
        EXECUTE format('ALTER TABLE %I ALTER COLUMN created_at SET NOT NULL', r.table_name);
    END LOOP;
END $$;
