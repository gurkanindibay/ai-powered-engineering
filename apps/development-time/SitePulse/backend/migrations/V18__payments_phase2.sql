-- V18: Payments phase 2 (SPEC-007, docs/PAYMENTS_REGULATORY_AND_MARKET_EVALUATION.md F1, F4, F7).
--
-- R1  Virman reversal: the advance a reversed virman spent is credited back to the
--     source debtor as a VIRMAN_REVERSAL advance ledger entry.
-- R4  Card payments go through a licensed provider (6493): payment_intents keeps only
--     provider references and states, never card data. A captured intent feeds the
--     single ingestion path and records the receipt it produced.
-- R5  İşletme projesi (KMK 35/37 as amended by Law 7579): operating budgets with
--     lines, per-unit shares, service records, objections, the revaluation-rate cap,
--     and the legal basis of every operational dues liability
--     (dues_liabilities.operating_budget_id).

-- ---------------------------------------------------------------------------
-- R1: virman reversal advance credit.
-- ---------------------------------------------------------------------------
ALTER TABLE advance_ledger_entries DROP CONSTRAINT IF EXISTS chk_advance_ledger_entry_type;
SELECT sp_add_constraint('advance_ledger_entries', 'chk_advance_ledger_entry_type',
    $c$CHECK (entry_type IN ('PAYMENT_SURPLUS', 'OFFSET_APPLIED', 'VIRMAN_DEBIT', 'REFUND', 'ADJUSTMENT',
                             'ADJUSTMENT_CREDIT', 'ADJUSTMENT_DEBIT', 'VIRMAN_REVERSAL'))$c$);

