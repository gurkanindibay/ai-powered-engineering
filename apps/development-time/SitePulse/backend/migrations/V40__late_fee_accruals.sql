-- STORY-07-13: the daily late-fee job persists one row per liability and day.
-- cumulative_fee is the liability's KMK 20 fee through accrual_date; daily_amount is the
-- difference from the previous day and is what the ledger books on that day. A segment is a run
-- of days with unchanged outstanding principal: its fee is computed from segment_start, on top of
-- segment_base, and rounded once, so daily runs never drift from one evaluation.
CREATE TABLE IF NOT EXISTS late_fee_accruals (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    due_id BIGINT NOT NULL REFERENCES dues_liabilities(id) ON DELETE CASCADE,
    accrual_date DATE NOT NULL,
    outstanding_principal NUMERIC(15,2) NOT NULL CHECK (outstanding_principal > 0),
    segment_start DATE NOT NULL,
    segment_base NUMERIC(15,2) NOT NULL CHECK (segment_base >= 0),
    cumulative_fee NUMERIC(15,2) NOT NULL CHECK (cumulative_fee >= 0),
    daily_amount NUMERIC(15,2) NOT NULL CHECK (daily_amount >= 0),
    CONSTRAINT uq_late_fee_due_day UNIQUE (due_id, accrual_date)
);
CREATE INDEX IF NOT EXISTS idx_late_fee_accruals_site ON late_fee_accruals (site_id, accrual_date);

SELECT sp_enable_tenant_rls('late_fee_accruals', 'site_id = sp_tenant_site()');
