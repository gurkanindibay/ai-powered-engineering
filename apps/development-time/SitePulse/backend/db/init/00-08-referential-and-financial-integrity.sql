-- 00-08: Referential & Financial Integrity Hardening (English Schema Standard)
-- Generated into migrations/V9 by `python3 scripts/schema_integrity_check.py --sync`.

-- 1. Canonical person types (normalize legacy non-English values first)
UPDATE persons SET person_type = 'HOME_OWNER' WHERE person_type IN ('KAT_MALIKI', 'OWNER');
UPDATE persons SET person_type = 'HOME_RESIDENT' WHERE person_type IN ('KAT_SAKINI', 'TENANT', 'RESIDENT');
UPDATE persons SET person_type = 'SITE_MANAGER' WHERE person_type IN ('YONETICI', 'MANAGER');

ALTER TABLE persons DROP CONSTRAINT IF EXISTS chk_persons_person_type;
ALTER TABLE persons ADD CONSTRAINT chk_persons_person_type
    CHECK (person_type IN ('HOME_OWNER', 'HOME_RESIDENT', 'SITE_MANAGER', 'SAAS_ADMIN'));

-- ON CONFLICT (email) needs a non-partial unique constraint; the partial
-- LOWER(email) index alone makes every upsert by email fail at runtime.
ALTER TABLE persons DROP CONSTRAINT IF EXISTS uq_persons_email;
ALTER TABLE persons ADD CONSTRAINT uq_persons_email UNIQUE (email);

ALTER TABLE persons DROP CONSTRAINT IF EXISTS chk_persons_email_not_blank;
ALTER TABLE persons ADD CONSTRAINT chk_persons_email_not_blank CHECK (email IS NULL OR email <> '');

-- 2. A unit may never belong to a site other than its block's site.
--    Previously units.site_id was denormalized, nullable and unverified.
UPDATE units u SET site_id = b.site_id
FROM blocks b
WHERE b.id = u.block_id AND u.site_id IS DISTINCT FROM b.site_id;

ALTER TABLE units ALTER COLUMN site_id SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_blocks_id_site ON blocks (id, site_id);

ALTER TABLE units DROP CONSTRAINT IF EXISTS fk_units_block_site;
ALTER TABLE units ADD CONSTRAINT fk_units_block_site
    FOREIGN KEY (block_id, site_id) REFERENCES blocks(id, site_id) ON DELETE CASCADE;

-- 3. An active occupancy session is by definition not yet ended.
ALTER TABLE unit_occupancies DROP CONSTRAINT IF EXISTS chk_occupancy_active_open;
ALTER TABLE unit_occupancies ADD CONSTRAINT chk_occupancy_active_open
    CHECK (NOT is_active OR end_date IS NULL);

-- 4. One active ownership record per (unit, person) — prevents duplicated title deed rows.
CREATE UNIQUE INDEX IF NOT EXISTS uq_unit_active_owner
    ON unit_ownerships (unit_id, person_id) WHERE is_active = TRUE;

-- 5. Domain vocabularies that were only comments before
ALTER TABLE dues_liabilities DROP CONSTRAINT IF EXISTS chk_dues_expense_type;
ALTER TABLE dues_liabilities ADD CONSTRAINT chk_dues_expense_type
    CHECK (expense_type IN ('OPERATIONAL_DUES', 'CAPITAL_DUES'));

ALTER TABLE dues_liabilities DROP CONSTRAINT IF EXISTS chk_dues_debtor_type;
ALTER TABLE dues_liabilities ADD CONSTRAINT chk_dues_debtor_type
    CHECK (debtor_type IN ('OWNER', 'TENANT'));

ALTER TABLE users DROP CONSTRAINT IF EXISTS chk_users_role;
ALTER TABLE users ADD CONSTRAINT chk_users_role
    CHECK (role IN ('SAAS_ADMIN', 'SITE_MANAGER', 'HOME_OWNER', 'HOME_RESIDENT'));

ALTER TABLE user_site_roles DROP CONSTRAINT IF EXISTS chk_user_site_roles_role;
ALTER TABLE user_site_roles ADD CONSTRAINT chk_user_site_roles_role
    CHECK (role IN ('SAAS_ADMIN', 'SITE_MANAGER', 'HOME_OWNER', 'HOME_RESIDENT'));

ALTER TABLE site_bank_accounts DROP CONSTRAINT IF EXISTS chk_bank_statement_format;
ALTER TABLE site_bank_accounts ADD CONSTRAINT chk_bank_statement_format
    CHECK (statement_format IN ('EXCEL', 'CSV', 'MT940'));

ALTER TABLE site_bank_accounts DROP CONSTRAINT IF EXISTS chk_bank_iban_format;
ALTER TABLE site_bank_accounts ADD CONSTRAINT chk_bank_iban_format
    CHECK (iban ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$');

-- 6. Capital dues must point at a real project and be accrued exactly once per installment
ALTER TABLE dues_liabilities DROP CONSTRAINT IF EXISTS fk_dues_capital_project;
ALTER TABLE dues_liabilities ADD CONSTRAINT fk_dues_capital_project
    FOREIGN KEY (capital_project_id) REFERENCES capital_projects(id) ON DELETE SET NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_unit_capital_installment
    ON dues_liabilities (unit_id, capital_project_id, installment_number)
    WHERE capital_project_id IS NOT NULL;

-- 7. A liability can never be paid beyond principal + accrued penalty
ALTER TABLE dues_liabilities DROP CONSTRAINT IF EXISTS chk_dues_paid_within_owed;
ALTER TABLE dues_liabilities ADD CONSTRAINT chk_dues_paid_within_owed
    CHECK (paid_amount <= principal_amount + delay_penalty);

-- 8. Receipt sequence numbers are gap-free per site (were declared but unenforced)
CREATE UNIQUE INDEX IF NOT EXISTS uq_site_receipt_sequence
    ON payment_receipts (site_id, sequence_number);

-- 9. Receipt allocation must reconcile to the receipt total
ALTER TABLE payment_receipts DROP CONSTRAINT IF EXISTS chk_receipt_allocation_sums;
ALTER TABLE payment_receipts ADD CONSTRAINT chk_receipt_allocation_sums
    CHECK (allocated_principal + allocated_penalty + allocated_advance = total_amount);
