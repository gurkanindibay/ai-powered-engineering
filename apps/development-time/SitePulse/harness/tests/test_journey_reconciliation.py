"""Self-test for the fixture-derived journey reconciliation model (issue #250)."""
from __future__ import annotations

import sys
import unittest
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "e2e"))

from support.journey_reconciliation import reconcile  # noqa: E402


class JourneyReconciliationTest(unittest.TestCase):
    def test_final_checkpoint(self) -> None:
        ledger = reconcile()
        a, b = ledger.site_totals("A"), ledger.site_totals("B")
        self.assertEqual(a["cash"], Decimal("90658.50"))
        self.assertEqual(a["total_debt_open"], Decimal("5804.09"))
        self.assertEqual(b["cash"], Decimal("189538.75"))
        self.assertEqual(b["total_debt_open"], Decimal("2661.67"))
        self.assertEqual(len(ledger.open_rows()), 11)
        self.assertEqual(ledger.joint_exposure("Cara"), Decimal("1223.75"))


if __name__ == "__main__":
    unittest.main()
