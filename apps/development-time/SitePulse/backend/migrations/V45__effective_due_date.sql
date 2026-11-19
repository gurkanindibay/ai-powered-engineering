-- Issue #206: late fees, grace and aging count from an effective due date, the later of the
-- period due date and the date the charge was created. The period due date (`due_date`) keeps
-- driving month and FIFO order and the limitation period.
ALTER TABLE dues_liabilities ADD COLUMN IF NOT EXISTS effective_due_date DATE;
-- Charges that exist already keep today's behaviour: their effective date is the period date.
UPDATE dues_liabilities SET effective_due_date = due_date WHERE effective_due_date IS NULL;
ALTER TABLE dues_liabilities ALTER COLUMN effective_due_date SET NOT NULL;

-- A writer that does not know about the column gets the period due date.
CREATE OR REPLACE FUNCTION dues_liabilities_default_effective_due_date() RETURNS trigger AS $$
BEGIN
    IF NEW.effective_due_date IS NULL THEN
        NEW.effective_due_date := NEW.due_date;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_dues_liabilities_effective_due_date ON dues_liabilities;
CREATE TRIGGER trg_dues_liabilities_effective_due_date
    BEFORE INSERT ON dues_liabilities
    FOR EACH ROW EXECUTE FUNCTION dues_liabilities_default_effective_due_date();

ALTER TABLE dues_liabilities DROP CONSTRAINT IF EXISTS chk_dues_effective_not_before_due;
ALTER TABLE dues_liabilities ADD CONSTRAINT chk_dues_effective_not_before_due
    CHECK (effective_due_date >= due_date);
