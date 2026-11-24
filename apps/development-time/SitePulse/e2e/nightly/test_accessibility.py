"""Audit Flutter's rendered semantics on ten SitePulse screens."""
from __future__ import annotations

import json
import os
from pathlib import Path

import pytest
from playwright.sync_api import expect

from pages import CapitalProjects, DuesManagement, ManagerCockpit, PaymentStream, ResidentsTab, ResidentHome, SaasAdmin
from support.flutter import by_id


def _screen(role, open_screen):
    def navigate(page, login_as):
        login_as(role)
        if role == "manager":
            ManagerCockpit(page).wait()
        open_screen(page)
    return navigate


SCREEN_CASES = (
    pytest.param("manager-dashboard", _screen("manager", lambda page: ManagerCockpit(page).wait()), id="manager-dashboard"),
    pytest.param("unit-directory", _screen("manager", lambda page: ResidentsTab(page).open()), id="unit-directory"),
    pytest.param("add-resident", _screen("manager", lambda page: ResidentsTab(page).open().start_add()), id="add-resident"),
    pytest.param("dues", _screen("manager", lambda page: DuesManagement(page).open()), id="dues"),
    pytest.param("payment-stream", _screen("manager", lambda page: PaymentStream(page).open()), id="payment-stream"),
    pytest.param("capital-projects", _screen("manager", lambda page: CapitalProjects(page).open()), id="capital-projects"),
    pytest.param("resident-dashboard", _screen("homeowner", lambda page: ResidentHome(page).wait()), id="resident-dashboard"),
    pytest.param("saas-sites", _screen("saas", lambda page: SaasAdmin(page).wait()), id="saas-sites"),
)

# Fail on the critical threshold and on missing accessible names even when
# axe rates the affected widget as serious.
NAME_RULES = {
    "aria-command-name", "aria-input-field-name", "aria-toggle-field-name",
    "button-name", "label", "link-name", "select-name",
}
FLUTTER_DISABLED_TEXT_PROXY = "textarea[data-semantics-role='text-field'][disabled]"


@pytest.fixture(scope="session")
def axe_script():
    path = Path(os.environ.get("SITEPULSE_AXE_JS", "node_modules/axe-core/axe.min.js"))
    if not path.is_file():
        pytest.fail("Install axe-core and set SITEPULSE_AXE_JS to the path of axe.min.js")
    return path.resolve()


def audit_accessibility(screen, axe_script, page, record_property):
    """Run axe and return the rules that ran and the blocking violations."""
    page.add_script_tag(path=str(axe_script))
    proxy_count = page.locator(FLUTTER_DISABLED_TEXT_PROXY).count()
    result = page.evaluate(
        "selector => axe.run({exclude: [[selector]]}, {resultTypes: ['violations', 'passes']})",
        FLUTTER_DISABLED_TEXT_PROXY,
    )
    violations = result["violations"]
    report = Path(__file__).resolve().parents[1] / ".artifacts" / "axe" / f"{screen}.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(violations, indent=2) + "\n", encoding="utf-8")
    record_property("axe_violations", len(violations))
    record_property("excluded_disabled_flutter_text_proxies", proxy_count)
    blocking = [violation["id"] for violation in violations
                if violation["impact"] == "critical" or violation["id"] in NAME_RULES]
    return result["passes"], blocking


@pytest.mark.parametrize(("screen", "navigate"), SCREEN_CASES)
def test_no_critical_accessibility_violations(screen, navigate, axe_script, page, login_as, record_property):
    navigate(page, login_as)
    passes, blocking = audit_accessibility(screen, axe_script, page, record_property)
    assert passes and not blocking, f"{screen}: {blocking}. Details in {screen}.json"


def test_sign_in_accessibility(axe_script, page, login_page, record_property):
    assert login_page.is_shown()
    passes, blocking = audit_accessibility("sign-in", axe_script, page, record_property)
    assert passes and not blocking, f"sign-in: {blocking}. Details in sign-in.json"


@pytest.mark.covers("SC-01-04-04")
def test_issue_description_has_accessible_name(axe_script, page, login_as, record_property):
    login_as("homeowner")
    ResidentHome(page).wait()
    by_id(page, "resident_action_requests").click()
    expect(page.get_by_label("Açıklama", exact=True)).to_be_visible()
    passes, blocking = audit_accessibility("resident-issue-form", axe_script, page, record_property)
    assert passes and not blocking, f"resident-issue-form: {blocking}. Details in resident-issue-form.json"
