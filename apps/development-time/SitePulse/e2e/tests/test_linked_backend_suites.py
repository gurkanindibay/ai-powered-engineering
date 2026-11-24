"""Run linked non-browser acceptance tests inside the recorded E2E run.

The feature runner excludes @linked scenarios from Gherkin execution. These
wrappers run their owning test suites and let the pytest execution recorder
attach the suite result to the associated scenarios for local run history.
Scenario evidence is declared on the individual tests with the covers marker.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

SITEPULSE = Path(__file__).resolve().parents[2]
BACKEND = SITEPULSE / "backend"
FLUTTER = SITEPULSE / "flutter"


def run_suite(command: list[str], cwd: Path) -> None:
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=600)
    if result.returncode != 0:
        output = (result.stdout + "\n" + result.stderr)[-6000:]
        pytest.fail(f"{' '.join(command)} failed with exit code {result.returncode}:\n{output}")


@pytest.mark.epic_05
@pytest.mark.suite_covers("SC-05-06-01")
def test_harness_linked_scenarios() -> None:
    run_suite(
        [sys.executable, "-m", "unittest", "discover", "-s", "harness/tests"],
        SITEPULSE,
    )


@pytest.mark.epic_07
@pytest.mark.suite_covers("SC-07-01-01")
@pytest.mark.suite_covers("SC-07-01-02")
@pytest.mark.suite_covers("SC-07-02-03")
@pytest.mark.suite_covers("SC-07-03-02")
@pytest.mark.suite_covers("SC-07-05-02")
@pytest.mark.suite_covers("SC-07-06-01")
@pytest.mark.suite_covers("SC-07-07-02")
def test_epic07_rust_linked_scenarios() -> None:
    run_suite(["cargo", "test", "--locked", "--test", "integration_tests"], BACKEND)


@pytest.mark.epic_07
@pytest.mark.suite_covers("SC-07-08-01")
@pytest.mark.suite_covers("SC-07-08-02")
@pytest.mark.suite_covers("SC-07-08-04")
def test_epic07_billing_period_linked_scenarios() -> None:
    run_suite(["cargo", "test", "--locked", "--test", "billing_period_tests"], BACKEND)


@pytest.mark.epic_07
@pytest.mark.suite_covers("SC-07-09-01")
@pytest.mark.suite_covers("SC-07-09-02")
@pytest.mark.suite_covers("SC-07-09-04")
@pytest.mark.suite_covers("SC-07-09-05")
@pytest.mark.suite_covers("SC-07-09-06")
def test_epic07_proration_linked_scenarios() -> None:
    run_suite(["cargo", "test", "--locked", "--test", "occupancy_proration_tests"], BACKEND)


@pytest.mark.epic_07
@pytest.mark.suite_covers("SC-07-11-01")
@pytest.mark.suite_covers("SC-07-11-02")
@pytest.mark.suite_covers("SC-07-11-03")
@pytest.mark.suite_covers("SC-07-11-04")
@pytest.mark.suite_covers("SC-07-11-05")
@pytest.mark.suite_covers("SC-07-09-03")
def test_epic07_accrual_corrections_linked_scenarios() -> None:
    run_suite(["cargo", "test", "--locked", "--test", "accrual_corrections_tests"], BACKEND)


@pytest.mark.epic_07
@pytest.mark.suite_covers("SC-07-07-03")
def test_epic07_flutter_linked_scenarios() -> None:
    run_suite(["flutter", "test", "test/dues_management_view_test.dart"], FLUTTER)


@pytest.mark.epic_11
@pytest.mark.suite_covers("SC-11-01-01")
@pytest.mark.suite_covers("SC-11-01-02")
@pytest.mark.suite_covers("SC-11-02-01")
@pytest.mark.suite_covers("SC-11-02-02")
@pytest.mark.suite_covers("SC-11-02-03")
@pytest.mark.suite_covers("SC-11-03-01")
@pytest.mark.suite_covers("SC-11-03-02")
@pytest.mark.suite_covers("SC-11-04-01")
@pytest.mark.suite_covers("SC-11-04-02")
@pytest.mark.suite_covers("SC-11-04-03")
@pytest.mark.suite_covers("SC-11-05-01")
@pytest.mark.suite_covers("SC-11-05-02")
@pytest.mark.suite_covers("SC-11-06-01")
@pytest.mark.suite_covers("SC-11-06-02")
@pytest.mark.suite_covers("SC-11-07-01")
@pytest.mark.suite_covers("SC-11-07-02")
@pytest.mark.suite_covers("SC-11-08-01")
@pytest.mark.suite_covers("SC-11-08-02")
@pytest.mark.suite_covers("SC-11-09-01")
@pytest.mark.suite_covers("SC-11-09-02")
@pytest.mark.suite_covers("SC-11-10-01")
@pytest.mark.suite_covers("SC-11-10-02")
@pytest.mark.suite_covers("SC-11-11-01")
@pytest.mark.suite_covers("SC-11-12-01")
@pytest.mark.suite_covers("SC-11-13-01")
@pytest.mark.suite_covers("SC-11-14-01")
def test_epic11_rust_linked_scenarios() -> None:
    run_suite(["cargo", "test", "--locked", "--test", "payments_phase3_tests"], BACKEND)


@pytest.mark.epic_11
@pytest.mark.suite_covers("SC-11-02-04")
@pytest.mark.suite_covers("SC-11-05-03")
@pytest.mark.suite_covers("SC-11-05-04")
def test_epic11_flutter_linked_scenarios() -> None:
    run_suite(["flutter", "test", "test/payments_phase3_test.dart"], FLUTTER)


@pytest.mark.epic_11
@pytest.mark.suite_covers("SC-11-07-03")
def test_epic11_api_linked_scenarios() -> None:
    run_suite([sys.executable, "scripts/api_system_check.py", "--json"], SITEPULSE)


@pytest.mark.epic_08
@pytest.mark.suite_covers("SC-08-02-02")
@pytest.mark.suite_covers("SC-08-05-02")
@pytest.mark.suite_covers("SC-08-06-01")
@pytest.mark.suite_covers("SC-08-06-02")
@pytest.mark.suite_covers("SC-08-06-03")
@pytest.mark.suite_covers("SC-08-07-01")
@pytest.mark.suite_covers("SC-08-07-02")
@pytest.mark.suite_covers("SC-08-07-03")
@pytest.mark.suite_covers("SC-08-07-04")
@pytest.mark.suite_covers("SC-08-07-05")
@pytest.mark.suite_covers("SC-08-07-06")
@pytest.mark.suite_covers("SC-08-07-07")
@pytest.mark.suite_covers("SC-08-07-08")
@pytest.mark.suite_covers("SC-08-08-01")
@pytest.mark.suite_covers("SC-08-08-02")
@pytest.mark.suite_covers("SC-08-08-03")
@pytest.mark.suite_covers("SC-08-09-01")
@pytest.mark.suite_covers("SC-08-09-02")
@pytest.mark.suite_covers("SC-08-09-03")
@pytest.mark.suite_covers("SC-08-09-04")
@pytest.mark.suite_covers("SC-08-10-01")
@pytest.mark.suite_covers("SC-08-10-02")
@pytest.mark.suite_covers("SC-08-10-03")
@pytest.mark.suite_covers("SC-08-10-04")
@pytest.mark.suite_covers("SC-08-10-05")
@pytest.mark.suite_covers("SC-08-10-06")
def test_epic08_rust_linked_scenarios() -> None:
    run_suite(["cargo", "test", "--locked", "--test", "occupancy_state_machine_tests"], BACKEND)


@pytest.mark.epic_08
@pytest.mark.suite_covers("SC-08-11-01")
@pytest.mark.suite_covers("SC-08-11-02")
@pytest.mark.suite_covers("SC-08-11-03")
def test_epic08_flutter_linked_scenarios() -> None:
    run_suite(["flutter", "test", "test/unit_workspace_test.dart"], FLUTTER)


@pytest.mark.epic_09
@pytest.mark.suite_covers("SC-09-01-02")
@pytest.mark.suite_covers("SC-09-02-02")
@pytest.mark.suite_covers("SC-09-05-01")
@pytest.mark.suite_covers("SC-09-06-01")
@pytest.mark.suite_covers("SC-09-06-02")
@pytest.mark.suite_covers("SC-09-07-01")
def test_epic09_rust_linked_scenarios() -> None:
    run_suite(["cargo", "test", "--locked", "--test", "payment_ledger_hardening_tests"], BACKEND)


@pytest.mark.epic_09
@pytest.mark.suite_covers("SC-09-01-02")
@pytest.mark.suite_covers("SC-09-06-02")
@pytest.mark.suite_covers("SC-09-07-01")
def test_epic09_flutter_linked_scenarios() -> None:
    run_suite(["flutter", "test", "test/payment_tracking_and_aging_test.dart"], FLUTTER)


@pytest.mark.suite_covers("SC-13-09-01")
def test_epic13_designated_payment_linked_scenario() -> None:
    run_suite(
        ["cargo", "test", "--locked", "--test", "payment_compliance_tests",
         "when_payer_designates_a_period_then_that_due_is_settled_before_older_dues"],
        BACKEND,
    )


@pytest.mark.suite_covers("SC-13-09-04")
@pytest.mark.suite_covers("SC-13-09-05")
def test_epic13_closed_period_linked_scenarios() -> None:
    run_suite(["cargo", "test", "--locked", "--test", "billing_period_lifecycle_tests"], BACKEND)


@pytest.mark.suite_covers("SC-13-05-02")
def test_epic13_due_day_month_end_linked_scenario() -> None:
    run_suite(
        ["cargo", "test", "--locked", "--test", "accrual_schedule_tests",
         "when_the_due_day_is_beyond_the_month_end_then_it_falls_on_the_last_day"],
        BACKEND,
    )


@pytest.mark.suite_covers("SC-13-12-01")
def test_epic13_sale_departure_joint_payment_linked_scenario() -> None:
    run_suite(["cargo", "test", "--locked", "--test", "accrual_corrections_tests", "when_a_paid_month_is_split"], BACKEND)


@pytest.mark.suite_covers("SC-13-12-02")
def test_epic13_capital_project_sale_override_linked_scenario() -> None:
    run_suite(["cargo", "test", "--locked", "--test", "sale_clearance_tests", "statement_itemizes_seller_debt"], BACKEND)


@pytest.mark.suite_covers("SC-13-12-03")
def test_epic13_supplementary_charge_linked_scenario() -> None:
    run_suite(["cargo", "test", "--locked", "--test", "supplementary_charge_tests", "when_the_charge_is_created_late"], BACKEND)


@pytest.mark.suite_covers("SC-13-12-04")
def test_epic13_catch_up_grace_reversal_linked_scenario() -> None:
    run_suite(["cargo", "test", "--locked", "--test", "payment_ledger_hardening_tests", "when_a_settled_payment_is_reversed"], BACKEND)


@pytest.mark.suite_covers("SC-13-12-05")
def test_epic13_unmatched_multi_debtor_transfer_linked_scenario() -> None:
    run_suite(["cargo", "test", "--locked", "--test", "bank_multi_debtor_tests"], BACKEND)


