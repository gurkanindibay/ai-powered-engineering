"""Run linked non-browser acceptance tests inside the recorded E2E run.

The feature runner excludes @linked scenarios from Gherkin execution. These
wrappers run their owning test suites and let the pytest execution recorder
attach the actual result to each linked scenario.
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
@pytest.mark.covers("SC-05-06-01")
def test_harness_linked_scenarios() -> None:
    run_suite(
        [sys.executable, "-m", "unittest", "discover", "-s", "harness/tests"],
        SITEPULSE,
    )


@pytest.mark.epic_07
@pytest.mark.covers("SC-07-01-01")
@pytest.mark.covers("SC-07-01-02")
@pytest.mark.covers("SC-07-02-03")
@pytest.mark.covers("SC-07-03-02")
@pytest.mark.covers("SC-07-05-02")
@pytest.mark.covers("SC-07-06-01")
@pytest.mark.covers("SC-07-07-02")
def test_epic07_rust_linked_scenarios() -> None:
    run_suite(["cargo", "test", "--locked", "--test", "integration_tests"], BACKEND)


@pytest.mark.epic_07
@pytest.mark.covers("SC-07-07-03")
def test_epic07_flutter_linked_scenarios() -> None:
    run_suite(["flutter", "test", "test/dues_management_view_test.dart"], FLUTTER)


@pytest.mark.epic_11
@pytest.mark.covers("SC-11-01-01")
@pytest.mark.covers("SC-11-01-02")
@pytest.mark.covers("SC-11-02-01")
@pytest.mark.covers("SC-11-02-02")
@pytest.mark.covers("SC-11-02-03")
@pytest.mark.covers("SC-11-03-01")
@pytest.mark.covers("SC-11-03-02")
@pytest.mark.covers("SC-11-04-01")
@pytest.mark.covers("SC-11-04-02")
@pytest.mark.covers("SC-11-04-03")
@pytest.mark.covers("SC-11-05-01")
@pytest.mark.covers("SC-11-05-02")
@pytest.mark.covers("SC-11-06-01")
@pytest.mark.covers("SC-11-06-02")
@pytest.mark.covers("SC-11-07-01")
@pytest.mark.covers("SC-11-07-02")
@pytest.mark.covers("SC-11-08-01")
@pytest.mark.covers("SC-11-08-02")
@pytest.mark.covers("SC-11-09-01")
@pytest.mark.covers("SC-11-09-02")
@pytest.mark.covers("SC-11-10-01")
@pytest.mark.covers("SC-11-10-02")
@pytest.mark.covers("SC-11-11-01")
@pytest.mark.covers("SC-11-12-01")
@pytest.mark.covers("SC-11-13-01")
@pytest.mark.covers("SC-11-14-01")
def test_epic11_rust_linked_scenarios() -> None:
    run_suite(["cargo", "test", "--locked", "--test", "payments_phase3_tests"], BACKEND)


@pytest.mark.epic_11
@pytest.mark.covers("SC-11-02-04")
@pytest.mark.covers("SC-11-05-03")
@pytest.mark.covers("SC-11-05-04")
def test_epic11_flutter_linked_scenarios() -> None:
    run_suite(["flutter", "test", "test/payments_phase3_test.dart"], FLUTTER)


@pytest.mark.epic_11
@pytest.mark.covers("SC-11-07-03")
def test_epic11_api_linked_scenarios() -> None:
    run_suite([sys.executable, "scripts/api_system_check.py", "--json"], SITEPULSE)


@pytest.mark.epic_08
@pytest.mark.covers("SC-08-02-02")
@pytest.mark.covers("SC-08-05-02")
@pytest.mark.covers("SC-08-06-01")
@pytest.mark.covers("SC-08-06-02")
@pytest.mark.covers("SC-08-06-03")
@pytest.mark.covers("SC-08-07-01")
@pytest.mark.covers("SC-08-07-02")
@pytest.mark.covers("SC-08-07-03")
@pytest.mark.covers("SC-08-07-04")
@pytest.mark.covers("SC-08-07-05")
@pytest.mark.covers("SC-08-07-06")
@pytest.mark.covers("SC-08-07-07")
@pytest.mark.covers("SC-08-07-08")
@pytest.mark.covers("SC-08-08-01")
@pytest.mark.covers("SC-08-08-02")
@pytest.mark.covers("SC-08-08-03")
@pytest.mark.covers("SC-08-09-01")
@pytest.mark.covers("SC-08-09-02")
@pytest.mark.covers("SC-08-09-03")
@pytest.mark.covers("SC-08-09-04")
@pytest.mark.covers("SC-08-10-01")
@pytest.mark.covers("SC-08-10-02")
@pytest.mark.covers("SC-08-10-03")
@pytest.mark.covers("SC-08-10-04")
@pytest.mark.covers("SC-08-10-05")
@pytest.mark.covers("SC-08-10-06")
def test_epic08_rust_linked_scenarios() -> None:
    run_suite(["cargo", "test", "--locked", "--test", "occupancy_state_machine_tests"], BACKEND)


@pytest.mark.epic_08
@pytest.mark.covers("SC-08-11-01")
@pytest.mark.covers("SC-08-11-02")
@pytest.mark.covers("SC-08-11-03")
def test_epic08_flutter_linked_scenarios() -> None:
    run_suite(["flutter", "test", "test/unit_workspace_test.dart"], FLUTTER)


@pytest.mark.epic_09
@pytest.mark.covers("SC-09-01-02")
@pytest.mark.covers("SC-09-02-02")
@pytest.mark.covers("SC-09-05-01")
@pytest.mark.covers("SC-09-06-01")
@pytest.mark.covers("SC-09-06-02")
@pytest.mark.covers("SC-09-07-01")
def test_epic09_rust_linked_scenarios() -> None:
    run_suite(["cargo", "test", "--locked", "--test", "payment_ledger_hardening_tests"], BACKEND)


@pytest.mark.epic_09
@pytest.mark.covers("SC-09-01-02")
@pytest.mark.covers("SC-09-06-02")
@pytest.mark.covers("SC-09-07-01")
def test_epic09_flutter_linked_scenarios() -> None:
    run_suite(["flutter", "test", "test/payment_tracking_and_aging_test.dart"], FLUTTER)

