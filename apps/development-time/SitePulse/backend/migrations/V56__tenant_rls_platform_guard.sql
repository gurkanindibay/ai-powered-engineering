-- V56: Fail-closed tenant row-level security with an explicit platform switch (issue #534).
--
-- V54 made unbound tenant queries fail closed by allowing only `sp_is_platform()`.
-- Two gaps remained:
--
--   * The platform switch had no single named predicate the plan and the policies
--     share, and nothing stopped a future policy whose predicate does not itself
--     mention `sp_tenant_site()` (a copy-paste mistake) from returning rows to an
--     unbound transaction: `sp_is_platform() OR (TRUE)` would allow everything.
--   * An explicit check that every policy was really re-created was missing, so a
--     table added between migrations could keep an older, permissive policy unseen.
--
-- Now every policy is
--     USING      (sp_platform() OR (sp_tenant_site() IS NOT NULL AND (<predicate>)))
--     WITH CHECK (sp_platform() OR (sp_tenant_site() IS NOT NULL AND (<predicate>)))
-- so an unbound session (neither `tx_bind_tenant` nor `tx_bind_platform`) sees no
-- rows and cannot write, whatever the predicate says.

-- `sp_platform()` is TRUE only inside a transaction that called
-- `db::tenant_guard::tx_bind_platform` (`app.platform = 'on'`, transaction-local).
CREATE OR REPLACE FUNCTION sp_platform() RETURNS BOOLEAN
LANGUAGE sql STABLE AS
$$ SELECT current_setting('app.platform', true) IS NOT DISTINCT FROM 'on' $$;

CREATE OR REPLACE FUNCTION sp_enable_tenant_rls(p_table TEXT, p_predicate TEXT) RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    IF to_regclass(p_table) IS NULL THEN
        RAISE NOTICE 'V56: table % does not exist, skipped', p_table;
        RETURN;
    END IF;
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', p_table);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', p_table);
    EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %I', p_table);
    EXECUTE format(
        'CREATE POLICY tenant_isolation ON %I '
        'USING (sp_platform() OR (sp_tenant_site() IS NOT NULL AND (%s))) '
        'WITH CHECK (sp_platform() OR (sp_tenant_site() IS NOT NULL AND (%s)))',
        p_table, p_predicate, p_predicate);
END $$;

-- Re-apply to every tenant-isolated table (V25..V53). Keep this list identical to
-- V54's: a table that is missing here still fails the check at the end below.
SELECT sp_enable_tenant_rls('sites', 'id = sp_tenant_site()');

SELECT sp_enable_tenant_rls(t, 'site_id = sp_tenant_site()')
FROM unnest(ARRAY[
    'units', 'blocks', 'house_types', 'dues_periods',
    'payment_entries', 'payment_receipts', 'payment_idempotency_keys', 'payment_intents',
    'receipt_counters', 'processed_bank_webhooks', 'reconciliation_queue',
    'debt_aging_snapshots', 'site_bank_accounts', 'unit_sender_ibans',
    'invitation_tokens', 'pending_registrations', 'capital_projects', 'operating_budgets',
    'support_grants', 'assembly_meetings', 'assembly_decisions', 'autopay_mandates',
    'bank_feed_connections', 'bank_reconciliation_runs', 'collection_cases',
    'communication_consents', 'data_retention_policies', 'dunning_actions', 'dunning_policies',
    'expense_approval_policies', 'expense_invoices', 'expense_payments', 'fee_invoices',
    'heat_cost_periods', 'ledger_adjustments', 'ledger_disputes', 'manual_journal_entries',
    'notifications', 'payment_plans', 'privacy_acknowledgements', 'privacy_notices',
    'saved_payment_methods', 'tenancy_leases', 'vendors', 'virman_requests',
    'account_activations',
    'occupancy_transitions', 'dues_accrual_runs', 'accrual_corrections',
    'advance_exit_settlements', 'advance_exit_disbursements', 'late_fee_accruals',
    'dues_period_snapshots', 'dues_period_reopen_requests',
    'dues_liability_joint_owners', 'seller_pays_overrides', 'person_advance_holds'
]) AS t;

