from __future__ import annotations

from playwright.sync_api import Page

from support.flutter import by_id, by_id_prefix, fill

from .shell import Shell


class ManagerCockpit:
    def __init__(self, page: Page):
        self.page = page

    def wait(self) -> "ManagerCockpit":
        by_id(self.page, "btn_open_unified_dues_center").wait_for(timeout=20_000)
        return self


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
