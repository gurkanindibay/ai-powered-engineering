-- V53: row-level isolation for child tables that reach their tenant through a
-- parent row.
--
-- V25 isolated tables that carry a tenant key directly (`site_id`, `unit_id`,
-- ...) and the children of a payment entry, a capital project or a budget.
-- Several child tables reach their tenant through another parent, so they had
-- no policy: a tenant-bound query that read them directly, without joining the
-- parent, could still return another site's rows. Each policy below resolves
-- the parent inside the caller's site, using the same
-- `sp_enable_tenant_rls(table, predicate)` helper as V25 (permissive when no
-- tenant is bound, WITH CHECK on writes).
--
-- `dues_period_migration_issues` stays deliberately un-isolated: it is the V37
-- migration audit log, written once by the migration and read only at startup
-- (a platform context) before any tenant is known; its `table_name`/`row_id`
-- pair does not identify a site reliably. It is listed in
-- `scripts/tenant_isolation_lint.py` RLS_EXEMPT.

-- Assemblies: an agenda item is reachable only through its meeting.
SELECT sp_enable_tenant_rls('assembly_agenda_items',
    'meeting_id IN (SELECT m.id FROM assembly_meetings m WHERE m.site_id = sp_tenant_site())');

-- Autopay: an attempt is reachable through its mandate (which pins the site)
-- and its due; both must belong to the caller's site, so a tenant cannot attach
-- another site's liability to its own mandate.
SELECT sp_enable_tenant_rls('autopay_attempts',
    'mandate_id IN (SELECT m.id FROM autopay_mandates m WHERE m.site_id = sp_tenant_site())
     AND due_id IN (SELECT d.id FROM dues_liabilities d WHERE d.unit_id IN
     (SELECT u.id FROM units u WHERE u.site_id = sp_tenant_site()))');

-- Collections: an event is reachable only through its case.
SELECT sp_enable_tenant_rls('collection_case_events',
    'case_id IN (SELECT c.id FROM collection_cases c WHERE c.site_id = sp_tenant_site())');

-- Manual journal: a line is reachable only through its entry.
SELECT sp_enable_tenant_rls('manual_journal_lines',
    'entry_id IN (SELECT e.id FROM manual_journal_entries e WHERE e.site_id = sp_tenant_site())');

-- Payment plans: an installment is reachable only through its plan.
SELECT sp_enable_tenant_rls('payment_plan_installments',
    'plan_id IN (SELECT p.id FROM payment_plans p WHERE p.site_id = sp_tenant_site())');

-- Household members link persons to an occupancy; the occupancy reaches the
-- tenant through its unit. This is the most sensitive of the group.
SELECT sp_enable_tenant_rls('occupancy_members',
    'occupancy_id IN (SELECT o.id FROM unit_occupancies o WHERE o.unit_id IN
     (SELECT u.id FROM units u WHERE u.site_id = sp_tenant_site()))');
