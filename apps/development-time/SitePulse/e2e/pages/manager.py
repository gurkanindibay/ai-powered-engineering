from __future__ import annotations

import re
import time

from playwright.sync_api import Page, expect
from playwright.sync_api import TimeoutError as PlaywrightTimeoutError

from pathlib import Path

from decimal import Decimal

from support.flutter import by_id, by_id_prefix, fill, text_of
from support.money import last_amount

from .person import PersonPicker, UnitWorkspace
from .shell import Shell


class ManagerCockpit:
    def __init__(self, page: Page):
        self.page = page

    def wait(self) -> "ManagerCockpit":
        marker = by_id(self.page, "btn_open_unified_dues_center")
        try:
            marker.wait_for(timeout=20_000)
        except PlaywrightTimeoutError:
            # A signed-in page occasionally redraws the cockpit without publishing its
            # semantics node, so the id never appears even though the dashboard is there
            # (#502). Reloading rebuilds the semantics tree and the session survives in
            # storage; this only runs on the path that would otherwise fail.
            self.page.reload(wait_until="networkidle")
            marker.wait_for(timeout=20_000)
        return self

    # -- 'Onay Bekleyen Başvurular' (EPIC-04) ------------------------------
    def pending_count(self) -> int:
        return int(text_of(by_id(self.page, "pending_count_badge")))

    def pending_card(self, request_id: str):
        return by_id(self.page, f"pending_card_{request_id}")

    def approve(self, request_id: str) -> str:
        """Approve a request; returns the temporary password the dialog shows."""
        by_id(self.page, f"btn_approve_{request_id}").click()
        password = by_id(self.page, "approval_credentials_password")
        password.wait_for(timeout=15_000)
        value = text_of(password)
        by_id(self.page, "btn_close_approval_dialog").click()
        return value


class ResidentsTab:
    """'Sakinler & Malikler' tab: one card per home owner / unit."""

    def __init__(self, page: Page):
        self.page = page

    def open(self) -> "ResidentsTab":
        Shell(self.page).nav("residents")
        by_id(self.page, "add_resident_btn").wait_for(timeout=15_000)
        return self

    def unit_card_ids(self) -> list[str]:
        """Unit ids that have a row (from module_unit_actions_<id>)."""
        prefix = "module_unit_actions_"
        return [i.removeprefix(prefix) for i in self.page.eval_on_selector_all(
            f'[flt-semantics-identifier^="{prefix}"]',
            "els => els.map(e => e.getAttribute('flt-semantics-identifier'))")]

    def start_add(self) -> "AddResidentForm":
        by_id(self.page, "add_resident_btn").click()
        return AddResidentForm(self.page).wait()

    def start_add_block(self) -> "AddBlockForm":
        """Open the block & units form (#285); the manager builds the site structure first."""
        by_id(self.page, "btn_add_block").click()
        return AddBlockForm(self.page).wait()


class AddBlockForm:
    """'Blok ve Daireleri Ekle': creates a block with its units and an optional tariff (#285)."""

    def __init__(self, page: Page):
        self.page = page

    def wait(self) -> "AddBlockForm":
        by_id(self.page, "block_form_name").wait_for(timeout=10_000)
        return self

    def fill(
        self,
        block_name: str,
        *,
        start_unit: int = 1,
        unit_count: int = 7,
        total_floors: int | None = None,
        house_type: str | None = None,
        monthly_dues: str | None = None,
    ) -> "AddBlockForm":
        fill(self.page, "block_form_name", block_name)
        fill(self.page, "block_form_start_unit", str(start_unit))
        fill(self.page, "block_form_unit_count", str(unit_count))
        if total_floors is not None:
            fill(self.page, "block_form_total_floors", str(total_floors))
        if house_type is not None:
            fill(self.page, "block_form_house_type", house_type)
        if monthly_dues is not None:
            fill(self.page, "block_form_monthly_dues", monthly_dues)
        return self

    def save(self) -> None:
        """Submit; waits for the form to close, or reports the refused-create reason."""
        by_id(self.page, "btn_save_block_units").click()
        error = by_id(self.page, "block_form_error")
        self.page.wait_for_function(
            "() => !!document.querySelector('[flt-semantics-identifier=\"block_form_error\"]')"
            " || !document.querySelector('[flt-semantics-identifier=\"block_form_name\"]')",
            timeout=20_000,
        )
        if error.count() > 0:
            raise AssertionError(f"block create refused: {text_of(error)}")


