"""Self-tests for scripts/flutter_reuse_inventory.py: reuse inventory and guard rules."""
import contextlib
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "flutter_reuse_inventory.py"
spec = importlib.util.spec_from_file_location("flutter_reuse_inventory", SCRIPT)
inventory = importlib.util.module_from_spec(spec)
sys.modules["flutter_reuse_inventory"] = inventory
spec.loader.exec_module(inventory)


def _scan(files: dict[str, str]) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        lib = Path(tmp) / "lib"
        for rel, source in files.items():
            path = lib / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source, encoding="utf-8")
        return inventory.scan(lib)


def _rules(report: dict) -> list[str]:
    return [f["rule"] for f in report["findings"]]


class FlutterReuseInventoryTests(unittest.TestCase):
    def test_counts_token_adoption_in_ui_only(self):
        report = _scan({
            "ui/a.dart": "final p = EdgeInsets.all(AppSpacing.md); final q = EdgeInsets.zero;",
            "domain/b.dart": "final p = EdgeInsets.all(1);",
        })
        self.assertEqual(report["inventory"]["EdgeInsets."], {"occurrences": 2, "files": 1})
        self.assertEqual(report["inventory"]["AppSpacing."], {"occurrences": 1, "files": 1})
        self.assertTrue(report["passed"])

    def test_clipboard_outside_helper_is_reported(self):
        report = _scan({
            "ui/components/card.dart": "Clipboard.setData(ClipboardData(text: iban));",
            "ui/design_system/sp_clipboard.dart": "await Clipboard.setData(ClipboardData(text: text));",
        })
        self.assertEqual(_rules(report), ["clipboard"])
        self.assertEqual(report["findings"][0]["file"], "ui/components/card.dart")

    def test_money_parse_in_ui_but_not_domain(self):
        report = _scan({
            "ui/form.dart": "final v = Decimal.tryParse(ctrl.text);",
            "domain/money.dart": "final v = Decimal.tryParse(text);",
        })
        self.assertEqual(_rules(report), ["money-parse"])

    def test_json_decimal_fallback_and_bank_amount_normalisation(self):
        report = _scan({
            "domain/models.dart": (
                "final a = Decimal.tryParse(json['amount']?.toString() ?? '0') ?? Decimal.zero;\n"
                "final b = raw.replaceAll('.', '').replaceAll(',', '.');\n"
            ),
        })
        self.assertEqual(sorted(_rules(report)), ["bank-amount", "json-decimal"])

    def test_raw_chip_selection_page_and_snackbar_are_reported(self):
        report = _scan({
            "ui/screen.dart": (
                "final c = FilterChip(label: l, onSelected: f);\n"
                "final p = SpSelectionPage(children: c);\n"
                "final s = SnackBar(content: t);\n"
                "final ok = SpFilterChip(label: l); final ok2 = spSnackBar(kind: k); final ok3 = showSnackBar(x);\n"
            ),
            "ui/design_system/sp_filter_chip.dart": "final c = FilterChip(label: l);",
            "ui/components/sp_dialog_pages.dart": "builder: (ctx) => SpSelectionPage(children: c),",
            "ui/design_system/sp_feedback.dart": "return SnackBar(content: c);",
        })
        self.assertEqual(_rules(report), ["filter-chip", "selection-page", "raw-snackbar"])

    def test_comments_are_ignored(self):
        report = _scan({"ui/a.dart": "// Clipboard.setData(x)\n/* Decimal.tryParse(y) */\nfinal ok = 1;"})
        self.assertTrue(report["passed"])

    def test_check_flag_sets_exit_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            lib = Path(tmp) / "lib" / "ui"
            lib.mkdir(parents=True)
            (lib / "a.dart").write_text("Clipboard.setData(x);", encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(inventory.main(["--lib", str(lib.parent), "--json"]), 0)
                self.assertEqual(inventory.main(["--lib", str(lib.parent), "--check", "--json"]), 1)


if __name__ == "__main__":
    unittest.main()
