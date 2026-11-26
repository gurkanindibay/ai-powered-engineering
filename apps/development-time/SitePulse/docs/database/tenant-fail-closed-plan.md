# Tenant RLS: from permissive-when-unbound to fail closed (issue #524)

## Where we are

`sp_tenant_site()` is `NULL` when no tenant is bound, and every `tenant_isolation`
policy (V25, V53) is `sp_tenant_site() IS NULL OR (<predicate>)`. A code path that forgets
`tx_bind_tenant` therefore reads every tenant. The migration cannot be flipped yet, because
most of the backend still reads through unbound pooled clients.

## What this change delivers

`scripts/tenant_isolation_lint.py` (gate `tenant-lint`) now also checks `src/db/` and
`src/handlers/`:

| Rule | Flags |
|---|---|
| `unbound-tenant-transaction` | `.transaction()` / `.build_transaction()` without `tx_bind_tenant` (was `src/services/` only). |
| `unbound-pool-query` | A query on a tenant table (any table with a tenant policy or key, minus `RLS_EXEMPT`) issued on a pooled client. |

Opt-outs, both visible in review:

- `// tenant-guard: platform` within six lines before the call (or 30 lines after a transaction open).
- `// tenant-guard: platform-file: <reason>` anywhere in a file that only runs in a platform context. Used by `src/db/sync.rs` (start-up and reload load of the read model).

The 103 findings that existed when the rules were widened are recorded per file in
`scripts/tenant_guard_baseline.json`. The baseline is a ratchet: a new finding fails the lint,
and so does an entry that is higher than the number of remaining findings (lower it).
Retiring an entry means moving that repository function onto `begin_tenant_read` /
`tx_bind_tenant`, or marking it as a platform path with a reason.

## Platform paths (inventory, step one of the fail-closed design)

| Path | Why it is cross-tenant |
|---|---|
| `db::sync::load_all_from_db` / `AppState::reload_from_db` | Builds the in-memory read model of every site. Also used after the system reset handlers. |
| `scheduler` jobs (dues accrual, debt aging, collections) | Sweep all sites; `with_scheduler_lock`. |
| `db::base::reset_db_to_seed_data`, `recreate_db_schema_and_seed` | Development and test reset. |
| `fetch_all_saas_site_summaries`, `fetch_saas_global_stats`, `create_site_with_manager_and_blocks`, `delete_site` | SaaS administration across sites (`/api/v1/saas/*`). |
| `fetch_payment_entries_from_db(pool, None)`, `fetch_units_summary_from_db` | "All sites" reads. |
| `persist_provisioned_site` and the `save_*` functions it calls | Site provisioning writes a new tenant before it has a binding. |

## Fail-closed design (not switched on yet)

1. Add `sp_platform()` = `current_setting('app.platform', true) = 'on'` and a
   `tx_bind_platform(&tx)` helper that sets it with `set_config(.., true)` (transaction local,
   like the tenant id, so pooled connections never leak it).
2. New migration redefines `sp_enable_tenant_rls` so the policy is
   `sp_platform() OR (sp_tenant_site() IS NOT NULL AND (<predicate>))`, and re-applies it to every
   table. An unbound session then sees no rows and its writes fail `WITH CHECK`.
3. Move each platform path above onto `tx_bind_platform`, and each baseline entry onto a tenant
   binding. Because the unbound path stays permissive until step 2, steps 1 and 3 can land
   table by table and keep the baseline shrinking; step 2 is the last PR and needs the baseline empty.
4. Add an integration test beside `rls_hides_other_tenants_inside_a_bound_transaction` that an
   unbound, non-bypass session returns no rows and fails writes.

Risk to check before step 2: any code that runs as a role that bypasses RLS (superuser in tests)
hides unbound reads. Run the DB lane with the `sitepulse_tenant`-style non-bypass runtime role
(`docs/database/runtime-role-setup.md`).

## Identity tables (`users`, `user_site_roles`, `persons`)

These stay RLS-exempt by design (login resolves them before a tenant is known, and a person can
belong to several sites). About 130 query sites touch them (most in `site_admin_service.rs`,
`user_repository.rs`, `site_repository.rs`, `unit_repository.rs`, `authorization.rs`). Confirming
each one filters by site or person scope has **not** been done in this change; it is the open
third checkbox of the issue.
