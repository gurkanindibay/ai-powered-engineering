-- STORY-07-09: opt-in policy; preserving the existing full-month behavior is
-- the safe default until a site manager explicitly enables occupancy proration.
ALTER TABLE sites
    ADD COLUMN IF NOT EXISTS proration_enabled BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE accrual_corrections
    ADD COLUMN IF NOT EXISTS replacement_shares JSONB NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS replacement_due_ids JSONB NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE accrual_corrections DROP CONSTRAINT IF EXISTS accrual_corrections_kind_check;
ALTER TABLE accrual_corrections
    ADD CONSTRAINT accrual_corrections_kind_check
    CHECK (kind IN ('CANCEL', 'REISSUE', 'SPLIT_REISSUE', 'CREDIT_NOTE'));

-- A unit-period can now have one owner liability and one tenant liability.
DROP INDEX IF EXISTS uq_unit_period_expense;
DROP INDEX IF EXISTS uq_unit_period_key_expense;
CREATE UNIQUE INDEX IF NOT EXISTS uq_unit_period_expense
    ON dues_liabilities (unit_id, period, expense_type, debtor_type)
    WHERE capital_project_id IS NULL AND status <> 'CANCELLED';
CREATE UNIQUE INDEX IF NOT EXISTS uq_unit_period_key_expense
    ON dues_liabilities (unit_id, period_key, expense_type, debtor_type)
    WHERE capital_project_id IS NULL AND period_key IS NOT NULL AND status <> 'CANCELLED';