SELECT sp_enable_tenant_rls(t, 'unit_id IN (SELECT u.id FROM units u WHERE u.site_id = sp_tenant_site())')
FROM unnest(ARRAY[
    'dues_liabilities', 'advance_balances', 'advance_ledger_entries',
    'unit_occupancies', 'unit_ownerships', 'unit_payer_names',
    'operating_budget_unit_shares', 'budget_objections', 'budget_service_records',
    'assembly_attendance', 'assembly_votes', 'heat_cost_shares', 'heat_meter_readings'
]) AS t;

SELECT sp_enable_tenant_rls('payment_allocations',
    'payment_entry_id IN (SELECT e.id FROM payment_entries e WHERE e.site_id = sp_tenant_site())');
SELECT sp_enable_tenant_rls(t,
    'project_id IN (SELECT p.id FROM capital_projects p WHERE p.site_id = sp_tenant_site())')
FROM unnest(ARRAY['capital_project_installments', 'capital_contractor_disbursements']) AS t;
SELECT sp_enable_tenant_rls('operating_budget_lines',
    'budget_id IN (SELECT b.id FROM operating_budgets b WHERE b.site_id = sp_tenant_site())');

-- Child tables (V53).
SELECT sp_enable_tenant_rls('assembly_agenda_items',
    'meeting_id IN (SELECT m.id FROM assembly_meetings m WHERE m.site_id = sp_tenant_site())');
SELECT sp_enable_tenant_rls('autopay_attempts',
    'mandate_id IN (SELECT m.id FROM autopay_mandates m WHERE m.site_id = sp_tenant_site())
     AND due_id IN (SELECT d.id FROM dues_liabilities d WHERE d.unit_id IN
     (SELECT u.id FROM units u WHERE u.site_id = sp_tenant_site()))');
SELECT sp_enable_tenant_rls('collection_case_events',
    'case_id IN (SELECT c.id FROM collection_cases c WHERE c.site_id = sp_tenant_site())');
SELECT sp_enable_tenant_rls('manual_journal_lines',
    'entry_id IN (SELECT e.id FROM manual_journal_entries e WHERE e.site_id = sp_tenant_site())');
SELECT sp_enable_tenant_rls('payment_plan_installments',
    'plan_id IN (SELECT p.id FROM payment_plans p WHERE p.site_id = sp_tenant_site())');
SELECT sp_enable_tenant_rls('occupancy_members',
    'occupancy_id IN (SELECT o.id FROM unit_occupancies o WHERE o.unit_id IN
     (SELECT u.id FROM units u WHERE u.site_id = sp_tenant_site()))');

-- Every tenant policy must now carry the platform switch and the unbound guard on
-- both the read and the write side. A table that was added between migrations and
-- is missing from the lists above keeps an older policy, so fail the migration
-- instead of leaving a permissive policy in place until runtime finds it.
DO $$
DECLARE
    stale TEXT;
BEGIN
    SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO stale
    FROM pg_policy p
    JOIN pg_class c ON c.oid = p.polrelid
    WHERE p.polname = 'tenant_isolation'
      AND (
          coalesce(pg_get_expr(p.polqual, p.polrelid), '') NOT LIKE '%sp_platform()%'
          OR coalesce(pg_get_expr(p.polqual, p.polrelid), '') NOT LIKE '%sp_tenant_site() IS NOT NULL%'
          OR coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '') NOT LIKE '%sp_platform()%'
          OR coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '') NOT LIKE '%sp_tenant_site() IS NOT NULL%'
      );
    IF stale IS NOT NULL THEN
        RAISE EXCEPTION 'V56: tenant_isolation policies not re-created with the fail-closed form: %', stale;
    END IF;
END $$;

-- No policy uses the V54 name any more; dropping it also proves nothing references it.
DROP FUNCTION IF EXISTS sp_is_platform();
