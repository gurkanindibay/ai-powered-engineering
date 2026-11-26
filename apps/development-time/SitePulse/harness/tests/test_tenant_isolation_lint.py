"""Self-tests for scripts/tenant_isolation_lint.py and scripts/lock_scope_lint.py."""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"


def _load(name: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


tenant_lint = _load("tenant_isolation_lint")
lock_lint = _load("lock_scope_lint")

MODELS = "pub struct SiteQ {\n    pub site_id: Option<String>,\n}\npub struct Plain {\n    pub name: String,\n}\n"


def _run(module, files: dict[str, str], **kwargs) -> list[str]:
    with tempfile.TemporaryDirectory() as tmp:
        backend = Path(tmp) / "backend"
        for rel, source in files.items():
            path = backend / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source, encoding="utf-8")
        return sorted(f["rule"] for f in module.lint(backend, **kwargs)["findings"])


class TenantIsolationLintTests(unittest.TestCase):
    def test_site_input_without_scope_is_flagged(self):
        rules = _run(tenant_lint, {
            "src/models/mod.rs": MODELS,
            "src/handlers/mod.rs": "pub async fn leak(State(s): State<AppState>, Query(q): Query<SiteQ>) -> X {\n}\n",
        })
        self.assertEqual(rules, ["unscoped-site-input"])

    def test_scoped_and_site_free_handlers_pass(self):
        rules = _run(tenant_lint, {
            "src/models/mod.rs": MODELS,
            "src/handlers/mod.rs": (
                "pub async fn ok(State(s): State<AppState>, scope: crate::tenancy::TenantScope, Query(q): Query<SiteQ>) -> X {\n}\n"
                "pub async fn plain(State(s): State<AppState>, Json(p): Json<Plain>) -> X {\n}\n"
            ),
        })
        self.assertEqual(rules, [])

    def test_authz_context_handler_needs_a_site_check(self):
        unscoped = (
            "pub async fn leak(ctx: AuthzContext, State(s): State<AppState>, Query(q): Query<SiteQ>) -> X {\n"
            "    s.list(q.site_id).await\n}\n"
        )
        rules = _run(tenant_lint, {"src/models/mod.rs": MODELS, "src/handlers/mod.rs": unscoped})
        self.assertEqual(rules, ["unscoped-site-input"])

    def test_authz_context_handler_that_checks_the_site_passes(self):
        checked = (
            "pub async fn by_require(ctx: AuthzContext, Query(q): Query<SiteQ>) -> X {\n"
            "    ctx.require(Permission::UnitRead, &site)?;\n}\n"
            "pub async fn by_claims(ctx: AuthzContext, Query(q): Query<SiteQ>) -> X {\n"
            "    svc.list(&ctx.claims.site_id).await\n}\n"
            "pub async fn by_context(ctx: AuthzContext, Query(q): Query<SiteQ>) -> X {\n"
            "    svc.list(&ctx, q).await\n}\n"
        )
        rules = _run(tenant_lint, {"src/models/mod.rs": MODELS, "src/handlers/mod.rs": checked})
        self.assertEqual(rules, [])

    def test_object_path_needs_a_scope_unless_the_middleware_owns_it(self):
        rules = _run(tenant_lint, {
            "src/models/mod.rs": MODELS,
            "src/handlers/mod.rs": (
                "pub async fn get_project(State(s): State<AppState>, Path(id): Path<String>) -> X {\n}\n"
                "pub async fn unit_view(State(s): State<AppState>, Path(id): Path<String>) -> X {\n}\n"
            ),
            "src/app.rs": (
                'Router::new()\n    .route(\n        "/api/v1/projects/:id",\n        get(handlers::get_project),\n    )\n'
                '    // a comment between routes\n'
                '    .route("/api/v1/residents/:unit_id/view", get(handlers::unit_view))\n'
            ),
        })
        self.assertEqual(rules, ["unscoped-object-path"])

    def test_route_table_style_is_parsed(self):
        rules = _run(tenant_lint, {
            "src/models/mod.rs": MODELS,
            "src/handlers/mod.rs": "pub async fn get_project(State(s): State<AppState>, Path(id): Path<String>) -> X {\n}\n",
            "src/app.rs": 'routes! {\n    get "/api/v1/projects/:id" => handlers::get_project, Require(UnitRead);\n}\n',
        })
        self.assertEqual(rules, ["unscoped-object-path"])

    def test_an_unparseable_router_fails_loudly(self):
        rules = _run(tenant_lint, {
            "src/models/mod.rs": MODELS,
            "src/handlers/mod.rs": "pub async fn x() -> X {\n}\n",
            "src/app.rs": "fn build_router() {}\n",
        })
        self.assertEqual(rules, ["unscoped-object-path"])

    def test_guessed_tenant_fallbacks_are_flagged_outside_fixtures_and_tests(self):
        rules = _run(tenant_lint, {
            "src/services/x.rs": 'fn f(s: Option<String>) -> String { s.unwrap_or_else(|| "1".to_string()) }\n'
                                 '#[cfg(test)]\nmod tests { fn g() { let _ = Some(1).map(|_| "x").unwrap_or("site-1"); } }\n',
            "src/state.rs": 'fn seed() { let _ = None::<String>.unwrap_or_else(|| "site-1".to_string()); }\n',
        })
        self.assertEqual(rules, ["guessed-tenant"])

    def test_service_transactions_must_bind_their_tenant(self):
        rules = _run(tenant_lint, {
            "src/services/a.rs": "async fn a() { let tx = client.transaction().await?; tx.execute(q).await?; }\n",
            "src/services/b.rs": "async fn b() {\n let tx = client.transaction().await?;\n crate::db::tx_bind_tenant(&tx, site).await?;\n}\n",
            "src/services/c.rs": "async fn c() {\n // tenant-guard: platform\n let tx = client.transaction().await?;\n}\n",
        })
        self.assertEqual(rules, ["unbound-tenant-transaction"])

    def test_tenant_keyed_tables_need_a_policy(self):
        rules = _run(tenant_lint, {
            "migrations/V1__init.sql": (
                "CREATE TABLE units (\n    id BIGINT,\n    site_id BIGINT\n);\n"
                "CREATE TABLE notes (\n    id BIGINT,\n    unit_id BIGINT\n);\n"
                "CREATE TABLE users (\n    id BIGINT,\n    site_id BIGINT\n);\n"
            ),
            "migrations/V2__rls.sql": "SELECT sp_enable_tenant_rls(t, 'x') FROM unnest(ARRAY['units']) AS t;\n",
        })
        self.assertEqual(rules, ["rls-coverage"])  # notes; users is exempt

    def test_parent_scoped_child_tables_need_a_policy(self):
        rules = _run(tenant_lint, {
            "migrations/V1__init.sql": (
                "CREATE TABLE assembly_meetings (\n    id BIGINT,\n    site_id BIGINT\n);\n"
                "CREATE TABLE assembly_agenda_items (\n    id BIGINT,\n    meeting_id BIGINT\n);\n"
            ),
            "migrations/V2__rls.sql": "SELECT sp_enable_tenant_rls('assembly_meetings', 'x');\n",
        })
        self.assertEqual(rules, ["rls-coverage"])

    def test_parent_scoped_child_tables_pass_with_their_policy(self):
        rules = _run(tenant_lint, {
            "migrations/V1__init.sql": (
                "CREATE TABLE assembly_meetings (\n    id BIGINT,\n    site_id BIGINT\n);\n"
                "CREATE TABLE assembly_agenda_items (\n    id BIGINT,\n    meeting_id BIGINT\n);\n"
                "CREATE TABLE payment_plans (\n    id BIGINT,\n    site_id BIGINT\n);\n"
                "CREATE TABLE payment_plan_installments (\n    id BIGINT,\n    plan_id BIGINT\n);\n"
            ),
            "migrations/V2__rls.sql": (
                "SELECT sp_enable_tenant_rls('assembly_meetings', 'site_id = sp_tenant_site()');\n"
                "SELECT sp_enable_tenant_rls('assembly_agenda_items', "
                "'meeting_id IN (SELECT m.id FROM assembly_meetings m WHERE m.site_id = sp_tenant_site())');\n"
                "SELECT sp_enable_tenant_rls('payment_plans', 'site_id = sp_tenant_site()');\n"
                "SELECT sp_enable_tenant_rls('payment_plan_installments', "
                "'plan_id IN (SELECT p.id FROM payment_plans p WHERE p.site_id = sp_tenant_site())');\n"
            ),
        })
        self.assertEqual(rules, [])

    def test_a_parent_scoped_policy_must_name_its_parent(self):
        rules = _run(tenant_lint, {
            "migrations/V1__init.sql": (
                "CREATE TABLE manual_journal_entries (\n    id BIGINT,\n    site_id BIGINT\n);\n"
                "CREATE TABLE manual_journal_lines (\n    id BIGINT,\n    entry_id BIGINT\n);\n"
            ),
            "migrations/V2__rls.sql": (
                "SELECT sp_enable_tenant_rls('manual_journal_entries', 'site_id = sp_tenant_site()');\n"
                "SELECT sp_enable_tenant_rls('manual_journal_lines', "
                "'entry_id IN (SELECT e.id FROM payment_plans e WHERE e.site_id = sp_tenant_site())');\n"
            ),
        })
        self.assertEqual(rules, ["rls-parent-predicate"])