-- ---------------------------------------------------------------------------
-- R5: işletme projesi.
-- ---------------------------------------------------------------------------
-- Yearly yeniden değerleme oranı (VUK mükerrer 298), the cap on an interim budget's
-- increase (KMK 37/2 as amended). Rates are maintained by the operator. The 2026
-- seed (25.49%) is the figure cited in the regulatory evaluation and must be checked
-- against the published VUK general communiqué before production use.
CREATE TABLE IF NOT EXISTS revaluation_rates (
    year INT PRIMARY KEY,
    rate NUMERIC(7,4) NOT NULL CHECK (rate >= 0),
    source TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO revaluation_rates (year, rate, source)
VALUES (2026, 25.4900, 'VUK mükerrer 298: yeniden değerleme oranı (verify against the published communiqué)')
ON CONFLICT (year) DO NOTHING;

CREATE TABLE IF NOT EXISTS operating_budgets (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE RESTRICT,
    fiscal_year INT NOT NULL CHECK (fiscal_year BETWEEN 2000 AND 2100),
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'DRAFT',
    previous_budget_id BIGINT REFERENCES operating_budgets(id) ON DELETE SET NULL,
    baseline_annual_amount NUMERIC(15,2) NOT NULL DEFAULT 0 CHECK (baseline_annual_amount >= 0),
    total_annual_amount NUMERIC(15,2) NOT NULL DEFAULT 0 CHECK (total_annual_amount >= 0),
    increase_rate NUMERIC(9,4),
    cap_rate NUMERIC(7,4),
    assembly_decision_ref TEXT,
    assembly_decision_date DATE,
    interim_issued_on DATE,
    interim_deadline DATE,
    objection_deadline DATE,
    notes TEXT,
    created_by TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_operating_budgets_status
        CHECK (status IN ('DRAFT', 'INTERIM', 'APPROVED', 'FINAL', 'REJECTED', 'SUPERSEDED')),
    CONSTRAINT chk_operating_budgets_period CHECK (period_end >= period_start),
    -- An assembly-approved budget names the decision it rests on.
    CONSTRAINT chk_operating_budgets_decision
        CHECK (status NOT IN ('APPROVED', 'FINAL') OR (assembly_decision_ref IS NOT NULL AND assembly_decision_date IS NOT NULL)),
    -- An interim budget carries its 3-month deadline to reach the assembly.
    CONSTRAINT chk_operating_budgets_interim
        CHECK (status <> 'INTERIM' OR (interim_issued_on IS NOT NULL AND interim_deadline IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS idx_operating_budgets_site ON operating_budgets (site_id, fiscal_year);
-- At most one budget in force per site and fiscal year.
CREATE UNIQUE INDEX IF NOT EXISTS uq_operating_budgets_in_force
    ON operating_budgets (site_id, fiscal_year) WHERE status IN ('INTERIM', 'APPROVED', 'FINAL');

CREATE TABLE IF NOT EXISTS operating_budget_lines (
    id BIGSERIAL PRIMARY KEY,
    budget_id BIGINT NOT NULL REFERENCES operating_budgets(id) ON DELETE CASCADE,
    category VARCHAR(30) NOT NULL,
    description TEXT,
    annual_amount NUMERIC(15,2) NOT NULL CHECK (annual_amount > 0),
    allocation_key VARCHAR(20) NOT NULL DEFAULT 'LAND_SHARE',
    CONSTRAINT chk_operating_budget_lines_category
        CHECK (category IN ('PERSONNEL', 'CLEANING', 'ENERGY', 'WATER', 'MAINTENANCE', 'INSURANCE',
                            'MANAGEMENT_FEE', 'SECURITY', 'GARDENING', 'RESERVE', 'OTHER')),
    CONSTRAINT chk_operating_budget_lines_key CHECK (allocation_key IN ('LAND_SHARE', 'EQUAL'))
);
CREATE INDEX IF NOT EXISTS idx_operating_budget_lines_budget ON operating_budget_lines (budget_id);

CREATE TABLE IF NOT EXISTS operating_budget_unit_shares (
    budget_id BIGINT NOT NULL REFERENCES operating_budgets(id) ON DELETE CASCADE,
    unit_id BIGINT NOT NULL REFERENCES units(id) ON DELETE RESTRICT,
    land_share INT NOT NULL CHECK (land_share > 0),
    annual_amount NUMERIC(15,2) NOT NULL CHECK (annual_amount >= 0),
    monthly_amount NUMERIC(15,2) NOT NULL CHECK (monthly_amount >= 0),
    PRIMARY KEY (budget_id, unit_id)
);

CREATE TABLE IF NOT EXISTS budget_service_records (
    id BIGSERIAL PRIMARY KEY,
    budget_id BIGINT NOT NULL REFERENCES operating_budgets(id) ON DELETE CASCADE,
    unit_id BIGINT NOT NULL REFERENCES units(id) ON DELETE RESTRICT,
    recipient_name TEXT NOT NULL,
    method VARCHAR(20) NOT NULL,
    served_on DATE NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_budget_service_method
        CHECK (method IN ('IN_ASSEMBLY', 'SIGNATURE', 'REGISTERED_MAIL', 'E_NOTIFICATION')),
    CONSTRAINT uq_budget_service_unit UNIQUE (budget_id, unit_id)
);

CREATE TABLE IF NOT EXISTS budget_objections (
    id BIGSERIAL PRIMARY KEY,
    budget_id BIGINT NOT NULL REFERENCES operating_budgets(id) ON DELETE CASCADE,
    unit_id BIGINT NOT NULL REFERENCES units(id) ON DELETE RESTRICT,
    objector_name TEXT NOT NULL,
    filed_on DATE NOT NULL,
    reason TEXT NOT NULL CHECK (length(trim(reason)) >= 3),
    status VARCHAR(20) NOT NULL DEFAULT 'OPEN',
    resolved_on DATE,
    resolution_note TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_budget_objections_status CHECK (status IN ('OPEN', 'UPHELD', 'DISMISSED')),
    CONSTRAINT chk_budget_objections_resolution CHECK ((status = 'OPEN') = (resolved_on IS NULL))
);

-- The legal basis of an operational dues liability (İİK 68/1 document chain).
ALTER TABLE dues_liabilities ADD COLUMN IF NOT EXISTS operating_budget_id BIGINT;
SELECT sp_add_constraint('dues_liabilities', 'fk_dues_liabilities_operating_budget',
    $c$FOREIGN KEY (operating_budget_id) REFERENCES operating_budgets(id) ON DELETE RESTRICT$c$);
CREATE INDEX IF NOT EXISTS idx_dues_liabilities_operating_budget
    ON dues_liabilities (operating_budget_id) WHERE operating_budget_id IS NOT NULL;

-- A site that requires a budget never accrues operational dues without one.
ALTER TABLE sites ADD COLUMN IF NOT EXISTS require_operating_budget BOOLEAN NOT NULL DEFAULT FALSE;

-- ---------------------------------------------------------------------------
-- R4: card payments through a licensed payment provider.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS payment_intents (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE RESTRICT,
    unit_id BIGINT NOT NULL REFERENCES units(id) ON DELETE RESTRICT,
    debtor_type VARCHAR(10) NOT NULL,
    payer_name TEXT NOT NULL,
    amount NUMERIC(15,2) NOT NULL CHECK (amount > 0),
    currency CHAR(3) NOT NULL DEFAULT 'TRY',
    provider VARCHAR(30) NOT NULL,
    provider_ref VARCHAR(100) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'CREATED',
    checkout_url TEXT,
    three_ds_status VARCHAR(20),
    fee_amount NUMERIC(15,2) CHECK (fee_amount IS NULL OR fee_amount >= 0),
    failure_reason TEXT,
    receipt_number VARCHAR(50),
    designation JSONB,
    created_by TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    captured_at TIMESTAMPTZ,
    CONSTRAINT chk_payment_intents_debtor CHECK (debtor_type IN ('OWNER', 'TENANT')),
    CONSTRAINT chk_payment_intents_status
        CHECK (status IN ('CREATED', 'AUTHORIZED', 'CAPTURED', 'FAILED', 'REFUNDED', 'EXPIRED')),
    CONSTRAINT chk_payment_intents_captured
        CHECK (status NOT IN ('CAPTURED', 'REFUNDED') OR (receipt_number IS NOT NULL AND captured_at IS NOT NULL)),
    CONSTRAINT uq_payment_intents_provider_ref UNIQUE (provider, provider_ref)
);
CREATE INDEX IF NOT EXISTS idx_payment_intents_unit ON payment_intents (unit_id, created_at DESC);


CREATE OR REPLACE VIEW v_integrity_violations AS
SELECT 'advance_balance_vs_ledger' AS check_name, ab.unit_id::text || '/' || ab.debtor_type AS subject,
       ab.balance - COALESCE(l.net, 0) AS difference
FROM advance_balances ab
LEFT JOIN (
    SELECT unit_id, debtor_type,
           SUM(CASE WHEN entry_type IN ('PAYMENT_SURPLUS', 'ADJUSTMENT_CREDIT', 'VIRMAN_REVERSAL') THEN amount
                    WHEN entry_type = 'ADJUSTMENT' THEN 0
                    ELSE -amount END) AS net
    FROM advance_ledger_entries GROUP BY unit_id, debtor_type
) l ON l.unit_id = ab.unit_id AND l.debtor_type = ab.debtor_type
WHERE ab.balance <> COALESCE(l.net, 0)
UNION ALL
SELECT 'installment_percentages', project_id::text, SUM(percentage) - 100
FROM capital_project_installments GROUP BY project_id HAVING SUM(percentage) <> 100
UNION ALL
-- A reversed entry's allocations no longer count as paid (O-2).
SELECT 'allocations_vs_dues_paid', d.id::text,
       (d.paid_principal + d.paid_penalty) - COALESCE(SUM(pa.principal_amount + pa.penalty_amount), 0)
FROM dues_liabilities d
LEFT JOIN payment_allocations pa ON pa.dues_liability_id = d.id
    AND NOT EXISTS (SELECT 1 FROM payment_entries re WHERE re.id = pa.payment_entry_id AND re.settlement_status = 'REVERSED')
GROUP BY d.id
HAVING EXISTS (SELECT 1 FROM payment_allocations x WHERE x.dues_liability_id = d.id)
   AND (d.paid_principal + d.paid_penalty) <> COALESCE(SUM(pa.principal_amount + pa.penalty_amount), 0)
UNION ALL
SELECT 'allocations_exceed_entry_amount', e.id::text,
       COALESCE(SUM(pa.principal_amount + pa.penalty_amount), 0) - e.amount
FROM payment_entries e
JOIN payment_allocations pa ON pa.payment_entry_id = e.id
GROUP BY e.id, e.amount
HAVING COALESCE(SUM(pa.principal_amount + pa.penalty_amount), 0) > e.amount
UNION ALL
SELECT 'entry_vs_receipt_amount', e.id::text, e.amount - r.total_amount
FROM payment_entries e
JOIN payment_receipts r ON r.id = e.receipt_id
WHERE e.amount <> r.total_amount AND e.payment_channel <> 'INTER_LEDGER'
UNION ALL
-- A reversal mirrors its original exactly (O-2).
SELECT 'reversal_vs_original', re.id::text, re.amount - o.amount
FROM payment_entries re
JOIN payment_entries o ON o.id = re.reverses_entry_id
WHERE re.amount <> o.amount OR o.settlement_status <> 'REVERSED' OR re.unit_id <> o.unit_id
UNION ALL
SELECT 'reversal_receipt_vs_original', rr.id::text, rr.total_amount - orr.total_amount
FROM payment_receipts rr
JOIN payment_receipts orr ON orr.id = rr.reverses_receipt_id
WHERE rr.total_amount <> orr.total_amount OR rr.allocated_principal <> orr.allocated_principal
   OR rr.allocated_penalty <> orr.allocated_penalty OR rr.allocated_advance <> orr.allocated_advance
UNION ALL
-- SPEC-007 R5: a budget's unit shares add up to its lines, to the kuruş.
SELECT 'budget_shares_vs_lines', b.id::text,
       COALESCE((SELECT SUM(s.annual_amount) FROM operating_budget_unit_shares s WHERE s.budget_id = b.id), 0)
     - COALESCE((SELECT SUM(l.annual_amount) FROM operating_budget_lines l WHERE l.budget_id = b.id), 0)
FROM operating_budgets b
WHERE b.status <> 'DRAFT'
  AND COALESCE((SELECT SUM(s.annual_amount) FROM operating_budget_unit_shares s WHERE s.budget_id = b.id), 0)
   <> COALESCE((SELECT SUM(l.annual_amount) FROM operating_budget_lines l WHERE l.budget_id = b.id), 0)
UNION ALL
-- SPEC-007 R4: a captured card payment has exactly the receipt it produced.
SELECT 'captured_intent_without_receipt', pi.id::text, pi.amount
FROM payment_intents pi
WHERE pi.status IN ('CAPTURED', 'REFUNDED')
  AND NOT EXISTS (SELECT 1 FROM payment_receipts r WHERE r.site_id = pi.site_id AND r.receipt_number = pi.receipt_number);
