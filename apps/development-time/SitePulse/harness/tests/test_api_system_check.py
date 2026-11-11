"""Static self-tests for scripts/api_system_check.py (no backend or PostgreSQL needed)."""
import importlib.util
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"


def _load(name: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


api_check = _load("api_system_check")


class PublicRouteMirrorTests(unittest.TestCase):
    def test_public_routes_mirror_matches_app_rs(self):
        # Regression: the OpenAPI/Swagger/Scalar doc routes were declared Public in app.rs
        # without being mirrored, so unauthenticated_routes_rejected failed on a 200.
        unmirrored, stale = api_check.public_route_drift()
        self.assertEqual(unmirrored, [], "Public in app.rs but missing from PUBLIC_ROUTES")
        self.assertEqual(stale, [], "in PUBLIC_ROUTES but not Public in app.rs")

    def test_parser_reads_only_public_policy(self):
        source = (
            '    get "/health" => handlers::health_check, Public;\n'
            '    get "/scalar" => handlers::scalar_ui, Public;\n'
            '    post "/api/v1/system/sync-db" => handlers::sync_db, Development;\n'
            '    get "/api/v1/residents/:unit_id/dashboard" => handlers::get_resident_dashboard, Require(UnitRead);\n'
        )
        self.assertEqual(api_check.public_routes_from_app(source), {"/health", "/scalar"})

    def test_drift_reports_both_directions(self):
        source = '    get "/brand-new-public" => handlers::x, Public;\n'
        unmirrored, stale = api_check.public_route_drift(source)
        self.assertEqual(unmirrored, ["/brand-new-public"])
        self.assertIn("/health", stale)


if __name__ == "__main__":
    unittest.main()
