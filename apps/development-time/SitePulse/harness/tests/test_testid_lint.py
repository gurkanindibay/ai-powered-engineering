"""Self-tests for scripts/testid_lint.py: it must fail on a Key without a matching testId."""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "testid_lint.py"
spec = importlib.util.spec_from_file_location("testid_lint", SCRIPT)
testid_lint = importlib.util.module_from_spec(spec)
sys.modules["testid_lint"] = testid_lint
spec.loader.exec_module(testid_lint)


def _lint(dart_source: str) -> dict:
    with tempfile.TemporaryDirectory(dir=testid_lint.ROOT) as tmp:
        ui = Path(tmp)
        (ui / "screen.dart").write_text(dart_source, encoding="utf-8")
        return testid_lint.lint(ui)


class TestIdLintTests(unittest.TestCase):
    def test_key_without_testid_is_reported(self):
        report = _lint("Widget b() => ElevatedButton(key: const Key('btn_save'), onPressed: null, child: x);")
        self.assertFalse(report["passed"])
        self.assertEqual([f["key"] for f in report["missing"]], ["btn_save"])

    def test_matching_testid_passes_including_interpolation(self):
        report = _lint("Widget b() => testId('row_${item.id}', InkWell(key: Key('row_${item.id}'), child: x));")
        self.assertTrue(report["passed"], report)
        self.assertEqual(report["checked"], 1)

    def test_quote_style_does_not_matter(self):
        report = _lint('Widget b() => testId("btn_x", TextButton(key: const Key(\'btn_x\'), child: y));')
        self.assertTrue(report["passed"], report)

    def test_unwrappable_constructor_is_skipped(self):
        report = _lint("final items = [DropdownMenuItem(key: const Key('opt_a'), value: 1, child: x)];")
        self.assertTrue(report["passed"], report)
        self.assertEqual([f["key"] for f in report["skipped"]], ["opt_a"])

    def test_ignore_pragma_exempts_state_keys(self):
        report = _lint("// testid-lint: ignore\nfinal s = SingleChildScrollView(key: Key('scroll_$i'), child: x);")
        self.assertTrue(report["passed"], report)

    def test_variable_and_global_keys_are_not_ids(self):
        report = _lint("final a = Form(key: _formKey, child: x); final b = Container(key: Key(id));")
        self.assertEqual(report["checked"], 0)

    def test_real_ui_has_no_missing_testids(self):
        report = testid_lint.lint(testid_lint.DEFAULT_UI)
        self.assertTrue(report["passed"], report["missing"][:5])


if __name__ == "__main__":
    unittest.main()
