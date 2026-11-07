from __future__ import annotations

from playwright.sync_api import Page

from support.flutter import by_id


class Shell:
    """Elements shared by every logged-in screen: header and bottom navigation."""

    # Bottom navigation labels (BottomNavigationBarItem cannot carry a testId).
    NAV = {
        "home": "Ana Sayfa",
        "dues": "Aidat Yönetimi",        # manager only
        "residents": "Sakinler & Malikler",  # manager
        "my_flat": "Dairem",             # homeowner / resident
        "sites": "Siteler",              # SaaS admin
        "profile": "Profil & Yetki",
    }

    def __init__(self, page: Page):
        self.page = page

    def nav(self, key: str) -> None:
        label = self.NAV[key]
        self.page.locator("flt-semantics[role=button][aria-current]").filter(has_text=label).first.click()

    def logout(self) -> None:
        by_id(self.page, "btn_header_logout").click()
