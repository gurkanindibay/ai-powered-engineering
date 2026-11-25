"""Browser journeys for session expiry and stale responses across identities."""
from __future__ import annotations

import json
import os
from decimal import Decimal
from pathlib import Path

import pytest
from playwright.sync_api import Page

from pages import ManagerCockpit, ResidentHome, Shell
from pages.login import LoginPage
from support.flutter import by_id
from support.journey_attempts import JourneyManifest, site_in_state, teardown_with_evidence
from support.journey_gui import amount_of, page_text, resident_email, sign_in_manager

E2E = Path(__file__).resolve().parents[1]


def _manifest(request) -> JourneyManifest:
    return JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )


def _install_held_fetch(page: Page, path: str) -> None:
    script = """(() => {
          const heldPath = __HELD_PATH__;
          window.__sitePulseHeldLoads = [];
          window.__sitePulseHoldResponse = false;
          const originalFetch = window.fetch.bind(window);
          window.fetch = (input, init) => {
            const url = typeof input === 'string' ? input : input.url;
            return originalFetch(input, init).then((response) => {
              if (!window.__sitePulseHoldResponse || !url.includes(heldPath)) return response;
              return new Promise((resolve) => {
                window.__sitePulseHeldLoads.push(() => resolve(response));
              });
            });
          };
        })();"""
    page.add_init_script(script.replace("__HELD_PATH__", json.dumps(path)))
    page.reload()
    by_id(page, "login_tab_quickAll").wait_for(timeout=10_000)


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.covers("SC-13-08-04")
@pytest.mark.gui_id("GUI-13-17")
def test_expired_manager_session_clears_previous_site_data(request, api, actors, stack, page, login_page):
    manifest = _manifest(request)
    try:
        saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
        old_site = site_in_state(
            "F5", api=api, stack=stack, saas=saas, manifest=manifest, name_suffix="expired"
        )
        next_site = site_in_state(
            "F4", api=api, stack=stack, saas=saas, manifest=manifest, name_suffix="fresh"
        )
        sign_in_manager(page, login_page, old_site)
        assert amount_of(page, "cockpit_remaining_debt") == Decimal("4567.50")

        def refuse_session_requests(route):
            if route.request.url.endswith("/api/v1/auth/login"):
                route.continue_()
            else:
                route.fulfill(status=401, content_type="application/json", body='{"error":"UNAUTHORIZED"}')

        page.route("**/api/v1/**", refuse_session_requests)
        Shell(page).nav("dues")
        by_id(page, "login_tab_quickAll").wait_for(timeout=20_000)
        assert by_id(page, "cockpit_remaining_debt").count() == 0
        assert "4.567,50" not in page_text(page)

        page.go_back()
        by_id(page, "login_tab_quickAll").wait_for(timeout=10_000)
        assert by_id(page, "cockpit_remaining_debt").count() == 0
        page.goto(f"{login_page.base_url.rstrip('/')}/#/manager/dues")
        by_id(page, "login_tab_quickAll").wait_for(timeout=10_000)
        assert by_id(page, "cockpit_remaining_debt").count() == 0

        page.unroute("**/api/v1/**", refuse_session_requests)
        LoginPage(page, login_page.base_url).login("manager", next_site.manager_email, next_site.manager_password)
        Shell(page).nav("home")
        ManagerCockpit(page).wait()
        assert amount_of(page, "cockpit_remaining_debt") == Decimal("8800.00")
        assert "4.567,50" not in page_text(page)
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
        raise
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.edge
@pytest.mark.role_resident
@pytest.mark.covers("SC-13-10-08")
@pytest.mark.gui_id("GUI-13-18")
def test_late_statement_response_cannot_replace_next_resident(request, api, actors, stack, page, login_page):
    manifest = _manifest(request)
    try:
        saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
        site_a = site_in_state("F4", api=api, stack=stack, saas=saas, manifest=manifest, name_suffix="resident-a")
        site_b = site_in_state("F4", api=api, stack=stack, saas=saas, manifest=manifest, name_suffix="resident-b")
        unit_a, unit_b = site_a.unit_ids[1], site_b.unit_ids[1]
        receipt_a = api.record_manual_payment(site_a.manager, unit_a, Decimal("510.00"), "Selin Demir", payer_role="TENANT")
        receipt_b = api.record_manual_payment(site_b.manager, unit_b, Decimal("520.00"), "Selin Demir", payer_role="TENANT")
        assert Decimal(str(receipt_a["total_amount"])) == Decimal("510.00")
        assert Decimal(str(receipt_b["total_amount"])) == Decimal("520.00")
        email_a = resident_email(stack, site_a, "Selin Demir")
        email_b = resident_email(stack, site_b, "Selin Demir")

        _install_held_fetch(page, f"/api/v1/residents/{unit_a}/statement")
        LoginPage(page, login_page.base_url).open().login("resident", email_a, site_a.manager_password)
        ResidentHome(page).wait()
        by_id(page, "resident_statement_entry").click()
        receipt_a_row = by_id(page, f"statement_receipt_{receipt_a['receipt_number']}")
        receipt_a_row.wait_for(timeout=15_000)
        assert "510,00" in page_text(page)

        page.keyboard.press("Escape")
        by_id(page, "hero_balance_amount").wait_for(timeout=10_000)
        page.evaluate("window.__sitePulseHoldResponse = true")
        by_id(page, "resident_statement_entry").click()
        page.wait_for_function("window.__sitePulseHeldLoads?.length === 1", timeout=15_000)

        page.keyboard.press("Escape")
        Shell(page).open_profile().logout()
        by_id(page, "login_tab_quickAll").wait_for(timeout=10_000)
        LoginPage(page, login_page.base_url).login("resident", email_b, site_b.manager_password)
        ResidentHome(page).wait()
        by_id(page, "resident_statement_entry").click()
        receipt_b_row = by_id(page, f"statement_receipt_{receipt_b['receipt_number']}")
        receipt_b_row.wait_for(timeout=15_000)
        assert "520,00" in page_text(page)
        assert "510,00" not in page_text(page)

        page.evaluate("window.__sitePulseHeldLoads.shift()()")
        page.wait_for_load_state("networkidle")
        assert "520,00" in page_text(page)
        assert "510,00" not in page_text(page)
        page.keyboard.press("Escape")
        by_id(page, "hero_balance_amount").wait_for(timeout=10_000)
        page.go_back()
        page.wait_for_function(
            "document.querySelector('[flt-semantics-identifier=\\\"hero_balance_amount\\\"]') || "
            "document.querySelector('[flt-semantics-identifier=\\\"login_tab_quickAll\\\"]')",
            timeout=10_000,
        )
        assert "510,00" not in page_text(page)
        page.reload()
        page.wait_for_function(
            "document.querySelector('[flt-semantics-identifier=\\\"hero_balance_amount\\\"]') || "
            "document.querySelector('[flt-semantics-identifier=\\\"login_tab_quickAll\\\"]')",
            timeout=20_000,
        )
        assert "510,00" not in page_text(page)
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
        raise
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)
