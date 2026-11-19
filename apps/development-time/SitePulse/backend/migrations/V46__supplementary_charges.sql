-- STORY-07-13: a back-dated start residing date posts a supplementary charge for days nobody
-- was billed. The charge is posted in the open period and refers to the month it bills.
-- NULL for every ordinary liability, which bills its own period.
ALTER TABLE dues_liabilities
    ADD COLUMN IF NOT EXISTS source_period TEXT;

-- One unit may now hold several charges in one posting period when they refer to different
-- months (the month's own charge plus a supplementary charge for an earlier, closed month).
DROP INDEX IF EXISTS uq_unit_period_expense;
DROP INDEX IF EXISTS uq_unit_period_key_expense;
CREATE UNIQUE INDEX IF NOT EXISTS uq_unit_period_expense
    ON dues_liabilities (unit_id, period, expense_type, debtor_type, COALESCE(source_period, ''))
    WHERE capital_project_id IS NULL AND status <> 'CANCELLED';
CREATE UNIQUE INDEX IF NOT EXISTS uq_unit_period_key_expense
    ON dues_liabilities (unit_id, period_key, expense_type, debtor_type, COALESCE(source_period, ''))
    WHERE capital_project_id IS NULL AND period_key IS NOT NULL AND status <> 'CANCELLED';
