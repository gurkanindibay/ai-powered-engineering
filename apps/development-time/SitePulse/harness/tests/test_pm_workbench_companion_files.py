"""Unit tests for the PM Workbench companion file endpoints (issue #418).

Verifies the one-click downloadable companion file endpoints:
  - GET /api/companion/bank-statement.csv
  - GET /api/companion/bank-statement.mt940
  - GET /api/companion/resident-import.xlsx
  - Query parameter formats and alternate alias routes

Verifies:
  1. Bank Statement (CSV & MT940): dynamically populated with the active seeded site's
     real Virtual IBANs (read from active manifest):
     - 1 clean exact-match payment (real virtual IBAN from the active manifest for unit A-1)
     - 1 ambiguous multi-debtor Virtual IBAN transfer (unit A-2) that lands in the UNMATCHED queue (Q11)
     - 1 duplicate bank transaction ID (idempotency check)
     - 1 unknown Virtual IBAN
  2. Resident Import Excel (.xlsx):
     - OpenXML XLSX format compatible with PersonImportXlsx in flutter
     - 5 valid resident rows + 1 intentionally invalid row (bad format) + 1 duplicate national ID
     - Semicolon-separated columns: block, unit_no, floor, owner_full_name, owner_email,
       owner_phone, land_share, monthly_dues, is_resident, tenant_full_name, tenant_email, tenant_phone.
  3. Safe fallback when no scenario is currently active.
  4. HEAD requests and HTTP 405 method guards.
"""
from __future__ import annotations

import io
import json
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import zipfile
from decimal import Decimal
from pathlib import Path
from typing import Any
import xml.etree.ElementTree as ET

BASE_DIR = Path(__file__).resolve().parents[2]
SCRIPTS_DIR = BASE_DIR / "scripts"
E2E_DIR = BASE_DIR / "e2e"

if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))
if str(E2E_DIR) not in sys.path:
    sys.path.insert(0, str(E2E_DIR))

import pm_workbench_web as web
from support.bank_files import (
    DEFAULT_RESIDENT_IMPORT_COLUMNS,
    build_companion_statement_rows,
    make_viban,
    resident_import_xlsx,
    statement_csv,
    statement_mt940,
)

F9_TEST_MANIFEST: dict[str, Any] = {
    "preset": "F9_RECON",
    "site_id": "7788",
    "site_name": "Companion Test Site F9",
    "reference_clock": "2026-11-19",
    "expected_site_totals": {
        "units": 7,
        "overdue": Decimal("9750.00"),
        "advance": Decimal("0.00"),
        "total_overdue": "9750.00",
        "total_advance": "0.00",
        "sites": 1,
        "virtual_ibans_assigned": 7,
        "duplicate_candidates": 1,
    },
    "unit_by_unit_expected_balances": [
        {
            "unit_number": 1,
            "unit": "A-1",
            "house_type": "Flat",
            "amount_due": "1500.00",
            "advance_balance": "0.00",
            "is_paid": False,
        },
        {
            "unit_number": 2,
            "unit": "A-2",
            "house_type": "Flat",
            "amount_due": "1500.00",
            "advance_balance": "0.00",
            "is_paid": False,
        },
    ],
    "personas": [
        {
            "role": "SITE_MANAGER",
            "name": "Companion Manager",
            "unit": None,
            "email": "manager.companion@example.test",
            "password": "E2E-Manager-1",
        }
    ],
    "pm_checklist": [
        "Verify deterministic Virtual IBANs (TR...) assigned to all 7 units",
        "Test bank statement import and automated reconciliation matching via Virtual IBAN",
    ],
}


class FakeSeedResult:
    def __init__(self, manifest: dict[str, Any]) -> None:
        outer = self

        class _Manifest:
            def to_dict(inner_self) -> dict[str, Any]:
                return dict(outer._manifest)

        self._manifest = manifest
        self.manifest = _Manifest()


