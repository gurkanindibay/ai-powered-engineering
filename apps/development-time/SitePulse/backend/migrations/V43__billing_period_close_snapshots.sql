-- STORY-07-12: close billing periods against an immutable report snapshot.

ALTER TABLE dues_periods DROP CONSTRAINT IF EXISTS chk_dues_periods_status;
ALTER TABLE dues_periods ADD CONSTRAINT chk_dues_periods_status
    CHECK (status IN ('DRAFT', 'OPEN', 'ACTIVE', 'ACCRUED', 'CLOSED'));
UPDATE dues_periods SET status = 'OPEN' WHERE status = 'ACTIVE';

CREATE TABLE IF NOT EXISTS dues_period_snapshots (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    period_id BIGINT NOT NULL REFERENCES dues_periods(id) ON DELETE RESTRICT,
    period_key TEXT NOT NULL,
    snapshot_version INTEGER NOT NULL DEFAULT 1,
    accrued NUMERIC(15,2) NOT NULL,
    collected NUMERIC(15,2) NOT NULL,
    outstanding NUMERIC(15,2) NOT NULL,
    corrections NUMERIC(15,2) NOT NULL,
    per_unit JSONB NOT NULL,
    trial_balance JSONB NOT NULL,
    account_report JSONB NOT NULL,
    journal_entries JSONB NOT NULL,
    closed_by TEXT NOT NULL,
    closed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_dues_period_snapshot UNIQUE (site_id, period_id, snapshot_version)
);

CREATE TABLE IF NOT EXISTS dues_period_reopen_requests (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    period_id BIGINT NOT NULL REFERENCES dues_periods(id) ON DELETE RESTRICT,
    reason TEXT NOT NULL CHECK (length(trim(reason)) >= 5),
    requested_by TEXT NOT NULL,
    requested_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status TEXT NOT NULL CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED')),
    decided_by TEXT,
    decided_at TIMESTAMPTZ,
    decision_note TEXT,
    CONSTRAINT chk_dues_period_reopen_four_eyes
        CHECK (decided_by IS NULL OR decided_by <> requested_by),
    CONSTRAINT chk_dues_period_reopen_decision
        CHECK ((status = 'PENDING') = (decided_at IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_dues_period_reopen_pending
    ON dues_period_reopen_requests (site_id, period_id) WHERE status = 'PENDING';

SELECT sp_enable_tenant_rls('dues_period_snapshots', 'site_id = sp_tenant_site()');
SELECT sp_enable_tenant_rls('dues_period_reopen_requests', 'site_id = sp_tenant_site()');
-- Keep economic accrual dates while placing postings created after close in an open month.
ALTER TABLE late_fee_accruals
    ADD COLUMN booked_on DATE;

ALTER TABLE ledger_adjustments
    ADD COLUMN booked_on DATE;
