"""Self-tests for scripts/rust_standards_lint.py: every hard rule fires, and only on code."""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "rust_standards_lint.py"
spec = importlib.util.spec_from_file_location("rust_standards_lint", SCRIPT)
rust_standards_lint = importlib.util.module_from_spec(spec)
sys.modules["rust_standards_lint"] = rust_standards_lint
spec.loader.exec_module(rust_standards_lint)


def _lint(files: dict[str, str], baseline: dict | None = None) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        backend = Path(tmp) / "backend"
        for rel, source in files.items():
            path = backend / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source, encoding="utf-8")
        base = None
        if baseline is not None:
            base = Path(tmp) / "baseline.json"
            base.write_text(json.dumps(baseline), encoding="utf-8")
        return rust_standards_lint.lint(backend, base, check_fmt=False)


def _rules(report: dict) -> list[str]:
    return sorted(f["rule"] for f in report["findings"])


class RustStandardsLintTests(unittest.TestCase):
    def test_flatten_in_query_extracted_struct_is_reported(self):
        report = _lint({
            "src/handlers/a.rs": (
                "#[derive(Deserialize)]\npub struct SearchParams {\n    #[serde(flatten)]\n"
                "    pub search: crate::models::Search,\n    pub site_id: Option<String>,\n}\n"
                "pub async fn h(Query(q): Query<SearchParams>) {}\n"
                "pub async fn j(Query(q): Query<crate::handlers::a::Plain>) {}\n"
            ),
            "src/handlers/b.rs": (
                "pub struct Plain { pub page: Option<i64> }\n"
                "#[derive(Deserialize)]\npub struct BodyOnly {\n    #[serde(flatten)]\n    pub base: Base,\n}\n"
                "pub async fn k(Json(b): Json<BodyOnly>) {}\n"
            ),
        })
        self.assertEqual(_rules(report), ["query-flatten"])
        self.assertEqual(report["findings"][0]["file"], "src/handlers/a.rs")
        self.assertEqual(report["findings"][0]["line"], 3)

    def test_person_inserts_are_confined_to_repository(self):
        report = _lint({
            "src/services/a.rs": 'const SQL: &str = "INSERT INTO persons (full_name) VALUES ($1)";\n',
            "src/db/person_repository.rs": 'const SQL: &str = "INSERT INTO persons (full_name) VALUES ($1)";\n',
        })
        self.assertEqual(_rules(report), ["person-insert-location"])

    def test_domain_must_not_depend_on_infrastructure(self):
        report = _lint({"src/domain/x.rs": "use axum::Json;\nfn f() { let _ = std::env::var(\"A\"); crate::state::AppState::new(); }\n"})
        self.assertEqual(_rules(report), ["domain-purity", "domain-purity", "domain-purity"])

    def test_only_handlers_may_import_handlers(self):
        report = _lint({
            "src/scheduler.rs": "use crate::handlers::ledger_snapshot;\n",
            "src/handlers/mod.rs": "use crate::handlers::other;\n",
            "src/app.rs": "use crate::handlers;\n",
        })
        self.assertEqual(_rules(report), ["layering"])

    def test_inline_email_normalization_is_reported(self):
        report = _lint({"src/services/a.rs": "fn f(r: &R) { let e = r.email.trim().to_lowercase(); let t = r.tenant_email.as_deref().unwrap_or(\"\").trim().to_lowercase(); }\n"})
        self.assertEqual(_rules(report), ["inline-email", "inline-email"])

    def test_inline_turkish_folding_is_reported_outside_domain_text(self):
        source = "fn f(s: &str) -> String { s.to_lowercase().replace('ı', \"i\").replace(['ş', 'Ş'], \"s\") }\n"
        # One finding per folded letter: ı, ş, Ş.
        self.assertEqual(_rules(_lint({"src/services/a.rs": source})), ["inline-turkish-fold"] * 3)
        self.assertEqual(_rules(_lint({"src/domain/text.rs": source})), [])

    def test_inline_iban_check_is_reported(self):
        report = _lint({"src/services/a.rs": "fn f(i: &str) -> bool { i.starts_with(\"TR\") && i.len() == 26 }\n"})
        self.assertEqual(_rules(report), ["inline-iban-check"])

    def test_regex_must_be_a_lazy_static(self):
        ok = 'static RE: LazyLock<Result<Regex, regex::Error>> = LazyLock::new(|| Regex::new(r"\\d+"));\n'
        bad = 'fn f() { let re = Regex::new(r"\\d+").ok(); }\n'
        self.assertEqual(_rules(_lint({"src/a.rs": ok})), [])
        self.assertEqual(_rules(_lint({"src/a.rs": bad})), ["regex-per-call"])

    # covers: SC-05-04-01
    def test_implicit_rounding_and_floats_are_reported(self):
        report = _lint({"src/a.rs": "fn f(d: Decimal) -> Decimal { let x: f64 = 0.1; d.round_dp(2) }\n"})
        self.assertEqual(_rules(report), ["float-money", "implicit-rounding"])

    def test_ad_hoc_hash_outside_fingerprint(self):
        source = "use sha2::Sha256;\n"
        self.assertEqual(_rules(_lint({"src/handlers/mod.rs": source})), ["ad-hoc-hash"])
        self.assertEqual(_rules(_lint({"src/domain/fingerprint.rs": source})), [])

    def test_non_english_identifier_is_reported_but_turkish_text_is_not(self):
        report = _lint({"src/a.rs": "fn f() { let tutarı = 1; let m = \"Tutarı ödendi\"; let c = 'ş'; } // açıklama\n"})
        self.assertEqual(_rules(report), ["non-english-identifier"])

    def test_comments_strings_and_test_modules_are_ignored(self):
        source = (
            "// email.to_lowercase() and Regex::new( in a comment\n"
            "/* nested /* block */ f64 */\n"
            "fn f() -> &'static str { \"starts_with(\\\"TR\\\") .round_dp(2)\" }\n"
            "fn g() -> &'static str { r#\"Regex::new(\"x\")\"# }\n"
            "#[cfg(test)]\nmod tests {\n    fn t() { let x = Some(1).unwrap(); let e = s.email.to_lowercase(); let r = Regex::new(\"a\"); }\n}\n"
        )
        report = _lint({"src/a.rs": source})
        self.assertEqual(_rules(report), [])
        self.assertEqual(report["counts"]["unwrap"], 0)

    def test_ratchet_fails_only_when_count_rises(self):
        source = "fn f() { a.unwrap(); b.unwrap(); }\n"
        self.assertTrue(_lint({"src/a.rs": source}, {"unwrap": 2})["passed"])
        report = _lint({"src/a.rs": source}, {"unwrap": 1})
        self.assertFalse(report["passed"])
        self.assertEqual(report["ratchet_exceeded"], [{"rule": "unwrap", "count": 2, "allowed": 1}])

    def test_string_error_counts_services_only(self):
        source = "pub fn f() -> Result<(), String> { Ok(()) }\n"
        self.assertEqual(_lint({"src/services/a.rs": source})["counts"]["string-error"], 1)
        self.assertEqual(_lint({"src/db/a.rs": source})["counts"]["string-error"], 0)

    def test_real_backend_passes(self):
        report = rust_standards_lint.lint(rust_standards_lint.DEFAULT_BACKEND, rust_standards_lint.DEFAULT_BASELINE, check_fmt=False)
        self.assertEqual(report["findings"], [], json.dumps(report["findings"], indent=2, ensure_ascii=False))
        self.assertEqual(report["ratchet_exceeded"], [])


if __name__ == "__main__":
    unittest.main()
