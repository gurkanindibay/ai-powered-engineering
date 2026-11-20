"""Independent, fixture-derived reconciliation model of the zero-to-multi-site journey (issue #250).

The journey analysis (docs/testing/journey-plan/zero-to-multi-site-financial-journey.md) defines two sites,
four monthly accruals and a payment timeline. This module recomputes accrued, collected and open principal,
collected and open fees, posted operating cash and the open receivable rows from those fixture inputs alone,
so a system under test can be compared with values that never came from the system itself.

It uses no product code and no network. Money is `Decimal` and every amount is rounded half-up to two places.
Late fee rule: 5% per 30 days on outstanding principal, zero grace days, rounded per segment. A segment ends
whenever the same debtor posts a payment on the same unit. The default waterfall pays accrued fees first and
then principal oldest period first, within one debtor and unit. A designated payment settles only its own charge.

Until the onboarding (#247) and history (#248) fixtures are on master this is the minimum local stand-in: it
describes the 88 units and every payment, and it counts a jointly liable receivable once.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date
from decimal import ROUND_HALF_UP, Decimal

CENT = Decimal("0.01")
FEE_RATE = Decimal("0.05")
FEE_DAYS = Decimal("30")
TIMEZONE = "Europe/Istanbul"
AS_OF = date(2027, 4, 10)
PERIODS = ("January", "February", "March", "April")
DUE_DATES = {name: date(2027, month, 10) for month, name in enumerate(PERIODS, start=1)}

TARIFF = {"A": Decimal("1000.00"), "B": Decimal("750.00")}
SITE_BLOCKS = {"A": {"A": 24}, "B": {"B1": 32, "B2": 32}}


def money(value: Decimal) -> Decimal:
    return value.quantize(CENT, rounding=ROUND_HALF_UP)


def unit_labels(site: str) -> list[str]:
    return [f"{block}-{n:02d}" for block, count in SITE_BLOCKS[site].items() for n in range(1, count + 1)]


@dataclass
class Charge:
    site: str
    unit: str
    period: str
    debtor: str
    principal: Decimal
    joint_owner: str | None = None
    open_principal: Decimal = Decimal("0.00")
    fee_accrued: Decimal = Decimal("0.00")
    fee_paid: Decimal = Decimal("0.00")
    paid_principal: Decimal = Decimal("0.00")
    fee_from: date | None = None

    def __post_init__(self) -> None:
        self.open_principal = self.principal
        self.fee_from = DUE_DATES[self.period]

    @property
    def open_fee(self) -> Decimal:
        return self.fee_accrued - self.fee_paid

    @property
    def status(self) -> str:
        if self.open_principal == 0 and self.open_fee == 0:
            return "Paid"
        return "Partial" if self.paid_principal > 0 else "Unpaid"

    def accrue_fee(self, until: date) -> None:
        start = self.fee_from
        if until > start and self.open_principal > 0:
            days = Decimal((until - start).days)
            self.fee_accrued += money(self.open_principal * FEE_RATE * days / FEE_DAYS)
        if until > start:
            self.fee_from = until


@dataclass(frozen=True)
class Payment:
    site: str
    unit: str
    payer: str
    on: date
    amount: Decimal
    designated_period: str | None = None


@dataclass
class Row:
    site: str
    unit: str
    debtor: str
    period: str
    principal: Decimal
    fee: Decimal
    joint_owner: str | None

    @property
    def total(self) -> Decimal:
        return self.principal + self.fee


def _d(text: str) -> Decimal:
    return Decimal(text)


# unit -> (period -> (primary debtor, jointly liable owner)).
DETAILED_DEBTORS: dict[tuple[str, str], dict[str, tuple[str, str | None]]] = {
    ("A", "A-01"): {"January": ("Ada", None), "February": ("Ada", None), "March": ("Ben", None), "April": ("Ben", None)},
    ("A", "A-02"): {"January": ("Dan", "Cara"), "February": ("Dan", "Cara"), "March": ("Cara", None), "April": ("Eli", "Cara")},
    ("A", "A-03"): {p: ("Fay", None) for p in PERIODS},
    ("B", "B1-01"): {"January": ("Gus", None), "February": ("Gus", None), "March": ("Hana", None), "April": ("Hana", None)},
    ("B", "B2-01"): {p: ("Juno", "Ivan") for p in PERIODS},
}

# (site, unit, payer, ISO date, amount, designated period)
DETAILED_PAYMENTS: list[tuple[str, str, str, str, str, str | None]] = [
    ("A", "A-01", "Ada", "2027-01-10", "400.00", None),
    ("A", "A-01", "Ada", "2027-02-10", "831.00", None),
    ("A", "A-01", "Ben", "2027-03-10", "500.00", None),
    ("A", "A-01", "Ben", "2027-04-10", "1025.83", None),
    ("A", "A-02", "Dan", "2027-02-10", "1301.67", None),
    ("A", "A-02", "Eli", "2027-04-10", "600.00", None),
    ("A", "A-03", "Fay", "2027-01-10", "1000.00", None),
    ("A", "A-03", "Fay", "2027-04-10", "1000.00", "April"),
    ("B", "B1-01", "Gus", "2027-01-10", "750.00", None),
    ("B", "B1-01", "Gus", "2027-02-10", "250.00", None),
    ("B", "B1-01", "Hana", "2027-04-10", "1038.75", None),
    ("B", "B2-01", "Juno", "2027-01-10", "750.00", None),
    ("B", "B2-01", "Juno", "2027-04-10", "750.00", "April"),
]


def fixture_charges() -> list[Charge]:
    """88 units x 4 periods: five detailed units plus a distinct owner-occupant in every other unit."""
    charges: list[Charge] = []
    for site in ("A", "B"):
        for unit in unit_labels(site):
            detail = DETAILED_DEBTORS.get((site, unit))
            for period in PERIODS:
                debtor, joint = detail[period] if detail else (f"Owner {unit}", None)
                charges.append(Charge(site, unit, period, debtor, TARIFF[site], joint))
    return charges


def fixture_payments() -> list[Payment]:
    detailed = {(s, u) for s, u, *_ in DETAILED_PAYMENTS}
    payments = [Payment(s, u, p, date.fromisoformat(d), _d(a), per) for s, u, p, d, a, per in DETAILED_PAYMENTS]
    for site in ("A", "B"):
        for unit in unit_labels(site):
            if (site, unit) in detailed:
                continue
            payments += [Payment(site, unit, f"Owner {unit}", due, TARIFF[site]) for due in DUE_DATES.values()]
    return sorted(payments, key=lambda p: (p.on, p.site, p.unit))


@dataclass
class Ledger:
    as_of: date
    charges: list[Charge]
    payments: list[Payment]
    cash: dict[str, Decimal] = field(default_factory=lambda: {"A": Decimal("0.00"), "B": Decimal("0.00")})
    allocations: list[tuple[Payment, Charge, str, Decimal]] = field(default_factory=list)

    def _apply(self, payment: Payment) -> None:
        """Apply one receipt. Fees are accrued up to the receipt date on every due charge of the
        payer, including charges whose principal the receipt does not touch. That splits a segment
        of unchanged principal into two roundings, which can differ from the product (one rounding
        per segment) by a cent on other fixture data; the approved fixture is unaffected."""
        own = [c for c in self.charges if (c.site, c.unit, c.debtor) == (payment.site, payment.unit, payment.payer)]
        due = [c for c in own if DUE_DATES[c.period] <= payment.on]
        if payment.designated_period:
            targets = [c for c in due if c.period == payment.designated_period]
        else:
            targets = sorted(due, key=lambda c: DUE_DATES[c.period])
        for charge in targets:
            charge.accrue_fee(payment.on)
        remaining = payment.amount
        self.cash[payment.site] += payment.amount
        for charge in targets:  # fees first, then principal oldest first
            fee = min(remaining, charge.open_fee)
            if fee > 0:
                charge.fee_paid += fee
                remaining -= fee
                self.allocations.append((payment, charge, "fee", fee))
        for charge in targets:
            principal = min(remaining, charge.open_principal)
            if principal > 0:
                charge.open_principal -= principal
                charge.paid_principal += principal
                remaining -= principal
                self.allocations.append((payment, charge, "principal", principal))
        if remaining != 0:
            raise ValueError(f"unallocated {remaining} from {payment}")

    def run(self) -> "Ledger":
        accrued = [c for c in self.charges if _accrual_day(c.period) <= self.as_of]
        self.charges = accrued
        for payment in sorted(self.payments, key=lambda p: (p.on, p.site, p.unit)):
            if payment.on <= self.as_of:
                self._apply(payment)
        for charge in self.charges:
            charge.accrue_fee(self.as_of)
        return self

    def open_rows(self) -> list[Row]:
        return [
            Row(c.site, c.unit, c.debtor, c.period, c.open_principal, c.open_fee, c.joint_owner)
            for c in self.charges
            if c.open_principal > 0 or c.open_fee > 0
        ]

    def site_totals(self, site: str) -> dict[str, Decimal]:
        """Each charge is one receivable: a jointly liable owner adds exposure, never a second row."""
        charges = [c for c in self.charges if c.site == site]
        return {
            "principal_accrued": sum((c.principal for c in charges), Decimal("0.00")),
            "principal_collected": sum((c.paid_principal for c in charges), Decimal("0.00")),
            "principal_open": sum((c.open_principal for c in charges), Decimal("0.00")),
            "fees_collected": sum((c.fee_paid for c in charges), Decimal("0.00")),
            "fees_open": sum((c.open_fee for c in charges), Decimal("0.00")),
            "cash": self.cash[site],
            "total_debt_open": sum((c.open_principal + c.open_fee for c in charges), Decimal("0.00")),
        }

    def primary_debt(self, debtor: str) -> Decimal:
        return sum((r.total for r in self.open_rows() if r.debtor == debtor), Decimal("0.00"))

    def joint_exposure(self, owner: str) -> Decimal:
        return sum((r.total for r in self.open_rows() if r.joint_owner == owner), Decimal("0.00"))

    def statuses(self, site: str, unit: str) -> dict[str, str]:
        return {c.period: c.status for c in self.charges if (c.site, c.unit) == (site, unit)}


def _accrual_day(period: str) -> date:
    return date(2027, PERIODS.index(period) + 1, 1)


def reconcile(as_of: date = AS_OF) -> Ledger:
    """Replay the whole fixture up to `as_of` (default: the final checkpoint, April 10, 2027)."""
    return Ledger(as_of, fixture_charges(), fixture_payments()).run()


CHECKPOINTS = [date(2027, 1, 10), date(2027, 2, 10), date(2027, 3, 10), date(2027, 4, 10)]


def cash_checkpoints() -> dict[date, dict[str, Decimal]]:
    return {day: dict(reconcile(day).cash) for day in CHECKPOINTS}