POOL_MIGRATION = {
    "migrations/V1__init.sql": "CREATE TABLE units (\n    id BIGINT,\n    site_id BIGINT\n);\n",
    "migrations/V2__rls.sql": "SELECT sp_enable_tenant_rls('units', 'site_id = sp_tenant_site()');\n",
}
POOL_READ = (
    "async fn f(pool: &Pool) {\n let client = pool.get().await?;\n"
    ' client.query("SELECT id FROM units", &[]).await?;\n}\n'
)


class UnboundDbAccessTests(unittest.TestCase):
    def test_pool_query_on_a_tenant_table_is_flagged(self):
        rules = _run(tenant_lint, {**POOL_MIGRATION, "src/db/units.rs": POOL_READ})
        self.assertEqual(rules, ["unbound-pool-query"])

    def test_handlers_are_covered_too(self):
        rules = _run(tenant_lint, {**POOL_MIGRATION, "src/handlers/x.rs": POOL_READ})
        self.assertEqual(rules, ["unbound-pool-query"])

    def test_non_tenant_tables_and_bound_transactions_pass(self):
        rules = _run(tenant_lint, {
            **POOL_MIGRATION,
            "src/db/a.rs": POOL_READ.replace("units", "users"),
            "src/db/b.rs": (
                "async fn f(pool: &Pool) {\n let mut client = pool.get().await?;\n"
                " let tx = begin_tenant_read(&mut client, 1).await?;\n"
                ' tx.query("SELECT id FROM units", &[]).await?;\n}\n'
            ),
        })
        self.assertEqual(rules, [])

    def test_platform_marker_opts_a_call_or_a_file_out(self):
        marked = POOL_READ.replace(" client.query", " // tenant-guard: platform (start-up)\n client.query")
        rules = _run(tenant_lint, {
            **POOL_MIGRATION,
            "src/db/a.rs": marked,
            "src/db/b.rs": "// tenant-guard: platform-file: start-up load\n" + POOL_READ,
        })
        self.assertEqual(rules, [])

    def test_unbound_transaction_in_a_repository_is_flagged(self):
        rules = _run(tenant_lint, {
            "src/db/a.rs": "async fn a() { let tx = client.transaction().await?; tx.execute(q).await?; }\n",
            "src/db/tenant_guard.rs": "async fn g() { let tx = client.transaction().await?; }\n",
        })
        self.assertEqual(rules, ["unbound-tenant-transaction"])

    def test_baseline_accepts_existing_debt_but_not_growth_or_stale_entries(self):
        files = {**POOL_MIGRATION, "src/db/units.rs": POOL_READ}
        accepted = {"unbound-pool-query": {"src/db/units.rs": 1}}
        self.assertEqual(_run(tenant_lint, files, baseline=accepted), [])
        self.assertEqual(
            _run(tenant_lint, files, baseline={"unbound-pool-query": {"src/db/units.rs": 0}}),
            ["unbound-pool-query"],
        )
        stale = _run(tenant_lint, files, baseline={"unbound-pool-query": {"src/db/units.rs": 2}})
        self.assertEqual(stale, ["stale-tenant-guard-baseline"])


