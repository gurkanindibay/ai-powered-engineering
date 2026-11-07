from __future__ import annotations

from playwright.sync_api import Page

from support.flutter import by_id, by_id_prefix, fill


class SaasAdmin:
    def __init__(self, page: Page):
        self.page = page

    def wait(self) -> "SaasAdmin":
        by_id_prefix(self.page, "btn_edit_site_").first.wait_for(timeout=20_000)
        return self

    def site_ids(self) -> list[str]:
        return sorted(i.removeprefix("btn_edit_site_") for i in self.page.eval_on_selector_all(
            '[flt-semantics-identifier^="btn_edit_site_"]',
            "els => els.map(e => e.getAttribute('flt-semantics-identifier'))"))

    @property
    def must_change_password_banner(self):
        return by_id(self.page, "banner_must_change_password")

    def change_password(self, current: str, new: str) -> None:
        by_id(self.page, "btn_open_change_password").click()
        by_id(self.page, "change_password_current").wait_for(timeout=10_000)
        fill(self.page, "change_password_current", current)
        fill(self.page, "change_password_new", new)
        fill(self.page, "change_password_confirm", new)
        by_id(self.page, "btn_submit_change_password").click()
