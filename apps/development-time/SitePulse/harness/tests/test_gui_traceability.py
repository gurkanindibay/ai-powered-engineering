"""Self-tests for scripts/gui_traceability.py and the story → GUI scenario catalogue."""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "gui_traceability.py"
spec = importlib.util.spec_from_file_location("gui_traceability", SCRIPT)
gt = importlib.util.module_from_spec(spec)
sys.modules["gui_traceability"] = gt
spec.loader.exec_module(gt)

JUNIT = """<?xml version="1.0"?><testsuites><testsuite>
<testcase classname="tests.test_a" name="test_ok"><properties><property name="gui_ids" value="GUI-06-01"/></properties></testcase>
<testcase classname="tests.test_b" name="test_bug"><properties><property name="gui_ids" value="GUI-07-03"/></properties>
  <skipped type="pytest.xfail" message="BUG"/></testcase>
<testcase classname="tests.test_c" name="test_broken"><properties><property name="gui_ids" value="GUI-08-01"/></properties>
  <failure message="boom"/></testcase>
</testsuite></testsuites>"""


class GuiTraceabilityTests(unittest.TestCase):
    def test_every_story_has_a_scenario_or_a_written_exclusion(self):
        report = gt.build(Path("/nonexistent/junit.xml"))
        self.assertEqual(report["counts"]["MISSING"], 0,
                         [r["story"] for r in report["rows"] if r["status"] == "MISSING"])
        self.assertGreaterEqual(report["stories"], 62)

    def test_outcomes_map_to_story_status(self):
        with tempfile.NamedTemporaryFile("w", suffix=".xml", delete=False) as f:
            f.write(JUNIT)
        rows = {r["story"]: r for r in gt.build(Path(f.name))["rows"]}
        self.assertEqual(rows["STORY-06-02"]["status"], "PASS")      # GUI-06-01 covers 06-02
        self.assertEqual(rows["STORY-07-02"]["status"], "DEFECT")    # GUI-07-03 is a strict xfail
        self.assertEqual(rows["STORY-08-04"]["status"], "FAIL")      # GUI-08-01 failed
        self.assertEqual(rows["STORY-05-01"]["status"], "EXCLUDED")
        self.assertEqual(rows["STORY-04-03"]["status"], "GAP")

    def test_markdown_section_is_delimited(self):
        text = gt.markdown(gt.build(Path("/nonexistent/junit.xml")))
        self.assertTrue(text.startswith(gt.BEGIN) and text.endswith(gt.END))


if __name__ == "__main__":
    unittest.main()
