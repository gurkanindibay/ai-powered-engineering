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


class PersonScopeLintTests(unittest.TestCase):
    def test_an_identity_query_without_scope_is_flagged(self):
        findings = _run({
            "src/db/person_repository.rs": (
                "pub async fn card(tx: &Tx, id: i64) -> Result<()> {\n"
                '    tx.query_one("SELECT full_name FROM persons WHERE id = $1", &[&id]).await?;\n'
                "}\n"
            ),
        })
        self.assertEqual(findings, ["src/db/person_repository.rs"])

    def test_a_site_key_in_the_statement_scopes_it(self):
        findings = _run({
            "src/db/person_repository.rs": (
                "pub async fn card(tx: &Tx, site: i64, id: i64) -> Result<()> {\n"
                '    tx.query_one("SELECT full_name FROM persons WHERE id = $1 AND site_id = $2", &[&id, &site]).await?;\n'
                "}\n"
            ),
        })
        self.assertEqual(findings, [])

    def test_each_scope_annotation_is_accepted(self):
        for kind in ("site", "person", "identity", "platform"):
            with self.subTest(kind=kind):
                findings = _run({
                    "src/db/person_repository.rs": (
                        "pub async fn card(tx: &Tx, id: i64) -> Result<()> {\n"
                        f"    // person-scope: {kind} — the caller resolved the id\n"
                        '    tx.query_one("SELECT full_name FROM persons WHERE id = $1", &[&id]).await?;\n'
                        "}\n"
                    ),
                })
                self.assertEqual(findings, [])

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

    def test_route_strings_and_messages_are_not_queries(self):
        findings = _run({
            "src/app.rs": 'const ROUTE: &str = "/api/v1/site-admin/persons";\n',
            "src/db/sync.rs": 'fn log() { tracing::info!("Loaded {} persons", 3); }\n',
        })
        self.assertEqual(findings, [])

    def test_a_test_module_is_not_audited(self):
        findings = _run({
            "src/db/person_repository.rs": (
                "pub async fn card(tx: &Tx, id: i64) -> Result<()> {\n"
                '    tx.query_one("SELECT full_name FROM persons WHERE id = $1 AND site_id = $2", &[&id, &id]).await?;\n'
                "}\n"
                "#[cfg(test)]\n"
                "mod tests {\n"
                '    fn fixture() -> &\'static str { "SELECT * FROM persons WHERE id = 1" }\n'
                "}\n"
            ),
        })
        self.assertEqual(findings, [])

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
