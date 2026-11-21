-- STORY-13-09 / issue 296: an unmatched bank statement item can be assigned by a manager to a
-- unit and a debtor role before it is settled. The assignment is kept apart from matched_unit_id
-- (the automatic match) so confirm-reconciliation can tell a machine match from a manager decision
-- and only falls back to the assignment when there is no matched_unit_id.
ALTER TABLE reconciliation_queue
    ADD COLUMN IF NOT EXISTS assigned_unit_id BIGINT;

ALTER TABLE reconciliation_queue
    ADD COLUMN IF NOT EXISTS assigned_debtor_role VARCHAR(10);

ALTER TABLE reconciliation_queue
    DROP CONSTRAINT IF EXISTS fk_reconciliation_assigned_unit;
ALTER TABLE reconciliation_queue
    ADD CONSTRAINT fk_reconciliation_assigned_unit
    FOREIGN KEY (assigned_unit_id) REFERENCES units(id) ON DELETE SET NULL;

ALTER TABLE reconciliation_queue
    DROP CONSTRAINT IF EXISTS chk_reconciliation_assigned_debtor;
ALTER TABLE reconciliation_queue
    ADD CONSTRAINT chk_reconciliation_assigned_debtor
    CHECK (assigned_debtor_role IS NULL OR assigned_debtor_role IN ('OWNER', 'TENANT'));

CREATE INDEX IF NOT EXISTS idx_reconciliation_assigned_unit
    ON reconciliation_queue (assigned_unit_id);

COMMENT ON COLUMN reconciliation_queue.assigned_unit_id IS
    'Manager assignment for an item without matched_unit_id; used by confirm-reconciliation';
COMMENT ON COLUMN reconciliation_queue.assigned_debtor_role IS
    'Debtor role chosen with assigned_unit_id: OWNER or TENANT';
