"""Self-tests for scripts/security_lint.py and scripts/dependency_audit.py."""
import datetime as dt
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]


def _load(name: str):
    spec = importlib.util.spec_from_file_location(name, PROJECT_ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


security_lint = _load("security_lint")
dependency_audit = _load("dependency_audit")

APP_RS = """
routes! {
    get "/health" => handlers::health_check, Public;
    get "/api/v1/things" => handlers::things, Require(SiteManage);
}
pub fn dev_routes_enabled() -> bool {
    !state::AppStateInner::is_production()
        && std::env::var("SITEPULSE_ENABLE_DEV_ROUTES").map(|v| v == "true").unwrap_or(false)
}
"""
# Assembled at runtime so this file never contains a secret-shaped literal.
FAKE_SECRET = "Zx9" + "Qw7Lm2Rt5Vb8Nc4Hd6Jf1Kg3Ps0"
KEY_HEADER = "-----BEGIN " + "RSA PRIVATE KEY-----"


def _lint(files: dict[str, str], baseline: dict | None = None) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp)
        for rel, source in files.items():
            path = repo / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source, encoding="utf-8")
        base = {"accepted": [], "internal_error_leaks": {}, "public_routes": ["GET /health"]}
        base.update(baseline or {})
        return security_lint.lint(repo, repo / "backend", repo / "flutter", base)


def _rules(report: dict) -> list[str]:
    return sorted(f["rule"] for f in report["findings"])


class SecretRules(unittest.TestCase):
    def test_env_backup_is_a_tracked_secret_file(self):
        report = _lint({"backend/.env.bak-1": f"KT_CLIENT_SECRET={FAKE_SECRET}\n"})
        self.assertEqual(_rules(report), ["hardcoded-secret", "tracked-secret-file"])
        self.assertNotIn(FAKE_SECRET, str(report), "the secret value must never be reported")

    def test_env_example_with_empty_values_passes(self):
        report = _lint({"backend/.env.example": "SITEPULSE_JWT_SECRET=\nDB_PASS=\n"})
        self.assertEqual(report["status"], "PASS")

    def test_private_key_block_and_key_file(self):
        report = _lint({"docs/notes.md": f"{KEY_HEADER}\n", "keys/server.pem": "x\n"})
        self.assertEqual(_rules(report), ["hardcoded-secret", "tracked-secret-file"])

    def test_descriptive_ci_placeholder_is_not_a_secret(self):
        report = _lint({"ci.yml": "  POSTGRES_PASSWORD: ci-only-password-for-tests\n"})
        self.assertEqual(report["status"], "PASS")


class WorkflowAndImageRules(unittest.TestCase):
    def test_workflow_needs_permissions(self):
        report = _lint({".github/workflows/ci.yml": "on: push\njobs: {}\n"})
        self.assertEqual(_rules(report), ["workflow-permissions"])

    def test_untrusted_context_in_script_and_target_trigger(self):
        workflow = (
            "on:\n  pull_request_target:\npermissions:\n  contents: read\njobs:\n  a:\n    steps:\n"
            "      - run: echo ${{ github.event.pull_request.title }}\n"
            "      - env:\n          TITLE: ${{ github.event.pull_request.title }}\n        run: echo \"$TITLE\"\n"
        )
        report = _lint({".github/workflows/ci.yml": workflow})
        self.assertEqual(_rules(report), ["workflow-untrusted", "workflow-untrusted"])

    def test_unpinned_images(self):
        report = _lint({
            "Dockerfile": "FROM rust:1.98 AS build\nFROM debian\nCOPY --from=build /a /a\nFROM build\n",
            "docker-compose.yml": "services:\n  db:\n    image: postgres:16-alpine\n  ui:\n    image: adminer:latest\n",
        })
        self.assertEqual(_rules(report), ["unpinned-image", "unpinned-image"])


class BackendRules(unittest.TestCase):
    def test_reviewed_public_route_passes_and_new_one_fails(self):
        self.assertEqual(_lint({"backend/src/app.rs": APP_RS})["status"], "PASS")
        added = APP_RS.replace("routes! {", 'routes! {\n    post "/api/v1/open" => handlers::open, Public;')
        self.assertEqual(_rules(_lint({"backend/src/app.rs": added})), ["public-route"])

    def test_system_route_must_be_development_and_guard_must_refuse_production(self):
        bad = APP_RS.replace("routes! {", 'routes! {\n    post "/api/v1/system/wipe" => handlers::wipe, Require(SiteManage);')
        self.assertEqual(_rules(_lint({"backend/src/app.rs": bad})), ["dev-route-guard"])
        unguarded = APP_RS.replace("!state::AppStateInner::is_production()\n        && ", "")
        self.assertEqual(_rules(_lint({"backend/src/app.rs": unguarded})), ["dev-route-guard"])

    def test_permissive_cors_and_weak_crypto(self):
        source = "fn a() { let c = CorsLayer::permissive(); }\nfn b() { v.insecure_disable_signature_validation(); }\n"
        report = _lint({"backend/src/app.rs": APP_RS, "backend/src/x.rs": source})
        self.assertEqual(_rules(report), ["permissive-cors", "weak-crypto"])

    def test_error_leak_ratchet(self):
        handler = (
            "fn a() { x.map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())) }\n"
            'fn b() { x.map_err(|e| (StatusCode::BAD_REQUEST, format!("bad: {}", e))) }\n'
        )
        files = {"backend/src/app.rs": APP_RS, "backend/src/handlers/h.rs": handler}
        self.assertEqual(_rules(_lint(files)), ["internal-error-leak"])
        allowed = {"internal_error_leaks": {"backend/src/handlers/h.rs": 1}}
        self.assertEqual(_lint(files, allowed)["status"], "PASS")
        looser = _lint(files, {"internal_error_leaks": {"backend/src/handlers/h.rs": 3}})
        self.assertEqual(looser["status"], "PASS")
        self.assertTrue(looser["stale_baseline"], "a baseline above the real count is reported")


