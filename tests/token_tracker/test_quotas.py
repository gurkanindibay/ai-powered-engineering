"""Unit tests for QuotaConfig and Decimal financial arithmetic."""
from __future__ import annotations

from decimal import Decimal
import unittest

from scripts.token_tracker.quotas import QuotaConfig, money, decimal_str


class TestQuotasAndDecimalMath(unittest.TestCase):
    def setUp(self):
        self.config = QuotaConfig()

    def test_money_helper_rejects_floats_and_booleans(self):
        with self.assertRaises(ValueError):
            money(12.34)  # Prohibited float
        with self.assertRaises(ValueError):
            money(True)   # Prohibited bool
        with self.assertRaises(ValueError):
            money("-5.00")  # Prohibited negative

        # Valid string or int
        self.assertEqual(money("12.34"), Decimal("12.34"))
        self.assertEqual(money(100), Decimal("100"))

    def test_model_family_resolution(self):
        self.assertEqual(self.config.resolve_model_family("claude-sonnet-5-5"), "claude-sonnet")
        self.assertEqual(self.config.resolve_model_family("Claude Opus 4"), "claude-opus")
        self.assertEqual(self.config.resolve_model_family("gpt-6-2-sol"), "gpt-sol")
        self.assertEqual(self.config.resolve_model_family("gpt-astra"), "gpt-astra")
        self.assertEqual(self.config.resolve_model_family("gemini-3-8-flash"), "gemini-flash")
        self.assertEqual(self.config.resolve_model_family("deepseek-v3"), "deepseek")
        self.assertEqual(self.config.resolve_model_family("unknown-model"), "default")

    def test_cost_calculation_is_exact_decimal(self):
        # claude-sonnet: input 3.00/M, output 15.00/M, cache read 0.30/M, cache write 3.75/M
        # 100,000 input = 0.30 USD
        # 10,000 output = 0.15 USD
        # total = 0.45 USD
        cost_str = self.config.calculate_cost(
            model="claude-sonnet-5-5",
            input_tokens=100000,
            output_tokens=10000,
            cache_read_tokens=0,
            cache_write_tokens=0,
        )
        self.assertEqual(Decimal(cost_str), Decimal("0.450000"))

    def test_copilot_multipliers(self):
        self.assertEqual(self.config.get_copilot_multiplier("o1"), Decimal("3.0"))
        self.assertEqual(self.config.get_copilot_multiplier("o1-mini"), Decimal("0.33"))
        self.assertEqual(self.config.get_copilot_multiplier("gpt-4o"), Decimal("1.0"))
        self.assertEqual(self.config.get_copilot_multiplier("deepseek-v3"), Decimal("0.0"))


if __name__ == "__main__":
    unittest.main()
