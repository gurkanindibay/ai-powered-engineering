from __future__ import annotations

from playwright.sync_api import Page

from support.flutter import by_id, fill, text_of

# Ids that only exist once a role's dashboard is on screen; none may show while the password is temporary.
DASHBOARD_MARKERS = ("btn_open_profile", "btn_open_unified_dues_center", "hero_balance_amount", "btn_open_add_site",
                     "nav_home", "nav_dues", "nav_residents", "nav_sites", "nav_my_flat", "finance_tab_ledger")


class ForcePasswordChange:
    """The only screen a user with a temporary password can open, for every role (STORY-06-06)."""

    SCREEN = "screen_force_password_change"

    def __init__(self, page: Page):
        self.page = page

    @property
    def screen(self):
        return by_id(self.page, self.SCREEN)

    def wait(self, timeout_ms: int = 20_000) -> "ForcePasswordChange":
        self.screen.wait_for(timeout=timeout_ms)
        return self

    def wait_gone(self, timeout_ms: int = 20_000) -> None:
        self.screen.wait_for(state="detached", timeout=timeout_ms)

    def visible_dashboard_markers(self) -> list[str]:
        return [m for m in DASHBOARD_MARKERS if by_id(self.page, m).count() > 0]

    def _fill(self, current: str, new: str, confirm: str) -> None:
        by_id(self.page, "change_password_current").wait_for(timeout=10_000)
        fill(self.page, "change_password_current", current)
        fill(self.page, "change_password_new", new)
        fill(self.page, "change_password_confirm", confirm)

    def submit_invalid(self, current: str, new: str, confirm: str) -> str:
        """Submit values the form must reject without calling the server; returns the error shown."""
        self._fill(current, new, confirm)
        by_id(self.page, "btn_submit_change_password").click()
        error = by_id(self.page, "change_password_error")
        error.wait_for(timeout=10_000)
        return text_of(error)

    def change(self, current: str, new: str) -> None:
        """Set the permanent password and wait for the server to accept it."""
        self._fill(current, new, new)
        with self.page.expect_response(lambda r: "/api/v1/auth/change-password" in r.url, timeout=15_000) as resp:
            by_id(self.page, "btn_submit_change_password").click()
        if resp.value.status != 200:
            raise AssertionError(f"change-password -> {resp.value.status}: {resp.value.text()[:300]}")

    def logout(self) -> None:
        by_id(self.page, "btn_force_password_logout").click()
