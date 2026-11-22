-- Allow multiple dues liabilities in the same period when liable_person_id is distinct
-- (e.g. successive tenants or owners in a split-reissue correction).
DROP INDEX IF EXISTS uq_unit_period_expense;
DROP INDEX IF EXISTS uq_unit_period_key_expense;
CREATE UNIQUE INDEX IF NOT EXISTS uq_unit_period_expense
    ON dues_liabilities (unit_id, period, expense_type, debtor_type, COALESCE(liable_person_id, 0), COALESCE(source_period, ''))
    WHERE capital_project_id IS NULL AND status <> 'CANCELLED';
CREATE UNIQUE INDEX IF NOT EXISTS uq_unit_period_key_expense
    ON dues_liabilities (unit_id, period_key, expense_type, debtor_type, COALESCE(liable_person_id, 0), COALESCE(source_period, ''))
    WHERE capital_project_id IS NULL AND period_key IS NOT NULL AND status <> 'CANCELLED';
