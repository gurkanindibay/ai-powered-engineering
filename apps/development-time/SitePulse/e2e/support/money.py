"""Exact money handling for GUI assertions: never float."""
from __future__ import annotations

import re
from decimal import Decimal

_AMOUNT = re.compile(r"[+-]?\s*₺?\s*[0-9][0-9.]*(?:,[0-9]{1,2})?")


def parse_try(text: str) -> Decimal:
    """Parse a Turkish-formatted amount shown on screen, e.g. '₺1.423,33', '+₺1.460,67'.

    Dots are thousands separators and the comma is the decimal separator.
    Raises ValueError when no amount is present.
    """
    match = _AMOUNT.search(text.replace(" ", " "))
    if not match:
        raise ValueError(f"no TRY amount in {text!r}")
    raw = match.group(0).replace("₺", "").replace(" ", "")
    sign = -1 if raw.startswith("-") else 1
    raw = raw.lstrip("+-").replace(".", "").replace(",", ".")
    return sign * Decimal(raw).quantize(Decimal("0.01"))


def last_amount(text: str) -> Decimal:
    """The amount after the last '₺' in a label, e.g. 'Toplam Pay: ₺285.714,29' -> Decimal('285714.29')."""
    if "₺" not in text:
        raise ValueError(f"no TRY amount in {text!r}")
    return parse_try("₺" + text.rsplit("₺", 1)[1])


def api_amount(value: object) -> Decimal:
    """Backend amounts arrive as strings ("1400.00"); quantize to kuruş."""
    return Decimal(str(value)).quantize(Decimal("0.01"))


def format_try(value: Decimal) -> str:
    """Format like the app: '₺1.423,33'."""
    q = value.quantize(Decimal("0.01"))
    sign = "-" if q < 0 else ""
    integer, _, frac = f"{abs(q):.2f}".partition(".")
    groups = []
    while integer:
        groups.insert(0, integer[-3:])
        integer = integer[:-3]
    return f"{sign}₺{'.'.join(groups)},{frac}"
