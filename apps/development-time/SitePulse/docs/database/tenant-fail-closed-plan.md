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
| site | a `WHERE`/`HAVING`/`ON` predicate binds a site key to a parameter, a literal or `sp_tenant_site()`, or an `INSERT` writes the site the caller serves | `SELECT id FROM persons WHERE site_id = $1 AND lower(email) = lower($2)` |
| person | the statement keys on a person or user id the caller resolved inside the site it serves | `UPDATE persons SET phone = $1 WHERE id = $2` in `update_home_owner`, where the id comes from the unit row selected with `site_id = $2` |
| identity | a global identity lookup (email, `google_sub`, session user id) where no site applies yet: sign-in, session validation, uniqueness checks, account activation | `SELECT id FROM users WHERE LOWER(email) = $1 AND is_active` |
| platform | start-up load and sync, migration, SaaS administration, provisioning, development seed and reset | `save_unit` in `src/db/unit_repository.rs`, called only by the startup sync |

Naming a site key is not filtering by one: a `site_id` in the `SELECT` list, a
`SET` clause, an `INSERT` column list or a conflict target does not scope a
statement. Only a predicate that also binds a value does (and `ON a.site_id =
b.site_id` binds nothing). SQL assembled from several literals (`format!`,
`concat!`) is judged literal by literal, so a shared filter such as
`person_directory_service`'s is annotated where it is appended.

Audit result (2026-11-27, `master`): **120 identity query sites, 0 unscoped**.
52 statements bind a site predicate in the SQL itself; the other 68 carry 68
annotations (19 `identity`, 11 `site`, 20 `platform`, 18 `person`), each directly
above the statement it justifies. The cases that look most like a missing filter
were checked in detail:

- `update_home_owner` (`src/services/site_admin_service.rs`) updates a person by
  id, but the id is read from the unit row selected with `site_id = $2`, so a
  manager cannot rename another site's person.
- `save_unit` (`src/db/unit_repository.rs`) resolves person ids without a site
  filter, but its only caller is the startup sync, which runs in a
  platform-bound transaction.
- `security.rs` returns `site_id` from a session lookup and `assign_platform_role`
  writes `site_id = NULL`; both are identity/platform statements, not site
  filters, and are annotated as such.

`scripts/person_scope_lint.py` (gate `person-scope-lint`) keeps the result true:
it fails any statement that names one of the three tables, looks like SQL, has no
site-binding predicate and has no `// person-scope: ...` annotation within four
lines above it, so one annotation cannot bless a second statement added later in
the same function. Its self-tests are `harness/tests/test_person_scope_lint.py`.
