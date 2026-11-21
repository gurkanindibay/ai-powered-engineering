-- V50: explicit per-unit monthly tariff override.
--
-- Registration and unit edit accept a monthly dues amount typed by the manager.
-- Until now that amount was only used to charge nobody (issue #286) and was then
-- dropped, so accrual always fell back to the house-type tariff and the unit
-- listing guessed its figure from the last liability or a hardcoded default.
--
-- The override is nullable and additive: a unit without one keeps resolving its
-- tariff exactly as before. Accrual precedence is operating-budget share >
-- unit override > house-type tariff.

ALTER TABLE units ADD COLUMN IF NOT EXISTS monthly_tariff_override NUMERIC(15, 2);

ALTER TABLE units DROP CONSTRAINT IF EXISTS chk_units_monthly_tariff_override_positive;
ALTER TABLE units ADD CONSTRAINT chk_units_monthly_tariff_override_positive
    CHECK (monthly_tariff_override IS NULL OR monthly_tariff_override > 0);
