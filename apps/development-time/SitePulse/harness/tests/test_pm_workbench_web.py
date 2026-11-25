"""Unit tests for the PM Workbench Web UI (pm_workbench_web.py).

Covers the Workbench HTTP API a Product Manager drives from the browser:
  - GET  /api/presets  scenario gallery grouped into packs A-F
  - GET  /api/active   active-scenario cheat sheet (null when idle)
  - POST /api/seed     one-click scenario preparation plus clock pinning
  - POST /api/reset    re-provision the active preset
  - GET  /, /healthz   the single-page UI and a liveness probe

Error handling is covered too: unknown presets, malformed or oversized
bodies, method mismatches, unknown paths, seeding failures and clock failures.

Seeding and clock control are injected, so nothing here needs a backend,
PostgreSQL or a browser.
"""
from __future__ import annotations

import json
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from decimal import Decimal
from pathlib import Path
from typing import Any
from unittest import mock

BASE_DIR = Path(__file__).resolve().parents[2]
SCRIPTS_DIR = BASE_DIR / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import pm_workbench as wb
import pm_workbench_web as web
from pm_scenarios import EXPECTED_UNIT_BALANCES, REFERENCE_CLOCKS

F5_MANIFEST: dict[str, Any] = {
    "preset": "F5",
    "site_id": "4242",
    "site_name": "PM Workbench F5",
    "reference_clock": "2026-11-19",
    "expected_site_totals": {
        "units": 7,
        "overdue": Decimal("4567.50"),
        "advance": Decimal("0.00"),
        "total_overdue": "4567.50",
        "total_advance": "0.00",
        "sites": 1,
    },
    "unit_by_unit_expected_balances": [
        {
            "unit_number": 2,
            "unit": "A-2",
            "house_type": "Flat",
            "amount_due": "1522.50",
            "advance_balance": "0.00",
            "is_paid": False,
        }
    ],
    "personas": [
        {
            "role": "SITE_MANAGER",
            "name": "Journey Manager",
            "unit": None,
            "email": "manager@example.test",
            "password": "E2E-Manager-1",
        }
    ],
    "pm_checklist": ["Open the dues ledger", "Verify A-2 is overdue"],
}


class FakeSeedResult:
    """Minimal stand-in for ``pm_scenarios.seeder.SeedResult``."""

    def __init__(self, manifest: dict[str, Any]) -> None:
        outer = self

        class _Manifest:
            def to_dict(inner_self) -> dict[str, Any]:
                return dict(outer._manifest)

        self._manifest = manifest
        self.manifest = _Manifest()


