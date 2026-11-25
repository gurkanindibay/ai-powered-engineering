"""Drift guard for the PM Manual Testing Playbook.

``docs/testing/PM_TEST_PLAYBOOK.md`` exists so a Product Manager can exercise
SitePulse by hand against a named preset. Every preset, clock and total it
quotes is copied from ``pm_scenarios`` (the single catalogue shared by the E2E
seeder, the workbench CLI and the Web UI). Nothing in a Markdown file stops
those copies from going stale, so this test parses the playbook tables and
compares them with the catalogue:

  - pack sections A-F keep the same letter, title and presets as ``PACKS``;
  - the Pack A/B preset tables match ``EXPECTED_TOTALS`` and
    ``REFERENCE_CLOCKS`` row by row, including the preset labels;
  - every unit-balance table matches ``EXPECTED_UNIT_BALANCES`` for at least
    one preset of its own pack;
  - the Pack C-F metric tables match the same catalogue, plus the capital
    budget quoted for ``F8_CAPITAL``;
  - every preset in the catalogue is documented, and every preset the
    playbook names exists in the catalogue.

A failure means either the playbook or the preset catalogue changed without
the other; the failure message names the preset and the quoted value.
"""
from __future__ import annotations

import re
import sys
import unittest
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any

BASE_DIR = Path(__file__).resolve().parents[2]
SCRIPTS_DIR = BASE_DIR / "scripts"
PLAYBOOK_PATH = BASE_DIR / "docs" / "testing" / "PM_TEST_PLAYBOOK.md"

if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import pm_workbench_web as web
from pm_scenarios import EXPECTED_TOTALS, EXPECTED_UNIT_BALANCES, REFERENCE_CLOCKS

PACK_HEADING_RE = re.compile(r"^Pack ([A-F]) — (.+?) \(([^)]*)\)$")
SEPARATOR_RE = re.compile(r"^\|[\s:\-|]+\|$")
MONEY_RE = re.compile(r"-?\d[\d,]*(?:\.\d+)?")
INT_RE = re.compile(r"-?\d+")
PRESET_TOKEN_RE = re.compile(r"`(F[0-9]+(?:_[A-Z]+)?)`")

TOTAL_INT_FIELDS = {
    "Blocks": "blocks",
    "Units": "units",
    "People": "people",
    "Accounts": "accounts",
    "Periods": "periods",
    "Liabilities": "liabilities",
    "Receipts": "receipts",
}
TOTAL_MONEY_FIELDS = {"Overdue": "overdue", "Advance": "advance"}
UNIT_FIELDS = {
    "Due": "amount_due",
    "Operational due": "amount_due",
    "Advance": "advance_balance",
    "Capital due": "capital_due",
}
METRIC_FIELDS = {
    "Reference clock": ("clock", "clock"),
    "Periods": ("periods", "int"),
    "People": ("people", "int"),
    "Sites": ("sites", "int"),
    "Liabilities / receipts": ("liabilities_receipts", "int_pair"),
    "Overdue": ("overdue", "money"),
    "Operational overdue / advance": ("operational_totals", "money_pair"),
    "Virtual IBANs assigned": ("virtual_ibans_assigned", "int"),
    "Duplicate candidates": ("duplicate_candidates", "int"),
    "Severe arrears units": ("severe_arrears_units", "int"),
    "Active payment plans": ("active_payment_plans", "int"),
    "Heat cost periods": ("heat_cost_periods", "int"),
    "Scheduled meetings": ("scheduled_meetings", "int"),
    "Capital projects": ("capital_projects", "int"),
    "Capital installments": ("capital_installments", "int"),
}


