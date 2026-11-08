-- V20: Payments phase 3 (SPEC-009, docs/PAYMENTS_PRODUCT_OWNER_EVALUATION.md F-01 .. F-17).
--
-- R1  budget allocation keys HOUSE_TYPE / METER / CUSTOM, budget transition mode
-- R2  KVKK: privacy notices, acknowledgements, channel consents, access log, retention
-- R3  KMK 22: tenancy leases (rent cap of the tenant's joint liability)
-- R4  notification delivery log, dunning policies and executed dunning steps
-- R5  resident virman requests and disputes
-- R6  saved payment methods (provider tokens), autopay mandates and attempts, card instalments
-- R7  vendors, expense invoices and payments, approval policy, manual journal entries
-- R8  collection cases and their events
-- R9  bank feed connections and daily ledger-vs-bank reconciliation runs
-- R10 payment plans with instalments, ledger adjustments (waivers / write-offs)
-- R11 heat-cost periods, meter readings and unit shares
-- R12 assembly meetings, agenda, attendance, votes and the decisions book
-- R13 management companies, their sites and members, fee invoices
--
-- Every SPEC-009 aggregate has a BIGSERIAL id; services never write ids themselves.

-- ---------------------------------------------------------------------------
-- Roles: the read-only auditor (denetçi).
-- ---------------------------------------------------------------------------
ALTER TABLE users DROP CONSTRAINT IF EXISTS chk_users_role;
SELECT sp_add_constraint('users', 'chk_users_role',
    $c$CHECK (role IN ('SAAS_ADMIN', 'SITE_MANAGER', 'HOME_OWNER', 'HOME_RESIDENT', 'AUDITOR'))$c$);
ALTER TABLE persons DROP CONSTRAINT IF EXISTS chk_persons_person_type;
SELECT sp_add_constraint('persons', 'chk_persons_person_type',
    $c$CHECK (person_type IN ('HOME_OWNER', 'HOME_RESIDENT', 'SITE_MANAGER', 'SAAS_ADMIN', 'AUDITOR'))$c$);

-- ---------------------------------------------------------------------------
-- R1: allocation keys and transition mode.
-- ---------------------------------------------------------------------------
ALTER TABLE operating_budget_lines DROP CONSTRAINT IF EXISTS chk_operating_budget_lines_key;
SELECT sp_add_constraint('operating_budget_lines', 'chk_operating_budget_lines_key',
    $c$CHECK (allocation_key IN ('LAND_SHARE', 'EQUAL', 'HOUSE_TYPE', 'METER', 'CUSTOM'))$c$);
-- Explicit per-unit weights of a METER or CUSTOM line: [{"unit_id": "14", "weight": 120}, ...].
ALTER TABLE operating_budget_lines ADD COLUMN IF NOT EXISTS unit_weights JSONB;
ALTER TABLE operating_budgets ADD COLUMN IF NOT EXISTS assembly_decision_id BIGINT;
-- Mid-year migration: accrual without a budget is tolerated until this date (at most 90 days).
ALTER TABLE sites ADD COLUMN IF NOT EXISTS budget_transition_until DATE;

-- ---------------------------------------------------------------------------
-- R2: KVKK.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS privacy_notices (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    version INT NOT NULL CHECK (version > 0),
    title TEXT NOT NULL,
    body TEXT NOT NULL CHECK (length(trim(body)) >= 20),
    published_at TIMESTAMPTZ NOT NULL,
    published_by TEXT NOT NULL,
    CONSTRAINT uq_privacy_notice_version UNIQUE (site_id, version)
);

CREATE TABLE IF NOT EXISTS privacy_acknowledgements (
    id BIGSERIAL PRIMARY KEY,
    notice_id BIGINT NOT NULL REFERENCES privacy_notices(id) ON DELETE CASCADE,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    user_ref TEXT NOT NULL,
    acknowledged_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT uq_privacy_ack UNIQUE (notice_id, user_ref)
);

CREATE TABLE IF NOT EXISTS communication_consents (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    user_ref TEXT NOT NULL,
    channel VARCHAR(20) NOT NULL,
    granted BOOLEAN NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT chk_consent_channel CHECK (channel IN ('EMAIL', 'SMS', 'PUSH', 'WHATSAPP')),
    CONSTRAINT uq_consent_user_channel UNIQUE (site_id, user_ref, channel)
);

CREATE TABLE IF NOT EXISTS financial_access_log (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT,
    actor TEXT NOT NULL,
    actor_role VARCHAR(20) NOT NULL,
    action VARCHAR(10) NOT NULL,
    resource VARCHAR(40) NOT NULL,
    subject_unit_id BIGINT,
    detail TEXT,
    occurred_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT chk_access_log_action CHECK (action IN ('VIEW', 'EXPORT', 'BLOCKED'))
);
CREATE INDEX IF NOT EXISTS idx_access_log_site ON financial_access_log (site_id, occurred_at DESC);

CREATE TABLE IF NOT EXISTS data_retention_policies (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    category VARCHAR(30) NOT NULL,
    retention_months INT NOT NULL CHECK (retention_months BETWEEN 1 AND 600),
    updated_by TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT chk_retention_category
        CHECK (category IN ('FINANCIAL_RECORDS', 'ACCESS_LOG', 'NOTIFICATIONS', 'SENDER_IBANS', 'STATEMENTS')),
    CONSTRAINT uq_retention_site_category UNIQUE (site_id, category)
);

-- ---------------------------------------------------------------------------
-- R3: KMK 22 leases.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tenancy_leases (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    unit_id BIGINT NOT NULL REFERENCES units(id) ON DELETE CASCADE,
    tenant_name TEXT NOT NULL,
    tenant_user_ref TEXT,
    monthly_rent NUMERIC(15,2) NOT NULL CHECK (monthly_rent > 0),
    lease_start DATE NOT NULL,
    lease_end DATE,
    rent_paid_through DATE,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_by TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT chk_lease_period CHECK (lease_end IS NULL OR lease_end >= lease_start)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_tenancy_lease_active ON tenancy_leases (unit_id) WHERE active;

-- ---------------------------------------------------------------------------
-- R4: notifications and dunning.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS notifications (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    unit_id BIGINT,
    recipient_ref TEXT NOT NULL,
    recipient_name TEXT NOT NULL,
    channel VARCHAR(20) NOT NULL,
    category VARCHAR(20) NOT NULL,
    subject TEXT NOT NULL,
    body TEXT NOT NULL,
    status VARCHAR(10) NOT NULL,
    block_reason TEXT,
    provider_ref TEXT,
    dedupe_key TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    sent_at TIMESTAMPTZ,
    CONSTRAINT chk_notification_channel
        CHECK (channel IN ('EMAIL', 'SMS', 'PUSH', 'WHATSAPP', 'LETTER', 'GROUP_CHAT', 'NOTICE_BOARD', 'WHATSAPP_GROUP')),
    CONSTRAINT chk_notification_category
        CHECK (category IN ('DEBT_REMINDER', 'DEBT_NOTICE', 'PAYMENT', 'AUTOPAY', 'PLAN', 'BUDGET', 'COLLECTION', 'SYSTEM')),
    CONSTRAINT chk_notification_status CHECK (status IN ('SENT', 'BLOCKED', 'FAILED')),
    -- KVKK 2026/348: a debt notice never reaches a group channel.
    CONSTRAINT chk_notification_debt_personal
        CHECK (status = 'BLOCKED' OR category NOT IN ('DEBT_REMINDER', 'DEBT_NOTICE', 'COLLECTION')
               OR channel IN ('EMAIL', 'SMS', 'PUSH', 'WHATSAPP', 'LETTER')),
    CONSTRAINT uq_notification_dedupe UNIQUE (site_id, dedupe_key)
);
CREATE INDEX IF NOT EXISTS idx_notifications_site ON notifications (site_id, created_at DESC);

CREATE TABLE IF NOT EXISTS dunning_policies (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL UNIQUE REFERENCES sites(id) ON DELETE CASCADE,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    steps JSONB NOT NULL,
    updated_by TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS dunning_actions (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    due_id BIGINT NOT NULL REFERENCES dues_liabilities(id) ON DELETE CASCADE,
    step_index INT NOT NULL CHECK (step_index >= 0),
    kind VARCHAR(20) NOT NULL,
    channel VARCHAR(20) NOT NULL,
    notification_id BIGINT REFERENCES notifications(id) ON DELETE SET NULL,
    executed_on DATE NOT NULL,
    outcome VARCHAR(10) NOT NULL,
    CONSTRAINT chk_dunning_kind CHECK (kind IN ('REMINDER', 'WRITTEN_WARNING', 'IHTARNAME')),
    CONSTRAINT chk_dunning_outcome CHECK (outcome IN ('SENT', 'BLOCKED', 'FAILED')),
    CONSTRAINT uq_dunning_due_step UNIQUE (due_id, step_index)
);

-- ---------------------------------------------------------------------------
-- R5: resident requests.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS virman_requests (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    unit_id BIGINT NOT NULL REFERENCES units(id) ON DELETE CASCADE,
    source_debtor VARCHAR(10) NOT NULL,
    target_debtor VARCHAR(10) NOT NULL,
    amount NUMERIC(15,2) NOT NULL CHECK (amount > 0),
    note TEXT,
    requested_by TEXT NOT NULL,
    status VARCHAR(10) NOT NULL,
    decided_by TEXT,
    decided_at TIMESTAMPTZ,
    decision_note TEXT,
    receipt_number VARCHAR(50),
    created_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT chk_virman_request_debtors
        CHECK (source_debtor IN ('OWNER', 'TENANT') AND target_debtor IN ('OWNER', 'TENANT') AND source_debtor <> target_debtor),
    CONSTRAINT chk_virman_request_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED')),
    CONSTRAINT chk_virman_request_decided CHECK ((status = 'PENDING') = (decided_at IS NULL))
);

CREATE TABLE IF NOT EXISTS ledger_disputes (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    unit_id BIGINT NOT NULL REFERENCES units(id) ON DELETE CASCADE,
    due_id BIGINT NOT NULL REFERENCES dues_liabilities(id) ON DELETE CASCADE,
    debtor_type VARCHAR(10) NOT NULL CHECK (debtor_type IN ('OWNER', 'TENANT')),
    reason TEXT NOT NULL CHECK (length(trim(reason)) >= 5),
    raised_by TEXT NOT NULL,
    status VARCHAR(10) NOT NULL,
    resolution_note TEXT,
    resolved_by TEXT,
    resolved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT chk_dispute_status CHECK (status IN ('OPEN', 'ACCEPTED', 'REJECTED')),
    CONSTRAINT chk_dispute_resolved CHECK ((status = 'OPEN') = (resolved_at IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_dispute_open_due ON ledger_disputes (due_id) WHERE status = 'OPEN';

-- ---------------------------------------------------------------------------
-- R6: autopay.
-- ---------------------------------------------------------------------------
ALTER TABLE payment_intents ADD COLUMN IF NOT EXISTS installment_count INT NOT NULL DEFAULT 1;
SELECT sp_add_constraint('payment_intents', 'chk_payment_intents_installments',
    $c$CHECK (installment_count IN (1, 2, 3, 6, 9, 12))$c$);
ALTER TABLE payment_intents ADD COLUMN IF NOT EXISTS save_card BOOLEAN NOT NULL DEFAULT FALSE;

CREATE TABLE IF NOT EXISTS saved_payment_methods (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    unit_id BIGINT NOT NULL REFERENCES units(id) ON DELETE CASCADE,
    debtor_type VARCHAR(10) NOT NULL CHECK (debtor_type IN ('OWNER', 'TENANT')),
    owner_ref TEXT NOT NULL,
    provider VARCHAR(30) NOT NULL,
    token_ref VARCHAR(120) NOT NULL,
    brand VARCHAR(20) NOT NULL,
    last4 CHAR(4) NOT NULL CHECK (last4 ~ '^[0-9]{4}$'),
    exp_month INT NOT NULL CHECK (exp_month BETWEEN 1 AND 12),
    exp_year INT NOT NULL CHECK (exp_year BETWEEN 2000 AND 2100),
    status VARCHAR(10) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT chk_payment_method_status CHECK (status IN ('ACTIVE', 'REVOKED', 'EXPIRED')),
    CONSTRAINT uq_payment_method_token UNIQUE (provider, token_ref)
);

CREATE TABLE IF NOT EXISTS autopay_mandates (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    unit_id BIGINT NOT NULL REFERENCES units(id) ON DELETE CASCADE,
    debtor_type VARCHAR(10) NOT NULL CHECK (debtor_type IN ('OWNER', 'TENANT')),
    payment_method_id BIGINT NOT NULL REFERENCES saved_payment_methods(id) ON DELETE RESTRICT,
    max_amount NUMERIC(15,2) CHECK (max_amount IS NULL OR max_amount > 0),
    status VARCHAR(10) NOT NULL,
    consented_by TEXT NOT NULL,
    consented_at TIMESTAMPTZ NOT NULL,
    suspended_reason TEXT,
    updated_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT chk_mandate_status CHECK (status IN ('ACTIVE', 'SUSPENDED', 'CANCELLED'))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_mandate_active ON autopay_mandates (unit_id, debtor_type) WHERE status = 'ACTIVE';

CREATE TABLE IF NOT EXISTS autopay_attempts (
    id BIGSERIAL PRIMARY KEY,
    mandate_id BIGINT NOT NULL REFERENCES autopay_mandates(id) ON DELETE CASCADE,
    due_id BIGINT NOT NULL REFERENCES dues_liabilities(id) ON DELETE CASCADE,
    attempt_no INT NOT NULL CHECK (attempt_no BETWEEN 1 AND 3),
    amount NUMERIC(15,2) NOT NULL CHECK (amount > 0),
    status VARCHAR(15) NOT NULL,
    provider_ref TEXT,
    receipt_number VARCHAR(50),
    failure_reason TEXT,
    attempted_on DATE NOT NULL,
    next_retry_on DATE,
    created_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT chk_autopay_attempt_status CHECK (status IN ('CAPTURED', 'DECLINED', 'EXPIRED_CARD')),
    -- A declined charge never carries a receipt (it never marks a due as paid).
    CONSTRAINT chk_autopay_receipt_only_captured CHECK ((status = 'CAPTURED') = (receipt_number IS NOT NULL)),
    CONSTRAINT uq_autopay_attempt UNIQUE (mandate_id, due_id, attempt_no)
);

-- ---------------------------------------------------------------------------
-- R7: expenses, approvals, manual journal.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vendors (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    tax_id VARCHAR(11) NOT NULL CHECK (tax_id ~ '^[0-9]{10,11}$'),
    iban VARCHAR(34),
    email TEXT,
    phone TEXT,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT uq_vendor_tax_id UNIQUE (site_id, tax_id)
);

CREATE TABLE IF NOT EXISTS expense_approval_policies (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL UNIQUE REFERENCES sites(id) ON DELETE CASCADE,
    manager_limit NUMERIC(15,2) NOT NULL CHECK (manager_limit >= 0),
    updated_by TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS expense_invoices (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    vendor_id BIGINT NOT NULL REFERENCES vendors(id) ON DELETE RESTRICT,
    invoice_number VARCHAR(50) NOT NULL,
    invoice_date DATE NOT NULL,
    due_date DATE,
    category VARCHAR(30) NOT NULL,
    description TEXT,
    net_amount NUMERIC(15,2) NOT NULL CHECK (net_amount > 0),
    vat_amount NUMERIC(15,2) NOT NULL CHECK (vat_amount >= 0),
    total_amount NUMERIC(15,2) NOT NULL,
    document_ref TEXT,
    status VARCHAR(20) NOT NULL,
    budget_id BIGINT REFERENCES operating_budgets(id) ON DELETE SET NULL,
    approvals JSONB NOT NULL DEFAULT '[]'::jsonb,
    rejection_reason TEXT,
    created_by TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT chk_expense_total CHECK (total_amount = net_amount + vat_amount),
    CONSTRAINT chk_expense_category
        CHECK (category IN ('PERSONNEL', 'CLEANING', 'ENERGY', 'WATER', 'MAINTENANCE', 'INSURANCE',
                            'MANAGEMENT_FEE', 'SECURITY', 'GARDENING', 'RESERVE', 'OTHER')),
    CONSTRAINT chk_expense_status
        CHECK (status IN ('PENDING_APPROVAL', 'APPROVED', 'PARTIALLY_PAID', 'PAID', 'REJECTED', 'CANCELLED')),
    CONSTRAINT uq_expense_vendor_invoice UNIQUE (site_id, vendor_id, invoice_number)
);
CREATE INDEX IF NOT EXISTS idx_expense_invoices_site ON expense_invoices (site_id, invoice_date);

CREATE TABLE IF NOT EXISTS expense_payments (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    invoice_id BIGINT NOT NULL REFERENCES expense_invoices(id) ON DELETE RESTRICT,
    amount NUMERIC(15,2) NOT NULL CHECK (amount > 0),
    paid_on DATE NOT NULL,
    method VARCHAR(20) NOT NULL CHECK (method IN ('BANK_TRANSFER', 'CASH')),
    reference TEXT,
    recorded_by TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS manual_journal_entries (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    entry_date DATE NOT NULL,
    kind VARCHAR(20) NOT NULL,
    description TEXT NOT NULL,
    created_by TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT chk_manual_journal_kind
        CHECK (kind IN ('GENERAL', 'OPENING', 'RESERVE_ALLOCATION', 'RESERVE_USE', 'BANK_FEE'))
);

CREATE TABLE IF NOT EXISTS manual_journal_lines (
    id BIGSERIAL PRIMARY KEY,
    entry_id BIGINT NOT NULL REFERENCES manual_journal_entries(id) ON DELETE CASCADE,
    account_code VARCHAR(10) NOT NULL,
    debit NUMERIC(15,2) NOT NULL DEFAULT 0 CHECK (debit >= 0),
    credit NUMERIC(15,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
    CONSTRAINT chk_manual_journal_line_side CHECK ((debit > 0) <> (credit > 0))
);

-- ---------------------------------------------------------------------------
-- R8: collections.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS collection_cases (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    unit_id BIGINT NOT NULL REFERENCES units(id) ON DELETE CASCADE,
    debtor_type VARCHAR(10) NOT NULL CHECK (debtor_type IN ('OWNER', 'TENANT')),
    due_ids JSONB NOT NULL,
    opened_amount NUMERIC(15,2) NOT NULL CHECK (opened_amount > 0),
    status VARCHAR(20) NOT NULL,
    lawyer_name TEXT,
    lawyer_contact TEXT,
    lawyer_token_digest VARCHAR(64),
    lawyer_token_expires_at TIMESTAMPTZ,
    opened_by TEXT NOT NULL,
    opened_at TIMESTAMPTZ NOT NULL,
    closed_at TIMESTAMPTZ,
    note TEXT,
    CONSTRAINT chk_collection_case_status
        CHECK (status IN ('REMINDED', 'NOTICE_SENT', 'MEDIATION', 'LAWYER_ASSIGNED', 'ICRA_FILED', 'COLLECTED', 'WRITTEN_OFF')),
    CONSTRAINT chk_collection_case_closed
        CHECK ((status IN ('COLLECTED', 'WRITTEN_OFF')) = (closed_at IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS collection_case_events (
    id BIGSERIAL PRIMARY KEY,
    case_id BIGINT NOT NULL REFERENCES collection_cases(id) ON DELETE CASCADE,
    from_status VARCHAR(20),
    to_status VARCHAR(20) NOT NULL,
    note TEXT,
    actor TEXT NOT NULL,
    occurred_on DATE NOT NULL,
    created_at TIMESTAMPTZ NOT NULL
);

-- ---------------------------------------------------------------------------
-- R9: bank feeds and daily reconciliation.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bank_feed_connections (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    provider VARCHAR(20) NOT NULL CHECK (provider IN ('SANDBOX', 'STATEMENT_FILE', 'KUVEYT_TURK')),
    account_iban VARCHAR(34) NOT NULL,
    credential_ref TEXT,
    status VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'DISABLED', 'ERROR')),
    last_synced_at TIMESTAMPTZ,
    last_error TEXT,
    created_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT uq_bank_feed_account UNIQUE (site_id, account_iban)
);

CREATE TABLE IF NOT EXISTS bank_reconciliation_runs (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    business_date DATE NOT NULL,
    bank_movement NUMERIC(15,2) NOT NULL,
    ledger_movement NUMERIC(15,2) NOT NULL,
    difference NUMERIC(15,2) NOT NULL,
    bank_closing_balance NUMERIC(15,2),
    details JSONB NOT NULL,
    run_by TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT chk_bank_recon_difference CHECK (difference = bank_movement - ledger_movement)
);

-- ---------------------------------------------------------------------------
-- R10: payment plans and adjustments.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS payment_plans (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    unit_id BIGINT NOT NULL REFERENCES units(id) ON DELETE CASCADE,
    debtor_type VARCHAR(10) NOT NULL CHECK (debtor_type IN ('OWNER', 'TENANT')),
    due_ids JSONB NOT NULL,
    total_amount NUMERIC(15,2) NOT NULL CHECK (total_amount > 0),
    installment_count INT NOT NULL CHECK (installment_count BETWEEN 2 AND 36),
    first_due_date DATE NOT NULL,
    grace_days INT NOT NULL CHECK (grace_days BETWEEN 0 AND 60),
    waive_penalty_on_completion BOOLEAN NOT NULL DEFAULT FALSE,
    status VARCHAR(10) NOT NULL,
    opened_on DATE NOT NULL,
    created_by TEXT NOT NULL,
    approved_by TEXT NOT NULL,
    closed_on DATE,
    note TEXT,
    CONSTRAINT chk_payment_plan_status CHECK (status IN ('ACTIVE', 'COMPLETED', 'BROKEN', 'CANCELLED')),
    CONSTRAINT chk_payment_plan_four_eyes CHECK (created_by <> approved_by)
);

CREATE TABLE IF NOT EXISTS payment_plan_installments (
    id BIGSERIAL PRIMARY KEY,
    plan_id BIGINT NOT NULL REFERENCES payment_plans(id) ON DELETE CASCADE,
    seq INT NOT NULL CHECK (seq > 0),
    due_date DATE NOT NULL,
    amount NUMERIC(15,2) NOT NULL CHECK (amount > 0),
    CONSTRAINT uq_payment_plan_seq UNIQUE (plan_id, seq)
);

CREATE TABLE IF NOT EXISTS ledger_adjustments (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    unit_id BIGINT NOT NULL REFERENCES units(id) ON DELETE CASCADE,
    due_id BIGINT NOT NULL REFERENCES dues_liabilities(id) ON DELETE RESTRICT,
    kind VARCHAR(25) NOT NULL CHECK (kind IN ('PENALTY_WAIVER', 'PRINCIPAL_WRITE_OFF')),
    amount NUMERIC(15,2) NOT NULL CHECK (amount > 0),
    reason TEXT NOT NULL CHECK (length(trim(reason)) >= 5),
    source VARCHAR(15) NOT NULL CHECK (source IN ('MANUAL', 'PAYMENT_PLAN', 'COLLECTION')),
    requested_by TEXT NOT NULL,
    requested_at TIMESTAMPTZ NOT NULL,
    status VARCHAR(10) NOT NULL CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED')),
    decided_by TEXT,
    decided_at TIMESTAMPTZ,
    decision_note TEXT,
    principal_before NUMERIC(15,2),
    penalty_before NUMERIC(15,2),
    -- Every waiver has an approver distinct from the requester.
    CONSTRAINT chk_adjustment_four_eyes CHECK (decided_by IS NULL OR decided_by <> requested_by),
    CONSTRAINT chk_adjustment_decided CHECK ((status = 'PENDING') = (decided_at IS NULL))
);

-- ---------------------------------------------------------------------------
-- R11: heat-share billing.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS heat_cost_periods (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    label TEXT NOT NULL,
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    total_cost NUMERIC(15,2) NOT NULL CHECK (total_cost > 0),
    consumption_share_percent NUMERIC(5,2) NOT NULL CHECK (consumption_share_percent BETWEEN 0 AND 100),
    due_date DATE NOT NULL,
    status VARCHAR(10) NOT NULL CHECK (status IN ('DRAFT', 'APPROVED')),
    approved_by TEXT,
    approved_at TIMESTAMPTZ,
    created_by TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT chk_heat_period CHECK (period_end >= period_start),
    CONSTRAINT uq_heat_period_label UNIQUE (site_id, label)
);

CREATE TABLE IF NOT EXISTS heat_meter_readings (
    id BIGSERIAL PRIMARY KEY,
    period_id BIGINT NOT NULL REFERENCES heat_cost_periods(id) ON DELETE CASCADE,
    unit_id BIGINT NOT NULL REFERENCES units(id) ON DELETE CASCADE,
    area_weight INT NOT NULL CHECK (area_weight >= 0),
    previous_reading NUMERIC(15,3) NOT NULL CHECK (previous_reading >= 0),
    current_reading NUMERIC(15,3) NOT NULL,
    CONSTRAINT chk_heat_reading_monotonic CHECK (current_reading >= previous_reading),
    CONSTRAINT uq_heat_reading_unit UNIQUE (period_id, unit_id)
);

CREATE TABLE IF NOT EXISTS heat_cost_shares (
    id BIGSERIAL PRIMARY KEY,
    period_id BIGINT NOT NULL REFERENCES heat_cost_periods(id) ON DELETE CASCADE,
    unit_id BIGINT NOT NULL REFERENCES units(id) ON DELETE CASCADE,
    fixed_amount NUMERIC(15,2) NOT NULL CHECK (fixed_amount >= 0),
    consumption_amount NUMERIC(15,2) NOT NULL CHECK (consumption_amount >= 0),
    total_amount NUMERIC(15,2) NOT NULL,
    due_id BIGINT REFERENCES dues_liabilities(id) ON DELETE SET NULL,
    CONSTRAINT chk_heat_share_total CHECK (total_amount = fixed_amount + consumption_amount),
    CONSTRAINT uq_heat_share_unit UNIQUE (period_id, unit_id)
);

-- ---------------------------------------------------------------------------
-- R12: assembly and decisions book.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS assembly_meetings (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    kind VARCHAR(15) NOT NULL CHECK (kind IN ('ORDINARY', 'EXTRAORDINARY')),
    call_number INT NOT NULL CHECK (call_number IN (1, 2)),
    scheduled_at TIMESTAMPTZ NOT NULL,
    location TEXT NOT NULL,
    status VARCHAR(10) NOT NULL CHECK (status IN ('PLANNED', 'HELD', 'NO_QUORUM', 'CANCELLED')),
    held_on DATE,
    created_by TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS assembly_decisions (
    id BIGSERIAL PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    meeting_id BIGINT REFERENCES assembly_meetings(id) ON DELETE SET NULL,
    decision_number INT NOT NULL CHECK (decision_number > 0),
    decided_on DATE NOT NULL,
    title TEXT NOT NULL,
    text TEXT NOT NULL,
    outcome VARCHAR(10) NOT NULL CHECK (outcome IN ('ACCEPTED', 'REJECTED')),
    rule VARCHAR(15) NOT NULL,
    yes_count INT NOT NULL DEFAULT 0,
    no_count INT NOT NULL DEFAULT 0,
    abstain_count INT NOT NULL DEFAULT 0,
    yes_land_share BIGINT NOT NULL DEFAULT 0,
    total_land_share BIGINT NOT NULL DEFAULT 0,
    linked_budget_id BIGINT REFERENCES operating_budgets(id) ON DELETE SET NULL,
    attachment_ref TEXT,
    recorded_by TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT uq_assembly_decision_number UNIQUE (site_id, decision_number)
);
SELECT sp_add_constraint('operating_budgets', 'fk_operating_budgets_decision',
    $c$FOREIGN KEY (assembly_decision_id) REFERENCES assembly_decisions(id) ON DELETE RESTRICT$c$);

CREATE TABLE IF NOT EXISTS assembly_agenda_items (
    id BIGSERIAL PRIMARY KEY,
    meeting_id BIGINT NOT NULL REFERENCES assembly_meetings(id) ON DELETE CASCADE,
    seq INT NOT NULL CHECK (seq > 0),
    title TEXT NOT NULL,
    description TEXT,
    rule VARCHAR(15) NOT NULL CHECK (rule IN ('SIMPLE', 'TWO_THIRDS', 'FOUR_FIFTHS', 'UNANIMOUS')),
    linked_budget_id BIGINT REFERENCES operating_budgets(id) ON DELETE SET NULL,
    status VARCHAR(10) NOT NULL CHECK (status IN ('OPEN', 'CLOSED')),
    decision_id BIGINT REFERENCES assembly_decisions(id) ON DELETE SET NULL,
    CONSTRAINT uq_agenda_seq UNIQUE (meeting_id, seq)
);

CREATE TABLE IF NOT EXISTS assembly_attendance (
    id BIGSERIAL PRIMARY KEY,
    meeting_id BIGINT NOT NULL REFERENCES assembly_meetings(id) ON DELETE CASCADE,
    unit_id BIGINT NOT NULL REFERENCES units(id) ON DELETE CASCADE,
    attendee_name TEXT NOT NULL,
    is_proxy BOOLEAN NOT NULL DEFAULT FALSE,
    CONSTRAINT uq_attendance_unit UNIQUE (meeting_id, unit_id)
);

CREATE TABLE IF NOT EXISTS assembly_votes (
    id BIGSERIAL PRIMARY KEY,
    agenda_item_id BIGINT NOT NULL REFERENCES assembly_agenda_items(id) ON DELETE CASCADE,
    unit_id BIGINT NOT NULL REFERENCES units(id) ON DELETE CASCADE,
    vote VARCHAR(10) NOT NULL CHECK (vote IN ('YES', 'NO', 'ABSTAIN')),
    CONSTRAINT uq_vote_unit UNIQUE (agenda_item_id, unit_id)
);

-- ---------------------------------------------------------------------------
-- R13: management companies and fee invoices.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS management_companies (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    tax_id VARCHAR(11) NOT NULL UNIQUE CHECK (tax_id ~ '^[0-9]{10,11}$'),
    tax_office TEXT NOT NULL,
    address TEXT,
    created_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS management_company_sites (
    id BIGSERIAL PRIMARY KEY,
    company_id BIGINT NOT NULL REFERENCES management_companies(id) ON DELETE CASCADE,
    site_id BIGINT NOT NULL UNIQUE REFERENCES sites(id) ON DELETE CASCADE,
    monthly_fee NUMERIC(15,2) NOT NULL CHECK (monthly_fee >= 0),
    vat_rate NUMERIC(5,2) NOT NULL CHECK (vat_rate BETWEEN 0 AND 100),
    active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS management_company_members (
    id BIGSERIAL PRIMARY KEY,
    company_id BIGINT NOT NULL REFERENCES management_companies(id) ON DELETE CASCADE,
    user_ref TEXT NOT NULL,
    CONSTRAINT uq_company_member UNIQUE (company_id, user_ref)
);

CREATE TABLE IF NOT EXISTS fee_invoices (
    id BIGSERIAL PRIMARY KEY,
    company_id BIGINT NOT NULL REFERENCES management_companies(id) ON DELETE RESTRICT,
    site_id BIGINT NOT NULL REFERENCES sites(id) ON DELETE RESTRICT,
    period VARCHAR(7) NOT NULL CHECK (period ~ '^[0-9]{4}-[0-9]{2}$'),
    net_amount NUMERIC(15,2) NOT NULL CHECK (net_amount >= 0),
    vat_amount NUMERIC(15,2) NOT NULL CHECK (vat_amount >= 0),
    total_amount NUMERIC(15,2) NOT NULL,
    document_type VARCHAR(10) NOT NULL CHECK (document_type IN ('E_ARSIV', 'E_FATURA')),
    status VARCHAR(10) NOT NULL CHECK (status IN ('ISSUED', 'CANCELLED')),
    integrator VARCHAR(20) NOT NULL,
    integrator_uuid VARCHAR(36) NOT NULL,
    issued_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT chk_fee_invoice_total CHECK (total_amount = net_amount + vat_amount)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_fee_invoice_period
    ON fee_invoices (company_id, site_id, period) WHERE status = 'ISSUED';

-- ---------------------------------------------------------------------------
-- Integrity view: SPEC-009 checks appended.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_finance_integrity_violations AS
-- An expense is never paid beyond its total.
SELECT 'expense_overpaid' AS check_name, i.id::text AS subject,
       COALESCE(SUM(p.amount), 0) - i.total_amount AS difference
FROM expense_invoices i
JOIN expense_payments p ON p.invoice_id = i.id
GROUP BY i.id, i.total_amount
HAVING COALESCE(SUM(p.amount), 0) > i.total_amount
UNION ALL
-- A manual journal entry balances.
SELECT 'manual_journal_unbalanced', e.id::text, SUM(l.debit) - SUM(l.credit)
FROM manual_journal_entries e
JOIN manual_journal_lines l ON l.entry_id = e.id
GROUP BY e.id
HAVING SUM(l.debit) <> SUM(l.credit)
UNION ALL
-- A plan's instalments add up to its total.
SELECT 'plan_installments_vs_total', p.id::text,
       COALESCE((SELECT SUM(i.amount) FROM payment_plan_installments i WHERE i.plan_id = p.id), 0) - p.total_amount
FROM payment_plans p
WHERE COALESCE((SELECT SUM(i.amount) FROM payment_plan_installments i WHERE i.plan_id = p.id), 0) <> p.total_amount
UNION ALL
-- A heat period's unit shares add up to its cost once approved.
SELECT 'heat_shares_vs_cost', h.id::text,
       COALESCE((SELECT SUM(s.total_amount) FROM heat_cost_shares s WHERE s.period_id = h.id), 0) - h.total_cost
FROM heat_cost_periods h
WHERE h.status = 'APPROVED'
  AND COALESCE((SELECT SUM(s.total_amount) FROM heat_cost_shares s WHERE s.period_id = h.id), 0) <> h.total_cost;
