-- V8: Schema Integrity Fixes — English person_type values, redundant index removal, and bank invariant (English Schema Standard)

-- 1. Migrate non-English person_type values to English equivalents
UPDATE persons SET person_type = 'HOME_OWNER' WHERE person_type = 'KAT_MALIKI';
UPDATE persons SET person_type = 'HOME_RESIDENT' WHERE person_type = 'KAT_SAKINI' OR person_type = 'TENANT';
UPDATE persons SET person_type = 'SITE_MANAGER' WHERE person_type = 'YONETICI';

-- 2. Remove duplicate index on dues_liabilities.capital_project_id
--    idx_dues_liabilities_capital_proj covers the same column
DROP INDEX IF EXISTS idx_dues_capital_project;

-- 3. Remove redundant index on advance_balances.unit_id
--    The primary key B-tree already covers this column
DROP INDEX IF EXISTS idx_advance_balances_unit;

-- 4. Enforce at most one active bank account per site
CREATE UNIQUE INDEX IF NOT EXISTS uq_site_active_bank ON site_bank_accounts (site_id) WHERE is_active = true;