class LockScopeLintTests(unittest.TestCase):
    def test_write_guard_held_across_database_io(self):
        rules = _run(lock_lint, {"src/handlers/mod.rs": (
            "async fn h() {\n"
            "    let mut inner = state.inner.write().await;\n"
            "    inner.x = 1;\n"
            "    crate::db::save(pool, &inner).await;\n"
            "}\n"
        )})
        self.assertEqual(rules, ["write-guard-across-io"])

    def test_await_on_its_own_line_is_still_found(self):
        rules = _run(lock_lint, {"src/main.rs": (
            "async fn main() {\n"
            "    let mut inner = state.inner.write().await;\n"
            "    db::load_all_from_db(p, &mut inner)\n"
            "        .await\n"
            "        .expect(\"load\");\n"
            "}\n"
        )})
        self.assertEqual(rules, ["write-guard-across-io"])

    def test_dropped_or_closed_guards_pass(self):
        rules = _run(lock_lint, {"src/handlers/mod.rs": (
            "async fn h() {\n"
            "    let inner = state.inner.read().await;\n"
            "    let copy = inner.x.clone();\n"
            "    drop(inner);\n"
            "    crate::db::save(pool, &copy).await;\n"
            "    {\n"
            "        let mut inner = state.inner.write().await;\n"
            "        inner.x = 2;\n"
            "    }\n"
            "    crate::db::save(pool, &copy).await;\n"
            "}\n"
        )})
        self.assertEqual(rules, [])

    def test_allow_marker_opts_out(self):
        rules = _run(lock_lint, {"src/x.rs": (
            "async fn h() {\n"
            "    let inner = state.inner.read().await; // lock-scope: allow start-up only\n"
            "    pool.get().await;\n"
            "}\n"
        )})
        self.assertEqual(rules, [])


if __name__ == "__main__":
    unittest.main()
