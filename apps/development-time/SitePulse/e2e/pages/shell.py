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

    def open_profile(self) -> "ProfileSheet":
        by_id(self.page, "btn_open_profile").click()
        by_id(self.page, "btn_logout").wait_for(timeout=10_000)
        return ProfileSheet(self.page)


class ProfileSheet:
    """'Profil & Yetki' full-screen sheet."""

    def __init__(self, page: Page):
        self.page = page

    def change_password(self, current: str, new: str) -> None:
        from support.flutter import fill
        by_id(self.page, "btn_change_password_sheet").click()
        by_id(self.page, "profile_change_password_current").wait_for(timeout=10_000)
        fill(self.page, "profile_change_password_current", current)
        fill(self.page, "profile_change_password_new", new)
        fill(self.page, "profile_change_password_confirm", new)
        by_id(self.page, "btn_submit_profile_change_password").click()
        by_id(self.page, "btn_submit_profile_change_password").wait_for(state="detached", timeout=15_000)

    def logout(self) -> None:
        by_id(self.page, "btn_logout").click()