class CompanionTestHarness:
    """Runs an ephemeral Workbench Web server for companion file testing."""

    def __init__(
        self,
        *,
        active_manifest: dict[str, Any] | None = None,
    ) -> None:
        self.active_manifest = active_manifest

        def seed_fn(preset: str) -> FakeSeedResult:
            manifest = dict(active_manifest or F9_TEST_MANIFEST)
            manifest["preset"] = preset
            return FakeSeedResult(manifest)

        def clock_fn(ref_date: str) -> dict[str, Any]:
            return {"action": "set_date", "date": ref_date, "status": "ok"}

        self._tmpdir = tempfile.TemporaryDirectory()
        self.service = web.WorkbenchService(
            seed_fn=seed_fn,
            clock_fn=clock_fn,
            state_path=Path(self._tmpdir.name) / "active.json",
        )
        if active_manifest is not None:
            self.service.prepare(active_manifest.get("preset", "F9_RECON"))

        self.server = web.create_server(self.service, host="127.0.0.1", port=0)
        self.port = self.server.server_address[1]
        self._thread = threading.Thread(
            target=self.server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True
        )

    def __enter__(self) -> "CompanionTestHarness":
        self._thread.start()
        return self

    def __exit__(self, *_exc: Any) -> None:
        self.server.shutdown()
        self.server.server_close()
        self._thread.join(timeout=5)
        self._tmpdir.cleanup()

    def url(self, path: str) -> str:
        return f"http://127.0.0.1:{self.port}{path}"

    def get(self, path: str) -> tuple[int, dict[str, str], bytes]:
        req = urllib.request.Request(self.url(path), method="GET")
        with urllib.request.urlopen(req) as resp:
            headers = {k.lower(): v for k, v in resp.headers.items()}
            return resp.status, headers, resp.read()

    def head(self, path: str) -> tuple[int, dict[str, str], bytes]:
        req = urllib.request.Request(self.url(path), method="HEAD")
        with urllib.request.urlopen(req) as resp:
            headers = {k.lower(): v for k, v in resp.headers.items()}
            return resp.status, headers, resp.read()