def _cells(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def _tables(section: str) -> list[tuple[list[str], list[list[str]]]]:
    lines = section.splitlines()
    tables: list[tuple[list[str], list[list[str]]]] = []
    index = 0
    while index < len(lines):
        header = lines[index].strip()
        is_header = header.startswith("|") and index + 1 < len(lines) and SEPARATOR_RE.match(
            lines[index + 1].strip()
        )
        if not is_header:
            index += 1
            continue
        rows: list[list[str]] = []
        cursor = index + 2
        while cursor < len(lines) and lines[cursor].strip().startswith("|"):
            rows.append(_cells(lines[cursor]))
            cursor += 1
        tables.append((_cells(header), rows))
        index = cursor
    return tables


def _sections(text: str) -> list[tuple[str, str]]:
    parts = re.split(r"^### ", text, flags=re.MULTILINE)
    sections: list[tuple[str, str]] = []
    for part in parts[1:]:
        heading, _, body = part.partition("\n")
        sections.append((heading.strip(), body))
    return sections


def _money(value: str) -> Decimal:
    match = MONEY_RE.search(value)
    if match is None:
        raise AssertionError(f"no amount in {value!r}")
    try:
        return Decimal(match.group(0).replace(",", ""))
    except InvalidOperation as err:  # pragma: no cover - defensive
        raise AssertionError(f"unparsable amount {value!r}") from err


def _ints(value: str) -> list[int]:
    return [int(token) for token in INT_RE.findall(value)]


def _pack_presets(letter: str) -> tuple[str, ...]:
    for pack in web.PACKS:
        if pack["id"] == letter:
            return tuple(pack["presets"])
    raise AssertionError(f"PACKS has no pack {letter!r}")


class PlaybookParsingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.text = PLAYBOOK_PATH.read_text(encoding="utf-8")
        self.sections = _sections(self.text)

    def test_playbook_exists(self) -> None:
        self.assertTrue(PLAYBOOK_PATH.is_file(), PLAYBOOK_PATH)

    def test_pack_sections_match_workbench_packs(self) -> None:
        found: dict[str, tuple[str, tuple[str, ...]]] = {}
        for heading, _body in self.sections:
            match = PACK_HEADING_RE.match(heading)
            if match is None:
                continue
            letter, title, presets_cell = match.groups()
            found[letter] = (title, tuple(PRESET_TOKEN_RE.findall(presets_cell)))

        expected = {pack["id"]: (pack["title"], tuple(pack["presets"])) for pack in web.PACKS}
        self.assertEqual(
            set(found),
            set(expected),
            "the playbook must describe every workbench pack A-F",
        )
        for letter, (title, presets) in expected.items():
            doc_title, doc_presets = found[letter]
            self.assertEqual(doc_title, title, f"pack {letter} title drifted")
            # A heading either lists every preset or abbreviates a range as `F0`-`F3`.
            self.assertIn(
                doc_presets,
                (presets, (presets[0], presets[-1])),
                f"pack {letter} preset range drifted",
            )

    def test_preset_tables_match_expected_totals_and_clocks(self) -> None:
        checked = 0
        for heading, body in self.sections:
            pack = PACK_HEADING_RE.match(heading)
            pack_presets = _pack_presets(pack.group(1)) if pack else ()
            for header, rows in _tables(body):
                if not header or header[0] != "Preset":
                    continue
                for row in rows:
                    cells = dict(zip(header, row))
                    preset = cells["Preset"].strip("`")
                    with self.subTest(preset=preset, header=header):
                        self.assertIn(preset, EXPECTED_TOTALS)
                        if pack_presets:
                            self.assertIn(preset, pack_presets)
                        totals = EXPECTED_TOTALS[preset]
                        self.assertEqual(
                            cells["Clock"],
                            REFERENCE_CLOCKS[preset],
                            f"{preset} clock drifted",
                        )
                        self.assertEqual(
                            cells["Label"],
                            web.PRESET_LABELS[preset],
                            f"{preset} label drifted",
                        )
                        for column, field in TOTAL_INT_FIELDS.items():
                            if column not in cells:
                                continue
                            self.assertEqual(
                                int(cells[column]),
                                totals[field],
                                f"{preset} {column} drifted",
                            )
                        for column, field in TOTAL_MONEY_FIELDS.items():
                            if column not in cells:
                                continue
                            self.assertEqual(
                                _money(cells[column]),
                                totals[field],
                                f"{preset} {column} drifted",
                            )
                        checked += 1
        self.assertGreater(checked, 0, "no preset table found in the playbook")

    def test_unit_balance_tables_match_expected_balances(self) -> None:
        checked = 0
        for heading, body in self.sections:
            pack = PACK_HEADING_RE.match(heading)
            if pack is None:
                continue
            pack_presets = _pack_presets(pack.group(1))
            for header, rows in _tables(body):
                if not header or header[0] != "Unit":
                    continue
                fields = {
                    column: UNIT_FIELDS[column] for column in header if column in UNIT_FIELDS
                }
                with self.subTest(pack=pack.group(1), header=header):
                    self.assertTrue(fields, f"unmapped unit table header {header}")
                    matches = [
                        preset
                        for preset in pack_presets
                        if _unit_table_matches(preset, header, fields, rows)
                    ]
                    self.assertTrue(
                        matches,
                        "the unit table under pack "
                        f"{pack.group(1)} matches no preset in {pack_presets}; "
                        "the playbook copies are stale",
                    )
                checked += 1
        self.assertGreater(checked, 0, "no unit-balance table found in the playbook")

    def test_metric_tables_match_expected_totals(self) -> None:
        checked = 0
        for heading, body in self.sections:
            pack = PACK_HEADING_RE.match(heading)
            if pack is None:
                continue
            pack_presets = _pack_presets(pack.group(1))
            for header, rows in _tables(body):
                if header != ["Metric", "Value"]:
                    continue
                with self.subTest(pack=pack.group(1)):
                    self.assertEqual(
                        len(pack_presets),
                        1,
                        f"pack {pack.group(1)} must describe exactly one preset",
                    )
                    preset = pack_presets[0]
                    totals = EXPECTED_TOTALS[preset]
                    metrics = {row[0]: row[1] for row in rows}
                    self.assertIn("Reference clock", metrics)
                    for label, value in metrics.items():
                        field, kind = METRIC_FIELDS[label]
                        self._assert_metric(preset, totals, label, value, field, kind)
                    self._assert_capital_budget(preset, totals, metrics.get("Capital projects", ""))
                checked += 1
        self.assertGreater(checked, 0, "no metric table found in the playbook")

    def _assert_metric(
        self,
        preset: str,
        totals: dict[str, Any],
        label: str,
        value: str,
        field: str,
        kind: str,
    ) -> None:
        if kind == "clock":
            self.assertEqual(value, REFERENCE_CLOCKS[preset], f"{preset} clock drifted")
            return
        if kind == "int":
            self.assertEqual(_ints(value)[0], totals[field], f"{preset} {label} drifted")
            return
        if kind == "money":
            self.assertEqual(_money(value), totals[field], f"{preset} {label} drifted")
            return
        parts = [_money(part) for part in value.split("/")]
        self.assertEqual(len(parts), 2, f"{preset} {label} needs two amounts")
        if kind == "int_pair":
            self.assertEqual(
                parts,
                [Decimal(totals["liabilities"]), Decimal(totals["receipts"])],
                f"{preset} {label} drifted",
            )
            return
        self.assertEqual(
            parts,
            [totals["overdue"], totals["advance"]],
            f"{preset} {label} drifted",
        )

    def _assert_capital_budget(
        self,
        preset: str,
        totals: dict[str, Any],
        cell: str,
    ) -> None:
        if "budget" not in cell:
            return
        self.assertIn("capital_budget", totals, f"{preset} has no capital budget")
        budget = cell.split("budget", 1)[1]
        self.assertEqual(_money(budget), totals["capital_budget"], f"{preset} budget drifted")


def _unit_table_matches(
    preset: str,
    header: list[str],
    fields: dict[str, str],
    rows: list[list[str]],
) -> bool:
    units = {unit["unit"]: unit for unit in EXPECTED_UNIT_BALANCES[preset]}
    if len(units) != len(rows):
        return False
    columns = {field: header.index(column) for column, field in fields.items()}
    for row in rows:
        unit = units.get(row[0].strip("`"))
        if unit is None:
            return False
        for field, position in columns.items():
            expected = unit.get(field)
            if expected is None or _money(row[position]) != Decimal(str(expected)):
                return False
    return True


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