class AddResidentForm:
    """The module's 'Yeni Daire / Sakin Tanımla' page; the owner is a person card (REQ-042)."""

    def __init__(self, page: Page):
        self.page = page

    def wait(self) -> "AddResidentForm":
        by_id(self.page, "module_new_resident_unit").wait_for(timeout=10_000)
        return self

    def fill(self, unit_no: str, full_name: str, email: str, phone: str,
             reuse_existing: bool = False, house_type: str | None = None,
             occupancy: str | None = None) -> "AddResidentForm":
        fill(self.page, "module_new_resident_unit", unit_no)
        PersonPicker(self.page, "module_new_resident_name").create(
            full_name, phone=phone, email=email, reuse_existing=reuse_existing)
        if occupancy is not None:
            self._set_occupancy(occupancy)
        if house_type is not None:
            self._set_house_type(house_type)
        return self

    def _set_occupancy(self, label: str) -> None:
        """Choose 'Malik Oturuyor', 'Daire Kirada' or 'Boş Daire' on the registration page."""
        selector = by_id(self.page, "module_occupancy_status_selector")
        selector.wait_for(timeout=10_000)
        selector.get_by_text(label, exact=True).click()
        self.page.evaluate("() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))")

    def _set_house_type(self, type_name: str) -> None:
        """Choose the unit's existing tariff from the registration page's house type menu."""
        dropdown = by_id(self.page, "module_new_resident_house_type")
        dropdown.wait_for(timeout=10_000)
        dropdown.click()
        # Flutter exposes the menu items as role=menuitem with the tariff in their accessible name.
        option = self.page.get_by_role("menuitem", name=re.compile(rf"^{re.escape(type_name)} \(")).last
        option.wait_for(timeout=5_000)
        option.click()
        option.wait_for(state="detached", timeout=5_000)

    def save(self) -> None:
        """Save, then dismiss the 'Sakin Kaydedildi!' confirmation and close the module."""
        by_id(self.page, "module_save_new_resident_btn").click()
        # An already existing unit (for example an empty one of a started site) asks to confirm first;
        # wait for whichever comes first instead of a fixed pause.
        confirm = by_id(self.page, "btn_confirmation_confirm")
        close = by_id(self.page, "btn_close_resident_provisioned")
        confirm.or_(close).first.wait_for(timeout=15_000)
        if confirm.count() > 0:
            confirm.click()
        close.wait_for(timeout=15_000)
        close.click()
        close.wait_for(state="detached", timeout=10_000)
        UnitWorkspace(self.page).close()


class DuesManagement:
    """'Aidat Yönetimi' tab with its segment tabs."""

    CAPITAL_SEGMENT = 4  # "🏗️ Demirbaş & Yatırım"

    def __init__(self, page: Page):
        self.page = page

    def open(self) -> "DuesManagement":
        Shell(self.page).nav("dues")
        by_id(self.page, "segment_tab_0").wait_for(timeout=15_000)
        return self

    def segment(self, index: int) -> "DuesManagement":
        by_id(self.page, f"segment_tab_{index}").click()
        return self

    def segment_count(self) -> int:
        return by_id_prefix(self.page, "segment_tab_").count()

    # -- period accrual (STORY-07-07) --------------------------------------
    def accrue_selected_period(self, expected_message: str | None = None) -> tuple[str, str]:
        """Run 'Toplu Aidat Tahakkuku'; returns (period shown in the dialog, result message)."""
        by_id(self.page, "btn_open_accrual_dialog").click()
        by_id(self.page, "btn_confirm_period_accrual").wait_for(timeout=10_000)
        period = text_of(by_id(self.page, "accrual_dialog_period"))
        by_id(self.page, "btn_confirm_period_accrual").click()
        message = by_id(self.page, "snackbar_accrual_result")
        message.wait_for(timeout=15_000)
        if expected_message:
            expect(message).to_contain_text(expected_message, timeout=15_000)
            text = expected_message
        else:
            expect(message).to_have_text(re.compile(r".*\S.*"), timeout=15_000)
            text = message.inner_text().strip()
        message.wait_for(state="detached", timeout=15_000)  # let the snackbar go before the next action
        return period, text

    # -- bank statement import (STORY-07-02) -------------------------------
    def upload_statement(self, path: Path) -> "ImportSummary":
        by_id(self.page, "btn_open_bank_import").click()
        with self.page.expect_file_chooser() as chooser:
            by_id(self.page, "btn_import_pick_file").click()
        chooser.value.set_files(str(path))
        return ImportSummary(self.page).wait()


class ImportSummary:
    """'İçe Aktarma Ara Sonucu' dialog after a statement upload."""

    def __init__(self, page: Page):
        self.page = page

    def wait(self) -> "ImportSummary":
        by_id(self.page, "import_summary_matched").wait_for(timeout=15_000)
        return self

    @staticmethod
    def _count_and_sum(text: str) -> tuple[int, Decimal]:
        # e.g. "Eşleşen Daireler (1)₺1.400,00"
        count = int(text.split("(", 1)[1].split(")", 1)[0])
        return count, last_amount(text)

    def matched(self) -> tuple[int, Decimal]:
        return self._count_and_sum(text_of(by_id(self.page, "import_summary_matched")))

    def unmatched(self) -> tuple[int, Decimal]:
        return self._count_and_sum(text_of(by_id(self.page, "import_summary_unmatched")))

    def confirm_matched(self) -> None:
        with self.page.expect_response(
            lambda r: "/api/v1/" in r.url and r.request.method == "POST", timeout=15_000
        ):
            by_id(self.page, "btn_confirm_matched_import").click()
        by_id(self.page, "btn_confirm_matched_import").wait_for(state="detached", timeout=10_000)


