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

Before serving, the backend verifies that forced row security is installed on
`payment_entries` and that the runtime identity is safe. Production startup stops
when either check fails. `/health` and `/api/v1/health` return HTTP 503 and expose a
`tenant_rls` readiness object when the checks fail. `SITEPULSE_MIGRATIONS_ONLY=true`
is for the privileged migration job and exits without starting the service.

After migrations, provision or verify the runtime membership with an administrator:

```sql
GRANT sitepulse_tenant TO sitepulse_runtime;
```

Use the actual runtime role name selected by deployment configuration. If V25 could
not create `sitepulse_tenant`, rerun provisioning with the migration role authorized
to create it, then apply the migration before starting the service.
