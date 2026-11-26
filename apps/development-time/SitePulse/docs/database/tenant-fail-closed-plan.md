# Tenant isolation: fail-closed row-level security

Status: implemented (issue #524 / #534). Migrations V25, V53, V54, V56.

SitePulse keeps one site's rows out of another's reach at two independent layers:

1. **Code** — every repository transaction is bound to its tenant, and a static
   gate refuses unbound access (see [Guardrails](#guardrails)).
2. **PostgreSQL** — row-level security (RLS) on every tenant-keyed table, forced
   even for the table owner, so a missed binding returns nothing instead of
   every tenant's data.

## Two switches, one transaction each

Both settings are transaction-local (`set_config(.., true)`), so a pooled
connection never carries a tenant or platform flag into the next checkout.

| Switch | Call | Effect |
|---|---|---|
| Tenant | `db::tenant_guard::tx_bind_tenant(&tx, site_id)` | sets `app.tenant_site_id`, clears `app.platform`, and drops to the `sitepulse_tenant` role (no `BYPASSRLS`) when it exists |
| Platform | `db::tenant_guard::tx_bind_platform(&tx)` | sets `app.platform = 'on'` and clears `app.tenant_site_id` |

Helpers start the transaction and bind it: `begin_tenant_read`, `begin_tenant_tx`,
`begin_platform_read`, `begin_platform_tx`.

## Policy shape (V56)

`sp_platform()` is true only when `app.platform = 'on'`. `sp_tenant_site()` reads
`app.tenant_site_id`. Every tenant table gets the same policy:

```sql
USING      (sp_platform() OR (sp_tenant_site() IS NOT NULL AND (<predicate>)))
WITH CHECK (sp_platform() OR (sp_tenant_site() IS NOT NULL AND (<predicate>)))
```

`<predicate>` is the table's own tenant rule: `site_id = sp_tenant_site()` for
tables with a site key, `id = sp_tenant_site()` for `sites`, and a parent
subselect for child tables (`unit_id IN (SELECT u.id FROM units u WHERE
u.site_id = sp_tenant_site())`, and the equivalents through meetings, payments,
projects, budgets, plans, cases and occupancies).

The explicit `sp_tenant_site() IS NOT NULL` guard makes the policy fail closed
even if a future predicate forgets to reference the tenant, and V56 aborts the
migration if any `tenant_isolation` policy keeps an older form. The startup
probe (`db::rls_guard_installed`) requires the same shape, so a policy added by a
later migration without `sp_enable_tenant_rls` fails readiness instead of running.

The guard covers the **unbound** case only: a session that *is* bound to a tenant
but uses a tenant-blind predicate (say `TRUE`) still sees every site's rows. The
lint's `rls-parent-predicate` rule and the DB isolation tests are the defence
there, so a new policy must always state its own tenant predicate.

## Identity tables: `users`, `user_site_roles`, `persons` (issue #535)

These three tables are RLS-exempt by design (`scripts/tenant_rls_config.json`):
sign-in and session validation read a user before any site is known, and a SaaS
administrator has no site. The exemption moves the responsibility to the code, so
every query against them must state one of four scopes:

| Scope | Meaning | Example |
|---|---|---|
| site | the statement filters by a site key, or by a table that carries one (`units`, `sites`, `v_person_roles`, `unit_occupancies`) | `SELECT id FROM persons WHERE site_id = $1 AND lower(email) = lower($2)` |
| person | the statement keys on a person or user id the caller resolved inside the site it serves | `UPDATE persons SET phone = $1 WHERE id = $2` in `update_home_owner`, where the id comes from the unit row selected with `site_id = $2` |
| identity | a global identity lookup (email, `google_sub`, session user id) where no site applies yet: sign-in, session validation, uniqueness checks, account activation | `SELECT id FROM users WHERE LOWER(email) = $1 AND is_active` |
| platform | start-up load and sync, migration, SaaS administration, provisioning, development seed and reset | `save_unit` in `src/db/unit_repository.rs`, called only by the startup sync |

Audit result (2026-11-27, `master`): **124 identity query sites, 0 unscoped**.
83 statements carry a site key in the SQL itself; the other 41 are covered by 26
annotations (12 `identity`, 7 `person`, 7 `platform`), each stated next to the
statement it justifies. The two sites that look most like a missing filter were
checked in detail:

- `update_home_owner` (`src/services/site_admin_service.rs`) updates a person by
  id, but the id is read from the unit row selected with `site_id = $2`, so a
  manager cannot rename another site's person.
- `save_unit` (`src/db/unit_repository.rs`) resolves person ids without a site
  filter, but its only caller is the startup sync, which runs in a
  platform-bound transaction.

`scripts/person_scope_lint.py` (gate `person-scope-lint`) keeps the result true:
it fails any statement that names one of the three tables, looks like SQL, has no
site key and has no `// person-scope: ...` annotation in its function. Its
self-tests are `harness/tests/test_person_scope_lint.py`.

## Platform paths

Rows that legitimately span sites (start-up load and reload, scheduler jobs, SaaS
administration, provisioning, development seed and reset) opt in explicitly with
`tx_bind_platform` / `begin_platform_tx` / `begin_platform_read`. Everything else
must bind a tenant.

## Guardrails

- `scripts/tenant_isolation_lint.py` (gate `tenant-lint`, also run from the
  harness) parses `backend/src` and fails on unscoped handlers and object paths,
  guessed tenant fallbacks, unbound transactions, unbound pool queries that touch
  tenant tables, a `// tenant-guard: platform` marker without a platform bind, and
  tenant tables without an RLS policy.
- `backend/tests/it/db_tenant_isolation_tests.rs` runs the real router and SQL
  against a throwaway database as the non-superuser runtime role: a bound
  transaction sees one site, an unbound one reads no rows and cannot insert,
  update or delete, and an explicitly platform-bound transaction reads across
  sites. The DB gates run with `DB_USER=sitepulse_runtime`, exactly as production
  serves requests.
- `db::rls_guard_installed` refuses to trust a database whose tenant tables do not
  all carry enabled, forced `tenant_isolation` policies, and the readiness check
  reports a runtime role that is a superuser or bypasses RLS.
