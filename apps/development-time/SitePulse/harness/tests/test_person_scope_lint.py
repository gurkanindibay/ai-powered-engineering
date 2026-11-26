"""Self-tests for scripts/person_scope_lint.py (issue #535)."""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
BACKEND = Path(__file__).resolve().parents[2] / "backend"


def _load(name: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


person_scope = _load("person_scope_lint")


def _run(files: dict[str, str]) -> list[str]:
    with tempfile.TemporaryDirectory() as tmp:
        backend = Path(tmp) / "backend"
        for rel, source in files.items():
            path = backend / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source, encoding="utf-8")
        return sorted(f["file"] for f in person_scope.audit(backend)["findings"])


def _one(sql: str, *, before: str = "") -> list[str]:
    """Runs the rule over one statement inside a function."""
    return _run({
        "src/db/person_repository.rs": (
            "pub async fn card(tx: &Tx, id: i64, site: i64) -> Result<()> {\n"
            + (f"    {before}\n" if before else "")
            + f'    tx.query_one("{sql}", &[&id, &site]).await?;\n'
            "}\n"
        ),
    })


class PersonScopeLintTests(unittest.TestCase):
    def test_an_identity_query_without_scope_is_flagged(self):
        self.assertEqual(
            _one("SELECT full_name FROM persons WHERE id = $1"),
            ["src/db/person_repository.rs"],
        )

    def test_a_site_key_in_a_select_list_does_not_scope_the_statement(self):
        # The reviewer's leak: the site id is returned, not filtered by.
        self.assertEqual(
            _one("SELECT p.id, p.full_name, p.site_id FROM persons p WHERE p.full_name ILIKE $1"),
            ["src/db/person_repository.rs"],
        )

    def test_a_site_key_in_a_set_clause_does_not_scope_the_statement(self):
        self.assertEqual(
            _one("UPDATE persons SET site_id = $1 WHERE id = $2"),
            ["src/db/person_repository.rs"],
        )

    def test_a_site_key_in_a_where_predicate_scopes_the_statement(self):
        self.assertEqual(
            _one("SELECT p.id, p.site_id FROM persons p WHERE p.full_name ILIKE $1 AND p.site_id = $2"),
            [],
        )

    def test_a_join_condition_that_binds_the_site_scopes_the_statement(self):
        self.assertEqual(
            _one(
                "SELECT p.id FROM persons p JOIN units u ON u.id = p.id AND u.site_id = $1"
            ),
            [],
        )

    def test_a_join_equality_without_a_bound_value_does_not_scope(self):
        self.assertEqual(
            _one("SELECT p.id FROM persons p JOIN units u ON u.site_id = p.site_id"),
            ["src/db/person_repository.rs"],
        )

    def test_each_scope_annotation_is_accepted(self):
        for kind in ("site", "person", "identity", "platform"):
            with self.subTest(kind=kind):
                self.assertEqual(
                    _one(
                        "SELECT full_name FROM persons WHERE id = $1",
                        before=f"// person-scope: {kind} — the caller resolved the id",
                    ),
                    [],
                )

    def test_a_marker_after_the_statement_does_not_cover_it(self):
        findings = _run({
            "src/db/person_repository.rs": (
                "pub async fn card(tx: &Tx, id: i64) -> Result<()> {\n"
                '    tx.query_one("SELECT full_name FROM persons WHERE id = $1", &[&id]).await?;\n'
                "    // person-scope: person — too late\n"
                "}\n"
            ),
        })
        self.assertEqual(findings, ["src/db/person_repository.rs"])

    def test_a_marker_covers_only_the_next_statement(self):
        findings = _run({
            "src/db/person_repository.rs": (
                "pub async fn cards(tx: &Tx, id: i64) -> Result<()> {\n"
                "    // person-scope: person — the caller resolved the id\n"
                '    tx.query_one("SELECT full_name FROM persons WHERE id = $1", &[&id]).await?;\n'
                "\n"
                "\n"
                "\n"
                "\n"
                "\n"
                '    tx.query_one("SELECT full_name FROM persons WHERE id = $1", &[&id]).await?;\n'
                "}\n"
            ),
        })
        self.assertEqual(findings, ["src/db/person_repository.rs"])

    def test_route_strings_and_messages_are_not_queries(self):
        findings = _run({
            "src/app.rs": 'const ROUTE: &str = "/api/v1/site-admin/persons";\n',
            "src/db/sync.rs": 'fn log() { tracing::info!("Loaded {} persons", 3); }\n',
        })
        self.assertEqual(findings, [])

    def test_a_quoted_value_naming_a_table_is_not_a_query(self):
        findings = _run({
            "src/db/audit_repository.rs": (
                "pub async fn record(tx: &Tx) -> Result<()> {\n"
                '    tx.execute("INSERT INTO audit_events(resource_type) VALUES (\'persons\')", &[]).await?;\n'
                "}\n"
            ),
        })
        self.assertEqual(findings, [])

    def test_a_mid_file_test_module_does_not_hide_production_code(self):
        findings = _run({
            "src/db/person_repository.rs": (
                "#[cfg(test)]\n"
                "mod tests {\n"
                '    fn fixture() -> &\'static str { "SELECT * FROM persons WHERE id = 1" }\n'
                "}\n"
                "\n"
                "pub async fn leak(tx: &Tx, id: i64) -> Result<()> {\n"
                '    tx.query_one("SELECT full_name FROM persons WHERE id = $1", &[&id]).await?;\n'
                "}\n"
            ),
        })
        self.assertEqual(findings, ["src/db/person_repository.rs"])

    def test_the_committed_workspace_passes(self):
        report = person_scope.audit(BACKEND)
        self.assertTrue(
            report["passed"],
            "\n".join(
                f"{f['file']}:{f['line']}: {f['message']}" for f in report["findings"]
            ),
        )
        self.assertGreater(
            report["counts"]["identity_query_sites"], 100,
            "the rule must keep finding the identity query sites it audits",
        )


if __name__ == "__main__":
    unittest.main()
