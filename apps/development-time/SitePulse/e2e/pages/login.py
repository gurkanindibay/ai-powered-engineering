from __future__ import annotations

from playwright.sync_api import Page

from support.flutter import by_id, fill, wait_for_app

# role key -> (login tab id suffix, field id prefix)
ROLES = {
    "homeowner": ("homeOwner", "homeowner"),
    "manager": ("siteManager", "manager"),
    "saas": ("saasAdmin", "saas"),
    # Home residents and auditors use the home-user form; the server decides the role.
    "resident": ("homeOwner", "homeowner"),
    "auditor": ("homeOwner", "homeowner"),
}


class LoginPage:
    def __init__(self, page: Page, base_url: str):
        self.page = page
        self.base_url = base_url

    def open(self) -> "LoginPage":
        self.page.goto(self.base_url)
        wait_for_app(self.page)
        by_id(self.page, "login_tab_quickAll").wait_for()
        return self

    def login(self, role: str, email: str, password: str) -> None:
        tab, prefix = ROLES[role]
        # A tab tap right after the first frame is occasionally dropped; retry until the panel shows.
        for attempt in range(3):
            by_id(self.page, f"login_tab_{tab}").click()
            try:
                by_id(self.page, f"login_{prefix}_email").wait_for(timeout=8_000)
                break
            except Exception:
                if attempt == 2:
                    raise
        # Fields may be prefilled; fill() clears them first.
        fill(self.page, f"login_{prefix}_email", email)
        fill(self.page, f"login_{prefix}_password", password)
        by_id(self.page, f"login_{prefix}_submit").click()

    @property
    def error_banner(self):
        return by_id(self.page, "login_error_banner")

    def is_shown(self) -> bool:
        return by_id(self.page, "login_tab_quickAll").count() > 0