class Harness:
    """Runs the UI server on an ephemeral port for one test."""

    def __init__(
        self,
        *,
        seed_manifests: dict[str, dict[str, Any]] | None = None,
        seed_error: Exception | None = None,
        clock_error: Exception | None = None,
        state_path: Path | None = None,
    ) -> None:
        self.seed_calls: list[str] = []
        self.clock_calls: list[str] = []
        self._seed_error = seed_error
        self._clock_error = clock_error
        self._manifests = seed_manifests or {}

        def seed_fn(preset: str) -> FakeSeedResult:
            self.seed_calls.append(preset)
            if self._seed_error is not None:
                raise self._seed_error
            manifest = dict(F5_MANIFEST)
            manifest.update(self._manifests.get(preset, {}))
            manifest["preset"] = preset
            return FakeSeedResult(manifest)

        def clock_fn(reference_date: str) -> dict[str, Any]:
            self.clock_calls.append(reference_date)
            if self._clock_error is not None:
                raise self._clock_error
            return {"action": "set_date", "date": reference_date, "status": "ok"}

        self._tmpdir = tempfile.TemporaryDirectory()
        self.service = web.WorkbenchService(
            seed_fn=seed_fn,
            clock_fn=clock_fn,
            state_path=state_path or Path(self._tmpdir.name) / "active.json",
        )
        self.server = web.create_server(self.service, host="127.0.0.1", port=0)
        self.port = self.server.server_address[1]
        self._thread = threading.Thread(
            target=self.server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True
        )

    def __enter__(self) -> "Harness":
        self._thread.start()
        return self

    def __exit__(self, *_exc: Any) -> None:
        self.server.shutdown()
        self.server.server_close()
        self._thread.join(timeout=5)
        self._tmpdir.cleanup()

    def url(self, path: str) -> str:
        return f"http://127.0.0.1:{self.port}{path}"

    def request(
        self,
        path: str,
        *,
        method: str = "GET",
        body: Any = None,
        raw_body: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> tuple[int, dict[str, str], bytes]:
        payload = raw_body
        request_headers = dict(headers or {})
        if payload is None and body is not None:
            payload = json.dumps(body).encode("utf-8")
            request_headers.setdefault("Content-Type", "application/json")
        request = urllib.request.Request(
            self.url(path), data=payload, headers=request_headers, method=method
        )
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, dict(response.headers), response.read()
        except urllib.error.HTTPError as err:
            try:
                return err.code, dict(err.headers), err.read()
            finally:
                err.close()

    def json(self, path: str, **kwargs: Any) -> tuple[int, dict[str, Any]]:
        status, _headers, raw = self.request(path, **kwargs)
        return status, json.loads(raw.decode("utf-8"))


class PresetGalleryTests(unittest.TestCase):
    """GET /api/presets exposes the full scenario catalogue."""

    def test_gallery_groups_presets_into_six_packs(self) -> None:
        with Harness() as harness:
            status, payload = harness.json("/api/presets")
        self.assertEqual(status, 200)
        self.assertEqual([pack["id"] for pack in payload["packs"]], ["A", "B", "C", "D", "E", "F"])

    def test_gallery_lists_every_seedable_preset_once(self) -> None:
        with Harness() as harness:
            _status, payload = harness.json("/api/presets")
        listed = [entry["preset"] for pack in payload["packs"] for entry in pack["presets"]]
        self.assertEqual(len(listed), len(set(listed)))
        self.assertEqual(
            sorted(listed),
            sorted(
                [
                    "F0",
                    "F1",
                    "F2",
                    "F3",
                    "F4",
                    "F5",
                    "F6",
                    "F7",
                    "F8_CAPITAL",
                    "F9_RECON",
                    "F10_GOVERNANCE",
                ]
            ),
        )

    def test_gallery_entries_carry_clock_units_and_checklist(self) -> None:
        with Harness() as harness:
            _status, payload = harness.json("/api/presets")
        entries = {entry["preset"]: entry for pack in payload["packs"] for entry in pack["presets"]}
        f5 = entries["F5"]
        self.assertEqual(f5["reference_clock"], REFERENCE_CLOCKS["F5"])
        self.assertEqual(f5["unit_count"], len(EXPECTED_UNIT_BALANCES["F5"]))
        self.assertTrue(f5["checklist"])
        self.assertTrue(f5["label"])
        self.assertTrue(f5["summary"])

    def test_gallery_money_values_are_exact_strings(self) -> None:
        with Harness() as harness:
            _status, payload = harness.json("/api/presets")
        for pack in payload["packs"]:
            for entry in pack["presets"]:
                for key, value in entry["expected_site_totals"].items():
                    self.assertNotIsInstance(
                        value, float, f"{entry['preset']}.{key} must not be a float"
                    )
                for unit in EXPECTED_UNIT_BALANCES[entry["preset"]]:
                    self.assertIsInstance(unit["amount_due"], str)

    def test_gallery_advertises_aliases(self) -> None:
        with Harness() as harness:
            _status, payload = harness.json("/api/presets")
        entries = {entry["preset"]: entry for pack in payload["packs"] for entry in pack["presets"]}
        self.assertIn("F8", entries["F8_CAPITAL"]["aliases"])
        self.assertIn("F9", entries["F9_RECON"]["aliases"])
        self.assertIn("F10", entries["F10_GOVERNANCE"]["aliases"])


class ActiveScenarioTests(unittest.TestCase):
    """GET /api/active reports the cheat sheet, or null when idle."""

    def test_idle_workbench_reports_no_active_scenario(self) -> None:
        with Harness() as harness:
            status, payload = harness.json("/api/active")
        self.assertEqual(status, 200)
        self.assertIsNone(payload["active"])

    def test_seeded_scenario_is_reported_with_cheat_sheet_fields(self) -> None:
        with Harness() as harness:
            harness.json("/api/seed", method="POST", body={"preset": "F5"})
            status, payload = harness.json("/api/active")
        self.assertEqual(status, 200)
        active = payload["active"]
        self.assertEqual(active["preset"], "F5")
        self.assertEqual(active["site_id"], "4242")
        self.assertEqual(active["site_name"], "PM Workbench F5")
        self.assertEqual(active["clock"]["status"], "SET")
        self.assertEqual(active["clock"]["reference_date"], "2026-11-19")
        self.assertEqual(active["expected_site_totals"]["overdue"], "4567.50")
        self.assertEqual(active["unit_by_unit_expected_balances"][0]["unit"], "A-2")
        self.assertEqual(active["personas"][0]["email"], "manager@example.test")
        self.assertEqual(active["pm_checklist"][0], "Open the dues ledger")


class SeedEndpointTests(unittest.TestCase):
    """POST /api/seed prepares a preset and pins the simulated clock."""

    def test_seed_returns_the_new_cheat_sheet(self) -> None:
        with Harness() as harness:
            status, payload = harness.json("/api/seed", method="POST", body={"preset": "F5"})
        self.assertEqual(status, 200)
        self.assertEqual(payload["preset"], "F5")
        self.assertEqual(payload["expected_site_totals"]["overdue"], "4567.50")

    def test_seed_pins_the_reference_clock_exactly_once(self) -> None:
        with Harness() as harness:
            harness.json("/api/seed", method="POST", body={"preset": "F5"})
            self.assertEqual(harness.seed_calls, ["F5"])
            self.assertEqual(harness.clock_calls, [REFERENCE_CLOCKS["F5"]])

    def test_seed_accepts_lowercase_and_aliases(self) -> None:
        with Harness() as harness:
            status, lowercase = harness.json("/api/seed", method="POST", body={"preset": " f6 "})
            status_alias, alias = harness.json("/api/seed", method="POST", body={"preset": "F8"})
        self.assertEqual(status, 200)
        self.assertEqual(lowercase["preset"], "F6")
        self.assertEqual(status_alias, 200)
        self.assertEqual(alias["preset"], "F8_CAPITAL")
        self.assertEqual(harness.clock_calls, [REFERENCE_CLOCKS["F6"], REFERENCE_CLOCKS["F8_CAPITAL"]])

    def test_seed_rejects_unknown_preset(self) -> None:
        with Harness() as harness:
            status, payload = harness.json("/api/seed", method="POST", body={"preset": "F99"})
            self.assertEqual(status, 400)
            self.assertIn("Unknown preset", payload["error"])
            self.assertEqual(harness.seed_calls, [])

    def test_seed_rejects_missing_preset(self) -> None:
        with Harness() as harness:
            status, payload = harness.json("/api/seed", method="POST", body={})
        self.assertEqual(status, 400)
        self.assertIn("preset name is required", payload["error"])

    def test_seed_rejects_non_string_preset(self) -> None:
        with Harness() as harness:
            status, payload = harness.json("/api/seed", method="POST", body={"preset": 5})
        self.assertEqual(status, 400)
        self.assertIn("preset name is required", payload["error"])

    def test_seed_rejects_malformed_json(self) -> None:
        with Harness() as harness:
            status, payload = harness.json(
                "/api/seed",
                method="POST",
                raw_body=b"{not json",
                headers={"Content-Type": "application/json"},
            )
        self.assertEqual(status, 400)
        self.assertIn("valid JSON", payload["error"])

    def test_seed_rejects_non_object_json(self) -> None:
        with Harness() as harness:
            status, payload = harness.json(
                "/api/seed", method="POST", raw_body=b'["F5"]'
            )
        self.assertEqual(status, 400)
        self.assertIn("JSON object", payload["error"])

    def test_seed_rejects_oversized_body(self) -> None:
        with Harness() as harness:
            status, payload = harness.json(
                "/api/seed",
                method="POST",
                raw_body=b"{}",
                headers={"Content-Length": str(web.MAX_REQUEST_BYTES + 1)},
            )
        self.assertEqual(status, 413)
        self.assertIn("exceeds", payload["error"])

    def test_seed_reports_seeding_failure_as_bad_gateway(self) -> None:
        with Harness(seed_error=RuntimeError("database is down")) as harness:
            status, payload = harness.json("/api/seed", method="POST", body={"preset": "F5"})
        self.assertEqual(status, 502)
        self.assertIn("Seeding F5 failed", payload["error"])

    def test_clock_failure_still_returns_the_scenario_with_a_warning(self) -> None:
        with Harness(clock_error=RuntimeError("clock route missing")) as harness:
            status, payload = harness.json("/api/seed", method="POST", body={"preset": "F5"})
        self.assertEqual(status, 200)
        self.assertEqual(payload["preset"], "F5")
        self.assertEqual(payload["clock"]["status"], "FAILED")
        self.assertIn("clock route missing", payload["clock"]["error"])

    def test_seed_without_content_length_defaults_to_empty_body(self) -> None:
        with Harness() as harness:
            status, payload = harness.json("/api/seed", method="POST", raw_body=b"")
        self.assertEqual(status, 400)
        self.assertIn("preset name is required", payload["error"])


class ResetEndpointTests(unittest.TestCase):
    """POST /api/reset re-provisions the active preset."""

    def test_reset_without_active_scenario_conflicts(self) -> None:
        with Harness() as harness:
            status, payload = harness.json("/api/reset", method="POST", body={})
        self.assertEqual(status, 409)
        self.assertIn("nothing to reset", payload["error"])

    def test_reset_reseeds_the_active_preset(self) -> None:
        with Harness(seed_manifests={"F6": {"site_name": "Reset F6"}}) as harness:
            harness.json("/api/seed", method="POST", body={"preset": "F6"})
            status, payload = harness.json("/api/reset", method="POST", body={})
            self.assertEqual(status, 200)
            self.assertEqual(payload["preset"], "F6")
            self.assertEqual(payload["site_name"], "Reset F6")
            self.assertEqual(harness.seed_calls, ["F6", "F6"])
            self.assertEqual(harness.clock_calls, [REFERENCE_CLOCKS["F6"], REFERENCE_CLOCKS["F6"]])


class StatePersistenceTests(unittest.TestCase):
    """The active scenario survives a Workbench restart."""

    def test_active_scenario_is_restored_from_the_state_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            state_path = Path(tmpdir) / "active.json"
            with Harness(state_path=state_path) as harness:
                harness.json("/api/seed", method="POST", body={"preset": "F5"})
            self.assertTrue(state_path.is_file())

            restored = web.WorkbenchService(
                seed_fn=lambda preset: FakeSeedResult(F5_MANIFEST),
                clock_fn=lambda date: {},
                state_path=state_path,
            )
            active = restored.active()
            self.assertIsNotNone(active)
            assert active is not None
            self.assertEqual(active.preset, "F5")
            self.assertEqual(active.manifest["site_name"], "PM Workbench F5")

    def test_corrupt_state_file_is_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            state_path = Path(tmpdir) / "active.json"
            state_path.write_text("{corrupt", encoding="utf-8")
            service = web.WorkbenchService(
                seed_fn=lambda preset: FakeSeedResult(F5_MANIFEST),
                clock_fn=lambda date: {},
                state_path=state_path,
            )
            with self.assertLogs(web.LOGGER, level="WARNING") as records:
                self.assertIsNone(service.active())
            self.assertIn("unreadable workbench state file", records.output[0])

    def test_malformed_state_payload_is_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            state_path = Path(tmpdir) / "active.json"
            state_path.write_text(json.dumps({"unexpected": True}), encoding="utf-8")
            service = web.WorkbenchService(
                seed_fn=lambda preset: FakeSeedResult(F5_MANIFEST),
                clock_fn=lambda date: {},
                state_path=state_path,
            )
            with self.assertLogs(web.LOGGER, level="WARNING") as records:
                self.assertIsNone(service.active())
            self.assertIn("malformed workbench state file", records.output[0])


class RoutingTests(unittest.TestCase):
    """Paths, methods and the served HTML."""

    def test_root_serves_the_single_page_ui(self) -> None:
        with Harness() as harness:
            status, headers, raw = harness.request("/")
        body = raw.decode("utf-8")
        self.assertEqual(status, 200)
        self.assertIn("text/html", headers["Content-Type"])
        self.assertIn("SitePulse PM Workbench", body)
        self.assertIn("/api/presets", body)
        self.assertIn("/api/seed", body)
        self.assertIn("/api/reset", body)
        self.assertIn("Reset Current Scenario", body)
        self.assertIn("Scenario gallery", body)

    def test_healthz_reports_ok(self) -> None:
        with Harness() as harness:
            status, payload = harness.json("/healthz")
        self.assertEqual(status, 200)
        self.assertEqual(payload["status"], "ok")

    def test_unknown_path_returns_not_found(self) -> None:
        with Harness() as harness:
            status, payload = harness.json("/api/nope")
        self.assertEqual(status, 404)
        self.assertIn("Unknown path", payload["error"])

    def test_get_on_post_route_reports_method_not_allowed(self) -> None:
        with Harness() as harness:
            status, headers, raw = harness.request("/api/seed")
        self.assertEqual(status, 405)
        self.assertEqual(headers["Allow"], "POST")
        self.assertIn("not supported", json.loads(raw.decode("utf-8"))["error"])

    def test_post_on_get_route_reports_method_not_allowed(self) -> None:
        with Harness() as harness:
            status, headers, raw = harness.request("/api/presets", method="POST", body={})
        self.assertEqual(status, 405)
        self.assertEqual(headers["Allow"], "GET")

    def test_trailing_slash_is_tolerated(self) -> None:
        with Harness() as harness:
            status, payload = harness.json("/api/presets/")
        self.assertEqual(status, 200)
        self.assertIn("packs", payload)


class GuardrailTests(unittest.TestCase):
    """The UI refuses to run in production and binds to loopback."""

    def test_create_server_enforces_the_production_guardrail(self) -> None:
        service = web.WorkbenchService(
            seed_fn=lambda preset: FakeSeedResult(F5_MANIFEST),
            clock_fn=lambda date: {},
            state_path=Path(tempfile.gettempdir()) / "unused-workbench-state.json",
        )
        sentinel = wb.ProductionGuardrailError("refusing to run in production")
        with mock.patch.object(wb, "check_production_guardrail", side_effect=sentinel) as guard:
            with self.assertRaises(wb.ProductionGuardrailError):
                web.create_server(service, host="127.0.0.1", port=0)
        guard.assert_called_once()

    def test_default_host_is_loopback(self) -> None:
        self.assertEqual(web.DEFAULT_UI_HOST, "127.0.0.1")
        self.assertEqual(web.DEFAULT_UI_PORT, 9095)


if __name__ == "__main__":
    unittest.main()
