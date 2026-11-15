import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from harness.loop.verification_gates import CommandSpec, run_command  # noqa: E402


class GateCacheTest(unittest.TestCase):
    def test_pass_is_reused_and_failure_is_not(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {"SITEPULSE_GATE_CACHE_DIR": tmp}):
            marker = Path(tmp) / "runs.txt"
            ok = CommandSpec([sys.executable, "-c", f"open({str(marker)!r}, 'a').write('x')"], ".")
            self.assertTrue(run_command("g", ok, ROOT).passed)
            self.assertTrue(run_command("g", ok, ROOT).passed)
            self.assertEqual(marker.read_text(), "x")
            bad = CommandSpec([sys.executable, "-c", "raise SystemExit(1)"], ".")
            self.assertFalse(run_command("g", bad, ROOT).passed)
            self.assertFalse(run_command("g", bad, ROOT).passed)

    def test_disabled_without_env(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("SITEPULSE_GATE_CACHE_DIR", None)
            marker = Path(tmp) / "runs.txt"
            spec = CommandSpec([sys.executable, "-c", f"open({str(marker)!r}, 'a').write('x')"], ".")
            run_command("g", spec, ROOT)
            run_command("g", spec, ROOT)
            self.assertEqual(marker.read_text(), "xx")


if __name__ == "__main__":
    unittest.main()