class PaymentStream:
    """'💳 Canlı Kasa' segment: the payment stream with its filter chips."""

    SEGMENT = 1

    def __init__(self, page: Page):
        self.page = page

    def open(self) -> "PaymentStream":
        DuesManagement(self.page).open().segment(self.SEGMENT)
        by_id(self.page, "filter_role_chip").wait_for(timeout=15_000)
        return self

    def filter_role(self, role: str) -> "PaymentStream":
        by_id(self.page, "filter_role_chip").click()
        by_id(self.page, f"filter_role_option_{role}").click()
        return self

    def entry_ids(self) -> list[str]:
        return self.page.eval_on_selector_all(
            '[flt-semantics-identifier^="payment_entry_"]',
            "els => els.map(e => e.getAttribute('flt-semantics-identifier'))")

    def wait_for_entries(self, predicate_js: str, timeout_ms: int = 15_000) -> None:
        """Wait until the list of entry ids satisfies a JS predicate over `ids`."""
        self.page.wait_for_function(
            "pred => { const ids = [...document.querySelectorAll('[flt-semantics-identifier^=\"payment_entry_\"]')]"
            ".map(e => e.getAttribute('flt-semantics-identifier')); return new Function('ids', pred)(ids); }",
            arg=predicate_js, timeout=timeout_ms)


class CapitalProjects:
    """'🏗️ Demirbaş & Yatırım' segment (EPIC-10)."""

    def __init__(self, page: Page):
        self.page = page

    def open(self) -> "CapitalProjects":
        DuesManagement(self.page).open().segment(DuesManagement.CAPITAL_SEGMENT)
        by_id(self.page, "btn_open_capital_project_wizard").wait_for(timeout=15_000)
        return self

    def create(self, title: str, budget: str, by_land_share: bool = True, installments: int = 1) -> None:
        by_id(self.page, "btn_open_capital_project_wizard").click()
        by_id(self.page, "input_capital_project_title").wait_for(timeout=10_000)
        fill(self.page, "input_capital_project_title", title)
        fill(self.page, "input_capital_project_budget", budget)
        by_id(self.page, "radio_allocation_by_land_share" if by_land_share else "radio_allocation_equal").click()
        by_id(self.page, f"chip_installments_{installments}").click()
        by_id(self.page, "btn_submit_capital_project").click()
        by_id_prefix(self.page, "project_tab_").first.wait_for(timeout=15_000)

    def show_unit_shares(self) -> "CapitalProjects":
        by_id(self.page, "subtab_button_1").click()
        by_id_prefix(self.page, "unit_share_").first.wait_for(timeout=10_000)
        return self

    def unit_share_texts(self) -> dict[str, str]:
        """{'<block>_<unit>': 'Arsa Payı: 24/1000 • Toplam Pay: ₺285.714,29'}"""
        ids = self.page.eval_on_selector_all(
            '[flt-semantics-identifier^="unit_share_"]',
            "els => els.map(e => e.getAttribute('flt-semantics-identifier'))")
        return {i.removeprefix("unit_share_"): text_of(by_id(self.page, i)) for i in ids}

    def accrue_installment(self, number: int) -> None:
        by_id(self.page, "subtab_button_0").click()
        by_id(self.page, f"btn_accrue_installment_{number}").click()
        by_id(self.page, "btn_confirm_accrual_dialog").click()

    def installment_accrued(self, number: int):
        return by_id(self.page, f"installment_accrued_{number}")


class Occupancy:
    """Move-in / move-out from a unit row on the 'Sakinler & Malikler' tab (EPIC-08).

    The row opens the owners & residents module's unit workspace; the tenant is a person card.
    """

    def __init__(self, page: Page):
        self.page = page

    def move_in(self, unit_id: str, full_name: str, email: str, phone: str) -> None:
        UnitWorkspace(self.page).open(unit_id).action(unit_id, "tenant_move_in", "owner_rents_out", "replace_tenant")
        by_id(self.page, "module_move_in_pick_existing_btn").wait_for(timeout=10_000)
        PersonPicker(self.page, "module_move_in_pick_existing_btn").create(full_name, phone=phone, email=email)
        by_id(self.page, "module_confirm_move_in_btn").click()
        by_id(self.page, "module_confirm_move_in_btn").wait_for(state="detached", timeout=15_000)
        UnitWorkspace(self.page).close()

    def move_out(self, unit_id: str) -> None:
        UnitWorkspace(self.page).open(unit_id).action(unit_id, "move_out")
        by_id(self.page, "module_confirm_move_out_btn").click()
        by_id(self.page, "module_confirm_move_out_btn").wait_for(state="detached", timeout=15_000)
        UnitWorkspace(self.page).close()
