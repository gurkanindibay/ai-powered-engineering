-- STORY-07-10: per-site accrual schedule, catch-up limit and late-fee grace period.
--
-- The defaults reproduce the behaviour before this story: accrue on the 1st, due on the 15th,
-- no grace period. Changing a site's setting affects only periods accrued afterwards, so the
-- grace period in force is copied onto every liability when it is accrued.
ALTER TABLE sites ADD COLUMN IF NOT EXISTS accrual_day SMALLINT NOT NULL DEFAULT 1
    CHECK (accrual_day BETWEEN 1 AND 28);
ALTER TABLE sites ADD COLUMN IF NOT EXISTS due_day SMALLINT NOT NULL DEFAULT 15
    CHECK (due_day BETWEEN 1 AND 31);
ALTER TABLE sites ADD COLUMN IF NOT EXISTS grace_days SMALLINT NOT NULL DEFAULT 0
    CHECK (grace_days BETWEEN 0 AND 30);
ALTER TABLE sites ADD COLUMN IF NOT EXISTS catch_up_limit_months SMALLINT NOT NULL DEFAULT 12
    CHECK (catch_up_limit_months BETWEEN 1 AND 60);
ALTER TABLE sites ADD COLUMN IF NOT EXISTS go_live_date DATE;

ALTER TABLE dues_liabilities ADD COLUMN IF NOT EXISTS grace_days INTEGER NOT NULL DEFAULT 0
    CHECK (grace_days BETWEEN 0 AND 30);
