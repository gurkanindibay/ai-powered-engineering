# PostgreSQL runtime role setup

SitePulse production requires separate migration and runtime database identities.
Run schema migrations with a role that can create and alter schema objects. Configure
`DB_USER` and `DB_PASS` for the service with a dedicated runtime role that is not a
superuser, does not have `BYPASSRLS`, `CREATEROLE`, or `CREATEDB`, and does not own
public tables. Keep credentials in the deployment secret store.

Migration V25 creates the non-login `sitepulse_tenant` role when permitted, grants it
the table and sequence privileges used by tenant-bound operations, and grants it to
the migration identity. The runtime identity also needs membership in
`sitepulse_tenant` so tenant-bound transactions can use `SET LOCAL ROLE`; grant that
membership during database provisioning if migrations ran under a different identity.
Do not grant `BYPASSRLS` to either the runtime identity or `sitepulse_tenant`.

Before serving, the backend verifies that every public table with a tenant key has
the forced `tenant_isolation` policy and that the runtime identity is safe. Expected
tenant keys, root tables and exemptions are shared by the runtime guard and
`scripts/tenant_isolation_lint.py` in `scripts/tenant_rls_config.json`. Production
startup stops when either check fails. `/health` and `/api/v1/health` are lightweight
liveness routes. `/ready` and `/api/v1/ready` check the database and return HTTP 503
with a coarse `tenant_rls.status` when checks fail. The service logs detailed role
flags at startup for operators.
`SITEPULSE_MIGRATIONS_ONLY=true` is for the privileged migration job and exits
without starting the service.

After migrations, provision or verify the runtime membership with an administrator:

```sql
GRANT sitepulse_tenant TO sitepulse_runtime;
```

Use the actual runtime role name selected by deployment configuration. If V25 could
not create `sitepulse_tenant`, rerun provisioning with the migration role authorized
to create it, then apply the migration before starting the service.

## CI runs the database gates as the runtime role

The point of the two identities is that an unbound query fails closed. CI proves it:
the `rust` job of `sitepulse-ci.yml` provisions `sitepulse_runtime`
(`LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB`) and runs
`rust-db-test`, `schema-integrity` and `api-system` with:

| Variable | Identity | Used for |
|:---|:---|:---|
| `DB_USER` / `DB_PASS` | `sitepulse_runtime` | the application under test: every request, service and repository call |
| `DB_ADMIN_USER` / `DB_ADMIN_PASS` | `sitepulse_user` (owner) | creating the throwaway databases, applying migrations, fixture SQL and assertions |

The fixtures in `backend/tests/it/test_db.rs` expose that split as
`TestDatabase::owner` (assertions and fixture SQL) and `TestDatabase::pool` (the
application). `scripts/api_system_check.py` and `scripts/schema_integrity_check.py`
read `DB_ADMIN_*` when it is set and fall back to `DB_USER`/`DB_PASS` otherwise, so a
single identity still works locally.

A test that needs to inspect rows therefore reads them through `owner`, and a test that
proves isolation uses `pool`. Adding a query that forgets to bind now fails CI instead
of returning every tenant's rows in production.
