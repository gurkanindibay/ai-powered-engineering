"""The E2E run shares one frozen date, so a run crossing the site's midnight keeps stable figures."""
from __future__ import annotations

import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "e2e"))

from support.fixture_clock import NOW_ENV, fixture_instant, site_local_date  # noqa: E402

BEFORE_MIDNIGHT = datetime(2026, 11, 24, 20, 59, 48, tzinfo=timezone.utc)  # 23:59:48 in Istanbul (UTC+3)


class FixtureClockTests(unittest.TestCase):
    def test_run_starting_before_site_midnight_keeps_one_date(self) -> None:
        pinned = fixture_instant(BEFORE_MIDNIGHT, {})
        self.assertEqual(site_local_date(pinned).isoformat(), "2026-11-24")
        # The wall clock reaches the next site day 12 seconds later; the frozen date does not move.
        self.assertEqual(site_local_date(BEFORE_MIDNIGHT + timedelta(seconds=12)).isoformat(), "2026-11-25")
        self.assertEqual(fixture_instant(BEFORE_MIDNIGHT + timedelta(seconds=12), {}).day, 25)  # a later run

    def test_pinned_instant_is_far_from_both_site_midnights(self) -> None:
        for start in (BEFORE_MIDNIGHT, BEFORE_MIDNIGHT + timedelta(hours=5), BEFORE_MIDNIGHT - timedelta(hours=20)):
            pinned = fixture_instant(start, {})
            self.assertEqual(site_local_date(pinned - timedelta(hours=6)), site_local_date(pinned))
            self.assertEqual(site_local_date(pinned + timedelta(hours=6)), site_local_date(pinned))

    def test_env_override_replaces_the_wall_clock(self) -> None:
        pinned = fixture_instant(BEFORE_MIDNIGHT, {NOW_ENV: "2026-11-24T20:59:48Z"})
        self.assertEqual(pinned, datetime(2026, 11, 24, 9, tzinfo=timezone.utc))

    def test_env_override_requires_an_offset(self) -> None:
        with self.assertRaises(ValueError):
            fixture_instant(BEFORE_MIDNIGHT, {NOW_ENV: "2026-11-24T20:59:48"})


if __name__ == "__main__":
    unittest.main()
