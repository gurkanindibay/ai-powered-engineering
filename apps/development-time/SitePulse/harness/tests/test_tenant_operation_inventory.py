"""Unit tests for the tenant operation inventory validator."""
from collections import Counter
import importlib.util
from pathlib import Path
import unittest

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
spec = importlib.util.spec_from_file_location(
    "tenant_operation_inventory", SCRIPTS / "tenant_operation_inventory.py"
)
inventory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inventory)


def entry(method, path, applicability="tenant_reference", runtime_tests=None):
    return {
        "method": method,
        "path": path,
        "applicability": applicability,
        "reason": "Example operation.",
        "evidence": "Rust handler example.",
        "runtime_tests": [] if runtime_tests is None else runtime_tests,
    }


class TenantOperationInventoryTests(unittest.TestCase):
    def test_all_methods_classified_and_path_metadata_ignored(self):
        document = {
            "paths": {
                "/unit/{id}": {
                    "get": {},
                    "delete": {},
                    "parameters": [],
                    "x-extension": True,
                },
                "/health": {"head": {}},
            }
        }
        operations = inventory.openapi_operations(document)
        rows = [entry("GET", "/unit/{id}"), entry("DELETE", "/unit/{id}"),
                entry("HEAD", "/health", "outside_scope")]
        result = inventory.validate({"version": 1, "operations": rows}, operations, Counter(operations))
        self.assertTrue(result["ok"])
        self.assertEqual(result["applicability_counts"], {
            "tenant_reference": 2, "implicit_tenant_scope": 0, "outside_scope": 1,
        })

    def test_reports_missing_stale_and_duplicate_operations(self):
        operations = {("GET", "/current"), ("POST", "/current")}
        rows = [entry("GET", "/current"), entry("GET", "/current"), entry("GET", "/removed")]
        result = inventory.validate({"version": 1, "operations": rows}, operations, Counter(operations))
        self.assertFalse(result["ok"])
        self.assertEqual(result["missing"], ["POST /current"])
        self.assertEqual(result["stale"], ["GET /removed"])
        self.assertEqual(result["duplicates"], ["GET /current"])
        self.assertEqual(result["applicability_counts"]["tenant_reference"], 0)

    def test_invalid_classification_is_not_counted(self):
        bad = entry("GET", "/health", "unknown")
        bad["reason"] = " "
        del bad["evidence"]
        operations = {("GET", "/health")}
        result = inventory.validate({"version": 1, "operations": [bad]}, operations, Counter(operations))
        self.assertFalse(result["ok"])
        self.assertEqual(len(result["invalid"]), 3)
        self.assertEqual(sum(result["applicability_counts"].values()), 0)

    def test_strict_runtime_evidence_counts_missing_tenant_operations(self):
        operations = {("GET", "/known"), ("GET", "/other"), ("GET", "/health")}
        rows = [
            entry("GET", "/known", runtime_tests=["e2e/example.py::test_known"]),
            entry("GET", "/other", "implicit_tenant_scope"),
            entry("GET", "/health", "outside_scope"),
        ]
        document = {"version": 1, "operations": rows}
        routes = Counter(operations)
        result = inventory.validate(document, operations, routes)
        self.assertTrue(result["ok"])
        self.assertEqual(result["runtime_coverage"], {
            "tenant_reference": {"tested": 1, "uncovered": 0},
            "implicit_tenant_scope": {"tested": 0, "uncovered": 1},
            "outside_scope": {"tested": 0, "uncovered": 1},
        })
        strict = inventory.validate(document, operations, routes, require_runtime_evidence=True)
        self.assertFalse(strict["ok"])
        self.assertEqual(strict["runtime_evidence_missing"], ["GET /other"])

        rows[1]["runtime_tests"] = ["e2e/example.py::test_other"]
        strict = inventory.validate(document, operations, routes, require_runtime_evidence=True)
        self.assertTrue(strict["ok"])
        self.assertEqual(strict["runtime_evidence_missing"], [])

    def test_invalid_runtime_test_references_cannot_supply_evidence(self):
        operations = {("GET", "/known")}
        for value, message in (
            ("example", "must be an array"),
            ([" "], "must be an array"),
            (["e2e/example.py::test_known", "e2e/example.py::test_known"], "duplicate references"),
        ):
            with self.subTest(value=value):
                document = {"version": 1, "operations": [entry("GET", "/known", runtime_tests=value)]}
                result = inventory.validate(document, operations, Counter(operations))
                self.assertFalse(result["ok"])
                self.assertIn(message, result["invalid"][0])
                self.assertEqual(result["runtime_coverage"]["tenant_reference"]["tested"], 0)

    def test_drifts_reported_separately_from_inventory_findings(self):
        source = """
routes! {
    get "/units/:unit_id" => handlers::units, RequireAny(&[Read, Admin]);
    get "/units/{unit_id}" => handlers::units, Require(Read);
    patch "/registered" => handlers::patch, Require(Admin);
}
fn irrelevant() {
    get "/elsewhere" => handlers::example, Public;
}
"""
        routes = inventory.registered_operations(source)
        operations = {("GET", "/units/{unit_id}"), ("POST", "/documented")}
        rows = [entry(*operation) for operation in operations]
        result = inventory.validate({"version": 1, "operations": rows}, operations, routes)
        self.assertFalse(result["ok"])
        self.assertEqual(result["missing"], [])
        self.assertEqual(result["stale"], [])
        self.assertEqual(result["routes_missing_from_openapi"], ["PATCH /registered"])
        self.assertEqual(result["openapi_missing_from_routes"], ["POST /documented"])
        self.assertEqual(result["duplicate_registered_routes"], ["GET /units/{unit_id}"])

    def test_repeated_method_key_is_rejected_instead_of_overwritten(self):
        with self.assertRaisesRegex(ValueError, "duplicate JSON key 'get'"):
            inventory._unique_object([("get", {}), ("get", {"summary": "duplicate"})])


if __name__ == "__main__":
    unittest.main()
