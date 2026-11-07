"""Self-tests for scripts/ui_style_lint.py: design-system rules from the UX report."""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "ui_style_lint.py"
spec = importlib.util.spec_from_file_location("ui_style_lint", SCRIPT)
ui_style_lint = importlib.util.module_from_spec(spec)
sys.modules["ui_style_lint"] = ui_style_lint
spec.loader.exec_module(ui_style_lint)


def _lint(files: dict[str, str], baseline: dict | None = None) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        ui = Path(tmp) / "ui"
        for rel, source in files.items():
            path = ui / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source, encoding="utf-8")
        base = None
        if baseline is not None:
            base = Path(tmp) / "baseline.json"
            base.write_text(json.dumps(baseline), encoding="utf-8")
        return ui_style_lint.lint(ui, base)


def _rules(report: dict) -> list[str]:
    return [f["rule"] for f in report["findings"]]


class UiStyleLintTests(unittest.TestCase):
    def test_font_below_floor_is_reported(self):
        report = _lint({"a.dart": "final s = TextStyle(fontSize: 11); final n = BottomNavigationBar(selectedFontSize: 10);"})
        self.assertEqual(_rules(report), ["font-floor", "font-floor"])
        self.assertFalse(report["passed"])

    def test_font_at_floor_passes(self):
        report = _lint({"a.dart": "final s = TextStyle(fontSize: 12); final t = TextStyle(fontSize: 12.5);"})
        self.assertTrue(report["passed"], report)

    def test_hand_printed_money_is_reported(self):
        report = _lint({"a.dart": "Text('₺${x.toStringAsFixed(2)}'); Text('₺$amount'); Text('Toplam ₺${a.b}');"})
        self.assertEqual(_rules(report), ["money-format"] * 3)

    def test_money_formatter_passes(self):
        report = _lint({"a.dart": "Text(formatTry(x)); Text('+${formatTry(y)} avans'); Text('Tutar (₺)');"})
        self.assertTrue(report["passed"], report)

    def test_emoji_in_string_is_reported_but_not_in_comments(self):
        report = _lint({"a.dart": "// 🏠 legacy comment\nfinal l = '🏠 Kat Maliki';"})
        self.assertEqual(_rules(report), ["emoji-icon"])
        self.assertEqual(report["findings"][0]["line"], 2)

    def test_stand_in_google_icon_is_reported(self):
        report = _lint({"a.dart": "final i = Icon(Icons.g_mobiledata);"})
        self.assertEqual(_rules(report), ["stand-in-icon"])

    def test_ratchet_blocks_new_literals_outside_theme(self):
        files = {
            "screen.dart": "final a = TextStyle(fontSize: 14, color: Color(0xFF112233));",
            "theme/app_theme.dart": "final b = TextStyle(fontSize: 14, color: Color(0xFF112233));",
        }
        report = _lint(files, {"literal-font-size": 0, "raw-color": 1})
        self.assertEqual(report["counts"], {"literal-font-size": 1, "raw-color": 1})
        self.assertEqual([r["rule"] for r in report["ratchet_exceeded"]], ["literal-font-size"])
        self.assertFalse(report["passed"])

    def test_without_baseline_counts_are_reported_only(self):
        report = _lint({"screen.dart": "final a = TextStyle(fontSize: 14);"})
        self.assertTrue(report["passed"], report)

    def test_real_ui_passes_with_committed_baseline(self):
        report = ui_style_lint.lint(ui_style_lint.DEFAULT_UI, ui_style_lint.DEFAULT_BASELINE)
        self.assertTrue(report["passed"], (report["findings"][:5], report["ratchet_exceeded"]))


if __name__ == "__main__":
    unittest.main()