class ClientAndToolingRules(unittest.TestCase):
    def test_token_in_browser_storage(self):
        report = _lint({"flutter/lib/a.dart": "void f() { html.window.localStorage['refresh_token'] = t; }\n"})
        self.assertEqual(_rules(report), ["insecure-token-storage"])

    def test_unsafe_python(self):
        report = _lint({"scripts/tool.py": "subprocess.run(cmd, shell=True)\nrequests.get(u, verify=False)\n"})
        self.assertEqual(_rules(report), ["unsafe-python", "unsafe-python"])

    def test_accepted_finding_is_not_reported(self):
        files = {"docker-compose.yml": "services:\n  ui:\n    image: adminer:latest\n"}
        key = "unpinned-image|docker-compose.yml|adminer:latest has no fixed version tag"
        report = _lint(files, {"accepted": [key]})
        self.assertEqual((report["status"], report["accepted"]), ("PASS", 1))


class RepositoryState(unittest.TestCase):
    def test_repository_passes_with_committed_baseline(self):
        baseline = security_lint.load_baseline(security_lint.DEFAULT_BASELINE)
        repo = security_lint.DEFAULT_REPO
        project = repo / security_lint.PROJECT_REL
        report = security_lint.lint(repo, project / "backend", project / "flutter", baseline)
        self.assertEqual(report["findings"], [])


class DependencyAudit(unittest.TestCase):
    def test_cargo_lock_keeps_registry_packages_only(self):
        lock = (
            '[[package]]\nname = "tokio"\nversion = "1.53.1"\n'
            'source = "registry+https://github.com/rust-lang/crates.io-index"\n\n'
            '[[package]]\nname = "sitepulse-backend"\nversion = "1.0.0"\n'
        )
        self.assertEqual(
            dependency_audit.parse_cargo_lock(lock), [dependency_audit.Package("crates.io", "tokio", "1.53.1")]
        )

    def test_pubspec_lock_keeps_hosted_packages_only(self):
        lock = (
            "packages:\n  http:\n    dependency: \"direct main\"\n    description:\n      name: http\n"
            "    source: hosted\n    version: \"1.6.0\"\n"
            "  flutter:\n    dependency: \"direct main\"\n    description: flutter\n    source: sdk\n"
            "    version: \"0.0.0\"\nsdks:\n  dart: \">=3.13.4\"\n"
        )
        self.assertEqual(dependency_audit.parse_pubspec_lock(lock), [dependency_audit.Package("Pub", "http", "1.6.0")])

    def test_real_lock_files_parse(self):
        packages = dependency_audit.read_packages(
            dependency_audit.DEFAULT_CARGO_LOCK, dependency_audit.DEFAULT_PUBSPEC_LOCK
        )
        self.assertGreater(len(packages), 100)
        self.assertEqual({p.ecosystem for p in packages}, {"crates.io", "Pub"})

    def test_aliases_merge_and_allowlist_expiry(self):
        make = lambda vid, aliases, severity: dependency_audit.Advisory(  # noqa: E731
            vid, "crates.io", "rustls", "0.23.45", severity=severity, aliases=aliases
        )
        merged = dependency_audit.merge_aliases(
            [make("GHSA-aaaa", ["RUSTSEC-1"], "LOW"), make("RUSTSEC-1", ["GHSA-aaaa"], "UNKNOWN")]
        )
        self.assertEqual([(a.id, a.aliases) for a in merged], [("GHSA-aaaa", ["RUSTSEC-1"])])

        entry = {"id": "RUSTSEC-1", "package": "rustls", "reason": "r", "expires": "2030-01-01"}
        notes = dependency_audit.apply_allowlist(merged, [entry], dt.date(2029, 1, 1))
        self.assertTrue(merged[0].accepted)
        self.assertEqual(notes, [])
        merged[0].accepted = False
        notes = dependency_audit.apply_allowlist(merged, [entry], dt.date(2031, 1, 1))
        self.assertFalse(merged[0].accepted)
        self.assertIn("expired", notes[0])


if __name__ == "__main__":
    unittest.main()
