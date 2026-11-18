-- #187: a backdated payment re-evaluates KMK 20 late fees from its payment date.
-- The penalty already charged above the recalculated amount is reversed by an
-- audited ledger adjustment, so the ledger gets a GL entry rather than an
-- in-place edit. The adjustment is system-generated (no manual request), so the
-- vocabulary of ledger_adjustments gains one kind and one source.
DO $$
DECLARE c record;
BEGIN
    FOR c IN
        SELECT conname FROM pg_constraint
        WHERE conrelid = 'ledger_adjustments'::regclass AND contype = 'c'
          AND (pg_get_constraintdef(oid) LIKE '%PENALTY_WAIVER%'
               OR pg_get_constraintdef(oid) LIKE '%PAYMENT_PLAN%')
          AND conname <> 'chk_ledger_adjustments_kind_v2'
          AND conname <> 'chk_ledger_adjustments_source_v2'
    LOOP
        EXECUTE format('ALTER TABLE ledger_adjustments DROP CONSTRAINT %I', c.conname);
    END LOOP;
END $$;

ALTER TABLE ledger_adjustments DROP CONSTRAINT IF EXISTS chk_ledger_adjustments_kind_v2;
ALTER TABLE ledger_adjustments ADD CONSTRAINT chk_ledger_adjustments_kind_v2
    CHECK (kind IN ('PENALTY_WAIVER', 'PRINCIPAL_WRITE_OFF', 'PENALTY_REEVALUATION'));
ALTER TABLE ledger_adjustments DROP CONSTRAINT IF EXISTS chk_ledger_adjustments_source_v2;
ALTER TABLE ledger_adjustments ADD CONSTRAINT chk_ledger_adjustments_source_v2
    CHECK (source IN ('MANUAL', 'PAYMENT_PLAN', 'COLLECTION', 'PAYMENT_DATE'));
