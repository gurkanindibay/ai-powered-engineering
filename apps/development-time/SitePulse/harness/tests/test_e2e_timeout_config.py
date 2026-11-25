"""The E2E suite keeps its per-test timeout, so one hung browser call cannot stall a job."""
from __future__ import annotations

import configparser
import unittest
from pathlib import Path

E2E = Path(__file__).resolve().parents[2] / "e2e"
# The slowest real E2E test takes about 85 s; a limit this far below it would kill healthy tests.
MIN_SECONDS = 120
# A limit this far above it would let a hang hold the job for most of the 90-minute job limit.
MAX_SECONDS = 900


class E2ETimeoutConfigTest(unittest.TestCase):
    def setUp(self) -> None:
        self.config = configparser.ConfigParser()
        self.config.read(E2E / "pytest.ini")
        self.section = self.config["pytest"]

    def test_per_test_timeout_is_set_in_a_sane_range(self) -> None:
        seconds = float(self.section["timeout"])
        self.assertGreaterEqual(seconds, MIN_SECONDS)
        self.assertLessEqual(seconds, MAX_SECONDS)

    def test_signal_method_lets_the_run_continue_after_a_timeout(self) -> None:
        # `thread` aborts the whole pytest process on the first timeout.
        self.assertEqual(self.section["timeout_method"].strip(), "signal")

    def test_timeout_covers_the_test_body_not_the_session_stack_setup(self) -> None:
        # The first test's setup builds and starts the whole stack, which can exceed the limit.
        self.assertEqual(self.section["timeout_func_only"].strip().lower(), "true")

    def test_missing_timeout_plugin_fails_at_startup(self) -> None:
        # Without the plugin, pytest only warns about the unknown `timeout` option and runs unlimited.
        required = self.section["required_plugins"].strip()
        self.assertRegex(required, r"^pytest-timeout>=\d+(\.\d+)*$")


if __name__ == "__main__":
    unittest.main()
