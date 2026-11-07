from __future__ import annotations

from playwright.sync_api import Page

from pathlib import Path

from support.flutter import by_id, by_id_prefix, fill, text_of

from .shell import Shell


class ManagerCockpit:
    def __init__(self, page: Page):
        self.page = page

    def wait(self) -> "ManagerCockpit":
        by_id(self.page, "btn_open_unified_dues_center").wait_for(timeout=20_000)
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
        """Home-owner ids that have a card (from delete_ho_<id>)."""
        return [i.removeprefix("delete_ho_") for i in self.page.eval_on_selector_all(
            '[flt-semantics-identifier^="delete_ho_"]',
            "els => els.map(e => e.getAttribute('flt-semantics-identifier'))")]

    def start_add(self) -> "AddResidentForm":
        by_id(self.page, "add_resident_btn").click()
        return AddResidentForm(self.page).wait()


class AddResidentForm:
    """Full-screen 'Yeni Daire / Sakin Ekle' form."""

    def __init__(self, page: Page):
        self.page = page

    def wait(self) -> "AddResidentForm":
        by_id(self.page, "add_resident_unit_field").wait_for(timeout=10_000)
        return self

    def fill(self, unit_no: str, full_name: str, email: str, phone: str) -> "AddResidentForm":
        fill(self.page, "add_resident_unit_field", unit_no)
        fill(self.page, "add_resident_name_field", full_name)
        fill(self.page, "add_resident_email_field", email)
        fill(self.page, "add_resident_phone_field", phone)
        return self

    def save(self) -> None:
        by_id(self.page, "btn_save_new_resident").click()


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
    def accrue_selected_period(self) -> tuple[str, str]:
        """Run 'Toplu Aidat Tahakkuku'; returns (period shown in the dialog, result message)."""
        by_id(self.page, "btn_open_accrual_dialog").click()
        by_id(self.page, "btn_confirm_period_accrual").wait_for(timeout=10_000)
        period = text_of(by_id(self.page, "accrual_dialog_period"))
        by_id(self.page, "btn_confirm_period_accrual").click()
        message = by_id(self.page, "snackbar_accrual_result")
        message.wait_for(timeout=15_000)
        text = text_of(message)
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
    def _count_and_sum(text: str) -> tuple[int, str]:
        # e.g. "Eşleşen Daireler (1)₺1400.00"
        count = int(text.split("(", 1)[1].split(")", 1)[0])
        return count, text.rsplit("₺", 1)[1].strip()

    def matched(self) -> tuple[int, str]:
        return self._count_and_sum(text_of(by_id(self.page, "import_summary_matched")))

    def unmatched(self) -> tuple[int, str]:
        return self._count_and_sum(text_of(by_id(self.page, "import_summary_unmatched")))

    def confirm_matched(self) -> None:
        by_id(self.page, "btn_confirm_matched_import").click()


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
        """{'<block>_<unit>': 'Arsa Payı: 24/1000 • Toplam Pay: ₺285714.29'}"""
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
    """Move-in / move-out actions on the 'Sakinler & Malikler' unit cards (EPIC-08)."""

    def __init__(self, page: Page):
        self.page = page

    def move_in(self, unit_id: str, full_name: str, email: str, phone: str) -> None:
        by_id(self.page, f"move_in_resident_to_{unit_id}").click()
        by_id(self.page, "move_in_name_field").wait_for(timeout=10_000)  # role defaults to TENANT
        fill(self.page, "move_in_name_field", full_name)
        fill(self.page, "move_in_email_field", email)
        fill(self.page, "move_in_phone_field", phone)
        by_id(self.page, "btn_confirm_move_in").click()
        by_id(self.page, "btn_confirm_move_in").wait_for(state="detached", timeout=15_000)

    def move_out(self, unit_id: str) -> None:
        by_id(self.page, f"move_out_resident_{unit_id}").click()
        by_id(self.page, "btn_confirm_move_out").click()
        by_id(self.page, "btn_confirm_move_out").wait_for(state="detached", timeout=15_000)
