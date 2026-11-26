"""Browser journeys for transient service failures and stale UI actions."""
from __future__ import annotations

import os
import json
from datetime import date, timedelta
from pathlib import Path
from decimal import Decimal

import pytest
from playwright.sync_api import TimeoutError as PlaywrightTimeoutError
from playwright.sync_api import Route

from pages import DuesManagement, ManagerCockpit, PersonPicker, ResidentsTab, Shell, UnitWorkspace
from pages.login import LoginPage
from support.flutter import by_id, by_id_prefix, fill
from support.journey_attempts import JourneyManifest, site_in_state, teardown_with_evidence
from support.journey_gui import amount_of, page_text, sign_in_manager

E2E = Path(__file__).resolve().parents[1]


def _manifest(request) -> JourneyManifest:
    return JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.allow_server_errors
@pytest.mark.covers("SC-13-08-02")
@pytest.mark.gui_id("GUI-13-19")
def test_payment_stream_distinguishes_loading_failure_and_recovery(
    request, api, actors, stack, page, login_page: LoginPage,
):
    manifest = _manifest(request)
    try:
        saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
        fixture = site_in_state("F5", api=api, stack=stack, saas=saas, manifest=manifest)
        sign_in_manager(page, login_page, fixture)
        ManagerCockpit(page).wait()
        DuesManagement(page).open()

        held_routes: list[Route] = []
        server_errors: list[tuple[int, str]] = []
        failed_requests = 0
        stream_mode = "hold"

        page.on(
            "response",
            lambda response: server_errors.append((response.status, response.url))
            if response.status >= 500
            else None,
        )

        def fail_stream(route: Route) -> None:
            nonlocal failed_requests
            failed_requests += 1
            route.fulfill(
                status=503,
                content_type="application/json",
                body='{"error":"TEMPORARY_FAILURE"}',
            )

        def control_payment_stream(route: Route) -> None:
            if stream_mode == "hold":
                held_routes.append(route)
            elif stream_mode == "fail":
                fail_stream(route)
            else:
                route.continue_()

        # Opening the page requests the stream more than once (the button and the
        # tab it mounts both fetch). A single answered copy ends the loading
        # state, so no request may complete until loading has been observed.
        page.route("**/api/v1/payments/stream*", control_payment_stream)
        by_id(page, "action_payment_tracking").click()
        by_id(page, "payment_stream_loading").wait_for(state="attached", timeout=5_000)
        assert held_routes, "the payment stream request must be held before it completes"
        assert by_id(page, "payment_stream_error").count() == 0
        assert by_id(page, "payment_stream_empty").count() == 0

        stream_mode = "fail"
        while held_routes:
            fail_stream(held_routes.pop(0))
        by_id(page, "payment_stream_error").wait_for(state="attached", timeout=10_000)
        assert by_id(page, "payment_stream_empty").count() == 0

        stream_mode = "pass"
        page.get_by_role("button", name="Tekrar Dene").click()
        by_id(page, "payment_stream_error").wait_for(state="detached", timeout=15_000)
        # The error leaves as soon as the retry starts loading; wait for the data.
        by_id_prefix(page, "payment_entry_").first.wait_for(state="attached", timeout=15_000)
        assert "8.000,00" in page_text(page)
        assert len(server_errors) == failed_requests, server_errors
        assert all(status == 503 and "/api/v1/payments/stream" in url for status, url in server_errors)
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
        raise
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.allow_server_errors
@pytest.mark.covers("SC-13-08-02")
@pytest.mark.gui_id("GUI-13-20")
def test_unit_directory_distinguishes_loading_failure_and_recovery(
    request, api, actors, stack, page, login_page: LoginPage,
):
    manifest = _manifest(request)
    try:
        saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
        fixture = site_in_state("F5", api=api, stack=stack, saas=saas, manifest=manifest)

        held_routes: list[Route] = []
        server_errors: list[tuple[int, str]] = []
        hold_directory_responses = True
        page.on(
            "response",
            lambda response: server_errors.append((response.status, response.url))
            if response.status >= 500
            else None,
        )

        def hold_directory_response(route: Route) -> None:
            if hold_directory_responses:
                held_routes.append(route)
            else:
                route.continue_()

        page.route("**/api/v1/site-admin/home-owners*", hold_directory_response)
        login_page.login("manager", fixture.manager_email, fixture.manager_password)
        ManagerCockpit(page).wait()
        Shell(page).nav("residents")
        assert held_routes, "unit directory responses must be held until its loading state is visible"
        by_id(page, "unit_directory_loading").wait_for(state="attached", timeout=5_000)

        hold_directory_responses = False
        for held_route in held_routes:
            held_route.fulfill(
                status=503,
                content_type="application/json",
                body='{"error":"TEMPORARY_FAILURE"}',
            )
        by_id(page, "unit_directory_error").wait_for(state="attached", timeout=10_000)
        assert by_id_prefix(page, "module_unit_actions_").count() == 0

        page.get_by_role("button", name="Tekrar Dene").click()
        by_id(page, "unit_directory_error").wait_for(state="detached", timeout=15_000)
        assert len(ResidentsTab(page).unit_card_ids()) == 7
        assert server_errors, "the deliberate outage must be observed by the page guard"
        assert all(status == 503 and "/api/v1/site-admin/home-owners" in url for status, url in server_errors)
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
        raise
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.allow_server_errors
@pytest.mark.covers("SC-13-08-02")
@pytest.mark.gui_id("GUI-13-21")
def test_collection_tracking_distinguishes_loading_failure_and_recovery(
    request, api, actors, stack, page, login_page: LoginPage,
):
    manifest = _manifest(request)
    try:
        saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
        fixture = site_in_state("F5", api=api, stack=stack, saas=saas, manifest=manifest)
        sign_in_manager(page, login_page, fixture)
        ManagerCockpit(page).wait()
        DuesManagement(page).open()

        held_routes: list[Route] = []
        server_errors: list[tuple[int, str]] = []
        hold_next_response = True
        page.on(
            "response",
            lambda response: server_errors.append((response.status, response.url))
            if response.status >= 500
            else None,
        )

        def hold_aging_response(route: Route) -> None:
            nonlocal hold_next_response
            if hold_next_response:
                hold_next_response = False
                held_routes.append(route)
            else:
                route.continue_()

        page.route("**/api/v1/payments/debt-aging*", hold_aging_response)
        by_id(page, "segment_tab_2").click()
        assert len(held_routes) == 1, "the first collection report response must be held"
        by_id(page, "debt_aging_loading").wait_for(state="attached", timeout=5_000)

        held_routes.pop().fulfill(
            status=503,
            content_type="application/json",
            body='{"error":"TEMPORARY_FAILURE"}',
        )
        by_id(page, "debt_aging_error").wait_for(state="attached", timeout=10_000)
        assert by_id(page, "aging_grand_total").count() == 0

        page.get_by_role("button", name="Tekrar Dene").click()
        by_id(page, "debt_aging_error").wait_for(state="detached", timeout=15_000)
        assert amount_of(page, "aging_grand_total") == Decimal("11117.50")
        assert len(server_errors) == 1, server_errors
        assert server_errors[0][0] == 503 and "/api/v1/payments/debt-aging" in server_errors[0][1]
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
        raise
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.allow_server_errors
@pytest.mark.covers("SC-13-08-06")
@pytest.mark.gui_id("GUI-13-22")
def test_lost_payment_confirmation_recovers_committed_payment_without_duplicate(
    request, api, actors, stack, page, login_page: LoginPage,
):
    manifest = _manifest(request)
    try:
        saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
        fixture = site_in_state("F5", api=api, stack=stack, saas=saas, manifest=manifest)
        unit_id = fixture.unit_ids[2]  # A-3 is owed exactly TRY 1,675.00.
        sign_in_manager(page, login_page, fixture)
        ManagerCockpit(page).wait()
        DuesManagement(page).open()
        by_id(page, "btn_dues_more_actions").click()
        by_id(page, "menu_item_manual_cash").click()

        by_id(page, "payment_manual_unit").click()
        by_id(page, "payment_manual_unit_option_3").click()
        fill(page, "payment_manual_amount", "1675,00")
        fill(page, "payment_manual_payer_name", "E2E Lost Confirmation A3")
        by_id(page, "payment_manual_role").click()
        by_id(page, "payment_manual_role_option_owner").click()

        committed_statuses: list[int] = []

        def lose_committed_response(route: Route) -> None:
            response = route.fetch()
            committed_statuses.append(response.status)
            route.abort()

        page.route("**/api/v1/payments/record-manual*", lose_committed_response)
        page.get_by_role("button", name="Tahsilatı Kaydet & Makbuz Üret").click()
        by_id(page, "payment_manual_amount").wait_for(state="detached", timeout=15_000)
        assert committed_statuses == [201], committed_statuses

        page.unroute("**/api/v1/payments/record-manual*", lose_committed_response)
        DuesManagement(page).open()
        by_id(page, "action_payment_tracking").click()
        entries = api.payment_stream(fixture.manager)["entries"]
        recovered = [entry for entry in entries if entry["payer_name"] == "E2E Lost Confirmation A3"]
        assert len(recovered) == 1, recovered
        by_id(page, f"payment_entry_{recovered[0]['id']}_OWNER").wait_for(state="attached", timeout=15_000)
        assert page_text(page).count("E2E Lost Confirmation A3") == 1, page_text(page)
        assert "1.675,00" in page_text(page)

        assert stack.sql(
            f"SELECT COUNT(*) FROM payment_receipts WHERE unit_id = {int(unit_id)} AND total_amount = 1675.00;"
        ) == "1"
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
        raise
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.covers("SC-13-08-07")
@pytest.mark.gui_id("GUI-13-23")
def test_stale_move_in_refreshes_to_the_first_managers_occupancy(
    request, api, actors, stack, page, login_page: LoginPage,
):
    manifest = _manifest(request)
    second_context = None
    try:
        saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
        fixture = site_in_state("F5", api=api, stack=stack, saas=saas, manifest=manifest)
        unit_id = fixture.unit_ids[2]  # A-3 is vacant and has an owner on record.
        second_email = actors["homeowner"]["email"].replace("'", "''")
        stack.sql(
            "UPDATE users SET person_id = NULL, role = 'SITE_MANAGER', "
            f"site_id = {int(fixture.site_id)} WHERE lower(email) = lower('{second_email}');"
        )
        stack.restart_backend()
        second_session = api.login(**actors["homeowner"])
        assert str(second_session.user["site_id"]) == str(fixture.site_id)

        browser_time = f"{stack.fixture_today}T12:00:00+03:00"
        page.clock.install(time=browser_time)
        sign_in_manager(page, login_page, fixture)
        ManagerCockpit(page).wait()
        second_context = page.context.browser.new_context(locale="tr-TR")
        second_page = second_context.new_page()
        # The second tab lives in its own window, so Chrome may treat it as backgrounded
        # and throttle animation frames. Flutter publishes no semantics nodes for an app
        # that boots in that state, which is why only this context's cockpit wait ever
        # times out (#502). Focusing the tab before it loads keeps rendering live.
        second_page.bring_to_front()
        second_page.clock.install(time=browser_time)
        second_login = LoginPage(second_page, login_page.base_url).open()
        second_login.login("manager", actors["homeowner"]["email"], actors["homeowner"]["password"])
        ManagerCockpit(second_page).wait()

        ResidentsTab(page).open()
        ResidentsTab(second_page).open()
        UnitWorkspace(page).open(unit_id).action(unit_id, "tenant_move_in")
        try:
            PersonPicker(page, "module_move_in_pick_existing_btn").create(
                "E2E First Manager Tenant",
                phone="+90 533 123 45 67",
                email="first-manager-tenant@e2e.test",
            )
        except PlaywrightTimeoutError:
            # Flutter renders the selected card but its nested test identifier
            # is not exposed to Playwright on this screen.
            pass
        person_id = stack.sql(
            f"SELECT id FROM persons WHERE site_id = {int(fixture.site_id)} "
            "AND email = 'first-manager-tenant@e2e.test';"
        )

        UnitWorkspace(second_page).open(unit_id).action(unit_id, "tenant_move_in")
        try:
            PersonPicker(second_page, "module_move_in_pick_existing_btn").choose(
                person_id, "E2E First Manager Tenant"
            )
        except PlaywrightTimeoutError:
            pass

        liabilities_before = stack.sql(
            f"SELECT COUNT(*) FROM dues_liabilities WHERE unit_id = {int(unit_id)};"
        )
        payments_before = stack.sql(
            f"SELECT COUNT(*) FROM payment_entries WHERE unit_id = {int(unit_id)};"
        )
        transition_date = (date.fromisoformat(stack.fixture_today) - timedelta(days=7)).isoformat()

        def pin_transition_date(route: Route) -> None:
            payload = route.request.post_data_json
            payload["effective_date"] = transition_date
            route.continue_(post_data=json.dumps(payload))

        page.route("**/occupancy-transitions*", pin_transition_date)
        with page.expect_response(
            lambda response: "/occupancy-transitions" in response.url and response.request.method == "POST",
            timeout=15_000,
        ) as first_response:
            by_id(page, "module_confirm_move_in_btn").click()
        response = first_response.value
        assert response.status == 200, (
            f"move-in failed on fixture date {stack.fixture_today}: {response.status} {response.text()}"
        )
        by_id(page, "module_confirm_move_in_btn").wait_for(state="detached", timeout=15_000)
        page.unroute("**/occupancy-transitions*", pin_transition_date)

        with second_page.expect_response(
            lambda response: "/occupancy-transitions" in response.url and response.request.method == "POST",
            timeout=15_000,
        ) as stale_response:
            second_page.route("**/occupancy-transitions*", pin_transition_date)
            by_id(second_page, "module_confirm_move_in_btn").click()
        response = stale_response.value
        assert response.status == 409, f"stale move-in must be refused, got {response.status}"

        # Reload the same client: the same backgrounded-tab rule applies, and the reload
        # boots the app from scratch, so focus the tab first (#502).
        second_page.bring_to_front()
        second_page.reload()
        LoginPage(second_page, login_page.base_url).open().login(
            "manager", actors["homeowner"]["email"], actors["homeowner"]["password"]
        )
        ManagerCockpit(second_page).wait()
        ResidentsTab(second_page).open()
        assert "E2E First Manager Tenant" in page_text(second_page)
        assert "E2E Second Manager Tenant" not in page_text(second_page)
        UnitWorkspace(second_page).open(unit_id)
        assert "Kiracı Değişikliği" in page_text(second_page)

        active_occupancies = stack.sql(
            f"SELECT COUNT(*) FROM unit_occupancies WHERE unit_id = {int(unit_id)} AND is_active;"
        )
        tenant_on_record = stack.sql(
            "SELECT p.full_name FROM units u JOIN persons p ON p.id = u.tenant_person_id "
            f"WHERE u.id = {int(unit_id)};"
        )
        assert active_occupancies == "1"
        assert tenant_on_record == "E2E First Manager Tenant"
        assert stack.sql(f"SELECT COUNT(*) FROM dues_liabilities WHERE unit_id = {int(unit_id)};") == liabilities_before
        assert stack.sql(f"SELECT COUNT(*) FROM payment_entries WHERE unit_id = {int(unit_id)};") == payments_before
    except BaseException as failure:
        if second_context is not None:
            second_context.close()
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
        raise
    else:
        if second_context is not None:
            second_context.close()
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)
