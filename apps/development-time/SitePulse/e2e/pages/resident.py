from __future__ import annotations

from decimal import Decimal

from playwright.sync_api import Page

from support.flutter import by_id, text_of
from support.money import parse_try


class ResidentHome:
    """Homeowner / resident dashboard (hero balance card)."""

    def __init__(self, page: Page):
        self.page = page

    def wait(self) -> "ResidentHome":
        by_id(self.page, "hero_balance_amount").wait_for(timeout=20_000)
        return self

    def balance(self) -> Decimal:
        return parse_try(text_of(by_id(self.page, "hero_balance_amount")))

    def balance_label(self) -> str:
        return text_of(by_id(self.page, "hero_balance_label"))

    def overdue_badge_visible(self) -> bool:
        return by_id(self.page, "hero_overdue_badge").count() > 0

    def iban_text(self) -> str:
        return text_of(by_id(self.page, "virtual_iban_text"))

    def copy_iban(self) -> None:
        by_id(self.page, "btn_copy_iban").click()