class CompanionFilesTest(unittest.TestCase):
    def test_bank_statement_csv_endpoint_with_active_manifest(self) -> None:
        with CompanionTestHarness(active_manifest=F9_TEST_MANIFEST) as h:
            status, headers, body = h.get("/api/companion/bank-statement.csv")
            self.assertEqual(status, 200)
            self.assertIn("text/csv", headers.get("content-type", ""))
            self.assertIn('filename="bank-statement.csv"', headers.get("content-disposition", ""))

            text = body.decode("utf-8")
            lines = [line.strip() for line in text.strip().split("\n") if line.strip()]
            self.assertEqual(len(lines), 5, f"Expected header + 4 rows, got: {lines}")
            self.assertEqual(lines[0], "Tarih;Referans;Açıklama;Tutar")

            # Check real Virtual IBANs computed from manifest site_id (7788)
            viban_a1 = make_viban("00205", "7788", "A", 1)
            viban_a2 = make_viban("00205", "7788", "A", 2)
            viban_unknown = make_viban("00205", 99999, "Z", 99)

            # Row 1: clean match for unit A-1
            self.assertIn("TXN-20261115-001", lines[1])
            self.assertIn(viban_a1, lines[1])
            self.assertIn("1.500,00", lines[1])

            # Row 2: ambiguous multi-debtor Virtual IBAN transfer (A-2) landing in Q11
            self.assertIn("TXN-20261115-002", lines[2])
            self.assertIn(viban_a2, lines[2])
            self.assertIn("800,00", lines[2])

            # Row 3: duplicate bank transaction ID (idempotency check)
            self.assertIn("TXN-20261115-001", lines[3])
            self.assertIn(viban_a1, lines[3])

            # Row 4: unknown Virtual IBAN
            self.assertIn("TXN-20261115-004", lines[4])
            self.assertIn(viban_unknown, lines[4])
            self.assertIn("500,00", lines[4])

    def test_bank_statement_mt940_endpoint_with_active_manifest(self) -> None:
        with CompanionTestHarness(active_manifest=F9_TEST_MANIFEST) as h:
            status, headers, body = h.get("/api/companion/bank-statement.mt940")
            self.assertEqual(status, 200)
            self.assertIn("text/plain", headers.get("content-type", ""))
            self.assertIn('filename="bank-statement.mt940"', headers.get("content-disposition", ""))

            text = body.decode("utf-8")
            self.assertTrue(text.startswith(":20:STARTMR"))
            self.assertIn(":25:", text)
            self.assertIn(":28C:00001/001", text)
            self.assertIn(":60F:C261101TRY50000,00", text)

            tag_61_lines = [l for l in text.splitlines() if l.startswith(":61:")]
            tag_86_lines = [l for l in text.splitlines() if l.startswith(":86:")]
            self.assertEqual(len(tag_61_lines), 4)
            self.assertEqual(len(tag_86_lines), 4)

            # Check that tag 61 has duplicate TXN reference
            refs = [l.split("//")[1] for l in tag_61_lines if "//" in l]
            self.assertEqual(refs.count("TXN-20261115-001"), 2)

            # Check narratives contain active manifest Virtual IBANs
            viban_a1 = make_viban("00205", "7788", "A", 1)
            viban_a2 = make_viban("00205", "7788", "A", 2)
            viban_unknown = make_viban("00205", 99999, "Z", 99)
            self.assertIn(viban_a1, text)
            self.assertIn(viban_a2, text)
            self.assertIn(viban_unknown, text)

            # Check closing tags
            self.assertIn(":62F:", text)
            self.assertTrue(text.rstrip().endswith("-"))

    def test_resident_import_xlsx_endpoint_and_contents(self) -> None:
        with CompanionTestHarness(active_manifest=F9_TEST_MANIFEST) as h:
            status, headers, body = h.get("/api/companion/resident-import.xlsx")
            self.assertEqual(status, 200)
            self.assertIn("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", headers.get("content-type", ""))
            self.assertIn('filename="resident-import.xlsx"', headers.get("content-disposition", ""))

            # Verify valid OpenXML zip archive structure
            with zipfile.ZipFile(io.BytesIO(body), "r") as z:
                names = set(z.namelist())
                self.assertIn("[Content_Types].xml", names)
                self.assertIn("_rels/.rels", names)
                self.assertIn("xl/workbook.xml", names)
                self.assertIn("xl/_rels/workbook.xml.rels", names)
                self.assertIn("xl/worksheets/sheet1.xml", names)
                self.assertIn("xl/sharedStrings.xml", names)

                # Parse shared strings
                sst_tree = ET.fromstring(z.read("xl/sharedStrings.xml"))
                strings = [
                    elem.text or ""
                    for elem in sst_tree.iter("{http://schemas.openxmlformats.org/spreadsheetml/2006/main}t")
                ]

                # Parse sheet1 cells
                sheet_tree = ET.fromstring(z.read("xl/worksheets/sheet1.xml"))
                parsed_rows: list[dict[str, str]] = []
                for row_el in sheet_tree.iter("{http://schemas.openxmlformats.org/spreadsheetml/2006/main}row"):
                    row_dict: dict[str, str] = {}
                    for c in row_el.iter("{http://schemas.openxmlformats.org/spreadsheetml/2006/main}c"):
                        cell_ref = c.attrib.get("r", "")
                        col_letter = "".join(ch for ch in cell_ref if ch.isalpha())
                        v = c.find("{http://schemas.openxmlformats.org/spreadsheetml/2006/main}v")
                        if v is not None and v.text:
                            row_dict[col_letter] = strings[int(v.text)]
                        else:
                            row_dict[col_letter] = ""
                    parsed_rows.append(row_dict)

            # Header row + 5 valid + 1 invalid + 1 duplicate = 8 rows
            self.assertEqual(len(parsed_rows), 8)

            # Row 1: Header row with all 12 columns
            header_vals = [parsed_rows[0].get(chr(65 + i), "") for i in range(12)]
            self.assertEqual(header_vals, DEFAULT_RESIDENT_IMPORT_COLUMNS)

            # Rows 2 to 6: 5 valid resident rows
            for i in range(1, 6):
                row = parsed_rows[i]
                self.assertEqual(row.get("A"), "B Blok")
                self.assertEqual(row.get("B"), str(i))  # unit_no 1..5
                self.assertTrue(bool(row.get("D")), f"Row {i} missing owner name")
                self.assertTrue("@" in row.get("E", ""), f"Row {i} invalid email")
                self.assertTrue(bool(row.get("F")), f"Row {i} missing phone")

            # Row 7: intentionally invalid row (bad format)
            invalid_row = parsed_rows[6]
            self.assertEqual(invalid_row.get("A"), "B Blok")
            self.assertEqual(invalid_row.get("B"), "XYZ")  # non-numeric unit
            self.assertEqual(invalid_row.get("C"), "abc")  # non-numeric floor
            self.assertEqual(invalid_row.get("D", ""), "")  # missing owner name
            self.assertEqual(invalid_row.get("E"), "invalid-email")
            self.assertEqual(invalid_row.get("F"), "bad-phone")

            # Row 8: duplicate person candidate (Ahmet Yılmaz with national ID / phone matching seeder)
            dup_row = parsed_rows[7]
            self.assertIn("Ahmet Yılmaz", dup_row.get("D", ""))
            self.assertIn("10000000146", dup_row.get("D", ""))
            self.assertEqual(dup_row.get("F"), "+90 532 111 22 33")

    def test_companion_endpoints_fallback_when_no_active_scenario(self) -> None:
        """When no scenario has been prepared yet, endpoints return valid default files."""
        with CompanionTestHarness(active_manifest=None) as h:
            status, _, body = h.get("/api/companion/bank-statement.csv")
            self.assertEqual(status, 200)
            self.assertIn("TXN-20261115-001", body.decode("utf-8"))

            status, _, body = h.get("/api/companion/bank-statement.mt940")
            self.assertEqual(status, 200)
            self.assertIn(":20:STARTMR", body.decode("utf-8"))

            status, _, body = h.get("/api/companion/resident-import.xlsx")
            self.assertEqual(status, 200)
            self.assertTrue(len(body) > 1000)

    def test_companion_alternate_routes_and_query_formats(self) -> None:
        with CompanionTestHarness(active_manifest=F9_TEST_MANIFEST) as h:
            # /api/companion/bank-csv alias
            s, hdrs, b = h.get("/api/companion/bank-csv")
            self.assertEqual(s, 200)
            self.assertIn("text/csv", hdrs.get("content-type", ""))

            # /api/companion/bank-statement.sta and /api/companion/bank-mt940 aliases
            s, hdrs, b = h.get("/api/companion/bank-statement.sta")
            self.assertEqual(s, 200)
            self.assertIn("text/plain", hdrs.get("content-type", ""))

            s, hdrs, b = h.get("/api/companion/bank-mt940")
            self.assertEqual(s, 200)
            self.assertIn("text/plain", hdrs.get("content-type", ""))

            # /api/companion/bank-statement with ?format=mt940 vs ?format=csv
            s, hdrs, b = h.get("/api/companion/bank-statement?format=mt940")
            self.assertEqual(s, 200)
            self.assertIn("text/plain", hdrs.get("content-type", ""))
            self.assertIn(":20:STARTMR", b.decode("utf-8"))

            s, hdrs, b = h.get("/api/companion/bank-statement?format=csv")
            self.assertEqual(s, 200)
            self.assertIn("text/csv", hdrs.get("content-type", ""))
            self.assertIn("Tarih;Referans;Açıklama;Tutar", b.decode("utf-8"))

            # /api/companion/resident-import and /api/companion/resident-xlsx aliases
            s, hdrs, b = h.get("/api/companion/resident-import")
            self.assertEqual(s, 200)
            self.assertIn("spreadsheetml.sheet", hdrs.get("content-type", ""))

            s, hdrs, b = h.get("/api/companion/resident-xlsx")
            self.assertEqual(s, 200)
            self.assertIn("spreadsheetml.sheet", hdrs.get("content-type", ""))

    def test_head_and_method_guards(self) -> None:
        with CompanionTestHarness(active_manifest=F9_TEST_MANIFEST) as h:
            # HEAD request returns 200 with 0 body bytes
            status, headers, body = h.head("/api/companion/bank-statement.csv")
            self.assertEqual(status, 200)
            self.assertEqual(body, b"")
            self.assertIn("text/csv", headers.get("content-type", ""))

            status, headers, body = h.head("/api/companion/resident-import.xlsx")
            self.assertEqual(status, 200)
            self.assertEqual(body, b"")

            # POST method is refused with 405 Method Not Allowed
            req = urllib.request.Request(
                h.url("/api/companion/bank-statement.csv"),
                data=b"{}",
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                urllib.request.urlopen(req)
            self.assertEqual(ctx.exception.code, 405)


if __name__ == "__main__":
    unittest.main()
