"""Time representative product actions against the observability SLOs."""
from __future__ import annotations

from collections import defaultdict
from decimal import Decimal
from math import ceil
from pathlib import Path
from time import perf_counter

SITE_COUNT = 50
UNITS_PER_SITE = 200
SAMPLED_UNITS_PER_SITE = 20
DUES = Decimal("1400.00")
CLOCK_DATE = "2026-11-02"
PAYMENT_TARGET_SECONDS = 0.8
ACCRUAL_TARGET_SECONDS = 30 * 60
RECONCILIATION_TARGET_SECONDS = 60


def _measure(action, *args, **kwargs):
    started = perf_counter()
    result = action(*args, **kwargs)
    return perf_counter() - started, result


def _record_times(record_property, action, samples):
    ordered = sorted(samples)
    record_property(f"{action}_samples", len(ordered))
    record_property(f"{action}_p95_ms", round(1000 * ordered[ceil(len(ordered) * 0.95) - 1], 2))
    record_property(f"{action}_max_ms", round(1000 * ordered[-1], 2))


def test_financial_actions_at_residential_volume(api, actors, stack, record_property):
    stack.sql(Path(__file__).with_name("volume_seed.sql").read_text(encoding="utf-8"))
    stack.restart_backend()
    rows = stack.sql(
        "SELECT s.id, u.id, u.unit_number, u.virtual_iban "
        "FROM sites s JOIN units u ON u.site_id = s.id "
        "WHERE s.slug LIKE 'nightly-volume-%' ORDER BY s.id, u.unit_number;"
    ).splitlines()
    units_by_site = defaultdict(list)
    for row in rows:
        site_id, unit_id, number, iban = row.split("|")
        units_by_site[site_id].append((unit_id, int(number), iban))
    assert len(units_by_site) == SITE_COUNT
    assert all(len(units) == UNITS_PER_SITE for units in units_by_site.values())

    managers = {
        site_id: api.login(f"manager-{site_id}@nightly.test", actors["manager"]["password"])
        for site_id in units_by_site
    }
    api.clock.set_date(CLOCK_DATE)
    accrual_seconds, report = _measure(api.clock.tick, timeout=ACCRUAL_TARGET_SECONDS)
    _record_times(record_property, "scheduler_tick", [accrual_seconds])
    assert accrual_seconds < ACCRUAL_TARGET_SECONDS
    tick_report = report["report"]
    assert tick_report["accrued_sites"] >= SITE_COUNT, tick_report
    assert stack.sql(
        "SELECT count(*) FROM dues_liabilities d JOIN units u ON u.id = d.unit_id "
        "JOIN sites s ON u.site_id = s.id WHERE s.slug LIKE 'nightly-volume-%';"
    ) == str(SITE_COUNT * UNITS_PER_SITE)

    payment_times = []
    statement_times = []
    reconciliation_times = []
    bank_rows_seen = 0
    bank_rows_matched_in_time = 0
    for site_id, units in units_by_site.items():
        manager = managers[site_id]
        for unit_id, number, _iban in units[:SAMPLED_UNITS_PER_SITE]:
            elapsed, payment = _measure(
                api.record_manual_payment, manager, unit_id, DUES, f"Nightly owner {number}",
                payment_date=CLOCK_DATE,
            )
            assert payment["receipt_number"]
            payment_times.append(elapsed)

        elapsed, statement = _measure(api.resident_statement, manager, units[-1][0])
        assert statement["debtors"]
        statement_times.append(elapsed)

        # Leave the bank sample unpaid so the preview represents real matches
        # against outstanding dues rather than replaying the manual payments.
        bank_units = units[-SAMPLED_UNITS_PER_SITE:]
        content = "\n".join(
            f"{CLOCK_DATE};Nightly bank transfer {iban};1400,00;TXN-NIGHTLY-{unit_id}"
            for unit_id, _number, iban in bank_units
        )
        elapsed, matches = _measure(
            api.call, "POST", "/api/v1/bank/statements/parse", manager.token,
            body={"site_id": site_id, "content": content}, timeout=RECONCILIATION_TARGET_SECONDS,
        )
        assert matches["total_transactions"] == len(bank_units)
        assert not matches["skipped_entries"]
        assert {m["matched_unit_id"] for m in matches["matches"] if m["matched_unit_id"]} <= {
            unit_id for unit_id, _number, _iban in bank_units
        }
        reconciliation_times.append(elapsed)
        bank_rows_seen += len(bank_units)
        if elapsed < RECONCILIATION_TARGET_SECONDS:
            bank_rows_matched_in_time += matches["matched_count"]

    _record_times(record_property, "payment_record", payment_times)
    _record_times(record_property, "statement", statement_times)
    _record_times(record_property, "reconciliation_preview", reconciliation_times)
    timely_payments = sum(elapsed < PAYMENT_TARGET_SECONDS for elapsed in payment_times)
    record_property("timely_payments", timely_payments)
    record_property("timely_matched_bank_rows", bank_rows_matched_in_time)
    assert timely_payments * 1000 >= len(payment_times) * 999
    assert bank_rows_matched_in_time * 100 >= bank_rows_seen * 98
