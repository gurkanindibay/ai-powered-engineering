-- V37: accrual corrections (STORY-07-11).
--
-- A wrong liability is corrected with a cancel, a re-issue or a credit note, each
-- requested with a reason and approved by a second person (four-eyes). The
-- liability row is never deleted; an approved cancel only sets it to CANCELLED,
-- and the paid amount goes to the debtor's advance balance.

CREATE TABLE IF NOT EXISTS accrual_corrections (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    unit_id BIGINT NOT NULL REFERENCES units(id) ON DELETE CASCADE,
    due_id BIGINT NOT NULL REFERENCES dues_liabilities(id) ON DELETE RESTRICT,
    period VARCHAR(20) NOT NULL,
    debtor_type VARCHAR(10) NOT NULL CHECK (debtor_type IN ('OWNER', 'TENANT')),
    kind VARCHAR(15) NOT NULL CHECK (kind IN ('CANCEL', 'REISSUE', 'CREDIT_NOTE')),
    amount NUMERIC(15,2) NOT NULL CHECK (amount > 0),
    new_due_date DATE,
    new_debtor_type VARCHAR(10) CHECK (new_debtor_type IN ('OWNER', 'TENANT')),
    reason TEXT NOT NULL CHECK (length(trim(reason)) >= 5),
    requested_by TEXT NOT NULL,
    requested_at TIMESTAMPTZ NOT NULL,
    status VARCHAR(10) NOT NULL CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED')),
    decided_by TEXT,
    decided_at TIMESTAMPTZ,
    decision_note TEXT,
    principal_before NUMERIC(15,2),
    penalty_before NUMERIC(15,2),
    paid_before NUMERIC(15,2),
    penalty_reversed NUMERIC(15,2),
    advance_credited NUMERIC(15,2),
    replacement_due_id BIGINT REFERENCES dues_liabilities(id) ON DELETE RESTRICT,
    -- The approver is never the requester.
    CONSTRAINT chk_correction_four_eyes CHECK (decided_by IS NULL OR decided_by <> requested_by),
    CONSTRAINT chk_correction_decided CHECK ((status = 'PENDING') = (decided_at IS NULL))
);

CREATE INDEX IF NOT EXISTS idx_accrual_corrections_site ON accrual_corrections (site_id, id);
CREATE INDEX IF NOT EXISTS idx_accrual_corrections_due ON accrual_corrections (due_id);

SELECT sp_enable_tenant_rls('accrual_corrections', 'site_id = sp_tenant_site()');

-- A re-issued liability replaces a cancelled one for the same unit, period and
-- expense type, so the duplicate guard ignores cancelled rows. Accrual still
-- refuses to charge a period again once any liability, cancelled or not, exists
-- (insert_accrued_due).
DROP INDEX IF EXISTS uq_unit_period_expense;
CREATE UNIQUE INDEX IF NOT EXISTS uq_unit_period_expense
    ON dues_liabilities (unit_id, period, expense_type)
    WHERE capital_project_id IS NULL AND status <> 'CANCELLED';
