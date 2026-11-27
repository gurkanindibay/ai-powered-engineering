"""Provider quotas, pricing tables, and decimal calculations."""
from __future__ import annotations

import json
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from pathlib import Path
import re
from typing import Any, Dict, Optional, Tuple

DEFAULT_CONFIG_PATH = Path(__file__).resolve().parents[2] / "config" / "provider-quotas.json"

MODEL_PATTERNS = [
    (r"claude.*opus", "claude-opus"),
    (r"claude.*sonnet", "claude-sonnet"),
    (r"claude.*haiku", "claude-haiku"),
    (r"gpt.*astra", "gpt-astra"),
    (r"gpt.*sol", "gpt-sol"),
    (r"gpt-4o", "gpt-sol"),
    (r"gemini.*ultra", "gemini-ultra"),
    (r"gemini.*pro", "gemini-pro"),
    (r"gemini.*flash", "gemini-flash"),
    (r"deepseek", "deepseek"),
]


def money(value: Any) -> Decimal:
    """Parse nonnegative finite decimal values without binary floating point."""
    if isinstance(value, bool):
        raise ValueError("Boolean cannot be a decimal money value")
    if isinstance(value, float):
        raise ValueError("Floats are prohibited for money; use string or Decimal per Rule 2")
    try:
        result = Decimal(str(value).strip())
    except (InvalidOperation, TypeError, ValueError) as exc:
        raise ValueError(f"Invalid decimal amount: {value}") from exc
    if not result.is_finite() or result < 0:
        raise ValueError(f"Amount must be finite and nonnegative: {result}")
    return result


def decimal_str(d: Decimal, places: int = 6) -> str:
    """Format decimal without scientific notation and with bounded precision."""
    q = Decimal("10") ** -places
    return str(d.quantize(q, rounding=ROUND_HALF_UP))


class QuotaConfig:
    def __init__(self, path: Optional[Path] = None):
        self.path = Path(path or DEFAULT_CONFIG_PATH).resolve()
        self.data: Dict[str, Any] = {}
        self.load()

    def load(self) -> None:
        if not self.path.exists():
            raise FileNotFoundError(f"Provider quotas config not found at: {self.path}")
        with open(self.path, "r", encoding="utf-8") as f:
            self.data = json.load(f)

    def resolve_model_family(self, model: str) -> str:
        norm = re.sub(r"[\s._/]+", "-", model.strip().lower())
        for pattern, family in MODEL_PATTERNS:
            if re.search(pattern, norm):
                return family
        return "default"

    def get_pricing(self, model: str) -> Dict[str, Decimal]:
        pricing_table = self.data.get("pricing", {})
        family = self.resolve_model_family(model)
        p = pricing_table.get(family, pricing_table.get("default", {
            "input_per_million": "3.00",
            "output_per_million": "15.00",
            "cache_read_per_million": "0.30",
            "cache_write_per_million": "3.75"
        }))
        return {
            "input_per_million": money(p.get("input_per_million", "3.00")),
            "output_per_million": money(p.get("output_per_million", "15.00")),
            "cache_read_per_million": money(p.get("cache_read_per_million", "0.30")),
            "cache_write_per_million": money(p.get("cache_write_per_million", "3.75")),
        }

    def calculate_cost(
        self,
        model: str,
        input_tokens: int = 0,
        output_tokens: int = 0,
        cache_read_tokens: int = 0,
        cache_write_tokens: int = 0,
    ) -> str:
        """Calculate USD cost as Decimal string."""
        rates = self.get_pricing(model)
        one_million = Decimal("1000000")
        cost = (
            (Decimal(input_tokens) * rates["input_per_million"]) +
            (Decimal(output_tokens) * rates["output_per_million"]) +
            (Decimal(cache_read_tokens) * rates["cache_read_per_million"]) +
            (Decimal(cache_write_tokens) * rates["cache_write_per_million"])
        ) / one_million
        return decimal_str(cost, places=6)

    def get_copilot_multiplier(self, model: str) -> Decimal:
        copilot_cfg = self.data.get("quotas", {}).get("copilot", {})
        multipliers = copilot_cfg.get("premium_request_multipliers", {})
        norm = model.strip().lower()
        sorted_keys = sorted(multipliers.keys(), key=len, reverse=True)
        for k in sorted_keys:
            if k == "default":
                continue
            if k in norm:
                return money(multipliers[k])
        return money(multipliers.get("default", "1.0"))

    def get_quota(self, provider: str) -> Dict[str, Any]:
        return self.data.get("quotas", {}).get(provider.lower(), {})
