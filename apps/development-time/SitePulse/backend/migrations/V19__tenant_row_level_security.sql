-- V19: Row-level tenant isolation (defense in depth for multi-tenancy).
--
-- Application code already filters by site; this migration makes PostgreSQL
-- enforce it too, so a query that forgets its `site_id` predicate cannot read
-- or change another tenant's rows.
--
-- How it works
--   * A tenant-bound transaction (db::tenant_guard::tx_bind_tenant) sets
--     `app.tenant_site_id` with set_config(.., is_local => true) and switches to
--     the role `sitepulse_tenant` with SET LOCAL ROLE. Both end with the
--     transaction, so pooled connections never leak a tenant.
--   * `sitepulse_tenant` has no BYPASSRLS, so the policies below apply even when
--     the service itself connects as a superuser or as the table owner.
--   * FORCE ROW LEVEL SECURITY makes the policies apply to the table owner too.
--   * When no tenant is bound (start-up load, platform scheduler, SaaS admin),
--     sp_tenant_site() is NULL and every policy is permissive, so existing
--     platform-level code paths keep working unchanged.
--
-- Referential-integrity checks bypass row security by design, so foreign keys
-- keep working across the policy boundary.

CREATE OR REPLACE FUNCTION sp_tenant_site() RETURNS BIGINT
LANGUAGE sql STABLE AS
$$ SELECT NULLIF(current_setting('app.tenant_site_id', true), '')::BIGINT $$;

-- ---------------------------------------------------------------------------
-- The non-bypass role used inside tenant-bound transactions.
-- Creating a role needs CREATEROLE; without it the migration still succeeds
-- (with a NOTICE) and isolation relies on FORCE ROW LEVEL SECURITY alone.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sitepulse_tenant') THEN
        BEGIN
            CREATE ROLE sitepulse_tenant NOLOGIN NOBYPASSRLS NOINHERIT;
        EXCEPTION WHEN insufficient_privilege THEN
            RAISE NOTICE 'V19: cannot create role sitepulse_tenant (no CREATEROLE); RLS relies on FORCE ROW LEVEL SECURITY';
        END;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sitepulse_tenant') THEN
        BEGIN
            EXECUTE format('GRANT sitepulse_tenant TO %I', current_user);
        EXCEPTION WHEN insufficient_privilege OR invalid_grant_operation THEN
            RAISE NOTICE 'V19: cannot grant sitepulse_tenant to %', current_user;
        END;
        GRANT USAGE ON SCHEMA public TO sitepulse_tenant;
        GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO sitepulse_tenant;
        GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO sitepulse_tenant;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public
            GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO sitepulse_tenant;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public
            GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO sitepulse_tenant;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Policy helper: one permissive `tenant_isolation` policy per table.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sp_enable_tenant_rls(p_table TEXT, p_predicate TEXT) RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    IF to_regclass(p_table) IS NULL THEN
        RAISE NOTICE 'V19: table % does not exist, skipped', p_table;
        RETURN;
    END IF;
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', p_table);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', p_table);
    EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %I', p_table);
    EXECUTE format(
        'CREATE POLICY tenant_isolation ON %I USING (sp_tenant_site() IS NULL OR (%s)) '
        'WITH CHECK (sp_tenant_site() IS NULL OR (%s))',
        p_table, p_predicate, p_predicate);
END $$;

-- The tenant itself.
SELECT sp_enable_tenant_rls('sites', 'id = sp_tenant_site()');

-- Tables that carry the tenant key directly.
SELECT sp_enable_tenant_rls(t, 'site_id = sp_tenant_site()')
FROM unnest(ARRAY[
    'units', 'blocks', 'house_types', 'dues_periods',
    'payment_entries', 'payment_receipts', 'payment_idempotency_keys', 'payment_intents',
    'receipt_counters', 'processed_bank_webhooks', 'reconciliation_queue',
    'debt_aging_snapshots', 'site_bank_accounts', 'unit_sender_ibans',
    'invitation_tokens', 'pending_registrations', 'capital_projects', 'operating_budgets'
]) AS t;

-- Tables owned through a unit.
SELECT sp_enable_tenant_rls(t, 'unit_id IN (SELECT u.id FROM units u WHERE u.site_id = sp_tenant_site())')
FROM unnest(ARRAY[
    'dues_liabilities', 'advance_balances', 'advance_ledger_entries',
    'unit_occupancies', 'unit_ownerships', 'unit_payer_names',
    'operating_budget_unit_shares', 'budget_objections', 'budget_service_records'
]) AS t;

-- Tables owned through a payment entry, a capital project or a budget.
SELECT sp_enable_tenant_rls('payment_allocations',
    'payment_entry_id IN (SELECT e.id FROM payment_entries e WHERE e.site_id = sp_tenant_site())');
SELECT sp_enable_tenant_rls(t,
    'project_id IN (SELECT p.id FROM capital_projects p WHERE p.site_id = sp_tenant_site())')
FROM unnest(ARRAY['capital_project_installments', 'capital_contractor_disbursements']) AS t;
SELECT sp_enable_tenant_rls('operating_budget_lines',
    'budget_id IN (SELECT b.id FROM operating_budgets b WHERE b.site_id = sp_tenant_site())');
